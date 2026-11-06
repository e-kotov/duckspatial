"""Run independent DBI/DuckDB processes; no duckspatial or testthat load."""
from pathlib import Path
import importlib.util
import json
import sys
import time

ROOT = Path.cwd()
OUT = ROOT / "diagnostics"
OUT.mkdir(exist_ok=True)
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("supervisor", ROOT / ".github/windows-test-supervisor.py")
supervisor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(supervisor)
supervisor.RUNNER = ROOT / ".github/windows-native-geometry.R"

cases = [(mode, stack, "t0")
         for mode in ("read", "geojson", "shapefile", "shapefile-mismatch")
         for stack in ("base", "sf")]
# Keep normal defaults as the primary control; this paired comparison merely
# tests a possible worker-lifetime mechanism and is not a production workaround.
cases += [("all", "base", "t0"), ("all", "base", "t1"),
          ("all", "sf", "t0"), ("all", "sf", "t1")]
results = []
started = time.monotonic()
budget = 24 * 60
for mode, stack, threads in cases:
    remaining = budget - (time.monotonic() - started)
    if remaining < 60:
        raise RuntimeError("Native-probe budget exhausted; partial results preserved")
    label = f"raw--{mode}--{stack}--{threads}"
    results.append(supervisor.invoke(label, limit=min(180, remaining)))
    (OUT / "native-summary.json").write_text(json.dumps(results, indent=2))
print(json.dumps(results, indent=2), flush=True)
raise SystemExit(0 if all(x["reason"] == "success" for x in results) else 1)
