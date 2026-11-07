out <- commandArgs(trailingOnly = TRUE)[[1L]]
dir.create(out, recursive = TRUE, showWarnings = FALSE)
package_path <- normalizePath(find.package("duckspatial"), winslash = "/")
expected_library <- Sys.getenv("EXPECTED_PACKAGE_LIBRARY")
if (nzchar(expected_library)) {
  stopifnot(identical(package_path, normalizePath(
    file.path(expected_library, "duckspatial"), winslash = "/"
  )))
}
writeLines(c(paste("duckspatial:", package_path), paste("library:", .libPaths())),
           file.path(out, "package-library-paths.txt"))
cat("INSTALLED_PACKAGE_PATH:", package_path, "\n")
capture.output(sessionInfo(), file = file.path(out, "R-session-info.txt"))
packages <- as.data.frame(utils::installed.packages(), stringsAsFactors = FALSE)
utils::write.csv(packages, file.path(out, "R-installed-packages.csv"), row.names = FALSE)
con <- DBI::dbConnect(duckdb::duckdb())
DBI::dbExecute(con, "INSTALL spatial")
DBI::dbExecute(con, "LOAD spatial")
utils::write.csv(DBI::dbGetQuery(con, "PRAGMA version"),
                 file.path(out, "DuckDB-version.csv"), row.names = FALSE)
utils::write.csv(DBI::dbGetQuery(con, "SELECT * FROM duckdb_extensions() WHERE extension_name = 'spatial'"),
                 file.path(out, "Spatial-version.csv"), row.names = FALSE)
print(DBI::dbGetQuery(con, "PRAGMA version"))
print(DBI::dbGetQuery(con, "SELECT extension_name, extension_version FROM duckdb_extensions() WHERE extension_name = 'spatial'"))
DBI::dbDisconnect(con, shutdown = TRUE)
