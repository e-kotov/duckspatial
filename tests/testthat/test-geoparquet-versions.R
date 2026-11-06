# Regression checks for GeoParquet 1.0 and 2.0 output.
testthat::skip_on_cran()
testthat::skip_if_not_installed("duckdb", minimum_version = "2.0.0")

gp_metadata <- function(conn, path) {
  p <- as.character(DBI::dbQuoteString(conn, path))
  kv <- DBI::dbGetQuery(conn, paste0(
    "SELECT decode(value) AS val FROM parquet_kv_metadata(", p,
    ") WHERE decode(key) = 'geo'"
  ))
  testthat::expect_equal(nrow(kv), 1L)
  jsonlite::fromJSON(kv$val[[1L]], simplifyVector = FALSE)
}

gp_type <- function(conn, path, column = "geometry") {
  p <- as.character(DBI::dbQuoteString(conn, path))
  schema <- DBI::dbGetQuery(conn, paste0(
    "DESCRIBE SELECT * FROM read_parquet(", p, ")"
  ))
  schema$column_type[match(column, schema$column_name)]
}

gp_points <- function(crs = 3857) {
  if (length(crs) == 1L && is.atomic(crs) && is.na(crs)) {
    crs <- sf::st_crs(NA)
  }
  sf::st_sf(
    id = c(1L, 2L, 3L),
    geometry = sf::st_sfc(
      sf::st_point(c(300000, 6000000)),
      sf::st_geometrycollection(),
      sf::st_point(c(500000, 6001000)),
      crs = crs
    )
  )
}

test_that("default GeoParquet is V1 and retains an explicit unknown CRS", {
  conn <- ddbs_temp_conn()
  x <- gp_points(crs = 3857)
  output <- tempfile(fileext = ".parquet")
  on.exit(unlink(output), add = TRUE)

  ddbs_write_dataset(x, output, conn = conn, crs = NA, quiet = TRUE)
  md <- gp_metadata(conn, output)
  expect_equal(md$version, "1.0.0")
  expect_true(is.null(md$columns$geometry$crs))
  expect_equal(md$primary_column, "geometry")

  # Read back through the GeoParquet-aware reader, not only the JSON footer.
  result <- ddbs_open_dataset(output, conn = conn)
  expect_true(is.na(ddbs_crs(result)))
  expect_equal(dplyr::count(result) |> dplyr::pull(n), 3)
})

test_that("GeoParquet V1 retains both known and unknown sf geometry CRS", {
  conn <- ddbs_temp_conn()
  x <- gp_points(3857)
  x$other <- sf::st_sfc(
    sf::st_point(c(1, 2)), sf::st_point(c(3, 4)),
    sf::st_point(c(5, 6)), crs = sf::st_crs(NA)
  )
  output <- tempfile(fileext = ".parquet")
  on.exit(unlink(output), add = TRUE)

  ddbs_write_dataset(x, output, conn = conn, quiet = TRUE)
  md <- gp_metadata(conn, output)
  expect_equal(md$version, "1.0.0")
  expect_equal(md$primary_column, "geometry")
  expect_equal(names(md$columns), c("geometry", "other"))
  expect_true(is.list(md$columns$geometry$crs))
  expect_null(md$columns$other$crs)
})

test_that("V2 explicitly rejects unknown CRS instead of producing CRS84", {
  conn <- ddbs_temp_conn()
  x <- gp_points(crs = NA)
  output <- tempfile(fileext = ".parquet")
  on.exit(unlink(output), add = TRUE)

  expect_error(
    ddbs_write_dataset(
      x, output, conn = conn, geoparquet_version = "V2", quiet = TRUE
    ),
    "unknown CRS"
  )
  expect_false(file.exists(output))
})

test_that("GeoParquet V2 exports native spatial types and known CRS", {
  conn <- ddbs_temp_conn()
  x <- gp_points(3857)
  output <- tempfile(fileext = ".parquet")
  on.exit(unlink(output), add = TRUE)

  ddbs_write_dataset(
    x, output, conn = conn, geoparquet_version = "V2",
    parquet_spatial_order = TRUE, parquet_compression = "zstd",
    parquet_compression_level = 3L, quiet = TRUE
  )
  md <- gp_metadata(conn, output)
  expect_equal(md$version, "2.0.0")
  expect_equal(md$primary_column, "geometry")
  expect_true(is.list(md$columns$geometry$crs))
  expect_match(gp_type(conn, output), "^GEOMETRY")

  result <- ddbs_open_dataset(output, conn = conn)
  expect_equal(ddbs_crs(result)$epsg, 3857)
  expect_equal(dplyr::count(result) |> dplyr::pull(n), 3)
})

test_that("Hilbert ordering tolerates degenerate, empty and null geometries", {
  conn <- ddbs_temp_conn()
  for (x in list(
    gp_points(4326)[0, , drop = FALSE],
    gp_points(4326)[2, , drop = FALSE],
    sf::st_sf(id = 1:2, geometry = sf::st_sfc(
      sf::st_point(c(1, 1)), sf::st_point(c(1, 1)), crs = 4326
    ))
  )) {
    output <- tempfile(fileext = ".parquet")
    expect_no_error(ddbs_write_dataset(
      x, output, conn = conn, geoparquet_version = "V2",
      parquet_spatial_order = TRUE, quiet = TRUE
    ))
    unlink(output)
  }
})

test_that("GeoParquet uses the current lazy query, not its source table", {
  conn <- ddbs_temp_conn()
  DBI::dbExecute(conn, paste0(
    "CREATE TEMP TABLE gp_query AS SELECT id, ",
    "ST_Point(id::DOUBLE, id::DOUBLE)::GEOMETRY('EPSG:4326') AS geometry ",
    "FROM range(1, 5) t(id)"
  ))
  lazy <- dplyr::tbl(conn, "gp_query") |>
    dplyr::filter(id > 2) |>
    dplyr::mutate(id = id * 10)
  output <- tempfile(fileext = ".parquet")
  on.exit(unlink(output), add = TRUE)

  ddbs_write_dataset(lazy, output, conn = conn,
                     geoparquet_version = "V2", quiet = TRUE)
  p <- as.character(DBI::dbQuoteString(conn, output))
  ids <- DBI::dbGetQuery(conn, paste0(
    "SELECT id FROM read_parquet(", p, ") ORDER BY id"
  ))$id
  expect_equal(as.numeric(ids), c(30, 40))
})

test_that("partitioned GeoParquet V2 has metadata in every output file", {
  conn <- ddbs_temp_conn()
  x <- gp_points(3857)
  x$partition <- c("A", "B", "A")
  output <- tempfile(fileext = ".parquet")
  on.exit(unlink(output, recursive = TRUE), add = TRUE)

  ddbs_write_dataset(
    x, output, conn = conn, geoparquet_version = "V2",
    partitioning = "partition", quiet = TRUE
  )
  files <- list.files(output, pattern = "[.]parquet$", recursive = TRUE,
                      full.names = TRUE)
  expect_gte(length(files), 2)
  for (file in files) {
    md <- gp_metadata(conn, file)
    expect_equal(md$version, "2.0.0")
    expect_equal(md$primary_column, "geometry")
  }
})

test_that("ordinary nested fields named GEOMETRY are not rejected", {
  conn <- ddbs_temp_conn()
  DBI::dbExecute(conn, paste0(
    "CREATE TEMP TABLE gp_named AS SELECT ",
    "ST_Point(1, 2)::GEOMETRY('EPSG:4326') AS geometry, ",
    "{'GEOMETRY': 'ordinary text'} AS attr"
  ))
  output <- tempfile(fileext = ".parquet")
  on.exit(unlink(output), add = TRUE)
  expect_no_error(ddbs_write_dataset(
    dplyr::tbl(conn, "gp_named"), output, conn = conn, quiet = TRUE
  ))
  expect_equal(gp_metadata(conn, output)$version, "1.0.0")
})

test_that("native unknown CRS is not replaced by a stale duckspatial_df attribute", {
  conn <- ddbs_temp_conn()
  DBI::dbExecute(conn, paste0(
    "CREATE TEMP TABLE gp_stale AS SELECT 1 AS id, ",
    "ST_Point(10, 20)::GEOMETRY('EPSG:3857') AS geometry"
  ))
  source <- as_duckspatial_df("gp_stale", conn = conn)
  cleared <- dplyr::mutate(
    source, geometry = dbplyr::sql("CAST(geometry AS GEOMETRY)")
  )
  # dplyr's duckspatial method retains the old R CRS despite the new SQL type.
  expect_equal(attr(cleared, "crs")$epsg, 3857)
  output <- tempfile(fileext = ".parquet")
  on.exit(unlink(output), add = TRUE)

  ddbs_write_dataset(cleared, output, conn = conn, quiet = TRUE)
  expect_null(gp_metadata(conn, output)$columns$geometry$crs)
  unlink(output)
  expect_error(ddbs_write_dataset(
    cleared, output, conn = conn,
    geoparquet_version = "V2", quiet = TRUE
  ), "unknown CRS")
})

test_that("GeoParquet V2 preserves M and ZM coordinates", {
  conn <- ddbs_temp_conn()
  for (dim in c("XYM", "XYZM")) {
    coords <- if (identical(dim, "XYM")) c(1, 2, 3) else c(1, 2, 3, 4)
    x <- sf::st_sf(
      id = 1L,
      geometry = sf::st_sfc(sf::st_point(coords, dim = dim), crs = 4326)
    )
    output <- tempfile(fileext = ".parquet")
    ddbs_write_dataset(
      x, output, conn = conn, geoparquet_version = "V2", quiet = TRUE
    )
    p <- as.character(DBI::dbQuoteString(conn, output))
    wkt <- DBI::dbGetQuery(conn, paste0(
      "SELECT ST_AsText(geometry) AS geom FROM read_parquet(", p, ")"
    ))$geom[[1L]]
    expect_match(wkt, if (identical(dim, "XYM")) "POINT M" else "POINT ZM",
                 fixed = TRUE)
    expect_equal(gp_metadata(conn, output)$version, "2.0.0")
    unlink(output)
  }
})

test_that("legacy storage CRS metadata is retained in GeoParquet V1", {
  file <- tempfile(fileext = ".duckdb")
  output <- tempfile(fileext = ".parquet")
  on.exit(unlink(c(file, output)), add = TRUE)
  conn <- ddbs_create_conn(file, duckdb_storage_version = "v1.0.0")
  on.exit(try(ddbs_stop_conn(conn), silent = TRUE), add = TRUE)
  ddbs_write_table(conn, gp_points(3857), "legacy_points", quiet = TRUE)
  source <- as_duckspatial_df("legacy_points", conn = conn)
  expect_equal(attr(source, "crs")$epsg, 3857)

  ddbs_write_dataset(source, output, conn = conn, quiet = TRUE)
  md <- gp_metadata(conn, output)
  expect_equal(md$version, "1.0.0")
  expect_true(is.list(md$columns$geometry$crs))
})
