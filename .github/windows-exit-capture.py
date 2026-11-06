"""Capture a native Windows quit hang without changing the reproducer's SQL.

This is diagnostic-branch tooling. A captured hang remains a failed process
exit; the debugger result must never convert it into a passing package check.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
from types import SimpleNamespace

import psutil

ROOT = Path.cwd()
OUT = ROOT / "diagnostics"
OUT.mkdir(exist_ok=True)
(OUT / "symbols").mkdir(exist_ok=True)
sys.dont_write_bytecode = True
CDB = Path(os.environ["CAPTURE_CDB"])


def clean_environment() -> dict[str, str]:
    # A full process dump includes its environment. Only pass Windows/R runtime
    # variables; no CI, GitHub, cloud, or repository credentials enter R or CDB.
    allowed = {
        "PATH", "PATHEXT", "SYSTEMROOT", "WINDIR", "SYSTEMDRIVE", "COMSPEC",
        "TEMP", "TMP", "USERPROFILE", "APPDATA", "LOCALAPPDATA", "HOMEDRIVE",
        "HOMEPATH", "PROGRAMFILES", "PROGRAMFILES(X86)", "PROGRAMW6432", "OS",
        "PROCESSOR_ARCHITECTURE", "PROCESSOR_IDENTIFIER", "NUMBER_OF_PROCESSORS",
        "R_HOME", "R_ARCH", "R_LIBS", "R_LIBS_USER", "R_LIBS_SITE", "R_USER",
        "R_ENVIRON", "R_ENVIRON_USER", "R_PROFILE", "R_PROFILE_USER",
        "LANG", "LC_ALL", "TZ",
    }
    return {k: v for k, v in os.environ.items() if k.upper() in allowed}


ENV = clean_environment()


def save_json(path: Path, value) -> None:
    path.write_text(json.dumps(value, indent=2), encoding="utf-8")


def sha256(path: Path) -> str:
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def process_info(pid: int) -> dict:
    info = {"pid": pid}
    try:
        proc = psutil.Process(pid)
        info.update(ppid=proc.ppid(), name=proc.name(), exe=proc.exe(),
                    created=proc.create_time(), status=proc.status(),
                    thread_count=proc.num_threads(),
                    threads=[x._asdict() for x in proc.threads()])
    except (psutil.NoSuchProcess, psutil.AccessDenied, OSError) as error:
        info["error"] = str(error)
    return info


def process_tree(launcher_pid: int, r_pid: int | None) -> list[dict]:
    ids = {launcher_pid}
    if r_pid is not None:
        ids.add(r_pid)
    try:
        ids.update(p.pid for p in psutil.Process(launcher_pid).children(recursive=True))
    except (psutil.NoSuchProcess, psutil.AccessDenied):
        pass
    return [process_info(pid) for pid in sorted(ids)]


def save_native_binaries(pid: int, folder: Path) -> list[dict]:
    names = {"r.dll", "duckdb.dll", "spatial.duckdb_extension", "rscript.exe",
             "libwinpthread-1.dll", "libstdc++-6.dll", "libgcc_s_seh-1.dll"}
    try:
        paths = sorted({m.path for m in psutil.Process(pid).memory_maps()
                        if Path(m.path).name.lower() in names})
    except (psutil.NoSuchProcess, psutil.AccessDenied, OSError) as error:
        return [{"error": str(error)}]
    entries = []
    for name in paths:
        source = Path(name)
        entry = {"source_path": name}
        try:
            digest = sha256(source)
            target = OUT / "native-binaries" / digest[:12] / source.name
            target.parent.mkdir(parents=True, exist_ok=True)
            if not target.exists():
                shutil.copy2(source, target)
            entry.update(sha256=digest, size=source.stat().st_size,
                         artifact_path=str(target.relative_to(ROOT)))
        except OSError as error:
            entry["error"] = str(error)
        entries.append(entry)
    save_json(folder / f"pid-{pid}-binaries.json", entries)
    return entries


def run_debugger(command: list[str], log: Path, timeout: int) -> dict:
    started = time.monotonic()
    result = {"command": command, "timeout_seconds": timeout}
    with log.open("wb") as output:
        try:
            completed = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT,
                                       env=ENV, timeout=timeout)
            result["exit_code"] = completed.returncode
        except subprocess.TimeoutExpired:
            result["timed_out"] = True
        except OSError as error:
            result["error"] = str(error)
    result["elapsed_seconds"] = round(time.monotonic() - started, 3)
    return result


captures = []
current_label = ""
capture_started = time.monotonic()


def capture_process(proc: subprocess.Popen) -> None:
    if captures:
        # One complete native capture plus the paired control is sufficient for
        # this run. Preserve later hangs as failures without extending the job.
        return
    folder = OUT / (current_label + "-native")
    folder.mkdir(exist_ok=True)
    checkpoint = OUT / f"{current_label}-checkpoints.log"
    text = checkpoint.read_text(encoding="utf-8", errors="replace") if checkpoint.exists() else ""
    match = re.search(r"PROCESS START: .* PID=(\d+)", text)
    r_pid = int(match.group(1)) if match else None
    tree = process_tree(proc.pid, r_pid)
    save_json(folder / "process-tree-before.json", tree)
    # First capture the authoritative R PID. If it has already gone away,
    # capture surviving launchers instead and record that distinction.
    live = [x["pid"] for x in tree if "error" not in x]
    targets = ([r_pid] if r_pid in live else [])
    targets += [pid for pid in live if pid not in targets]
    targets = targets[:3]
    result = {"label": current_label, "launcher_pid": proc.pid, "r_pid": r_pid,
              "r_alive_before_capture": r_pid in live,
              "checkpoints": text.splitlines()[-12:], "targets": []}
    print(f"CAPTURE {current_label}: launcher={proc.pid}, R={r_pid}, live={live}", flush=True)
    for pid in targets:
        # Full memory for R (or first surviving wrapper); smaller dumps for
        # additional launchers preserve their thread/module state as well.
        full = pid == targets[0]
        dump = folder / f"pid-{pid}.dmp"
        script = folder / f"pid-{pid}-capture.cdb"
        script.write_text(
            '.echo NATIVE_CAPTURE_BEGIN\n'
            f'.dump /o /{"mA" if full else "mFhut"} "{dump.as_posix()}"\n'
            '.echo THREAD_STACKS\n~* kv 100\n.echo MODULES\nlmv\n'
            '.echo CRITICAL_SECTIONS\n!ntsdexts.locks\n'
            '.echo NATIVE_CAPTURE_COMPLETE\nqd\n', encoding="utf-8")
        binaries = save_native_binaries(pid, folder)
        debugger_log = folder / f"pid-{pid}-capture.log"
        capture = run_debugger(
            [str(CDB), "-pv", "-pd", "-p", str(pid), "-y", str(OUT / "symbols"),
             "-logo", str(debugger_log), "-cf", str(script)],
            folder / f"pid-{pid}-capture-console.log", 90)
        capture.update(pid=pid, is_r_process=pid == r_pid,
                       dump_kind="full-accessible-memory" if full else "thread-module-handle",
                       native_binaries=binaries)
        capture_text = debugger_log.read_text(encoding="utf-8", errors="replace") if debugger_log.exists() else ""
        capture["dump_write_confirmed"] = "Dump successfully written" in capture_text
        capture["capture_commands_completed"] = "NATIVE_CAPTURE_COMPLETE" in capture_text
        if dump.exists():
            with dump.open("rb") as handle:
                capture["minidump_magic_valid"] = handle.read(4) == b"MDMP"
            capture.update(dump=str(dump.relative_to(ROOT)), size=dump.stat().st_size,
                           sha256=sha256(dump))
        result["targets"].append(capture)
        save_json(folder / "capture-result.json", result)
    result["process_tree_after_detach"] = process_tree(proc.pid, r_pid)
    result["launcher_alive_after_detach"] = proc.poll() is None
    captures.append(result)
    save_json(OUT / "capture-summary.json", captures)


def capture_before_kill(proc: subprocess.Popen) -> str:
    try:
        capture_process(proc)
    except Exception as error:
        save_json(OUT / f"{current_label}-capture-error.json",
                  {"type": type(error).__name__, "error": str(error)})
        print(f"Native capture failed: {type(error).__name__}: {error}", flush=True)
    finally:
        # Even a missing checkpoint, debugger failure, or process race must not
        # bypass the original supervisor's strict termination behavior.
        killed = original_stop(proc)
    save_json(OUT / f"{current_label}-process-tree-after-kill.json", process_tree(proc.pid, None))
    return killed


spec = importlib.util.spec_from_file_location("supervisor", ROOT / ".github/windows-test-supervisor.py")
supervisor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(supervisor)
supervisor.RUNNER = ROOT / ".github/windows-native-geometry.R"
supervisor.subprocess = SimpleNamespace(
    Popen=lambda *args, **kwargs: subprocess.Popen(*args, env=ENV, **kwargs),
    run=lambda *args, **kwargs: subprocess.run(*args, env=ENV, **kwargs),
)
original_stop = supervisor.stop_child
supervisor.stop_child = capture_before_kill

save_json(OUT / "capture-tooling.json", {
    "cdb": str(CDB), "cdb_sha256": sha256(CDB),
    "launcher_on_path": shutil.which("Rscript"),
    "reproducer_sha256": sha256(supervisor.RUNNER),
    "supervisor_sha256": sha256(ROOT / ".github/windows-test-supervisor.py"),
    "environment_variable_names": sorted(ENV),
    "note": "R/CDB receive only allowlisted runtime variables, never CI credentials.",
})

results = []
# Reuse the exact existing reproduction and a paired one-thread control. Do not
# change DuckDB SQL, add a sleep in R, or globally reduce production threads.
for repetition in range(1, 4):
    current_label = "raw--all--base--t0"
    if repetition > 1:
        previous = OUT / f"attempt-{repetition - 1}"
        previous.mkdir(exist_ok=True)
        for path in list(OUT.glob(current_label + "*")):
            shutil.move(str(path), previous / path.name)
    result = supervisor.invoke(current_label, limit=180, quit_grace=30)
    result["attempt"] = repetition
    results.append(result)
    save_json(OUT / "native-exit-results.json", results)
    if captures:
        break

current_label = "raw--all--base--t1"
results.append(supervisor.invoke(current_label, limit=180, quit_grace=30))
save_json(OUT / "native-exit-results.json", results)

# Symbolic analysis happens after preservation and termination, against the
# saved file. Network/symbol delays cannot prevent the initial native capture.
for capture in captures:
    for target in capture["targets"]:
        if not target.get("minidump_magic_valid"):
            continue
        dump = ROOT / target["dump"]
        analysis = dump.with_suffix(".analysis.log")
        commands = (
            '.reload; .echo THREAD_STACKS; ~* kv 100; .echo MODULES; lmv; '
            '.echo CRITICAL_SECTIONS; !ntsdexts.locks; '
            '.echo HANG_ANALYSIS; !analyze -hang; .echo ANALYSIS_COMPLETE; q'
        )
        target["analysis"] = run_debugger(
            [str(CDB), "-z", str(dump), "-y",
             f"srv*{OUT / 'symbols'}*https://msdl.microsoft.com/download/symbols",
             "-logo", str(analysis), "-c", commands],
            dump.with_suffix(".analysis-console.log"), 120)
        save_json(OUT / "capture-summary.json", captures)

print(json.dumps({"results": results, "captured_processes": sum(len(x["targets"]) for x in captures),
                  "elapsed_seconds": round(time.monotonic() - capture_started, 3)}, indent=2), flush=True)
raise SystemExit(0 if results and all(x["reason"] == "success" for x in results) else 1)
