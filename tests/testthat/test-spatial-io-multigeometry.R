testthat::skip_on_cran()
testthat::skip_if_not_installed("sf")
testthat::skip_if_not_installed("duckdb", minimum_version = "2.0.0")

test_that("persistent and Arrow ingestion preserve all geometry columns", {
  conn <- ddbs_temp_conn()
  first <- sf::st_sfc(
    sf::st_point(c(7, 50)),
    sf::st_point(c(8, 51)),
    crs = 4326
  )
  second <- sf::st_transform(first, 3857)
  x <- sf::st_sf(id = 1:2, secondary = first,
                 active = second, sf_column_name = "active")

  for (mode in c("table", "view", "as")) {
    name <- paste0("multigeom_", mode)
    if (mode == "table") ddbs_write_table(conn, x, name, quiet = TRUE)
    if (mode == "view") ddbs_register_table(conn, x, name, quiet = TRUE)
    lazy <- if (mode == "as") {
      as_duckspatial_df(x, conn = conn)
    } else {
      as_duckspatial_df(name, conn = conn)
    }
    desc <- DBI::dbGetQuery(
      conn, paste0("DESCRIBE ", if (mode == "as") attr(lazy, "source_table") else name)
    )
    geometry_types <- stats::setNames(desc$column_type, desc$column_name)
    expect_true(all(c("secondary", "active") %in% names(geometry_types)))
    expect_match(geometry_types[["secondary"]], "^GEOMETRY")
    expect_match(geometry_types[["active"]], "^GEOMETRY")
    expect_equal(duckspatial:::ddbs_crs_from_geometry_type(
      geometry_types[["secondary"]])$epsg, 4326)
    expect_equal(duckspatial:::ddbs_crs_from_geometry_type(
      geometry_types[["active"]])$epsg, 3857)
    expect_equal(attr(lazy, "sf_column"), "active")

    result <- dplyr::collect(lazy)
    expect_s3_class(result, "sf")
    expect_equal(attr(result, "sf_column"), "active")
    expect_s3_class(result$active, "sfc")
    expect_s3_class(result$secondary, "sfc")
    expect_equal(sf::st_crs(result$active)$epsg, 3857)
    expect_equal(sf::st_crs(result$secondary)$epsg, 4326)
    expect_equal(sf::st_as_binary(result$active),
                 sf::st_as_binary(x$active))
    expect_equal(sf::st_as_binary(result$secondary),
                 sf::st_as_binary(x$secondary))
    if (mode != "as") {
      direct <- ddbs_read_table(conn, name, quiet = TRUE)
      expect_s3_class(direct$secondary, "sfc")
      expect_s3_class(direct$active, "sfc")
      expect_equal(sf::st_crs(direct$secondary)$epsg, 4326)
      expect_equal(sf::st_crs(direct$active)$epsg, 3857)
    }
  }
})

test_that("multi-geometry collection output modes remain consistent", {
  conn <- ddbs_temp_conn()
  DBI::dbExecute(conn,
    paste0("CREATE TABLE multi_formats AS SELECT 1 AS id, ",
           "ST_Point(7, 50)::GEOMETRY('EPSG:4326') AS secondary, ",
           "ST_Point(1000, 2000)::GEOMETRY('EPSG:3857') AS active"))
  lazy <- as_duckspatial_df("multi_formats", conn = conn)
  expect_equal(attr(lazy, "sf_column"), "secondary")

  raw <- dplyr::collect(lazy, as = "raw")
  expect_true(is.raw(raw$secondary[[1]]))
  expect_true(is.raw(raw$active[[1]]))

  tib <- dplyr::collect(lazy, as = "tibble")
  expect_identical(names(tib), "id")

  sf <- dplyr::collect(lazy, as = "sf")
  expect_s3_class(sf$secondary, "sfc")
  expect_s3_class(sf$active, "sfc")
  expect_equal(sf::st_crs(sf$secondary)$epsg, 4326)
  expect_equal(sf::st_crs(sf$active)$epsg, 3857)

  ga <- dplyr::collect(lazy, as = "geoarrow")
  expect_s3_class(ga$secondary, "geoarrow_vctr")
  expect_s3_class(ga$active, "geoarrow_vctr")
})

test_that("multi-geometry collection handles zero rows and NULL geometry", {
  conn <- ddbs_temp_conn()
  DBI::dbExecute(conn,
    paste0("CREATE TABLE empty_multi (",
           "id INTEGER, active GEOMETRY('EPSG:3857'), ",
           "secondary GEOMETRY('EPSG:4326'))"))
  x <- as_duckspatial_df("empty_multi", conn = conn)
  out <- dplyr::collect(x)
  expect_equal(nrow(out), 0)
  expect_s3_class(out$active, "sfc")
  expect_s3_class(out$secondary, "sfc")
  expect_equal(sf::st_crs(out$active)$epsg, 3857)
  expect_equal(sf::st_crs(out$secondary)$epsg, 4326)
  DBI::dbExecute(conn, "INSERT INTO empty_multi VALUES (1, NULL, NULL)")
  out <- dplyr::collect(x)
  expect_true(all(sf::st_is_empty(out$active) | is.na(out$active)))
  expect_true(all(sf::st_is_empty(out$secondary) | is.na(out$secondary)))
})
