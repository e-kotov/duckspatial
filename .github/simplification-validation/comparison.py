"""Run reference and candidate under the same installed R/Python dependencies."""
import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

from commands import run


def package_versions(path):
    with path.open(newline="") as stream:
        return sorted({(row["Package"], row["Version"]) for row in csv.DictReader(stream)
                       if row["Package"] != "duckspatial"})


def show_test_logs(directory, label):
    for suffix in ("stdout.log", "stderr.log", "totals.json"):
        path = directory / f"{label}-{suffix}"
        print(f"::group::{label} {suffix}", flush=True)
        print(path.read_text(encoding="utf-8", errors="replace") if path.exists() else "Not produced", flush=True)
        print("::endgroup::", flush=True)


parser = argparse.ArgumentParser()
parser.add_argument("--workspace", type=Path, required=True)
args = parser.parse_args()
workspace = args.workspace.resolve()
harness = workspace / "harness/.github/simplification-validation"
preserved = workspace / "harness/.github/upstream-validation"
config = json.loads((harness / "sources.json").read_text())
evidence = workspace / "evidence"
evidence.mkdir(exist_ok=True)
interop = os.name != "nt"
results = {}
all_ok = True

if interop:
    (evidence / "python-versions.txt").write_text(
        subprocess.check_output([sys.executable, "-m", "pip", "freeze"], text=True))

for label in ("reference7", "candidate", "reference8", "stack"):
    source = workspace / label
    out = evidence / label
    out.mkdir(exist_ok=True)
    library = Path(os.environ["RUNNER_TEMP"]) / f"simplification-{label}-library"
    library.mkdir(exist_ok=True)
    versions = "V1,V2" if label in ("reference7", "candidate") else "V1,V1.1,V2"
    library_paths = os.pathsep.join(filter(None, [str(library), os.environ.get("R_LIBS", "")]))
    env = dict(os.environ, R_LIBS=library_paths,
               EXPECTED_PACKAGE_LIBRARY=str(library),
               GEOPARQUET_FIXTURE_VERSIONS=versions,
               DIAGNOSTICS_DIR=str(out / "tests"))
    record = {"source_sha": config[label], "fixture_versions": versions, "stages": {}}
    results[label] = record
    record["stages"]["install"] = run(
        ["R", "CMD", "INSTALL", f"--library={library}", str(source)],
        cwd=source, env=env, output=out / "install", timeout=180)
    if not record["stages"]["install"]:
        all_ok = False
        continue

    record["stages"]["environment"] = run(
        ["Rscript", str(harness / "environment.R"), str(out / "environment")],
        cwd=source, env=env, output=out / "environment-record", timeout=120)
    record["stages"]["regression"] = run(
        [sys.executable, str(preserved / "windows-test-supervisor.py"),
         "--runner", str(harness / "run-tests.R"), "--label", label,
         "--expected-sha", config[label], "--filter", "^geoparquet", "--limit", "360"],
        cwd=source, env=env, output=out / "regression", timeout=450)
    show_test_logs(out / "tests", label)

    # The additional candidate file is an independent contract probe against
    # each installed reference. None of the reference's source files is edited.
    if label.startswith("reference"):
        extra = workspace / "candidate/tests/testthat/test-geoparquet-options.R"
        if not extra.is_file():
            raise FileNotFoundError(extra)
        record["extra_contract_test_sha256"] = hashlib.sha256(extra.read_bytes()).hexdigest()
        extra_env = dict(env, EXTRA_CONTRACT_TEST_FILE=str(extra),
                         DIAGNOSTICS_DIR=str(out / "extra-tests"))
        record["stages"]["additional-contract"] = run(
            [sys.executable, str(preserved / "windows-test-supervisor.py"),
             "--runner", str(harness / "run-tests.R"), "--label", label + "-extra",
             "--expected-sha", config[label], "--limit", "180"],
            cwd=source, env=extra_env, output=out / "additional-contract", timeout=270)
        show_test_logs(out / "extra-tests", label + "-extra")

    if interop:
        fixtures = out / "geoparquet-interop"
        record["stages"]["generate-fixtures"] = run(
            ["Rscript", str(harness / "interop/generate_geoparquet_fixtures.R"), str(fixtures)],
            cwd=source, env=env, output=out / "generate-fixtures", timeout=180)
        if record["stages"]["generate-fixtures"]:
            for script in ("validate_geoparquet.py", "validate_geoparquet_readers.py", "run_core_conformance.py"):
                record["stages"][script] = run(
                    [sys.executable, str(harness / "interop" / script), str(fixtures)],
                    cwd=source, env=env, output=out / script.replace(".py", ""), timeout=240)
        if label in ("candidate", "stack"):
            record["stages"]["generated-help-consistency"] = run(
                ["Rscript", str(harness / "document.R"), "check", str(out / "documentation")],
                cwd=source, env=env, output=out / "documentation", timeout=180)
    record["passed"] = all(record["stages"].values())
    all_ok &= record["passed"]
    (evidence / "comparison-results.json").write_text(json.dumps(results, indent=2) + "\n")

dependencies = {}
for label in results:
    path = evidence / label / "environment/R-installed-packages.csv"
    if path.exists():
        dependencies[label] = package_versions(path)
dependencies_equal = len(dependencies) == 4 and all(
    versions == dependencies["reference7"] for versions in dependencies.values())
(evidence / "dependency-comparison.json").write_text(json.dumps({
    "same_dependencies_for_all_sources": dependencies_equal,
    "versions": dependencies,
}, indent=2) + "\n")
all_ok &= dependencies_equal

if interop:
    for reference, candidate in (("reference7", "candidate"), ("reference8", "stack")):
        all_ok &= run(
            [sys.executable, str(harness / "compare-files.py"),
             str(evidence / reference / "geoparquet-interop"),
             str(evidence / candidate / "geoparquet-interop")],
            cwd=workspace, env=dict(os.environ), output=evidence / f"equivalence-{candidate}", timeout=180)

summary = {"all_required_stages_passed": all_ok, "independent_interoperability_run": interop,
           "same_dependencies_for_all_sources": dependencies_equal, "sources": results}
(evidence / "comparison-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps(summary, indent=2))
raise SystemExit(0 if all_ok else 1)
