# Diagnostic-only DBI/DuckDB reproduction. Does not load duckspatial, testthat,
# sf, Arrow, or any GeoParquet writer. Reuses the prior failed-install experiment.
options(warn = 1)
args <- commandArgs(trailingOnly = TRUE)
label <- args[[1L]]
mode <- Sys.getenv("NATIVE_CASE")
stopifnot(mode %in% c("aws-anchor", "failed-install-anchor", "aws-control",
                     "failed-install-control", "anchor-control"))
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
                    " R_HOME=", R.home(), " CASE=", mode)
library(DBI)
library(duckdb)
print(sessionInfo())

trace("rapi_prepare", where = asNamespace("duckdb"), print = FALSE,
  tracer = quote(.GlobalEnv$.windows_checkpoint("SQL ENTER: ", query)),
  exit = quote(.GlobalEnv$.windows_checkpoint("SQL LEAVE")))
for (native_call in c("rapi_execute", "rapi_disconnect", "rapi_shutdown")) {
  trace(native_call, where = asNamespace("duckdb"), print = FALSE,
    tracer = substitute(.GlobalEnv$.windows_checkpoint(LABEL),
                        list(LABEL = paste(native_call, "ENTER"))),
    exit = substitute(.GlobalEnv$.windows_checkpoint(LABEL),
                      list(LABEL = paste(native_call, "LEAVE"))))
}

workload_error <- tryCatch({
  anchor <- NULL
  if (mode %in% c("aws-anchor", "failed-install-anchor", "anchor-control")) {
    .windows_checkpoint("SPATIAL ANCHOR CONNECT")
    anchor <- dbConnect(duckdb(shared_home = FALSE))
    dbExecute(anchor, "INSTALL spatial; LOAD spatial;")
  }
  .windows_checkpoint("CONNECT TEST CONNECTION")
  conn <- dbConnect(duckdb(shared_home = FALSE))
  install_errors <- list()
  if (startsWith(mode, "failed-install")) {
    for (sql in c("INSTALL nonexistent_extension_xyz;",
                  "INSTALL nonexistent_extension_xyz FROM community;")) {
      err <- tryCatch({ dbExecute(conn, sql); NULL }, error = identity)
      stopifnot(inherits(err, "error"))
      install_errors[[length(install_errors) + 1L]] <- err
      .windows_checkpoint("EXPECTED INSTALL ERROR: ", conditionMessage(err))
    }
  } else if (startsWith(mode, "aws")) {
    # Same core-then-community install sequence as ddbs_install(). Outcomes
    # are recorded; a download error is distinct from a native process crash.
    installed <- tryCatch({
      dbExecute(conn, "INSTALL aws;")
      "core"
    }, error = function(e) {
      install_errors$core <<- e
      .windows_checkpoint("AWS CORE INSTALL ERROR: ", conditionMessage(e))
      tryCatch({
        dbExecute(conn, "INSTALL aws FROM community;")
        "community"
      }, error = function(e2) {
        install_errors$community <<- e2
        .windows_checkpoint("AWS COMMUNITY INSTALL ERROR: ", conditionMessage(e2))
        NULL
      })
    })
    .windows_checkpoint("AWS INSTALL RETURNED: ", if (is.null(installed)) "both repositories failed" else installed)
  }
  .windows_checkpoint("DISCONNECT ENTER")
  dbDisconnect(conn)
  .windows_checkpoint("DISCONNECT LEAVE")
  if (!is.null(anchor)) {
    .windows_checkpoint("SPATIAL ANCHOR DISCONNECT ENTER")
    dbDisconnect(anchor)
    .windows_checkpoint("SPATIAL ANCHOR DISCONNECT LEAVE")
  }
  .windows_checkpoint("NATIVE WORKLOAD RETURNED")
  NULL
}, error = function(e) {
  .windows_checkpoint("R ERROR: ", conditionMessage(e))
  print(e)
  e
})
.windows_checkpoint("GC ENTER")
gc()
.windows_checkpoint("GC LEAVE")
stopifnot(!"duckspatial" %in% loadedNamespaces(), !"testthat" %in% loadedNamespaces())
print(loadedNamespaces())
status <- if (is.null(workload_error)) 0L else 1L
.windows_checkpoint("R EXIT REQUEST: status=", status)
quit(save = "no", status = status)
