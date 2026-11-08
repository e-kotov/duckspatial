# Regression tests for DuckDB DBI result ownership during Arrow conversion.
testthat::skip_on_cran()
testthat::skip_if_not_installed("duckdb")
testthat::skip_if_not_installed("nanoarrow")
testthat::skip_if_not_installed("arrow")
testthat::skip_if_not_installed("geoarrow")

test_that("Arrow streams remain usable after result cleanup and source shutdown", {
  conn <- ddbs_temp_conn()
  input <- sf::st_sf(
    id = 1:5,
    geometry = sf::st_sfc(
      lapply(as.double(1:5), function(i) sf::st_point(c(i, -i))),
      crs = 4326
    )
  )
  x <- duckspatial::as_duckspatial_df(input, conn = conn)

  results <- list()
  fetch_arrow <- duckdb::duckdb_fetch_arrow
  testthat::local_mocked_bindings(
    duckdb_fetch_arrow = function(res, ...) {
      results[[length(results) + 1L]] <<- res
      fetch_arrow(res, ...)
    },
    .package = "duckdb"
  )

  streams <- lapply(c(FALSE, TRUE), function(native) {
    nanoarrow::as_nanoarrow_array_stream(x, native = native, chunk_size = 2)
  })
  expect_length(results, 2)
  for (result in results) {
    expect_s4_class(result, "duckdb_result")
    expect_false(DBI::dbIsValid(result))
  }

  duckspatial::ddbs_stop_conn(conn)
  rm(x, result)
  results <- list()
  invisible(gc())
  for (stream in streams) {
    table <- arrow::as_arrow_table(stream)
    expect_equal(table$num_rows, 5)
    expect_equal(table[["id"]]$num_chunks, 3)
    expect_equal(table[["geometry"]]$num_chunks, 3)
    values <- as.data.frame(table)
    expect_equal(values$id, input$id)
    expect_equal(
      sf::st_coordinates(sf::st_as_sfc(values$geometry)),
      sf::st_coordinates(input)
    )
    stream$release()
  }
})

test_that("failed Arrow fetch clears the DBI result", {
  result <- NULL
  fetch_arrow <- duckdb::duckdb_fetch_arrow
  testthat::local_mocked_bindings(
    duckdb_fetch_arrow = function(res, ...) {
      result <<- res
      fetch_arrow(res, ...)
    },
    .package = "duckdb"
  )

  expect_error(
    nanoarrow::as_nanoarrow_array_stream(points_ddbs, chunk_size = 0),
    "Chunk Size"
  )
  expect_s4_class(result, "duckdb_result")
  expect_false(DBI::dbIsValid(result))
})

test_that("cross-connection import clears the source result on failed registration", {
  source_conn <- ddbs_temp_conn()
  target_conn <- ddbs_temp_conn()
  expected <- data.frame(id = 1:3, label = c("a", NA_character_, "c"))
  DBI::dbWriteTable(source_conn, "source_data", expected)
  source <- dplyr::tbl(source_conn, "source_data")

  arrow_result <- NULL
  registration_attempted <- FALSE
  fetch_arrow <- duckdb::duckdb_fetch_arrow
  testthat::local_mocked_bindings(
    duckdb_fetch_arrow = function(res, ...) {
      arrow_result <<- res
      fetch_arrow(res, ...)
    },
    duckdb_register_arrow = function(conn, ...) {
      registration_attempted <<- identical(conn, target_conn)
      stop("test target Arrow registration failure", call. = FALSE)
    },
    .package = "duckdb"
  )

  expect_warning(
    imported <- import_view_to_connection(
      target_conn, source_conn, source, "fallback_import"
    ),
    "Imported via duckdb_register"
  )
  expect_identical(imported$method, "duckdb_register")
  expect_true(registration_attempted)
  expect_s4_class(arrow_result, "duckdb_result")
  expect_false(DBI::dbIsValid(arrow_result))
  expect_equal(
    DBI::dbGetQuery(target_conn, "SELECT * FROM fallback_import ORDER BY id"),
    expected
  )
  expect_true(DBI::dbIsValid(source_conn))
})
