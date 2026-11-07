# Plain R DBI -> DuckDB SQL: no duckspatial, sf, or geometry conversions.
args <- commandArgs(TRUE)
stopifnot(length(args) == 2L)
out <- normalizePath(args[[1L]], mustWork = FALSE)
manifest <- args[[2L]]
dir.create(out, recursive = TRUE, showWarnings = FALSE)
cases <- jsonlite::fromJSON(manifest)
conn <- DBI::dbConnect(duckdb::duckdb(), dbdir = ":memory:")
on.exit(DBI::dbDisconnect(conn, shutdown = TRUE))
DBI::dbExecute(conn, "INSTALL spatial")
DBI::dbExecute(conn, "LOAD spatial")
results <- list()
for (name in names(cases)) {
  sql <- cases[[name]]
  for (version in c("V1", "V2")) {
    path <- normalizePath(file.path(out, paste0(name, "-", tolower(version), ".parquet")), mustWork = FALSE)
    result <- list(case = name, version = version, sql = sql, status = "ok", error = NULL)
    tryCatch({
      types <- DBI::dbGetQuery(conn, paste("DESCRIBE", sql))
      result$types <- stats::setNames(as.list(types$column_type), types$column_name)
      sql_path <- as.character(DBI::dbQuoteString(conn, path))
      DBI::dbExecute(conn, paste0("COPY (", sql, ") TO ", sql_path,
        " (FORMAT PARQUET, GEOPARQUET_VERSION '", version, "')"))
    }, error = function(e) {
      result$status <<- "error"
      result$error <<- conditionMessage(e)
    })
    results[[length(results) + 1L]] <- result
    cat("CASE", name, version, result$status, result$error, "\n")
  }
}
writeLines(as.character(jsonlite::toJSON(results, pretty = TRUE, auto_unbox = TRUE, null = "null")),
           file.path(out, "results-r.json"))
