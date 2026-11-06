# Standalone DBI/DuckDB reproduction. No duckspatial/testthat functions or load.
args <- commandArgs(trailingOnly = TRUE)
label <- args[[1L]]
parts <- strsplit(label, "--", fixed = TRUE)[[1L]]
stopifnot(length(parts) == 4L, parts[[1L]] == "raw")
mode <- parts[[2L]]
with_sf <- parts[[3L]] == "sf"
one_thread <- parts[[4L]] == "t1"
log_dir <- normalizePath("diagnostics", winslash = "/")
checkpoint_file <- file.path(log_dir, paste0(label, "-checkpoints.log"))
.windows_checkpoint <- function(..., console = TRUE) {
  line <- paste(format(Sys.time(), "%Y-%m-%d %H:%M:%OS3"), paste0(..., collapse = ""))
  cat(line, "\n", file = checkpoint_file, append = TRUE)
  if (console) {
    cat(line, "\n", file = stderr())
    flush(stderr())
  }
}
.windows_checkpoint("PROCESS START: ", label, " PID=", Sys.getpid())
library(DBI)
library(duckdb)
if (with_sf) library(sf)
stopifnot(!any(c("duckspatial", "testthat") %in% loadedNamespaces()))
print(sessionInfo())
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
input <- normalizePath("inst/spatial/countries.geojson", winslash = "/", mustWork = TRUE)
run_iteration <- function(iteration) {
  .windows_checkpoint("ITERATION ENTER: ", iteration)
  output_dir <- tempfile("duckdb-native-geometry-")
  dir.create(output_dir)
  drv <- duckdb::duckdb(shared_home = FALSE,
                       config = if (one_thread) list(threads = "1") else list())
  conn <- DBI::dbConnect(drv)
  on.exit({
    .windows_checkpoint("OWNED CONNECTION CLEANUP ENTER: ", iteration)
    if (DBI::dbIsValid(conn)) {
      DBI::dbExecute(conn, "FORCE CHECKPOINT")
      DBI::dbDisconnect(conn)
    }
    duckdb::duckdb_shutdown(drv)
    unlink(output_dir, recursive = TRUE)
    .windows_checkpoint("OWNED CONNECTION CLEANUP LEAVE: ", iteration)
  }, add = TRUE)
  DBI::dbExecute(conn, "INSTALL spatial; LOAD spatial;")
  quote_path <- function(path) as.character(DBI::dbQuoteString(conn, normalizePath(path, winslash = "/", mustWork = FALSE)))
  DBI::dbExecute(conn, paste0("CREATE TABLE countries AS SELECT * FROM ST_Read(", quote_path(input), ")"))
  stopifnot(DBI::dbGetQuery(conn, "SELECT COUNT(*) AS n FROM countries")$n == 257)
  operations <- if (mode == "all") c("geojson", "shapefile", "shapefile-mismatch") else mode
  for (operation in operations) {
    if (operation == "read") next
    suffix <- if (operation == "shapefile") ".shp" else ".geojson"
    driver <- if (operation == "geojson") "GeoJSON" else "ESRI Shapefile"
    path <- file.path(output_dir, paste0(operation, suffix))
    .windows_checkpoint("COPY ENTER: ", operation)
    sql <- paste0("COPY countries TO ", quote_path(path),
                  " (FORMAT GDAL, DRIVER ", as.character(DBI::dbQuoteString(conn, driver)), ")")
    DBI::dbExecute(conn, sql)
    stopifnot(file.exists(path))
    if (operation != "shapefile-mismatch") {
      count <- DBI::dbGetQuery(conn, paste0("SELECT COUNT(*) AS n FROM ST_Read(", quote_path(path), ")"))
      stopifnot(count$n == 257)
    }
    .windows_checkpoint("COPY LEAVE: ", operation)
  }
  .windows_checkpoint("ITERATION RETURN: ", iteration)
}

test_error <- tryCatch({
  .windows_checkpoint("TESTS ENTER")
  for (iteration in seq_len(3L)) {
    run_iteration(iteration)
    gc()
  }
  stopifnot(!any(c("duckspatial", "testthat") %in% loadedNamespaces()))
  .windows_checkpoint("TESTS RETURNED")
  NULL
}, error = function(e) {
  .windows_checkpoint("R ERROR: ", conditionMessage(e))
  print(e)
  e
})
.windows_checkpoint("GC ENTER")
gc()
.windows_checkpoint("GC LEAVE")
status <- if (is.null(test_error)) 0L else 1L
.windows_checkpoint("R EXIT REQUEST: status=", status)
quit(save = "no", status = status)
