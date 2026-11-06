"""Debug-branch-only test-case isolation; no package source modifications."""
from pathlib import Path
import importlib.util
import json
import shutil
import subprocess
import sys
import textwrap
import time

ROOT = Path.cwd()
OUT = ROOT / "diagnostics"
OUT.mkdir(exist_ok=True)
sys.dont_write_bytecode = True

# Reuse exactly the package diagnostics runner, including setup/helper loading,
# native boundary tracing, package unload, GC, and the process-exit checkpoint.
workflow = (ROOT / ".github/workflows/windows-geoparquet-diagnostics.yaml").read_text()
start = "          @'\n"
end = "          '@ | Set-Content -Path .github/windows-test-diagnostics.R"
assert workflow.count(end) == 1, "Diagnostic runner extraction marker changed"
runner = textwrap.dedent(workflow.split(start, 1)[1].split(end, 1)[0])
assert "test_filter" in runner and "SELECTED TEST FILES" in runner
(ROOT / ".github/windows-test-diagnostics.R").write_text(runner)

splitter = OUT / "split-validation-cases.R"
splitter.write_text(r'''
source_file <- "tests/testthat/test-ddbs_write_dataset-validation.R"
exprs <- parse(source_file, keep.source = FALSE)
is_test <- vapply(exprs, function(x) is.call(x) && identical(x[[1L]], as.name("test_that")), logical(1))
stopifnot(sum(is_test) == 8L, sum(!is_test) == 1L)
prefix <- unlist(lapply(exprs[!is_test], deparse, width.cutoff = 500L))
stopifnot(identical(prefix, "testthat::skip_on_cran()"))
tests <- exprs[is_test]
for (i in seq_along(tests)) {
  code <- c(prefix, deparse(tests[[i]], width.cutoff = 500L))
  path <- file.path("diagnostics", sprintf("validation-case-%02d.R", i))
  writeLines(code, path)
  stopifnot(identical(parse(path, keep.source = FALSE)[[2L]], tests[[i]]))
  writeLines(as.character(tests[[i]][[2L]]), sub("[.]R$", "-title.txt", path))
}
cat("Validated eight original top-level test expressions and shared prefix.\n")
''')
subprocess.run(["Rscript", str(splitter)], check=True)

spec = importlib.util.spec_from_file_location("supervisor", ROOT / ".github/windows-test-supervisor.py")
supervisor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(supervisor)

temporary_test = ROOT / "tests/testthat/test-windows-exit-case.R"
assert not temporary_test.exists(), "Refusing to replace an existing test file"
results = []
started = time.monotonic()
budget = 24 * 60
try:
    for index in range(1, 9):
        remaining = budget - (time.monotonic() - started)
        if remaining < 60:
            raise RuntimeError("Case-probe budget exhausted; partial results preserved")
        label = f"validation-case-{index:02d}"
        shutil.copyfile(OUT / f"{label}.R", temporary_test)
        result = supervisor.invoke(label, ["windows-exit-case"], limit=min(180, remaining))
        result["title"] = (OUT / f"{label}-title.txt").read_text().strip()
        results.append(result)
        temporary_test.unlink()
        (OUT / "case-summary.json").write_text(json.dumps(results, indent=2))
    # The full-suite minimizer also observed this pair hanging while both
    # singletons passed. Repeat it without changing package/test source.
    for index in range(1, 3):
        remaining = budget - (time.monotonic() - started)
        if remaining < 60:
            raise RuntimeError("Pair-probe budget exhausted; partial results preserved")
        results.append(supervisor.invoke(
            f"arrow-pair-{index:02d}", ["ddbs_open_dataset", "formats_autodetect"],
            limit=min(300, remaining)))
        (OUT / "case-summary.json").write_text(json.dumps(results, indent=2))
finally:
    temporary_test.unlink(missing_ok=True)

print(json.dumps(results, indent=2), flush=True)
raise SystemExit(0 if all(x["reason"] == "success" for x in results) else 1)
