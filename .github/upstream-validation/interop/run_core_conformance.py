"""Run the independent core validator on every fresh physical fixture."""
from collections import Counter
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1] if len(sys.argv) > 1 else "geoparquet-interop")
paths = sorted(path for path in root.rglob("*.parquet") if path.is_file())
assert len(paths) == 34, f"Expected 34 physical fixtures, found {len(paths)}"
reports = []
counts = Counter()
versions = Counter()
failed = False
for path in paths:
    result = subprocess.run(
        ["geoparquet-validator", "check", str(path), "--class", "core", "--json"],
        capture_output=True, text=True, check=False,
    )
    report = json.loads(result.stdout)
    core = [item for item in report["outcomes"] if item["id"].startswith("/conf/core/")]
    assert core and not report["sampled"], str(path)
    counts.update(item["status"] for item in core)
    versions[report["version"]] += 1
    bad = result.returncode != 0 or any(item["status"] not in ("pass", "skip") for item in core)
    failed |= bad
    reports.append({"path": str(path.relative_to(root)),
                    "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                    "exit_code": result.returncode, "stderr": result.stderr,
                    "report": report})
    print("CORE_FAIL" if bad else "CORE_PASS", path.relative_to(root), flush=True)

summary = {"physical_files": len(paths), "files_by_version": dict(versions),
           "core_outcomes": dict(counts), "failed": failed, "files": reports}
(root / "core-conformance.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
print(json.dumps({key: value for key, value in summary.items() if key != "files"}))
raise SystemExit(1 if failed else 0)
