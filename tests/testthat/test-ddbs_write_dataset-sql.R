# Regression coverage for SQL quoting in the legacy COPY writer.
testthat::skip_on_cran()

sql_copy_test_sf <- function() {
  sf::st_as_sf(
    data.frame(id = 1:3, label = c("cafe", NA_character_, "blue"),
               x = c(1, 2, 3), y = c(4, 5, 6)),
    coords = c("x", "y"), crs = 4326
  )
}

test_that("COPY accepts apostrophes, spaces and Unicode in output paths", {
  conn <- ddbs_temp_conn()
  data <- sql_copy_test_sf()
  dir <- tempfile()
  dir.create(dir)
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)

  # Double quotes in filenames are invalid on Windows, but valid on Unix.
  basename <- "O'Brien café 中文 spaced"
  if (.Platform$file.sep == "/") basename <- paste0(basename, ' "quoted"')

  for (ext in c(".csv", ".parquet", ".geojson")) {
    path <- file.path(dir, paste0(basename, ext))
    expect_no_error(ddbs_write_dataset(data, path, conn = conn, quiet = TRUE),
                    info = ext)
    expect_true(file.exists(path), info = ext)
  }
})

test_that("COPY escapes apostrophes in string-valued CSV options", {
  conn <- ddbs_temp_conn()
  path <- tempfile(fileext = ".csv")
  on.exit(unlink(path), add = TRUE)

  expect_no_error(ddbs_write_dataset(
    sql_copy_test_sf(), path, conn = conn,
    options = list(NULLSTR = "O'Brien"), quiet = TRUE
  ))
  expect_true(any(grepl("O'Brien", readLines(path, warn = FALSE), fixed = TRUE)))
})

test_that("partitioning quotes reserved, spaced and quoted column names", {
  conn <- ddbs_temp_conn()
  data <- sql_copy_test_sf()
  data[["select"]] <- c("A", "B", "A")
  data[["city name"]] <- c("one", "two", "one")
  data[['quo"ted']] <- c("x", "y", "x")
  root <- tempfile()
  dir.create(root)
  on.exit(unlink(root, recursive = TRUE), add = TRUE)

  for (i in seq_along(c("select", "city name", 'quo"ted'))) {
    col <- c("select", "city name", 'quo"ted')[[i]]
    path <- file.path(root, paste0("out", i, ".parquet"))
    expect_no_error(ddbs_write_dataset(data, path, conn = conn,
                                       partitioning = col, quiet = TRUE), info = col)
    expect_true(dir.exists(path), info = col)
    expect_gt(length(list.files(path, recursive = TRUE, pattern = "[.]parquet$")),
              0L, info = col)
  }
})

test_that("explicit COPY option expressions keep precedence over partitioning", {
  conn <- ddbs_temp_conn()
  data <- sql_copy_test_sf()
  data[["select"]] <- c("A", "B", "A")
  data[["city name"]] <- c("one", "two", "one")
  root <- tempfile()
  dir.create(root)
  on.exit(unlink(root, recursive = TRUE), add = TRUE)

  parquet_path <- file.path(root, "override.parquet")
  expect_no_error(ddbs_write_dataset(
    data, parquet_path, conn = conn, partitioning = "select",
    options = list(PARTITION_BY = '("city name")'), quiet = TRUE
  ))
  expect_true(dir.exists(file.path(parquet_path, "city name=one")))
  expect_false(dir.exists(file.path(parquet_path, "select=A")))

  csv_path <- file.path(root, "expression.csv")
  expect_no_error(ddbs_write_dataset(
    data, csv_path, conn = conn,
    options = list(FORCE_QUOTE = "('label')"), quiet = TRUE
  ))
  expect_true(file.exists(csv_path))
})
