"""Verify frozen inputs, unmodified regression files and preserved validators."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def git(root, *args):
    return subprocess.check_output(["git", *args], cwd=root, text=True).strip()


def verify(workspace, config, labels):
    harness = workspace / "harness"
    expected = json.loads((harness / ".github/simplification-validation/preserved-harness.json").read_text())
    for path, digest in expected["files"].items():
        assert hashlib.sha256((harness / path).read_bytes()).hexdigest() == digest, path
    recorded = {"validation_harness_sha": git(harness, "rev-parse", "HEAD"),
                "preserved_harness": expected, "sources": {}, "regression_files": {}}
    for label in labels:
        source = workspace / label
        assert git(source, "rev-parse", "HEAD") == config[label], label
        assert not git(source, "status", "--porcelain", "--untracked-files=no"), label
        recorded["sources"][label] = config[label]
    for reference, candidate in (("reference7", "candidate"), ("reference8", "stack")):
        if reference not in labels or candidate not in labels:
            continue
        for path in sorted((workspace / reference / "tests/testthat").glob("test-geoparquet-*.R")):
            relative = path.relative_to(workspace / reference)
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            other = workspace / candidate / relative
            assert other.read_bytes() == path.read_bytes(), (candidate, relative)
            recorded["regression_files"].setdefault(candidate, {})[str(relative)] = digest
    return recorded


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--labels", nargs="+", default=["reference7", "candidate", "reference8", "stack"])
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    config = json.loads((args.workspace / "harness/.github/simplification-validation/sources.json").read_text())
    result = verify(args.workspace, config, args.labels)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
