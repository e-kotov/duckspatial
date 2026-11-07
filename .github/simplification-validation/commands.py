"""Record real subprocess exit codes; a timeout is always a failed command."""
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import signal
import subprocess
import time


def run(command, *, cwd, env, output, timeout):
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    record = {"command": list(map(str, command)), "cwd": str(cwd),
              "started_utc": datetime.now(timezone.utc).isoformat(),
              "timeout_seconds": timeout}
    print("RUN", " ".join(record["command"]), flush=True)
    with output.with_suffix(".log").open("wb") as log:
        proc = subprocess.Popen(record["command"], cwd=cwd, env=env,
                                stdout=log, stderr=subprocess.STDOUT,
                                start_new_session=os.name != "nt")
        try:
            code = proc.wait(timeout=timeout)
            record["reason"] = "success" if code == 0 else "process-failure"
        except subprocess.TimeoutExpired:
            record["reason"] = "timeout"
            if os.name == "nt":
                killed = subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"],
                                        capture_output=True, text=True, timeout=15)
                record["kill_output"] = killed.stdout + killed.stderr
            else:
                os.killpg(proc.pid, signal.SIGKILL)
            code = proc.wait(timeout=20)
    record.update(exit_code=code, elapsed_seconds=round(time.monotonic() - started, 3))
    output.with_suffix(".json").write_text(json.dumps(record, indent=2) + "\n")
    print(output.with_suffix(".log").read_text(errors="replace")[-6000:], flush=True)
    print(json.dumps(record), flush=True)
    return record["reason"] == "success"
