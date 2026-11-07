"""Characterize identifier handling in two frozen packages, without editing them."""
import json
import os
from pathlib import Path

from commands import run

workspace = Path.cwd()
harness = workspace / "harness/.github/simplification-validation"
config = json.loads((harness / "sources.json").read_text())
evidence = workspace / "identifier-evidence"
evidence.mkdir(exist_ok=True)
success = True
for label in ("reference7", "candidate"):
    source = workspace / label
    out = evidence / label
    out.mkdir(exist_ok=True)
    library = Path(os.environ["RUNNER_TEMP"]) / f"identifier-probe-{label}"
    library.mkdir(exist_ok=True)
    env = dict(os.environ)
    env["R_LIBS"] = os.pathsep.join(filter(None, (str(library), env.get("R_LIBS"))))
    installed = run(["R", "CMD", "INSTALL", f"--library={library}", str(source)],
                    cwd=source, env=env, output=out / "install", timeout=180)
    success &= installed
    if installed:
        success &= run(["Rscript", str(harness / "probe-identifiers.R"), label,
                        config[label], str(out), str(library)],
                       cwd=source, env=env, output=out / "probe", timeout=180)

reports = {}
for label in ("reference7", "candidate"):
    path = evidence / label / "identifiers.json"
    if path.exists():
        reports[label] = json.loads(path.read_text())
if len(reports) == 2:
    for key, reference in reports["reference7"]["records"].items():
        candidate = reports["candidate"]["records"][key]
        print(key, reference["outcome"], candidate["outcome"],
              "DIFFERENT" if reference["outcome"] != candidate["outcome"] else "same")
print(json.dumps({"probe_execution_succeeded": success}, indent=2))
raise SystemExit(0 if success else 1)
