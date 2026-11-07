# GeoParquet 1.1 WKB, stacked on the V2 export infrastructure.
testthat::skip_on_cran()
testthat::skip_if_not_installed("duckdb", minimum_version = "2.0.0")

gp11_metadata <- function(conn, path) {
  p <- as.character(DBI::dbQuoteString(conn, path))
  values <- DBI::dbGetQuery(conn, paste0(
    "SELECT decode(value) AS val FROM parquet_kv_metadata(", p,
    ") WHERE decode(key) = 'geo'"
  ))$val
  testthat::expect_length(values, 1L)
  jsonlite::fromJSON(values[[1L]], simplifyVector = FALSE)
}

gp11_crs <- function(md, column) {
  value <- md$columns[[column]]$crs
  if (is.null(value)) return(sf::st_crs(NA))
  sf::st_crs(as.character(jsonlite::toJSON(value, auto_unbox = TRUE, digits = NA)))
}

test_that("1.1 is opt-in and V1 remains the default", {
  conn <- ddbs_temp_conn()
  x <- sf::st_sf(
    id = 1:2,
    geometry = sf::st_sfc(sf::st_point(c(1, 2)),
                          sf::st_point(c(3, 4)), crs = 4326)
  )
  cases <- list(
    list(args = list(), version = "1.0.0"),
    list(args = list(geoparquet_version = "V1"), version = "1.0.0"),
    list(args = list(geoparquet_version = "V1.1"), version = "1.1.0"),
    list(args = list(options = list(GEOPARQUET_VERSION = "V1.1")),
         version = "1.1.0"),
    list(args = list(geoparquet_version = "V2"), version = "2.0.0")
  )
  for (case in cases) {
    path <- tempfile(fileext = ".parquet")
    do.call(ddbs_write_dataset, c(list(
      data = x, path = path, conn = conn, quiet = TRUE
    ), case$args))
    md <- gp11_metadata(conn, path)
    expect_equal(md$version, case$version)
    expect_equal(md$primary_column, "geometry")
    expect_equal(md$columns$geometry$encoding, "WKB")
    expect_length(md$columns$geometry$geometry_types, 0L)
    expect_equal(gp11_crs(md, "geometry")$epsg, 4326)
    ds <- ddbs_open_dataset(path, conn = conn)
    expect_equal(dplyr::count(ds) |> dplyr::pull(n), 2)
    expect_equal(ddbs_crs(ds)$epsg, 4326)
    unlink(path)
  }
  path <- tempfile(fileext = ".parquet")
  expect_error(ddbs_write_dataset(
    x, path, conn = conn, geoparquet_version = "V2",
    options = list(GEOPARQUET_VERSION = "V1.1"), quiet = TRUE
  ), "Conflicting")
  expect_error(ddbs_write_dataset(
    x, path, conn = conn, geoparquet_version = "V1.2", quiet = TRUE
  ), "must be one of")
  expect_false(file.exists(path))
})

test_that("1.1 handles mixed geometry, multiple CRS, unknown and custom CRS", {
  conn <- ddbs_temp_conn()
  x <- sf::st_sf(
    id = 1:3,
    other = sf::st_sfc(sf::st_point(c(3, 5)),
                       sf::st_point(c(6, 7)), sf::st_point(c(8, 9)),
                       crs = sf::st_crs(NA)),
    geometry = sf::st_sfc(
      sf::st_linestring(matrix(c(0, 0, 1, 1), ncol = 2, byrow = TRUE)),
      sf::st_polygon(list(matrix(c(0, 0, 2, 0, 2, 2, 0, 0),
                                 ncol = 2, byrow = TRUE))),
      sf::st_geometrycollection(), crs = 3857
    ), sf_column_name = "geometry"
  )
  path <- tempfile(fileext = ".parquet")
  on.exit(unlink(path), add = TRUE)
  ddbs_write_dataset(x, path, conn = conn, geoparquet_version = "V1.1",
                     quiet = TRUE)
  md <- gp11_metadata(conn, path)
  expect_equal(md$version, "1.1.0")
  expect_equal(md$primary_column, "geometry")
  expect_setequal(names(md$columns), c("geometry", "other"))
  expect_null(md$columns$other$crs)
  expect_equal(gp11_crs(md, "geometry")$epsg, 3857)
  expect_true(all(vapply(md$columns, function(z) z$encoding == "WKB", logical(1))))
  expect_false("covering" %in% names(md$columns$geometry))
  ds <- ddbs_open_dataset(path, conn = conn)
  expect_equal(dplyr::count(ds) |> dplyr::pull(n), 3)

  custom <- sf::st_sf(geometry = sf::st_sfc(sf::st_point(c(10, 20)),
    crs = "+proj=aeqd +lat_0=52 +lon_0=13 +datum=WGS84 +units=m +no_defs"))
  custom_path <- tempfile(fileext = ".parquet")
  on.exit(unlink(custom_path), add = TRUE)
  ddbs_write_dataset(custom, custom_path, conn = conn,
                     geoparquet_version = "V1.1", quiet = TRUE)
  expect_true(gp11_crs(gp11_metadata(conn, custom_path), "geometry") ==
                sf::st_crs(custom))
  unknown_path <- tempfile(fileext = ".parquet")
  on.exit(unlink(unknown_path), add = TRUE)
  ddbs_write_dataset(custom, unknown_path, conn = conn, crs = NA,
                     geoparquet_version = "V1.1", quiet = TRUE)
  expect_null(gp11_metadata(conn, unknown_path)$columns$geometry$crs)
})

test_that("1.1 exports the actual lazy query with NULL and empty geometries", {
  conn <- ddbs_temp_conn()
  DBI::dbExecute(conn, paste0(
    "CREATE TEMP TABLE gp11_lazy AS SELECT id, ",
    "ST_GeomFromText(wkt)::GEOMETRY('EPSG:3857') AS geometry, ",
    "ST_Point(id, id)::GEOMETRY('EPSG:4326') AS other FROM (VALUES ",
    "(1, 'LINESTRING (0 0, 1 2)'), ",
    "(2, 'POLYGON ((0 0, 2 0, 2 2, 0 0))'), ",
    "(3, 'POINT EMPTY'), (4, NULL)) t(id, wkt)"
  ))
  lazy <- dplyr::tbl(conn, "gp11_lazy") |>
    dplyr::filter(id != 2L) |>
    dplyr::mutate(id = id * 10L) |>
    dplyr::rename(shape = geometry)
  path <- tempfile(fileext = ".parquet")
  on.exit(unlink(path), add = TRUE)
  ddbs_write_dataset(lazy, path, conn = conn, geoparquet_version = "V1.1",
                     parquet_spatial_order = TRUE, quiet = TRUE)
  md <- gp11_metadata(conn, path)
  expect_equal(md$primary_column, "shape")
  expect_equal(gp11_crs(md, "shape")$epsg, 3857)
  expect_equal(gp11_crs(md, "other")$epsg, 4326)
  p <- as.character(DBI::dbQuoteString(conn, path))
  rows <- DBI::dbGetQuery(conn, paste0(
    "SELECT id, ST_AsText(shape) AS wkt FROM read_parquet(", p, ") ORDER BY id"
  ))
  expect_equal(as.integer(rows$id), c(10L, 30L, 40L))
  expect_equal(rows$wkt[[1L]], "LINESTRING (0 0, 1 2)")
  expect_match(rows$wkt[[2L]], "EMPTY")
  expect_true(is.na(rows$wkt[[3L]]))
  expect_equal(dplyr::count(ddbs_open_dataset(path, conn = conn)) |>
                 dplyr::pull(n), 3)

  transformed <- dplyr::tbl(conn, dbplyr::sql(
    "SELECT ST_Point(1, 2)::GEOMETRY('EPSG:4326') AS geometry"
  )) |>
    dplyr::mutate(geometry = dbplyr::sql(
      "ST_Transform(geometry, 'EPSG:3857', always_xy := true)"
    ))
  transformed_path <- tempfile(fileext = ".parquet")
  on.exit(unlink(transformed_path), add = TRUE)
  ddbs_write_dataset(transformed, transformed_path, conn = conn,
                     geoparquet_version = "V1.1", quiet = TRUE)
  expect_equal(gp11_crs(gp11_metadata(conn, transformed_path),
                        "geometry")$epsg, 3857)
})

test_that("1.1 rejects measured sf and secondary lazy geometries", {
  conn <- ddbs_temp_conn()
  for (dim in c("XYM", "XYZM")) {
    coords <- if (dim == "XYM") c(1, 2, 3) else c(1, 2, 3, 4)
    x <- sf::st_sf(geometry = sf::st_sfc(
      sf::st_point(coords, dim = dim), crs = 4326
    ))
    path <- tempfile(fileext = ".parquet")
    expect_error(ddbs_write_dataset(
      x, path, conn = conn, geoparquet_version = "V1.1", quiet = TRUE
    ), "GeoParquet 1[.]1.*M.*V2")
    expect_equal(as.numeric(x$geometry[[1L]]), coords)
    unlink(path)
  }
  lazy <- dplyr::tbl(conn, dbplyr::sql(paste0(
    "SELECT ST_Point(1, 2)::GEOMETRY('EPSG:4326') AS geometry, ",
    "ST_GeomFromText('POINT M EMPTY')::GEOMETRY('EPSG:3857') AS other"
  )))
  path <- tempfile(fileext = ".parquet")
  expect_error(ddbs_write_dataset(
    lazy, path, conn = conn, geoparquet_version = "V1.1", quiet = TRUE
  ), "GeoParquet 1[.]1.*M.*V2")
  unlink(path)
})

test_that("1.1 supports zero rows and partitioned metadata but not partitioned ordering", {
  conn <- ddbs_temp_conn()
  x <- sf::st_sf(
    part = c("A", "B", "A"),
    geometry = sf::st_sfc(sf::st_point(c(1, 2)),
                          sf::st_point(c(3, 4)), sf::st_point(), crs = 4326)
  )
  empty_path <- tempfile(fileext = ".parquet")
  on.exit(unlink(empty_path), add = TRUE)
  ddbs_write_dataset(x[0, ], empty_path, conn = conn,
                     geoparquet_version = "V1.1", quiet = TRUE)
  expect_equal(gp11_metadata(conn, empty_path)$version, "1.1.0")
  expect_equal(dplyr::count(ddbs_open_dataset(empty_path, conn = conn)) |>
                 dplyr::pull(n), 0)
  part_path <- tempfile(fileext = ".parquet")
  on.exit(unlink(part_path, recursive = TRUE), add = TRUE)
  ddbs_write_dataset(x, part_path, conn = conn, partitioning = "part",
                     geoparquet_version = "V1.1", quiet = TRUE)
  paths <- list.files(part_path, pattern = "[.]parquet$", recursive = TRUE,
                      full.names = TRUE)
  expect_equal(length(paths), 2L)
  for (path in paths) {
    expect_equal(gp11_metadata(conn, path)$version, "1.1.0")
    expect_equal(gp11_metadata(conn, path)$primary_column, "geometry")
  }
  ordered_path <- tempfile(fileext = ".parquet")
  expect_error(ddbs_write_dataset(
    x, ordered_path, conn = conn, geoparquet_version = "V1.1",
    partitioning = "part", parquet_spatial_order = TRUE, quiet = TRUE
  ), "cannot guarantee spatial ordering")
  expect_false(file.exists(ordered_path))
})
