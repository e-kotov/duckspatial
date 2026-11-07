# Diagnostic-only runner adapted from PR #5's Windows diagnostic workflow.
# Runs the checked-out tests unmodified, preserving their actual exit status.
options(warn = 1)
args <- commandArgs(trailingOnly = TRUE)
label <- args[[1L]]
test_filter <- if (length(args) >= 2L) args[[2L]] else NULL
log_dir <- normalizePath(Sys.getenv("DIAGNOSTICS_DIR", "diagnostics"), winslash = "/")
checkpoint_file <- file.path(log_dir, paste0(label, "-checkpoints.log"))
.windows_checkpoint <- function(..., console = TRUE) {
  line <- paste(format(Sys.time(), "%Y-%m-%d %H:%M:%OS3"),
                paste0(..., collapse = ""))
  cat(line, "\n", file = checkpoint_file, append = TRUE)
  if (console) {
    cat(line, "\n", file = stderr())
    flush(stderr())
  }
}
.windows_checkpoint("PROCESS START: ", label, " PID=", Sys.getpid(),
                    " R_HOME=", R.home())
library(testthat)
library(duckdb)
print(sessionInfo())

# These are instrumentation only: no changed connection config, mocked calls,
# or altered tests. The immediately written enter/leave markers survive crashes.
trace("rapi_prepare", where = asNamespace("duckdb"), print = FALSE,
  tracer = quote(.GlobalEnv$.windows_checkpoint("SQL ENTER: ", query, console = FALSE)),
  exit = quote(.GlobalEnv$.windows_checkpoint("SQL LEAVE", console = FALSE)))
for (native_call in c("rapi_execute", "rapi_disconnect", "rapi_shutdown")) {
  trace(native_call, where = asNamespace("duckdb"), print = FALSE,
    tracer = substitute(.GlobalEnv$.windows_checkpoint(LABEL, console = FALSE),
                        list(LABEL = paste(native_call, "ENTER"))),
    exit = substitute(.GlobalEnv$.windows_checkpoint(LABEL, console = FALSE),
                      list(LABEL = paste(native_call, "LEAVE"))))
}

test_error <- tryCatch({
  selected_files <- testthat:::find_test_scripts(
    "tests/testthat", filter = test_filter, full.names = FALSE)
  if (!length(selected_files)) stop("Diagnostic filter selected no test files")
  .windows_checkpoint("SELECTED TEST FILES: ", paste(basename(selected_files), collapse = ", "))
  .windows_checkpoint("TESTS ENTER")
  results <- testthat::test_local(
    filter = test_filter, reporter = "location", stop_on_failure = TRUE)
  saveRDS(results, file.path(log_dir, paste0(label, "-test-results.rds")))
  result_frame <- as.data.frame(results)
  result_frame <- result_frame[, !vapply(result_frame, is.list, logical(1)), drop = FALSE]
  utils::write.csv(result_frame, file.path(log_dir, paste0(label, "-test-results.csv")), row.names = FALSE)
  .windows_checkpoint("TESTS RETURNED")
  NULL
}, error = function(e) {
  .windows_checkpoint("R ERROR: ", conditionMessage(e))
  print(e)
  dump.frames(file.path(log_dir, paste0(label, "-frames")), to.file = TRUE)
  e
})

# Same teardown probes as the original diagnostic. Assertion completion and
# successful process exit remain separate, mandatory observations.
.windows_checkpoint("PACKAGE UNLOAD ENTER")
if ("duckspatial" %in% loadedNamespaces()) pkgload::unload("duckspatial")
.windows_checkpoint("PACKAGE UNLOAD LEAVE")
.windows_checkpoint("GC ENTER")
gc()
.windows_checkpoint("GC LEAVE")
status <- if (is.null(test_error)) 0L else 1L
.windows_checkpoint("R EXIT REQUEST: status=", status)
quit(save = "no", status = status)
