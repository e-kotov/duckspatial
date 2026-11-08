# GeoParquet schemas must not contain native geometry types below the root.
testthat::skip_on_cran()
testthat::skip_if_not_installed("duckdb", minimum_version = "2.0.0")

test_that("sf name collisions cannot silently replace geometry or attribute values", {
  conn <- ddbs_temp_conn()
  geometries <- sf::st_sf(
    id = 1L,
    geom = sf::st_sfc(sf::st_point(c(1, 2)), crs = 4326),
    GEOM = sf::st_sfc(sf::st_point(c(300000, 6000000)), crs = 3857),
    sf_column_name = "geom"
  )
  attributes <- sf::st_sf(
    id = 1L, ID = 99L,
    geom = sf::st_sfc(sf::st_point(c(1, 2)), crs = 4326)
  )
  for (source in list(geometries, attributes)) {
    for (version in c("V1", "V2")) {
      output <- tempfile(fileext = ".parquet")
      expect_error(ddbs_write_dataset(
        source, output, conn = conn, geoparquet_version = version, quiet = TRUE
      ), "unique ignoring ASCII case")
      expect_false(file.exists(output))
    }
  }
})

test_that("GeoParquet rejects nested geometry types before writing", {
  conn <- ddbs_temp_conn()
  nested <- c(
    "[ST_Point(3, 4)]",
    "[ST_Point(3, 4)]::GEOMETRY[1]",
    "[ST_Point(3, 4)::GEOMETRY('EPSG:4326')]",
    "{'geom': ST_Point(3, 4)}",
    "{'GEOMETRY': [ST_Point(3, 4)]}",
    "MAP(['a'], [ST_Point(3, 4)])"
  )
  for (expr in nested) {
    source <- dplyr::tbl(conn, dbplyr::sql(paste0(
      "SELECT ST_Point(1, 2)::GEOMETRY('EPSG:4326') AS geometry, ",
      expr, " AS nested_geometry"
    )), vars = c("geometry", "nested_geometry"))
    for (version in c("V1", "V2")) {
      output <- tempfile(fileext = ".parquet")
      expect_error(ddbs_write_dataset(
        source, output, conn = conn, geoparquet_version = version, quiet = TRUE
      ), "must be top-level")
      expect_false(file.exists(output))
    }
  }

  # An array must not be mistaken for a root geometry even when it is the only
  # column and its element type has native CRS metadata.
  source <- dplyr::tbl(conn, dbplyr::sql(paste0(
    "SELECT [ST_Point(1, 2)::GEOMETRY('EPSG:4326')] AS geometries"
  )), vars = "geometries")
  output <- tempfile(fileext = ".parquet")
  expect_error(ddbs_write_dataset(source, output, conn = conn, quiet = TRUE),
               "must be top-level")
  expect_false(file.exists(output))
})

test_that("geometry-like enum labels and quoted field names are ordinary data", {
  conn <- ddbs_temp_conn()
  source <- dplyr::tbl(conn, dbplyr::sql(paste0(
    "SELECT ST_Point(1, 2)::GEOMETRY('EPSG:4326') AS geometry, ",
    "'GEOMETRY, label'::ENUM('GEOMETRY, label') AS enum_attr, ",
    "'a''GEOMETRY]'::ENUM('a''GEOMETRY]') AS escaped_enum_attr, ",
    "{'GEOMETRY[]': 7, 'GEOMETRY': 'ordinary text'} AS struct_attr"
  )))
  for (version in c("V1", "V2")) {
    output <- tempfile(fileext = ".parquet")
    on.exit(unlink(output), add = TRUE)
    expect_no_error(ddbs_write_dataset(
      source, output, conn = conn, geoparquet_version = version, quiet = TRUE
    ))
    p <- as.character(DBI::dbQuoteString(conn, output))
    values <- DBI::dbGetQuery(conn, paste0(
      "SELECT enum_attr, escaped_enum_attr, struct_attr['GEOMETRY[]'] AS value ",
      "FROM read_parquet(", p, ")"
    ))
    expect_equal(values$enum_attr, "GEOMETRY, label")
    expect_equal(values$escaped_enum_attr, "a'GEOMETRY]")
    expect_equal(values$value, 7L)
    unlink(output)
  }
})

test_that("legacy PARTITION_BY identifier lists still write partitioned datasets", {
  conn <- ddbs_temp_conn()
  source <- sf::st_sf(
    id = 1:2, part = c("A", "B"), subpart = c("a", "b"),
    geometry = sf::st_sfc(sf::st_point(c(1, 2)), sf::st_point(c(3, 4)),
                          crs = 4326)
  )
  source[["group name"]] <- c("C", "D")
  source[["gr\u00fcppe"]] <- c("C", "D")
  source[['quote"name']] <- c("c", "d")
  for (partition_by in c("(part)", "PART", "(PART)", '("PART")',
                          "(gr\u00fcppe)",
                          "(part, subpart)", "(pArT, SuBpArT)",
                          '("group name", "quote""name")',
                          '("GROUP NAME", "QUOTE""NAME")')) {
    output <- tempfile(fileext = ".parquet")
    expect_no_error(ddbs_write_dataset(
      source, output, conn = conn, options = list(partition_by = partition_by),
      quiet = TRUE
    ))
    files <- list.files(output, pattern = "[.]parquet$", recursive = TRUE,
                        full.names = TRUE)
    expect_equal(length(files), 2L)
    unlink(output, recursive = TRUE)
  }
  output <- tempfile(fileext = ".parquet")
  expect_no_error(ddbs_write_dataset(
    source, output, conn = conn, partitioning = "PART", quiet = TRUE
  ))
  expect_setequal(list.dirs(output, recursive = FALSE, full.names = FALSE),
                   c("part=A", "part=B"))
  unlink(output, recursive = TRUE)

  output <- tempfile(fileext = ".parquet")
  expect_error(ddbs_write_dataset(
    source, output, conn = conn,
    options = list(PARTITION_BY = "(upper(part))"), quiet = TRUE
  ), "column-name list")
  expect_error(ddbs_write_dataset(
    source, output, conn = conn,
    options = list(PARTITION_BY = "(GeOmEtRy)"), quiet = TRUE
  ), "Geometry columns cannot")
  expect_error(ddbs_write_dataset(
    source, output, conn = conn, partitioning = "GEOMETRY", quiet = TRUE
  ), "Geometry columns cannot")
  expect_error(ddbs_write_dataset(
    source, output, conn = conn,
    options = list(PARTITION_BY = "(part, PART)"), quiet = TRUE
  ), "unique column names")
  expect_error(ddbs_write_dataset(
    source, output, conn = conn, partitioning = c("part", "PART"), quiet = TRUE
  ), "unique column names")
  expect_false(file.exists(output))
})

test_that("PARTITION_BY options retain precedence over grouping and arguments", {
  conn <- ddbs_temp_conn()
  source <- dplyr::tbl(conn, dbplyr::sql(paste0(
    "SELECT ST_Point(id, id)::GEOMETRY('EPSG:4326') AS geometry, ",
    "id % 2 AS first_group, id % 3 AS chosen_group FROM range(6) t(id)"
  ))) |>
    dplyr::group_by(first_group)
  for (explicit in c(FALSE, TRUE)) {
    output <- tempfile(fileext = ".parquet")
    args <- list(data = source, path = output, conn = conn, quiet = TRUE,
                 options = list(PARTITION_BY = "(chosen_group)"))
    if (explicit) args$partitioning <- "first_group"
    expect_no_error(do.call(ddbs_write_dataset, args))
    dirs <- list.dirs(output, recursive = FALSE, full.names = FALSE)
    expect_setequal(dirs, paste0("chosen_group=", 0:2))
    unlink(output, recursive = TRUE)
  }
})

test_that("spatial ordering rejects partitioned and explicitly unordered output", {
  conn <- ddbs_temp_conn()
  source <- sf::st_sf(
    part = c("A", "B"),
    geometry = sf::st_sfc(sf::st_point(c(1, 2)), sf::st_point(c(3, 4)),
                          crs = 4326)
  )
  for (version in c("V1", "V2")) {
    output <- tempfile(fileext = ".parquet")
    expect_error(ddbs_write_dataset(
      source, output, conn = conn, geoparquet_version = version,
      parquet_spatial_order = TRUE, partitioning = "part", quiet = TRUE
    ), "cannot guarantee spatial ordering for partitioned output")
    expect_error(ddbs_write_dataset(
      source, output, conn = conn, geoparquet_version = version,
      parquet_spatial_order = TRUE,
      options = list(PARTITION_BY = "(part)"), quiet = TRUE
    ), "cannot guarantee spatial ordering for partitioned output")
    for (preserve in list(FALSE, "false", DBI::SQL("FALSE"), 0)) {
      expect_error(ddbs_write_dataset(
        source, output, conn = conn, geoparquet_version = version,
        parquet_spatial_order = TRUE,
        options = list(PRESERVE_ORDER = preserve), quiet = TRUE
      ), "requires.*PRESERVE_ORDER = TRUE")
    }
    expect_false(file.exists(output))
  }
})

test_that("spatial order survives a connection allowing unordered writes", {
  conn <- ddbs_temp_conn()
  # This connection is owned and closed by the test; no shared setting changes.
  DBI::dbExecute(conn, "SET preserve_insertion_order = FALSE")
  source <- dplyr::tbl(conn, dbplyr::sql(paste0(
    "SELECT id, ST_Point((id * 17) % 101, (id * 37) % 103)",
    "::GEOMETRY('EPSG:3857') AS geometry FROM range(6000) t(id)"
  )))
  for (version in c("V1", "V2")) {
    output <- tempfile(fileext = ".parquet")
    ddbs_write_dataset(
      source, output, conn = conn, geoparquet_version = version,
      parquet_spatial_order = TRUE, parquet_row_group_size = 2048, quiet = TRUE
    )
    p <- as.character(DBI::dbQuoteString(conn, output))
    indices <- DBI::dbGetQuery(conn, paste0(
      "SELECT ST_Hilbert(geometry, ST_MakeBox2D(ST_Point(0, 0), ",
      "ST_Point(100, 102))) AS h FROM read_parquet(", p,
      ", file_row_number = TRUE) ORDER BY file_row_number"
    ))$h
    expect_length(indices, 6000L)
    expect_true(all(diff(as.numeric(indices)) >= 0))
    expect_false(DBI::dbGetQuery(conn, paste0(
      "SELECT current_setting('preserve_insertion_order') AS value"
    ))$value[[1L]])
    unlink(output)
  }
})
