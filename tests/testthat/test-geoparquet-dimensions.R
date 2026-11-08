# GeoParquet 1.0 permits XY/XYZ; measured geometries require GeoParquet 2.0.
testthat::skip_on_cran()
testthat::skip_if_not_installed("duckdb", minimum_version = "2.0.0")

test_that("GeoParquet V1 rejects measured sf geometries without dropping M", {
  conn <- ddbs_temp_conn()
  for (dim in c("XYM", "XYZM")) {
    coords <- if (dim == "XYM") c(1, 2, 3) else c(1, 2, 3, 4)
    x <- sf::st_sf(
      geometry = sf::st_sfc(sf::st_point(coords, dim = dim), crs = 4326)
    )
    output <- tempfile(fileext = ".parquet")
    expect_error(
      ddbs_write_dataset(x, output, conn = conn, quiet = TRUE),
      "GeoParquet 1.0.*M.*V2"
    )
    unlink(output)
    # Export failure must not alter the input geometry or its coordinates.
    expect_equal(unname(as.numeric(x$geometry[[1L]])), coords)
    expect_equal(class(x$geometry[[1L]])[[1L]], dim)
  }
})

test_that("V1 checks secondary geometry columns and measured empty collections", {
  conn <- ddbs_temp_conn()
  for (wkt in c(
    "POINT M (3 4 5)", "POINT ZM (3 4 5 6)",
    "POINT M EMPTY", "GEOMETRYCOLLECTION M EMPTY",
    "GEOMETRYCOLLECTION ZM (POINT ZM (3 4 5 6))"
  )) {
    sql <- paste0(
      "SELECT id, ST_Point(id, id)::GEOMETRY('EPSG:4326') AS geometry, ",
      "CASE WHEN id = 1 THEN ST_Point(1, 2) ELSE ST_GeomFromText(",
      DBI::dbQuoteString(conn, wkt), ") END::GEOMETRY('EPSG:3857') AS measured ",
      "FROM range(1, 3) t(id)"
    )
    lazy <- dplyr::tbl(conn, dbplyr::sql(sql))
    output <- tempfile(fileext = ".parquet")
    expect_error(
      ddbs_write_dataset(lazy, output, conn = conn, quiet = TRUE),
      "GeoParquet 1.0.*M.*V2"
    )
    unlink(output)
  }
})

test_that("GeoParquet V1 retains XYZ coordinates and empty geometries", {
  conn <- ddbs_temp_conn()
  x <- sf::st_sf(
    id = 1:2,
    geometry = sf::st_sfc(
      sf::st_point(c(1, 2, 3), dim = "XYZ"),
      sf::st_point(rep(NA_real_, 3L), dim = "XYZ"), crs = 4326
    )
  )
  output <- tempfile(fileext = ".parquet")
  on.exit(unlink(output), add = TRUE)
  ddbs_write_dataset(x, output, conn = conn, quiet = TRUE)
  p <- as.character(DBI::dbQuoteString(conn, output))
  result <- DBI::dbGetQuery(conn, paste0(
    "SELECT ST_AsText(geometry) AS wkt FROM read_parquet(", p, ") ORDER BY id"
  ))
  expect_equal(result$wkt, c("POINT Z (1 2 3)", "POINT Z EMPTY"))
})

test_that("V2 retains measured secondary geometries, nulls and empty values", {
  conn <- ddbs_temp_conn()
  lazy <- dplyr::tbl(conn, dbplyr::sql(paste0(
    "SELECT id, ST_Point(id, id)::GEOMETRY('EPSG:4326') AS geometry, ",
    "CASE WHEN id = 1 THEN ST_GeomFromText('POINT M (10 20 30)') ",
    "WHEN id = 2 THEN ST_GeomFromText('POINT M EMPTY') ",
    "ELSE NULL END::GEOMETRY('EPSG:3857') AS measured, ",
    "CASE WHEN id = 1 THEN ST_GeomFromText('POINT ZM (40 50 60 70)') ",
    "WHEN id = 2 THEN ST_GeomFromText('POINT ZM EMPTY') ",
    "ELSE NULL END::GEOMETRY('EPSG:3857') AS measured_z ",
    "FROM range(1, 4) t(id)"
  )))
  output <- tempfile(fileext = ".parquet")
  on.exit(unlink(output), add = TRUE)
  ddbs_write_dataset(
    lazy, output, conn = conn, geoparquet_version = "V2",
    parquet_spatial_order = TRUE, quiet = TRUE
  )
  p <- as.character(DBI::dbQuoteString(conn, output))
  result <- DBI::dbGetQuery(conn, paste0(
    "SELECT ST_AsText(measured) AS m, ST_AsText(measured_z) AS zm ",
    "FROM read_parquet(", p, ") ORDER BY id"
  ))
  expect_equal(result$m, c("POINT M (10 20 30)", "POINT M EMPTY", NA_character_))
  expect_equal(result$zm, c("POINT ZM (40 50 60 70)", "POINT ZM EMPTY", NA_character_))
})
