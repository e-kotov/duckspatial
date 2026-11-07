"""Reproduce the before/after counts without mixing code, help and tests."""
from collections import Counter
import json
from pathlib import Path
import subprocess

REFS = {
    "main": "677ed965894f20b5f83bdc6a389f42ccddb6a7ba",
    "reference7": "04c34956cb71d2ab6d23072fc9774e9c4d09bc8d",
    "candidate": "22de905bc18988c4cd0e56eafe6cb6dba50248ae",
}


def read(ref, path):
    result = subprocess.run(["git", "show", f"{ref}:{path}"],
                            text=True, capture_output=True)
    if result.returncode and not (ref == REFS["main"] and path == "R/io_geoparquet.R"):
        result.check_returncode()
    return result.stdout if result.returncode == 0 else ""


results = {}
for label, ref in REFS.items():
    files, totals = {}, Counter()
    for path in ("R/io_geoparquet.R", "R/io_write_dataset.R"):
        source = read(ref, path)
        counts = Counter(
            "blank" if not line.strip() else
            "roxygen" if line.lstrip().startswith("#'") else
            "comment" if line.lstrip().startswith("#") else "code"
            for line in source.splitlines()
        )
        files[path] = {"total": len(source.splitlines()), **counts}
        totals.update(counts)
        if path == "R/io_write_dataset.R":
            doc = source.split("ddbs_write_dataset <- function(", 1)[0]
            files["public_roxygen"] = {
                "lines": len(doc.splitlines()),
                "words_excluding_roxygen_prefix": len(doc.replace("#'", "").split()),
            }
    help_text = read(ref, "man/ddbs_write_dataset.Rd")
    files["generated_help"] = {"lines": len(help_text.splitlines())}
    files["r_totals"] = dict(totals)
    tests = subprocess.check_output(
        ["git", "ls-tree", "-r", "--name-only", ref, "tests/testthat"], text=True
    ).splitlines()
    geoparquet = [path for path in tests if Path(path).name.startswith("test-geoparquet-")]
    files["geoparquet_tests"] = {
        "files": len(geoparquet),
        "lines": sum(len(read(ref, path).splitlines()) for path in geoparquet),
    }
    results[label] = {"source_sha": ref, **files}

print(json.dumps(results, indent=2))
