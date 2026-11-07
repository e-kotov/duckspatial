testthat::skip_on_cran()
testthat::skip_if_not_installed("duckdb", minimum_version = "2.0.0")

gp_crs_metadata <- function(conn, path) {
  p <- as.character(DBI::dbQuoteString(conn, path))
  value <- DBI::dbGetQuery(conn, paste0(
    "SELECT decode(value) AS json FROM parquet_kv_metadata(", p,
    ") WHERE decode(key) = 'geo'"
  ))$json
  expect_length(value, 1L)
  jsonlite::fromJSON(value[[1L]], simplifyVector = FALSE)
}

gp_crs_definition <- function(metadata, column) {
  value <- metadata$columns[[column]]$crs
  if (is.null(value)) return(sf::st_crs(NA))
  sf::st_crs(as.character(jsonlite::toJSON(value, auto_unbox = TRUE, digits = NA)))
}

gp_two_crses <- function() {
  custom <- sf::st_crs(
    "+proj=aeqd +lat_0=52.5 +lon_0=13.4 +datum=WGS84 +units=m +no_defs"
  )
  sf::st_sf(
    id = 1:2,
    projected = sf::st_sfc(
      sf::st_point(c(300000, 6000000)), sf::st_point(c(400000, 6100000)),
      crs = 3857
    ),
    local = sf::st_sfc(
      sf::st_point(c(10, 20)), sf::st_point(c(30, 40)), crs = custom
    ),
    sf_column_name = "local"
  )
}

test_that("both versions preserve a non-first active geometry and custom CRS", {
  conn <- ddbs_temp_conn()
  x <- gp_two_crses()
  custom <- sf::st_crs(x$local)
  expect_true(is.na(custom$epsg))
  for (version in c("V1", "V2")) {
    output <- tempfile(fileext = ".parquet")
    ddbs_write_dataset(
      x, output, conn = conn, geoparquet_version = version, quiet = TRUE
    )
    md <- gp_crs_metadata(conn, output)
    expect_equal(md$primary_column, "local")
    expect_setequal(names(md$columns), c("local", "projected"))
    expect_true(gp_crs_definition(md, "local") == custom)
    expect_equal(gp_crs_definition(md, "projected")$epsg, 3857)
    p <- as.character(DBI::dbQuoteString(conn, output))
    coords <- DBI::dbGetQuery(conn, paste0(
      "SELECT ST_X(local) AS lx, ST_Y(local) AS ly, ",
      "ST_X(projected) AS px, ST_Y(projected) AS py ",
      "FROM read_parquet(", p, ") ORDER BY id"
    ))
    expect_equal(coords, data.frame(
      lx = c(10, 30), ly = c(20, 40),
      px = c(300000, 400000), py = c(6000000, 6100000)
    ))
    unlink(output)
  }
})

test_that("a CRS override assigns only the active geometry without transformation", {
  conn <- ddbs_temp_conn()
  x <- gp_two_crses()
  original_crs <- sf::st_crs(x$local)
  for (version in c("V1", "V2")) {
    output <- tempfile(fileext = ".parquet")
    ddbs_write_dataset(
      x, output, conn = conn, crs = 4326,
      geoparquet_version = version, quiet = TRUE
    )
    md <- gp_crs_metadata(conn, output)
    expect_equal(md$primary_column, "local")
    expect_equal(gp_crs_definition(md, "local")$epsg, 4326)
    expect_equal(gp_crs_definition(md, "projected")$epsg, 3857)
    p <- as.character(DBI::dbQuoteString(conn, output))
    wkt <- DBI::dbGetQuery(conn, paste0(
      "SELECT ST_AsText(local) AS geom FROM read_parquet(", p, ") ORDER BY id"
    ))$geom
    expect_equal(wkt, c("POINT (10 20)", "POINT (30 40)"))
    unlink(output)
  }
  expect_true(sf::st_crs(x$local) == original_crs)
  expect_equal(sf::st_crs(x$projected)$epsg, 3857)
})

test_that("overriding a lazy primary CRS cannot relabel an unknown secondary CRS", {
  conn <- ddbs_temp_conn()
  lazy <- dplyr::tbl(conn, dbplyr::sql(paste0(
    "SELECT ST_Point(1, 2)::GEOMETRY('EPSG:4326') AS geometry, ",
    "CAST(ST_Point(300000, 6000000)::GEOMETRY('EPSG:3857') AS GEOMETRY) ",
    "AS unknown"
  )))
  output <- tempfile(fileext = ".parquet")
  on.exit(unlink(output), add = TRUE)
  ddbs_write_dataset(lazy, output, conn = conn, crs = 4326, quiet = TRUE)
  md <- gp_crs_metadata(conn, output)
  expect_equal(gp_crs_definition(md, "geometry")$epsg, 4326)
  expect_true("crs" %in% names(md$columns$unknown))
  expect_null(md$columns$unknown$crs)
  unlink(output)
  expect_error(ddbs_write_dataset(
    lazy, output, conn = conn, crs = 4326,
    geoparquet_version = "V2", quiet = TRUE
  ), "unknown CRS")
  expect_false(file.exists(output))
})

test_that("CRS is retained for native null and empty secondary geometry columns", {
  conn <- ddbs_temp_conn()
  for (n in 0:1) {
    lazy <- dplyr::tbl(conn, dbplyr::sql(paste0(
      "SELECT NULL::GEOMETRY('EPSG:4326') AS geometry, ",
      "ST_GeomFromText('POINT EMPTY')::GEOMETRY('EPSG:3857') AS secondary ",
      "FROM range(", n, ")"
    )))
    for (version in c("V1", "V2")) {
      output <- tempfile(fileext = ".parquet")
      ddbs_write_dataset(
        lazy, output, conn = conn, geoparquet_version = version, quiet = TRUE
      )
      md <- gp_crs_metadata(conn, output)
      expect_equal(gp_crs_definition(md, "geometry")$epsg, 4326)
      expect_equal(gp_crs_definition(md, "secondary")$epsg, 3857)
      p <- as.character(DBI::dbQuoteString(conn, output))
      rows <- DBI::dbGetQuery(conn, paste0(
        "SELECT geometry IS NULL AS is_null, ST_IsEmpty(secondary) AS is_empty ",
        "FROM read_parquet(", p, ")"
      ))
      expect_equal(nrow(rows), n)
      expect_true(all(rows$is_null))
      expect_true(all(rows$is_empty))
      unlink(output)
    }
  }
})
