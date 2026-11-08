# Compatibility checks for native COPY modes and quoted options.
testthat::skip_on_cran()
testthat::skip_if_not_installed("duckdb", minimum_version = "2.0.0")

test_that("missing column names are rejected while the literal NA name is retained", {
  conn <- ddbs_temp_conn()
  source <- sf::st_sf(
    id = 17L, geometry = sf::st_sfc(sf::st_point(c(1, 2)), crs = 4326)
  )
  output <- tempfile(fileext = ".parquet")
  on.exit(unlink(output), add = TRUE)
  names(source)[[1L]] <- NA_character_
  for (version in c("V1", "V2")) {
    expect_error(ddbs_write_dataset(
      source, output, conn = conn, geoparquet_version = version, quiet = TRUE
    ))
    expect_false(file.exists(output))
  }

  names(source)[[1L]] <- "NA"
  p <- as.character(DBI::dbQuoteString(conn, output))
  for (version in c("V1", "V2")) {
    expect_no_error(ddbs_write_dataset(
      source, output, conn = conn, geoparquet_version = version, quiet = TRUE
    ))
    expect_equal(DBI::dbGetQuery(conn, paste0(
      'SELECT "NA" AS id FROM read_parquet(', p, ")"
    ))$id, 17L)
    unlink(output)
  }
})

test_that("native BOTH and NONE options retain EPSG and custom CRS", {
  conn <- ddbs_temp_conn()
  custom <- sf::st_crs(
    "+proj=aeqd +lat_0=52.5 +lon_0=13.4 +datum=WGS84 +units=m +no_defs"
  )
  source <- sf::st_sf(
    id = 1:2,
    projected = sf::st_sfc(
      sf::st_point(c(300000, 6000000)), sf::st_point(c(400000, 6100000)),
      crs = 3857
    ),
    local = sf::st_sfc(
      sf::st_point(c(10, 20)), sf::st_point(c(30, 40)), crs = custom
    ),
    sf_column_name = "projected"
  )
  output <- tempfile(fileext = ".parquet")
  on.exit(unlink(output), add = TRUE)
  p <- as.character(DBI::dbQuoteString(conn, output))

  for (version in c("BOTH", "NONE")) {
    ddbs_write_dataset(
      source, output, conn = conn,
      options = list(GEOPARQUET_VERSION = version), quiet = TRUE
    )
    geo_keys <- DBI::dbGetQuery(conn, paste0(
      "SELECT decode(key) AS key FROM parquet_kv_metadata(", p,
      ") WHERE decode(key) = 'geo'"
    ))$key
    expect_length(geo_keys, if (version == "BOTH") 1L else 0L)
    result <- DBI::dbGetQuery(conn, paste0(
      "SELECT ST_CRS(projected) AS projected_crs, ST_CRS(local) AS local_crs, ",
      "ST_X(projected) AS px, ST_Y(projected) AS py, ",
      "ST_X(local) AS lx, ST_Y(local) AS ly ",
      "FROM read_parquet(", p, ") ORDER BY id"
    ))
    expect_equal(sf::st_crs(result$projected_crs[[1L]])$epsg, 3857)
    expect_true(sf::st_crs(result$local_crs[[1L]]) == custom)
    expect_equal(result[c("px", "py", "lx", "ly")], data.frame(
      px = c(300000, 400000), py = c(6000000, 6100000),
      lx = c(10, 30), ly = c(20, 40)
    ))
    unlink(output)
  }
})

test_that("quoted geometry and metadata names survive GeoParquet export", {
  conn <- ddbs_temp_conn()
  source <- sf::st_sf(
    id = 1L, geometry = sf::st_sfc(sf::st_point(c(1, 2)), crs = 4326)
  )
  geometry_name <- 'geom" name'
  names(source)[[2L]] <- geometry_name
  sf::st_geometry(source) <- geometry_name
  key <- 'owner" note'
  value <- "O'Brien's sample\nsecond line"
  output <- tempfile(fileext = ".parquet")
  on.exit(unlink(output), add = TRUE)
  p <- as.character(DBI::dbQuoteString(conn, output))

  for (version in c("V1", "V2")) {
    ddbs_write_dataset(
      source, output, conn = conn, geoparquet_version = version,
      options = list(kv_metadata = stats::setNames(list(value), key)),
      quiet = TRUE
    )
    metadata <- DBI::dbGetQuery(conn, paste0(
      "SELECT decode(key) AS key, decode(value) AS value ",
      "FROM parquet_kv_metadata(", p, ")"
    ))
    expect_equal(metadata$value[metadata$key == key], value)
    geo <- jsonlite::fromJSON(metadata$value[metadata$key == "geo"],
                              simplifyVector = FALSE)
    expect_equal(geo$primary_column, geometry_name)
    geometry <- DBI::dbQuoteIdentifier(conn, geometry_name)
    expect_equal(DBI::dbGetQuery(conn, paste0(
      "SELECT ST_AsText(", geometry, ") AS geometry FROM read_parquet(", p, ")"
    ))$geometry, "POINT (1 2)")
    unlink(output)
  }
})

test_that("COPY options retain precedence and failed local exports clean up", {
  conn <- ddbs_temp_conn()
  source <- sf::st_sf(
    id = 1L, geometry = sf::st_sfc(sf::st_point(c(1, 2)), crs = 4326)
  )
  tables <- sort(DBI::dbListTables(conn))
  output <- tempfile(fileext = ".parquet")
  on.exit(unlink(output), add = TRUE)
  p <- as.character(DBI::dbQuoteString(conn, output))
  ddbs_write_dataset(
    source, output, conn = conn, parquet_compression = "snappy",
    options = list(geoparquet_version = "v2", compression = "zstd",
                   compression_level = 1L), quiet = TRUE
  )
  metadata <- DBI::dbGetQuery(conn, paste0(
    "SELECT decode(value) AS value FROM parquet_kv_metadata(", p,
    ") WHERE decode(key) = 'geo'"
  ))$value
  expect_equal(jsonlite::fromJSON(metadata)$version, "2.0.0")
  expect_equal(unique(DBI::dbGetQuery(conn, paste0(
    "SELECT compression FROM parquet_metadata(", p, ")"
  ))$compression), "ZSTD")
  unlink(output)

  expect_error(ddbs_write_dataset(
    source, output, conn = conn, geoparquet_version = "V1",
    options = list(GEOPARQUET_VERSION = "V2"), quiet = TRUE
  ), "Conflicting")
  # This rejection occurs after the local sf data have been registered.
  expect_error(ddbs_write_dataset(
    source, output, conn = conn,
    options = list(KV_METADATA = list(GeO = "reserved")), quiet = TRUE
  ), "managed by duckspatial")
  expect_false(file.exists(output))
  expect_identical(sort(DBI::dbListTables(conn)), tables)
  expect_true(DBI::dbIsValid(conn))
})
