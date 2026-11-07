"""Diagnostic-only supervisor adapted from PR #5's windows-test-supervisor.py.

Preserves a strict process-exit gate. No changed tests, skips, mocks or connection
settings. Run from an exact source checkout; the harness may live elsewhere.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time


def stop_child(proc: subprocess.Popen) -> str:
    if proc.poll() is not None:
        return "already exited"
    if os.name == "nt":
        killed = subprocess.run(
            ["taskkill", "/PID", str(proc.pid), "/T", "/F"],
            capture_output=True, text=True, timeout=10,
        )
        detail = killed.stdout + killed.stderr
    else:
        os.killpg(proc.pid, signal.SIGKILL)
        detail = "killed diagnostic child process group"
    proc.wait(timeout=15)
    return detail


def windows_evidence(out: Path, label: str, started_utc: str, pid: int,
                     *, process_only: bool = False) -> None:
    if os.name != "nt":
        return
    env = dict(os.environ, DIAGNOSTIC_PID=str(pid), DIAGNOSTIC_START=started_utc)
    process_script = r"""
    $all = @(Get-CimInstance Win32_Process)
    $selected = @([int]$env:DIAGNOSTIC_PID)
    do {
      $oldCount = $selected.Count
      $selected += @($all | Where-Object { $_.ParentProcessId -in $selected } |
        Select-Object -ExpandProperty ProcessId)
      $selected = @($selected | Select-Object -Unique)
    } while ($selected.Count -gt $oldCount)
    $all | Where-Object { $_.ProcessId -in $selected } |
      Select-Object ProcessId, ParentProcessId, Name, ExecutablePath, CommandLine |
      ConvertTo-Json -Depth 4
    """
    event_script = r"""
    Get-WinEvent -FilterHashtable @{
      LogName = 'Application'; StartTime = [DateTime]::Parse($env:DIAGNOSTIC_START)
    } -ErrorAction SilentlyContinue |
      Where-Object { $_.Id -in 1000, 1001 } |
      Select-Object TimeCreated, Id, ProviderName, Message |
      ConvertTo-Json -Depth 4
    """
    requests = [("processes", process_script)]
    if not process_only:
        requests.append(("crash-events", event_script))
    for suffix, script in requests:
        try:
            result = subprocess.run(
                ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script],
                capture_output=True, timeout=20, env=env,
            )
            (out / f"{label}-{suffix}.log").write_bytes(result.stdout + result.stderr)
        except (OSError, subprocess.TimeoutExpired) as exc:
            (out / f"{label}-{suffix}.log").write_text(str(exc), encoding="utf-8")


def invoke(args: argparse.Namespace) -> dict:
    root = Path.cwd()
    out = Path(os.environ.get("DIAGNOSTICS_DIR", "diagnostics")).resolve()
    out.mkdir(parents=True, exist_ok=True)
    sha = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    if sha != args.expected_sha:
        raise RuntimeError(f"Expected source {args.expected_sha}, checked out {sha}")
    dirty = subprocess.check_output(
        ["git", "status", "--porcelain", "--untracked-files=no"], text=True)
    if dirty:
        raise RuntimeError(f"Tracked source files were changed before diagnostics: {dirty}")
    runner = Path(args.runner).resolve()
    label = args.label
    checkpoint = out / f"{label}-checkpoints.log"
    stdout = out / f"{label}-stdout.log"
    stderr = out / f"{label}-stderr.log"
    command = ["Rscript", str(runner), label]
    if args.filter:
        command.append(args.filter)
    env = dict(os.environ, DIAGNOSTICS_DIR=str(out))
    if args.case:
        env["NATIVE_CASE"] = args.case
    checkpoint.unlink(missing_ok=True)
    started_utc = datetime.now(timezone.utc).isoformat()
    started = time.monotonic()
    quit_seen = None
    exit_status = None
    reason = None
    kill_detail = None
    process_captured = False
    print(f"START {label}: {sha}, filter={args.filter}, case={args.case}", flush=True)
    with stdout.open("wb") as fout, stderr.open("wb") as ferr:
        proc = subprocess.Popen(command, stdout=fout, stderr=ferr, env=env,
                                start_new_session=os.name != "nt")
        while True:
            checkpoints = checkpoint.read_text(encoding="utf-8", errors="replace") if checkpoint.exists() else ""
            returned = "TESTS RETURNED" in checkpoints or "NATIVE WORKLOAD RETURNED" in checkpoints
            r_error = " R ERROR:" in checkpoints
            match = re.search(r"R EXIT REQUEST: status=(\d+)", checkpoints)
            if match and quit_seen is None:
                quit_seen = time.monotonic()
                exit_status = int(match.group(1))
                print(f"QUIT REQUEST {label}: status={exit_status}", flush=True)
            code = proc.poll()
            if code is not None:
                reason = "success" if code == 0 else "process-failure"
                break
            now = time.monotonic()
            if not process_captured and now - started >= 5:
                windows_evidence(out, label + "-running", started_utc, proc.pid, process_only=True)
                process_captured = True
            if quit_seen is not None and now - quit_seen >= args.quit_grace:
                reason = ("quit-hang" if exit_status == 0 and returned and not r_error
                          else "quit-hang-after-test-error")
                windows_evidence(out, label + "-before-kill", started_utc, proc.pid, process_only=True)
                kill_detail = stop_child(proc)
                break
            if now - started >= args.limit:
                reason = "execution-timeout"
                windows_evidence(out, label + "-before-kill", started_utc, proc.pid, process_only=True)
                kill_detail = stop_child(proc)
                break
            time.sleep(1)
        code = proc.wait(timeout=15)
    # Final read closes the race between the last marker and child exit.
    final_text = checkpoint.read_text(encoding="utf-8", errors="replace") if checkpoint.exists() else ""
    tests_returned = "TESTS RETURNED" in final_text
    native_returned = "NATIVE WORKLOAD RETURNED" in final_text
    r_error = " R ERROR:" in final_text
    match = re.search(r"R EXIT REQUEST: status=(\d+)", final_text)
    if match:
        exit_status = int(match.group(1))
    if reason in ("success", "process-failure"):
        reason = ("success" if code == 0 and (tests_returned or native_returned)
                  and exit_status == 0 and not r_error else "process-failure")
    result = dict(
        label=label, source_sha=sha, runner=str(runner),
        runner_sha256=hashlib.sha256(runner.read_bytes()).hexdigest(),
        command=command, test_filter=args.filter, native_case=args.case,
        reason=reason, exit_code=code, exit_hex=f"0x{code & 0xffffffff:08X}",
        tests_returned=tests_returned, native_workload_returned=native_returned,
        r_error=r_error, requested_exit_status=exit_status,
        elapsed_seconds=round(time.monotonic() - started, 3),
        quit_grace_seconds=args.quit_grace, kill_detail=kill_detail,
        started_utc=started_utc, launcher_pid=proc.pid, source_directory=str(root),
        stdout=str(stdout), stderr=str(stderr), checkpoints=str(checkpoint),
    )
    (out / f"{label}-result.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result), flush=True)
    windows_evidence(out, label, started_utc, proc.pid)
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--runner", required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--expected-sha", required=True)
    parser.add_argument("--filter")
    parser.add_argument("--case")
    parser.add_argument("--limit", type=float, default=900)
    parser.add_argument("--quit-grace", type=float, default=30)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_-]+", args.label):
        parser.error("label must use only letters, numbers, underscores or hyphens")
    if not re.fullmatch(r"[0-9a-f]{40}", args.expected_sha):
        parser.error("expected SHA must be a full lowercase hexadecimal commit SHA")
    result = invoke(args)
    raise SystemExit(0 if result["reason"] == "success" else 1)
