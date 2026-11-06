
# 0. Set up --------------------------------------------------------------

skip_if(Sys.getenv("TEST_ONE") != "")
testthat::skip_on_cran()
testthat::skip_if_not_installed("duckdb")

# Failed extension downloads in DuckDB R 2.0.0 can cause an access violation in
# native dbDisconnect() on Windows, after the expected R error has returned.
# The Windows diagnostic workflow reproduces that independently with DBI and
# duckdb only. Exercise our repository/error handling at the DBI boundary;
# successful spatial installation and loading remain real integration tests.
local_extension_dbi <- function(conn, extension, installed = FALSE,
                                loaded = FALSE, errors = character(),
                                .env = parent.frame()) {
  expected_conn <- conn
  state <- new.env(parent = emptyenv())
  state$sql <- character()
  state$catalog <- data.frame(
    extension_name = extension,
    installed = installed,
    loaded = loaded,
    extension_version = "test-version"
  )

  testthat::local_mocked_bindings(
    dbGetQuery = function(conn, statement, ...) {
      stopifnot(identical(conn, expected_conn))
      stopifnot(identical(as.character(statement), "SELECT * FROM duckdb_extensions();"))
      state$catalog
    },
    dbExecute = function(conn, statement, ...) {
      stopifnot(identical(conn, expected_conn))
      sql <- as.character(statement)
      state$sql <- c(state$sql, sql)
      if (sql %in% names(errors)) stop(errors[[sql]], call. = FALSE)
      0L
    },
    .package = "DBI",
    .env = .env
  )
  state
}


# 1. ddbs_install() ------------------------------------------------------

describe("ddbs_install()", {

  describe("expected behavior", {

    it("returns TRUE invisibly on install", {
      conn <- duckdb::dbConnect(duckdb::duckdb())
      on.exit(duckdb::dbDisconnect(conn), add = TRUE)
      result <- ddbs_install(conn, quiet = TRUE)
      expect_true(result)
    })

    it("returns TRUE invisibly when already installed", {
      conn <- duckdb::dbConnect(duckdb::duckdb())
      on.exit(duckdb::dbDisconnect(conn), add = TRUE)
      ddbs_install(conn, quiet = TRUE)
      result <- ddbs_install(conn, quiet = TRUE)
      expect_true(result)
    })

    it("shows a message with quiet = FALSE", {
      conn <- duckdb::dbConnect(duckdb::duckdb())
      on.exit(duckdb::dbDisconnect(conn), add = TRUE)
      expect_message(ddbs_install(conn, quiet = FALSE))
    })

    it("shows already-installed message on repeated calls with quiet = FALSE", {
      conn <- duckdb::dbConnect(duckdb::duckdb())
      on.exit(duckdb::dbDisconnect(conn), add = TRUE)
      ddbs_install(conn, quiet = TRUE)
      expect_message(ddbs_install(conn, quiet = FALSE), "already installed")
    })

    it("suppresses all messages with quiet = TRUE", {
      conn <- duckdb::dbConnect(duckdb::duckdb())
      on.exit(duckdb::dbDisconnect(conn), add = TRUE)
      expect_no_message(ddbs_install(conn, quiet = TRUE))
      expect_no_message(ddbs_install(conn, quiet = TRUE))
    })
  })

  describe("errors", {

    it("errors when extension cannot be found in any repository", {
      conn <- duckdb::dbConnect(duckdb::duckdb())
      on.exit(duckdb::dbDisconnect(conn), add = TRUE)
      sql <- c("INSTALL nonexistent_extension_xyz;",
               "INSTALL nonexistent_extension_xyz FROM community;")
      state <- local_extension_dbi(
        conn, "nonexistent_extension_xyz",
        errors = stats::setNames(c("core download failed", "community download failed"), sql)
      )
      err <- expect_error(
        ddbs_install(conn, extension = "nonexistent_extension_xyz"),
        "Failed to install"
      )
      expect_match(conditionMessage(err), "core: core download failed", fixed = TRUE)
      expect_match(conditionMessage(err), "community: community download failed", fixed = TRUE)
      expect_identical(state$sql, sql)
    })

    it("errors when trying to upgrade an already-loaded extension", {
      conn <- duckdb::dbConnect(duckdb::duckdb())
      on.exit(duckdb::dbDisconnect(conn), add = TRUE)
      ddbs_install(conn, quiet = TRUE)
      ddbs_load(conn, quiet = TRUE, create_macros = FALSE)
      expect_error(
        ddbs_install(conn, upgrade = TRUE),
        "already loaded"
      )
    })
  })

  describe("repos argument", {

    it("validates the repos type", {
      conn <- duckdb::dbConnect(duckdb::duckdb())
      on.exit(duckdb::dbDisconnect(conn), add = TRUE)
      expect_error(ddbs_install(conn, repos = 123))
    })

    it("installs from an explicit core repository", {
      conn <- duckdb::dbConnect(duckdb::duckdb())
      on.exit(duckdb::dbDisconnect(conn), add = TRUE)
      state <- local_extension_dbi(conn, "spatial", installed = TRUE)
      res <- withVisible(
        ddbs_install(conn, extension = "spatial", repos = "core", upgrade = TRUE, quiet = TRUE)
      )
      expect_true(res$value)
      expect_false(res$visible)
      expect_identical(state$sql, "FORCE INSTALL spatial FROM core;")
    })

    it("errors clearly on an unknown repository name", {
      conn <- duckdb::dbConnect(duckdb::duckdb())
      on.exit(duckdb::dbDisconnect(conn), add = TRUE)
      sql <- "FORCE INSTALL spatial FROM not_a_real_repo_xyz;"
      state <- local_extension_dbi(
        conn, "spatial", installed = TRUE,
        errors = stats::setNames("unknown repository", sql)
      )
      expect_error(
        ddbs_install(conn, extension = "spatial", repos = "not_a_real_repo_xyz", upgrade = TRUE),
        "Failed to upgrade"
      )
      expect_identical(state$sql, sql) # Explicit repositories must never fall back.
    })

    it("quotes a repository URL as a SQL string", {
      conn <- duckdb::dbConnect(duckdb::duckdb())
      on.exit(duckdb::dbDisconnect(conn), add = TRUE)
      state <- local_extension_dbi(conn, "custom_ext")
      expect_true(ddbs_install(
        conn, extension = "custom_ext", repos = "https://example.invalid/o'repo", quiet = TRUE
      ))
      expect_identical(state$sql,
                       "INSTALL custom_ext FROM 'https://example.invalid/o''repo';")
    })
  })
})


# 2. ddbs_load() ---------------------------------------------------------

describe("ddbs_load()", {

  describe("expected behavior", {

    it("loads the spatial extension without error", {
      conn <- duckdb::dbConnect(duckdb::duckdb())
      on.exit(duckdb::dbDisconnect(conn), add = TRUE)
      ddbs_install(conn, quiet = TRUE)
      expect_no_error(ddbs_load(conn, quiet = TRUE, create_macros = FALSE))
    })

    it("shows success message with quiet = FALSE", {
      conn <- duckdb::dbConnect(duckdb::duckdb())
      on.exit(duckdb::dbDisconnect(conn), add = TRUE)
      ddbs_install(conn, quiet = TRUE)
      expect_message(ddbs_load(conn, quiet = FALSE, create_macros = FALSE), "loaded")
    })

    it("suppresses messages with quiet = TRUE", {
      conn <- duckdb::dbConnect(duckdb::duckdb())
      on.exit(duckdb::dbDisconnect(conn), add = TRUE)
      ddbs_install(conn, quiet = TRUE)
      expect_no_message(ddbs_load(conn, quiet = TRUE, create_macros = FALSE))
    })

    it("can be called again on an already-loaded extension", {
      conn <- duckdb::dbConnect(duckdb::duckdb())
      on.exit(duckdb::dbDisconnect(conn), add = TRUE)
      ddbs_install(conn, quiet = TRUE)
      ddbs_load(conn, quiet = TRUE, create_macros = FALSE)
      expect_no_error(ddbs_load(conn, quiet = TRUE, create_macros = FALSE))
    })
  })


})


# 3. Other extensions ----------------------------------------------------

test_that("community fallback installs and loads the requested extension", {
  conn <- duckdb::dbConnect(duckdb::duckdb())
  on.exit(duckdb::dbDisconnect(conn), add = TRUE)
  state <- local_extension_dbi(
    conn, "h3", errors = c("INSTALL h3;" = "not in core")
  )
  expect_message(expect_true(ddbs_install(conn, extension = "h3")),
                 "community repository")
  expect_identical(state$sql, c("INSTALL h3;", "INSTALL h3 FROM community;"))

  state$catalog$installed <- TRUE
  expect_no_error(ddbs_load(conn, extension = "h3", quiet = TRUE, create_macros = FALSE))
  expect_identical(state$sql, c(
    "INSTALL h3;", "INSTALL h3 FROM community;", "LOAD h3;", "SET geometry_always_xy = true"
  ))
})

test_that("a successful core installation does not try community", {
  conn <- duckdb::dbConnect(duckdb::duckdb())
  on.exit(duckdb::dbDisconnect(conn), add = TRUE)
  state <- local_extension_dbi(conn, "aws")
  res <- withVisible(ddbs_install(conn, extension = "aws", quiet = TRUE))
  expect_true(res$value)
  expect_false(res$visible)
  expect_identical(state$sql, "INSTALL aws;")

  state$catalog$installed <- TRUE
  expect_no_error(ddbs_load(conn, extension = "aws", quiet = TRUE, create_macros = FALSE))
  expect_identical(state$sql,
                   c("INSTALL aws;", "LOAD aws;", "SET geometry_always_xy = true"))
})

test_that("extension load errors preserve the requested target and diagnostic", {
  conn <- duckdb::dbConnect(duckdb::duckdb())
  on.exit(duckdb::dbDisconnect(conn), add = TRUE)
  state <- local_extension_dbi(
    conn, "h3", installed = TRUE,
    errors = c("LOAD h3;" = "incompatible extension binary")
  )
  err <- expect_error(
    ddbs_load(conn, extension = "h3", create_macros = FALSE), "Failed to load the h3 extension"
  )
  expect_match(conditionMessage(err), "incompatible extension binary", fixed = TRUE)
  expect_identical(state$sql, "LOAD h3;")
})


# 4. ddbs_extension_info() -----------------------------------------------

describe("ddbs_extension_info()", {

  it("returns the extension row as a one-row tibble, invisibly", {
    conn <- ddbs_create_conn()
    on.exit(ddbs_stop_conn(conn), add = TRUE)

    res <- withVisible(ddbs_extension_info(conn))
    expect_false(res$visible)
    expect_s3_class(res$value, "tbl_df")
    expect_equal(nrow(res$value), 1L)
    expect_equal(res$value$extension_name, "spatial")
    expect_true("loaded" %in% names(res$value))
  })

  it("uses the default connection when conn = NULL", {
    out <- ddbs_extension_info()
    expect_s3_class(out, "tbl_df")
    expect_equal(out$extension_name, "spatial")
  })

  it("errors on an unknown extension", {
    conn <- duckdb::dbConnect(duckdb::duckdb())
    on.exit(duckdb::dbDisconnect(conn), add = TRUE)
    expect_error(ddbs_extension_info(conn, extension = "not_a_real_extension_xyz"))
  })

  it("validates the extension argument", {
    conn <- duckdb::dbConnect(duckdb::duckdb())
    on.exit(duckdb::dbDisconnect(conn), add = TRUE)
    expect_error(ddbs_extension_info(conn, extension = 1))
  })
})
