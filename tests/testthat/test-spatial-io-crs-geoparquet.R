testthat::skip_on_cran()
testthat::skip_if_not_installed("duckdb", minimum_version = "2.0.0")
testthat::skip_if_not_installed("sf")

test_that("typed native CRS survives empty and NULL-only columns", {
  conn <- ddbs_temp_conn()

  DBI::dbExecute(conn, "CREATE TABLE empty_crs (g GEOMETRY('EPSG:3857'))")
  DBI::dbExecute(conn, "CREATE TABLE null_crs (g GEOMETRY('EPSG:4326'))")
  DBI::dbExecute(conn, "INSERT INTO null_crs VALUES (NULL)")
  DBI::dbExecute(conn, "CREATE TABLE generic_crs (g GEOMETRY)")

  expect_equal(ddbs_crs("empty_crs", conn = conn)$epsg, 3857)
  expect_equal(ddbs_crs("null_crs", conn = conn)$epsg, 4326)
  expect_true(is.na(ddbs_crs("generic_crs", conn = conn)))
  DBI::dbExecute(conn, "CREATE VIEW typed_view AS SELECT * FROM empty_crs")
  expect_equal(ddbs_crs("typed_view", conn = conn)$epsg, 3857)
})

test_that("a known CRS can be recovered when the first row is NULL", {
  conn <- ddbs_temp_conn()
  DBI::dbExecute(conn, "CREATE TABLE nullable (g GEOMETRY('EPSG:4326'))")
  DBI::dbExecute(conn, "INSERT INTO nullable VALUES (NULL), (ST_Point(8, 50))")
  expect_equal(ddbs_crs("nullable", conn = conn)$epsg, 4326)
})

test_that("GeoParquet metadata distinguishes absent CRS from explicit null", {
  conn <- ddbs_temp_conn()
  # Test the parser with actual on-disk footers, not just parsed JSON.
  write_fixture <- function(primary_crs = "absent") {
    col <- list(encoding = "WKB", geometry_types = list("Point"))
    if (identical(primary_crs, "null")) col["crs"] <- list(NULL)

    meta <- list(
      version = "1.1.0",
      primary_column = "secondary",
      columns = list(
        geometry = list(encoding = "WKB", geometry_types = list("Point"),
                        crs = NULL),
        secondary = col
      )
    )
    binary <- sf::st_as_binary(sf::st_sfc(sf::st_point(c(7, 51))))
    tab <- arrow::Table$create(
      id = 1L,
      geometry = arrow::Array$create(unclass(binary), type = arrow::binary()),
      secondary = arrow::Array$create(unclass(binary), type = arrow::binary())
    )
    tab <- tab$ReplaceSchemaMetadata(list(
      geo = jsonlite::toJSON(meta, auto_unbox = TRUE, null = "null", digits = NA)
    ))
    path <- tempfile(fileext = ".parquet")
    arrow::write_parquet(tab, path)
    path
  }
  p_absent <- write_fixture()
  p_null <- write_fixture("null")
  on.exit(unlink(c(p_absent, p_null)), add = TRUE)

  expect_false(is.null(duckspatial:::get_parquet_geometry_metadata(p_absent, conn)))
  expect_false(is.null(duckspatial:::get_parquet_geometry_metadata(p_null, conn)))
  absent <- duckspatial:::get_parquet_crs(p_absent, conn)
  unknown <- duckspatial:::get_parquet_crs(p_null, conn)
  expect_true(duckspatial:::crs_equal(absent, sf::st_crs("OGC:CRS84")))
  expect_true(is.na(unknown))
  for (p in c(p_absent, p_null)) {
    ds <- ddbs_open_dataset(p, conn = conn)
    expect_s3_class(ds, "duckspatial_df")
    expect_equal(attr(ds, "sf_column"), "secondary")
  }
})
