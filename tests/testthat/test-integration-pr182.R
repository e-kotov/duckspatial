# Temporary integration regression for upstream PR #182 + clean GeoParquet #7/#8.
# Runs only in an experimental branch of e-kotov/duckspatial.
testthat::skip_on_cran()
testthat::skip_if_not_installed("duckdb", minimum_version = "2.0.0")

pr182_geo_metadata <- function(conn, path) {
  quoted <- as.character(DBI::dbQuoteString(conn, path))
  raw <- DBI::dbGetQuery(conn, paste0(
    "SELECT decode(value) AS value FROM parquet_kv_metadata(",
    quoted, ") WHERE decode(key) = 'geo'"
  ))$value
  testthat::expect_length(raw, 1L)
  jsonlite::fromJSON(raw[[1L]], simplifyVector = FALSE)
}

pr182_row_count <- function(conn, path) {
  quoted <- as.character(DBI::dbQuoteString(conn, path))
  as.integer(DBI::dbGetQuery(
    conn, paste0("SELECT COUNT(*) AS n FROM read_parquet(", quoted, ")")
  )$n[[1L]])
}

pr182_fixture <- function(conn) {
  pts <- sf::st_as_sf(
    data.frame(id = 1:6, grp = rep(letters[1:3], 2),
               x = 1:6, y = 1:6),
    coords = c("x", "y"), crs = 4326
  )
  ddbs_write_table(conn, pts, "pr182_points", quiet = TRUE)
  as_duckspatial_df("pr182_points", conn)
}

test_that("PR182 distinct preserves rendered query for every GeoParquet version", {
  conn <- ddbs_create_conn()
  on.exit(ddbs_stop_conn(conn), add = TRUE)
  d <- pr182_fixture(conn)
  reduced <- dplyr::distinct(d, grp, .keep_all = TRUE)
  expect_null(attr(reduced, "source_table"))
  for (version in c("V1", "V1.1", "V2")) {
    path <- tempfile(fileext = ".parquet")
    ddbs_write_dataset(reduced, path, conn = conn,
                       geoparquet_version = version, quiet = TRUE)
    expect_equal(pr182_row_count(conn, path), 3L)
    expect_equal(pr182_geo_metadata(conn, path)$primary_column, "geometry")
    unlink(path)
  }
  counted <- dplyr::count(d, grp)
  expect_null(attr(counted, "source_table"))
  expect_error(
    ddbs_write_dataset(counted, tempfile(fileext = ".parquet"),
                       conn = conn, quiet = TRUE),
    "does not contain a spatial column"
  )
})

test_that("PR182 selected/renamed geometry survives GeoParquet metadata and query", {
  conn <- ddbs_create_conn()
  on.exit(ddbs_stop_conn(conn), add = TRUE)
  d <- pr182_fixture(conn)
  selected <- d |>
    dplyr::filter(grp != "c") |>
    dplyr::select(grp, geom2 = geometry) |>
    dplyr::distinct(grp, .keep_all = TRUE)
  expect_equal(attr(selected, "sf_column"), "geom2")
  expect_null(attr(selected, "source_table"))
  for (version in c("V1", "V1.1", "V2")) {
    path <- tempfile(fileext = ".parquet")
    ddbs_write_dataset(selected, path, conn = conn,
                       geoparquet_version = version, quiet = TRUE)
    md <- pr182_geo_metadata(conn, path)
    expect_equal(pr182_row_count(conn, path), 2L)
    expect_equal(md$primary_column, "geom2")
    expect_true("geom2" %in% names(md$columns))
    expect_false("geometry" %in% names(md$columns))
    expect_equal(sf::st_crs(jsonlite::toJSON(md$columns$geom2$crs,
                                            auto_unbox = TRUE))$epsg, 4326)
    unlink(path)
  }
})

test_that("PR182 reprojecting mutate never reuses stale old CRS", {
  conn <- ddbs_create_conn()
  on.exit(ddbs_stop_conn(conn), add = TRUE)
  d <- pr182_fixture(conn)
  expect_warning(
    projected <- dplyr::mutate(
      d, geometry = dplyr::sql(
        "ST_Transform(geometry, 'EPSG:4326', 'EPSG:3857', always_xy := true)"
      )
    ), "reprojected"
  )
  expect_true(is.na(ddbs_crs(projected)))
  for (version in c("V1", "V1.1")) {
    path <- tempfile(fileext = ".parquet")
    ddbs_write_dataset(projected, path, conn = conn,
                       geoparquet_version = version, quiet = TRUE)
    md <- pr182_geo_metadata(conn, path)
    current <- md$columns$geometry$crs
    if (!is.null(current)) {
      epsg <- sf::st_crs(jsonlite::toJSON(current, auto_unbox = TRUE))$epsg
      expect_false(identical(epsg, 4326L),
                   info = paste("stale EPSG:4326 in", version))
    }
    expect_equal(pr182_row_count(conn, path), 6L)
    unlink(path)
  }
  # Explicit assignment is valid after the transformation for all three versions.
  for (version in c("V1", "V1.1", "V2")) {
    path <- tempfile(fileext = ".parquet")
    ddbs_write_dataset(projected, path, conn = conn, crs = "EPSG:3857",
                       geoparquet_version = version, quiet = TRUE)
    md <- pr182_geo_metadata(conn, path)
    expect_equal(sf::st_crs(jsonlite::toJSON(md$columns$geometry$crs,
                                            auto_unbox = TRUE))$epsg, 3857)
    unlink(path)
  }
})

test_that("PR182 source-table guard still protects non-Parquet native writer", {
  conn <- ddbs_create_conn()
  on.exit(ddbs_stop_conn(conn), add = TRUE)
  d <- pr182_fixture(conn)
  reduced <- dplyr::distinct(d, grp, .keep_all = TRUE)
  csv <- tempfile(fileext = ".csv")
  on.exit(unlink(csv), add = TRUE)
  ddbs_write_dataset(reduced, csv, conn = conn, quiet = TRUE)
  quoted <- as.character(DBI::dbQuoteString(conn, csv))
  count <- DBI::dbGetQuery(
    conn, paste0("SELECT COUNT(*) AS n FROM read_csv_auto(", quoted, ")")
  )$n[[1L]]
  expect_equal(as.integer(count), 3L)
})
