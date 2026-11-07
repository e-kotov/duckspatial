# Run from an unchanged source checkout after installing it into a separate
# library. Arguments: label, exact source SHA, output directory, library path.
args <- commandArgs(trailingOnly = TRUE)
stopifnot(length(args) == 4L)
label <- args[[1L]]
expected_sha <- args[[2L]]
out <- args[[3L]]
library_path <- args[[4L]]
dir.create(out, recursive = TRUE, showWarnings = FALSE)
sha <- system2("git", c("rev-parse", "HEAD"), stdout = TRUE)
stopifnot(identical(sha, expected_sha))
stopifnot(!length(system2("git", c("status", "--porcelain", "--untracked-files=no"),
                         stdout = TRUE)))
.libPaths(c(library_path, .libPaths()))
library(duckspatial)
stopifnot(identical(normalizePath(find.package("duckspatial")),
                    normalizePath(file.path(library_path, "duckspatial"))))
capture.output(sessionInfo(), file = file.path(out, "session-info.txt"))

run_probe <- function() {
  conn <- ddbs_create_conn()
  on.exit(ddbs_stop_conn(conn), add = TRUE)
  cases <- list(
    valid = list(index = 1L, name = "id"),
    missing_attribute = list(index = 1L, name = NA_character_),
    literal_NA_attribute = list(index = 1L, name = "NA"),
    empty_attribute = list(index = 1L, name = ""),
    missing_geometry = list(index = 2L, name = NA_character_),
    literal_NA_geometry = list(index = 2L, name = "NA"),
    empty_geometry = list(index = 2L, name = "")
  )
  records <- list()
  write_report <- function() {
    report <- list(label = label, source_sha = sha,
                   installed_package = find.package("duckspatial"),
                   library_paths = .libPaths(),
                   duckdb = as.character(utils::packageVersion("duckdb")),
                   sf = as.character(utils::packageVersion("sf")),
                   engine = DBI::dbGetQuery(conn, "PRAGMA version"),
                   identifier_quote_control = quote_control,
                   records = records)
    jsonlite::write_json(report, file.path(out, "identifiers.json"),
                         auto_unbox = TRUE, pretty = TRUE, null = "null",
                         na = "null", digits = NA)
  }
  attempt <- function(expr) tryCatch(expr, error = function(e) {
    list(error = conditionMessage(e), error_classes = class(e))
  })
  quote_control <- list(
    dbi_missing = attempt(as.character(DBI::dbQuoteIdentifier(conn, NA_character_))),
    package_missing = duckspatial:::sql_ident(NA_character_)
  )

  for (case_name in names(cases)) {
    specification <- cases[[case_name]]
    # Use sf's public name-replacement method. Record construction failures
    # separately from export failures, especially for a missing active name.
    input <- attempt({
      x <- sf::st_sf(
        id = 17L,
        geometry = sf::st_sfc(sf::st_point(c(1, 2)), crs = 4326)
      )
      new_names <- names(x)
      new_names[[specification$index]] <- specification$name
      names(x) <- new_names
      x
    })
    for (version in c("V1", "V2")) {
      key <- paste(case_name, version, sep = "-")
      record <- list(case = case_name, version = version)
      if (!inherits(input, "sf")) {
        record$outcome <- "construction-error"
        record$details <- input
      } else {
        record$input_names <- unname(names(input))
        record$missing_names <- unname(is.na(names(input)))
        record$active_geometry <- attr(input, "sf_column", exact = TRUE)
        before <- sort(DBI::dbListTables(conn))
        path <- file.path(out, paste0(key, ".parquet"))
        result <- attempt({
          ddbs_write_dataset(input, path, conn = conn,
                             geoparquet_version = version, quiet = TRUE)
          "exported"
        })
        record$outcome <- if (identical(result, "exported")) "exported" else "export-error"
        if (!identical(result, "exported")) record$details <- result
        record$file_exists <- file.exists(path)
        record$connection_valid <- DBI::dbIsValid(conn)
        record$tables_before <- before
        record$tables_after <- sort(DBI::dbListTables(conn))
        record$cleanup_unchanged <- identical(record$tables_before, record$tables_after)
        if (record$file_exists) {
          quoted <- DBI::dbQuoteString(conn, path)
          record$output_schema <- attempt(DBI::dbGetQuery(conn, paste0(
            "DESCRIBE SELECT * FROM read_parquet(", quoted, ")"
          )))
          if (is.data.frame(record$output_schema)) {
            fields <- record$output_schema$column_name
            geometry <- fields[grepl("^GEOMETRY", record$output_schema$column_type)]
            attribute <- setdiff(fields, geometry)
            if (length(attribute) == 1L && length(geometry) == 1L) {
              record$output_values <- attempt(DBI::dbGetQuery(conn, paste0(
                "SELECT ", DBI::dbQuoteIdentifier(conn, attribute), " AS attribute, ",
                "ST_AsText(", DBI::dbQuoteIdentifier(conn, geometry), ") AS geometry_wkt ",
                "FROM read_parquet(", quoted, ")"
              )))
            }
          }
        }
      }
      records[[key]] <- record
      write_report()
      cat(label, key, record$outcome, "\n")
      if (!is.null(record$details$error)) cat(record$details$error, "\n")
    }
  }
  cat("IDENTIFIER PROBE RETURNED\n")
}
run_probe()
cat("IDENTIFIER PROBE CLEANUP RETURNED\n")
