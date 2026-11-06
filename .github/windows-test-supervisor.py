"""Supervise R diagnostics and minimize a verified quit hang.

The full-suite invocation remains a strict gate. The optional bisect command
collects evidence after that gate fails; it never changes the gate's outcome.
Requires the R runner to accept an optional second argument as its test filter.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time

ROOT = Path.cwd()
OUT = ROOT / "diagnostics"
RUNNER = ROOT / ".github/windows-test-diagnostics.R"


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


def invoke(label: str, files: list[str] | None = None,
           limit: float = 900, quit_grace: float = 30) -> dict:
    OUT.mkdir(exist_ok=True)
    checkpoint = OUT / f"{label}-checkpoints.log"
    stdout = OUT / f"{label}-stdout.log"
    stderr = OUT / f"{label}-stderr.log"
    command = ["Rscript", str(RUNNER), label]
    if files is not None:
        command.append("^(" + "|".join(re.escape(x) for x in files) + ")$")
    (OUT / f"{label}-files.json").write_text(json.dumps(files, indent=2))
    checkpoint.unlink(missing_ok=True)
    started = time.monotonic()
    quit_seen = None
    exit_status = None
    tests_returned = False
    r_error = False
    offset = 0
    carry = ""
    reason = None
    kill_detail = None
    print(f"START {label}: {len(files) if files is not None else 'all'} test files", flush=True)
    with stdout.open("wb") as out, stderr.open("wb") as err:
        proc = subprocess.Popen(command, stdout=out, stderr=err,
                                start_new_session=os.name != "nt")
        while True:
            if checkpoint.exists():
                with checkpoint.open("rb") as handle:
                    handle.seek(offset)
                    addition = handle.read()
                    offset = handle.tell()
                text = carry + addition.decode("utf-8", errors="replace")
                tests_returned |= "TESTS RETURNED" in text
                r_error |= "R ERROR:" in text
                match = re.search(r"R EXIT REQUEST: status=(\d+)", text)
                if match and quit_seen is None:
                    quit_seen = time.monotonic()
                    exit_status = int(match.group(1))
                    print(f"QUIT REQUEST {label}: status={exit_status}", flush=True)
                carry = text[-512:]
            code = proc.poll()
            if code is not None:
                reason = "success" if code == 0 else "process-failure"
                break
            now = time.monotonic()
            if quit_seen is not None and now - quit_seen >= quit_grace:
                reason = ("quit-hang" if exit_status == 0 and tests_returned and not r_error
                          else "quit-hang-after-test-error")
                kill_detail = stop_child(proc)
                break
            if now - started >= limit:
                reason = "execution-timeout"
                kill_detail = stop_child(proc)
                break
            time.sleep(1)
        code = proc.wait(timeout=15)
    # A process can exit between the final checkpoint read and poll(). Read the
    # completed file once more, then require all success evidence explicitly.
    final_text = checkpoint.read_text(encoding="utf-8", errors="replace") if checkpoint.exists() else ""
    tests_returned = "TESTS RETURNED" in final_text
    r_error = "R ERROR:" in final_text
    match = re.search(r"R EXIT REQUEST: status=(\d+)", final_text)
    if match:
        exit_status = int(match.group(1))
    if reason in ("success", "process-failure"):
        reason = ("success" if code == 0 and tests_returned and exit_status == 0 and not r_error
                  else "process-failure")
    result = dict(label=label, files=files, reason=reason, exit_code=code,
                  exit_hex=f"0x{code & 0xffffffff:08X}",
                  tests_returned=tests_returned, r_error=r_error,
                  requested_exit_status=exit_status,
                  elapsed_seconds=round(time.monotonic() - started, 3),
                  quit_grace_seconds=quit_grace, kill_detail=kill_detail,
                  stdout=str(stdout.relative_to(ROOT)),
                  stderr=str(stderr.relative_to(ROOT)),
                  checkpoints=str(checkpoint.relative_to(ROOT)))
    (OUT / f"{label}-result.json").write_text(json.dumps(result, indent=2))
    print(json.dumps(result), flush=True)
    return result


def bisect(max_probes: int, budget: float) -> None:
    full = json.loads((OUT / "full-suite-result.json").read_text())
    if full["reason"] != "quit-hang":
        print("No verified successful-test quit hang to minimize.", flush=True)
        return
    current = sorted(p.name[5:-2] for p in (ROOT / "tests/testthat").glob("test-*.R"))
    cache = {tuple(current): full}
    evidence = []
    started = time.monotonic()
    partitions = 2
    exhausted = False
    # Query streams are a source-backed ownership lead, not an assumed cause.
    # Run these small groups first, then retain only an observed reproducer.
    for candidate in (["nanoarrow_methods"],
                      ["utils_format", "formats_autodetect", "ddbs_open_dataset"]):
        remaining = budget - (time.monotonic() - started)
        if len(evidence) >= max_probes or remaining < 60:
            exhausted = True
            break
        candidate = sorted(candidate)
        result = invoke(f"subset-{len(evidence) + 1:02d}", candidate,
                        limit=min(900, remaining))
        cache[tuple(candidate)] = result
        evidence.append(result)
        if result["reason"] == "quit-hang":
            current = candidate
            break
    while len(current) > 1 and not exhausted:
        progress = False
        for index in range(partitions):
            begin = len(current) * index // partitions
            end = len(current) * (index + 1) // partitions
            candidate = current[:begin] + current[end:]
            key = tuple(candidate)
            if not candidate:
                continue
            if key not in cache:
                remaining = budget - (time.monotonic() - started)
                if len(evidence) >= max_probes or remaining < 60:
                    exhausted = True
                    break
                result = invoke(f"subset-{len(evidence) + 1:02d}", candidate,
                                limit=min(900, remaining))
                cache[key] = result
                evidence.append(result)
            if cache[key]["reason"] == "quit-hang":
                current = candidate
                partitions = max(2, partitions - 1)
                progress = True
                break
        if exhausted:
            break
        if progress:
            continue
        if partitions == len(current):
            break
        partitions = min(len(current), partitions * 2)
    summary = dict(reproducing_files=current, probes=evidence,
                   budget_exhausted=exhausted,
                   search_completed=not exhausted,
                   inconclusive_subsets=[x["label"] for x in evidence
                                         if x["reason"] not in ("success", "quit-hang")],
                   note="A reproducing subset passed assertions and hung after requesting exit 0; "
                        "the strict full-suite gate remains failed.")
    (OUT / "bisection-summary.json").write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["full-suite", "bisect"])
    parser.add_argument("--max-probes", type=int, default=16)
    parser.add_argument("--budget", type=float, default=1200)
    args = parser.parse_args()
    if args.mode == "full-suite":
        result = invoke("full-suite")
        raise SystemExit(0 if result["reason"] == "success" else 1)
    bisect(args.max_probes, args.budget)
