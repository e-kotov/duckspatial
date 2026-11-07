# Runs the existing tests unchanged. The preserved supervisor separately requires
# the R process to exit successfully after these completion markers.
args <- commandArgs(trailingOnly = TRUE)
label <- args[[1L]]
filter <- if (length(args) >= 2L) args[[2L]] else NULL
out <- Sys.getenv("DIAGNOSTICS_DIR")
dir.create(out, recursive = TRUE, showWarnings = FALSE)
checkpoint <- file.path(out, paste0(label, "-checkpoints.log"))
mark <- function(text) {
  cat(format(Sys.time(), "%Y-%m-%d %H:%M:%OS3"), text, "\n",
      file = checkpoint, append = TRUE)
}
mark("PROCESS START")
capture.output(sessionInfo(), file = file.path(out, paste0(label, "-session-before.txt")))
status <- tryCatch({
  extra_file <- Sys.getenv("EXTRA_CONTRACT_TEST_FILE")
  files <- if (nzchar(extra_file)) extra_file else
    testthat:::find_test_scripts("tests/testthat", filter = filter)
  stopifnot(length(files) > 0L)
  writeLines(files, file.path(out, paste0(label, "-selected-tests.txt")))
  if (nzchar(extra_file)) {
    library(testthat)
    library(duckspatial)
    actual_path <- normalizePath(getNamespaceInfo("duckspatial", "path"), winslash = "/")
    expected_path <- normalizePath(file.path(Sys.getenv("EXPECTED_PACKAGE_LIBRARY"),
                                            "duckspatial"), winslash = "/")
    stopifnot(identical(actual_path, expected_path))
    cat("INSTALLED_REFERENCE_NAMESPACE:", actual_path, "\n")
    results <- testthat::test_file(
      extra_file, package = "duckspatial", load_package = "installed",
      reporter = "summary", stop_on_failure = TRUE
    )
  } else {
    results <- testthat::test_local(filter = filter, reporter = "summary",
                                    stop_on_failure = TRUE)
  }
  saveRDS(results, file.path(out, paste0(label, "-results.rds")))
  table <- as.data.frame(results)
  table <- table[, !vapply(table, is.list, logical(1)), drop = FALSE]
  utils::write.csv(table, file.path(out, paste0(label, "-results.csv")), row.names = FALSE)
  totals <- vapply(table[, intersect(c("failed", "error", "warning", "skipped", "passed"),
                                    names(table)), drop = FALSE], sum, numeric(1))
  writeLines(jsonlite::toJSON(as.list(totals), auto_unbox = TRUE),
             file.path(out, paste0(label, "-totals.json")))
  print(totals)
  capture.output(sessionInfo(), file = file.path(out, paste0(label, "-session-after.txt")))
  mark("TESTS RETURNED")
  0L
}, error = function(e) {
  mark(paste("R ERROR:", conditionMessage(e)))
  message(conditionMessage(e))
  1L
})
mark(paste0("R EXIT REQUEST: status=", status))
quit(save = "no", status = status)
