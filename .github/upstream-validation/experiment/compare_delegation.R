# Temporary experiment: generate identical duckspatial GeoParquet fixtures through
# a baseline DuckDB COPY delegation, the enhanced PR #8 writer, or raw SQL COPY.
# The data/scenarios below are the unchanged, previously validated interoperability
# fixture cases from commit 233b033d (except the writer adapter and reporting).
args <- commandArgs(TRUE)
stopifnot(length(args) == 3L)
lane <- args[[1L]]
out <- normalizePath(args[[2L]], mustWork = FALSE)
lib <- normalizePath(args[[3L]], mustWork = TRUE)
stopifnot(lane %in% c("legacy", "enhanced", "direct"))
dir.create(out, recursive = TRUE, showWarnings = FALSE)
library(duckspatial, lib.loc = lib)
con <- ddbs_create_conn(threads = 4L)
results <- list()

write_fixture <- function(x, name, version = "V1", ...) {
  extras <- list(...)
  path <- file.path(out, name)
  warning_text <- character()
  status <- "ok"
  error_text <- ""
  result <- tryCatch(withCallingHandlers({
    if (lane == "enhanced") {
      do.call(ddbs_write_dataset, c(
        list(data = x, path = path, conn = con, geoparquet_version = version,
             quiet = TRUE), extras
      ))
    } else if (lane == "legacy") {
      # Use the *unchanged* pre-PR writer, delegating its GeoParquet version
      # via the existing options argument to DuckDB. Map optional COPY
      # controls but do not reimplement geometry or CRS handling.
      extras$parquet_spatial_order <- NULL
      level <- extras$parquet_compression_level
      extras$parquet_compression_level <- NULL
      options <- list(GEOPARQUET_VERSION = version)
      if (!is.null(level)) options$COMPRESSION_LEVEL <- level
      do.call(ddbs_write_dataset, c(
        list(data = x, path = path, conn = con, quiet = TRUE, options = options),
        extras
      ))
    } else {
      # Test bare DuckDB SQL COPY on already typed, lazily queried geometry.
      # Local sf needs a registration/conversion step and is separately
      # covered by the baseline duckspatial writer.
      if (!inherits(x, "tbl_lazy")) {
        status <- "skip"
        stop("Direct COPY lane intentionally covers typed lazy SQL only")
      }
      opts <- c("FORMAT PARQUET", paste0(
        "GEOPARQUET_VERSION ", as.character(DBI::dbQuoteString(con, version))
      ))
      if (!is.null(extras$parquet_compression)) {
        opts <- c(opts, paste0("COMPRESSION ",
          as.character(DBI::dbQuoteString(con, extras$parquet_compression))))
      }
      if (!is.null(extras$parquet_compression_level)) {
        opts <- c(opts, paste0("COMPRESSION_LEVEL ",
          as.integer(extras$parquet_compression_level)))
      }
      if (!is.null(extras$parquet_row_group_size)) {
        opts <- c(opts, paste0("ROW_GROUP_SIZE ",
          as.integer(extras$parquet_row_group_size)))
      }
      if (length(extras$partitioning)) {
        quoted <- vapply(extras$partitioning,
          function(s) as.character(DBI::dbQuoteIdentifier(con, s)), character(1))
        opts <- c(opts, paste0("PARTITION_BY (", paste(quoted, collapse = ", "), ")"))
      }
      query <- as.character(dbplyr::sql_render(x, con = con))
      DBI::dbExecute(con, paste0(
        "COPY (", query, ") TO ",
        as.character(DBI::dbQuoteString(con, path)),
        " (", paste(opts, collapse = ", "), ")"
      ))
    }
    if (!file.exists(path) && !dir.exists(path)) {
      stop("Writer returned without creating a file or partition directory")
    }
    invisible(NULL)
  }, warning = function(w) {
    warning_text <<- c(warning_text, conditionMessage(w))
    invokeRestart("muffleWarning")
  }), error = function(e) e)
  if (inherits(result, "error")) {
    if (status != "skip") status <- "error"
    error_text <- conditionMessage(result)
  }
  results[[length(results) + 1L]] <<- list(
    lane = lane, case = name, version = version,
    status = status, error = error_text,
    warnings = paste(warning_text, collapse = " | ")
  )
  cat(sprintf("CASE lane=%s name=%s version=%s status=%s %s\n",
              lane, name, version, status,
              gsub("[\r\n]+", " ", substr(error_text, 1L, 160L))))
  invisible(NULL)
}

x <- sf::st_sf(
  id = 1:2,
  geometry = sf::st_sfc(sf::st_point(c(1, 2)), sf::st_point(c(3, 4)), crs = 4326)
)
write_fixture(x, "gp-v1.parquet", crs = NA)
write_fixture(x, "gp-v1.1.parquet", "V1.1")
write_fixture(x, "unknown-v1.1.parquet", "V1.1", crs = NA)
write_fixture(x, "gp-v2.parquet", "V2")

# Active geometry is deliberately second among two differently projected columns.
multi <- sf::st_sf(
  id = 1:3, part = c("A", "B", "A"),
  other = sf::st_sfc(sf::st_point(c(1, 2)), sf::st_point(c(3, 4)),
                     sf::st_point(c(5, 6)), crs = 4326),
  geometry = sf::st_sfc(sf::st_point(c(1000, 2000)),
                        sf::st_point(c(3000, 4000)), sf::st_point(), crs = 3857),
  sf_column_name = "geometry"
)
for (version in c("V1", "V1.1", "V2")) {
  tag <- tolower(version)
  write_fixture(multi, paste0("multi-", tag, ".parquet"), version,
                parquet_spatial_order = TRUE, parquet_compression = "zstd",
                parquet_compression_level = 3L)
  write_fixture(multi, paste0("partitioned-", tag, ".parquet"), version,
                partitioning = "part")
  write_fixture(multi[0, ], paste0("empty-", tag, ".parquet"), version,
                parquet_spatial_order = TRUE)
}

# Typed lazy inputs exercise ISO WKB dimensions, NULLs, empties, and the actual
# filtered/renamed query. The primary geometry has explicit native CRS metadata.
DBI::dbExecute(con, paste0(
  "CREATE TEMP TABLE gp_dimensions AS SELECT id, ",
  "ST_GeomFromText(wkt)::GEOMETRY('EPSG:4326') AS geometry, ",
  "CASE WHEN id = 2 THEN NULL ELSE ST_Point(10 * id, 20 * id) END",
  "::GEOMETRY('EPSG:3857') AS other FROM (VALUES ",
  "(1, 'POINT (1 2)'), (2, 'POINT Z (3 4 5)'), ",
  "(3, 'POINT M (6 7 8)'), (4, 'POINT ZM (9 10 11 12)'), ",
  "(5, 'POINT EMPTY'), (6, NULL), (7, 'POINT M EMPTY'), ",
  "(8, 'GEOMETRYCOLLECTION ZM (POINT ZM (13 14 15 16))')",
  ") t(id, wkt)"
))
lazy <- dplyr::tbl(con, "gp_dimensions")
for (version in c("V1", "V1.1", "V2")) {
  selected <- if (version != "V2") dplyr::filter(lazy, id %in% c(1L, 2L, 5L, 6L)) else lazy
  selected <- dplyr::mutate(selected, id = id * 10L)
  selected <- dplyr::rename(selected, shape = geometry)
  write_fixture(selected, paste0("dimensions-", tolower(version), ".parquet"),
                version, parquet_spatial_order = TRUE)
  write_fixture(dplyr::filter(selected, id == 60L),
                paste0("null-", tolower(version), ".parquet"), version,
                parquet_spatial_order = TRUE)
}

# A derived native CRS must win over the original source CRS.
projected <- dplyr::filter(lazy, id == 1L)
projected <- dplyr::mutate(projected, geometry = dbplyr::sql(paste0(
  "ST_Transform(geometry, 'EPSG:3857', always_xy := true)"
)))
for (version in c("V1", "V1.1", "V2")) {
  write_fixture(projected, paste0("transformed-", tolower(version), ".parquet"),
                version)
}

custom <- x
sf::st_crs(custom) <- NA
sf::st_crs(custom) <- "+proj=aeqd +lat_0=52 +lon_0=13 +datum=WGS84 +units=m +no_defs"
for (version in c("V1", "V1.1", "V2")) {
  write_fixture(custom, paste0("custom-", tolower(version), ".parquet"), version)
}

# Non-point WKB preserves every vertex, interior ring and dimension. The Python
# validator defines its expected geometries separately, including NULL/EMPTY.
DBI::dbExecute(con, paste0(
  "CREATE TEMP TABLE gp_nonpoint AS SELECT id, ",
  "ST_GeomFromText(wkt)::GEOMETRY('EPSG:3857') AS geometry FROM (VALUES ",
  "(1, 'LINESTRING (-8 4, 2 -3, 11 9)'), ",
  "(2, 'LINESTRING Z (-4 2 7, 6 12 -5, 15 3 19)'), ",
  "(3, 'POLYGON ((0 0, 8 0, 8 8, 0 8, 0 0), ",
  "(2 2, 2 6, 6 6, 6 2, 2 2))'), ",
  "(4, 'POLYGON Z ((20 20 1, 30 20 2, 30 30 9, 20 30 -2, 20 20 1))'), ",
  "(5, 'MULTILINESTRING ((-10 20, -5 25, 0 20), (5 20, 10 15))'), ",
  "(6, 'MULTIPOLYGON (((40 0, 44 0, 44 4, 40 4, 40 0)), ",
  "((50 0, 54 0, 54 4, 50 4, 50 0)))'), ",
  "(7, 'LINESTRING EMPTY'), (8, 'POLYGON EMPTY'), (9, NULL), ",
  "(10, 'LINESTRING M (-20 -10 -12, -10 -5 70, 0 -10 5)'), ",
  "(11, 'POLYGON ZM ((60 0 1 2, 64 0 4 9, 64 4 8 -3, ",
  "60 4 5 6, 60 0 1 2))')",
  ") t(id, wkt)"
))
nonpoint <- dplyr::tbl(con, "gp_nonpoint")

# A permuted two-dimensional grid spans three physical row groups with the
# requested size. Expected Hilbert order is calculated independently in Python.
DBI::dbExecute(con, paste0(
  "CREATE TEMP TABLE gp_ordered_groups AS SELECT id, ",
  "ST_Point((id * 17) % 101, (id * 37) % 103)",
  "::GEOMETRY('EPSG:3857') AS geometry FROM range(6000) t(id) ",
  "ORDER BY (id * 7919) % 6000"
))
ordered_groups <- dplyr::tbl(con, "gp_ordered_groups")
for (version in c("V1", "V1.1", "V2")) {
  tag <- tolower(version)
  selected <- if (version != "V2") dplyr::filter(nonpoint, id <= 9L) else nonpoint
  write_fixture(selected, paste0("nonpoint-", tag, ".parquet"), version)
  write_fixture(ordered_groups, paste0("ordered-row-groups-", tag, ".parquet"),
                version, parquet_spatial_order = TRUE,
                parquet_row_group_size = 2048L)
}
ddbs_stop_conn(con)
write.csv(do.call(rbind, lapply(results, as.data.frame)), file.path(out, "write-log.csv"), row.names = FALSE)
cat("RESULTS", lane, "success", sum(vapply(results, function(r) r$status == "ok", logical(1))), "failed", sum(vapply(results, function(r) r$status == "error", logical(1))), "skipped", sum(vapply(results, function(r) r$status == "skip", logical(1))), "\n")
