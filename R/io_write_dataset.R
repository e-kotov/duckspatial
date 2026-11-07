#' Write spatial dataset to disk
#'
#' Writes spatial data to disk using DuckDB's `COPY` command for Parquet and
#' GDAL spatial formats, or as a native DuckDB database for `.duckdb`, `.db`,
#' and `.ddb` paths. Format is auto-detected from file extension for common
#' formats, or can be specified explicitly via `gdal_driver`.
#' 
#' Persistent DuckDB database files created by duckspatial use **Native 
#' Spatial Storage** (`storage_version = "v1.5.0"`) by default so CRS metadata is
#' retained in native `GEOMETRY` columns. These files require DuckDB >= 1.5.0
#' to open; use **Legacy Compatibility** (`storage_version = "v1.0.0"`) 
#' when the output must be readable by older DuckDB versions.
#'
#' @param data A `duckspatial_df`, `tbl_lazy` (DuckDB), or `sf` object.
#' @param path Path to output file.
#' @param gdal_driver GDAL driver name for writing spatial formats. If `NULL` (default),
#'   the driver is auto-detected from the file extension for common formats:
#'   - `.geojson`, `.json` → "GeoJSON"
#'   - `.shp` → "ESRI Shapefile"  
#'   - `.gpkg` → "GPKG"
#'   - `.fgb` → "FlatGeobuf"
#'   - `.kml` → "KML"
#'   - `.gpx` → "GPX"
#'   - `.gml` → "GML"
#'   - `.sqlite` → "SQLite"
#'   
#'   For **non-standard file extensions** (e.g., `.dat`, `.xyz`) or to **explicitly override** 
#'   auto-detection, specify the exact driver name as it appears in `ddbs_drivers()$short_name`. 
#'   Examples: `gdal_driver = "GeoJSON"`, `gdal_driver = "ESRI Shapefile"`.
#'   
#'   **Note**: If you specify a driver that doesn't match the file extension (e.g., 
#'   `path = "output.shp"` with `gdal_driver = "GeoJSON"`), a warning will be issued but 
#'   your explicit driver choice will be honored (creating a GeoJSON file with `.shp` extension).
#'   
#'   The function validates that the specified driver is available and writable on your 
#'   system. Note: `.parquet` and `.csv` files use native DuckDB writers and do not 
#'   require a GDAL driver.
#' @template conn_null
#' @param overwrite Logical. If `TRUE`, overwrites existing file.
#' @param crs Output CRS assignment (e.g., "EPSG:4326"). Passed to GDAL as `SRS`.
#'   For Parquet, overrides the active geometry column's CRS; `NA` explicitly
#'   means unknown in V1 or V1.1 output. V2 currently rejects unknown CRS because
#'   DuckDB cannot encode native `srid:0`. This assigns metadata, not a
#'   coordinate transformation.
#'   Use [ddbs_transform()] or [sf::st_transform()] to reproject first.
#' @param layer Table name for native DuckDB database output.
#' @param options Named list of additional options passed to `COPY`. For Parquet,
#'   names are case-insensitive. An existing `GEOPARQUET_VERSION` option is
#'   honoured unless it conflicts with an explicitly supplied
#'   `geoparquet_version`. For V1, V1.1 and V2, `KV_METADATA` must be a named list of strings;
#'   its `geo` key is reserved. Other options override the convenience arguments.
#'   Supply `PARTITION_BY` as column names, a parenthesized SQL identifier list,
#'   or use `partitioning`. Spatial ordering requires `PRESERVE_ORDER = TRUE`;
#'   a conflicting option is rejected.
#' @param partitioning Character vector of columns to partition by (Parquet/CSV only).
#' @param parquet_compression Compression codec for Parquet.
#' @param parquet_row_group_size Row group size for Parquet.
#' @param layer_creation_options GDAL layer creation options.
#' @template quiet
#' @param duckdb_storage_version Storage compatibility for newly created native
#'   DuckDB database files (\code{.duckdb}, \code{.db}, \code{.ddb}). See
#'   \url{https://duckdb.org/docs/internals/storage} for more information on
#'   DuckDB storage versions and compatibility.
#'   \itemize{
#'     \item \code{"v1.5.0"} (\strong{Native Spatial Storage}, Default): Preserves
#'           CRS metadata in native DuckDB \code{GEOMETRY} columns. Requires
#'           DuckDB >= 1.5.0 to open the file.
#'     \item \code{"v1.0.0"} (\strong{Legacy Compatibility}): Creates
#'           files readable by older DuckDB versions (>= 1.0.0). Persists CRS
#'           metadata in duckspatial-managed column comments (a convention not
#'           recognized by other spatial software).
#'     \item \code{"latest"}: Use the highest storage version supported by your
#'           installed DuckDB engine.
#'   }
#'   Other major version strings like \code{"v1.4.0"}, \code{"v1.3.0"}, etc., are also supported.
#' @param geoparquet_version GeoParquet output version: `"V1"` (default,
#'   1.0.0, for compatibility with older readers), `"V1.1"` (1.1.0, WKB),
#'   or `"V2"` (2.0.0, native Parquet geometry logical types and row-group
#'   geospatial statistics). Parquet output only.
#'   This is independent of `PARQUET_VERSION` and `duckdb_storage_version`.
#' @param parquet_spatial_order Logical. If `TRUE`, order Parquet rows by a
#'   Hilbert index of the active geometry within the dataset extent. Null and
#'   empty geometries sort last. This adds an extent scan and an external sort
#'   in DuckDB; it does not collect the dataset into R. Requires a single output
#'   file (no partitioning). Default is `FALSE`.
#' @param parquet_compression_level Optional integer ZSTD compression level.
#'   Requires `parquet_compression = "zstd"` (or the equivalent COPY option).
#'
#' @details
#' Parquet exports preserve each geometry column's CRS. For lazy input, the
#' native DuckDB query type is authoritative, including unknown CRS: an R
#' attribute may be stale after dplyr transformations. The legacy DuckDB
#' storage mode uses the R attribute when native geometry types lack CRS.
#' `crs` overrides the
#' active geometry without changing any other geometry column or the input.
#'
#' V2 delegates native geometry serialization and row-group statistics to
#' DuckDB, and supplies one explicit `geo` metadata block at write time. This
#' preserves the active geometry, writes full PROJJSON definitions, and pairs
#' known CRS in the native type and inline PROJJSON in the metadata. DuckDB 2.0
#' cannot construct native `srid:0`: V2 therefore rejects unknown CRS rather
#' than silently labelling its coordinates CRS84. V1 and V1.1 write WKB geometry columns with explicit `crs: null` for
#' unknown CRS. V1.1 intentionally omits optional native coordinate encodings
#' and bbox covering columns. All versions declare `geometry_types: []`
#' (unknown types), as permitted by the specifications. Only V2 has native
#' row-group geospatial type and bounds statistics. No whole-dataset
#' bounding box is incorrectly reused in partition files. No post-write file
#' rewriting or R-side geometry serialization is performed for lazy inputs.
#' V1 and V1.1 support XY and XYZ geometries. Measured geometries (XYM or
#' XYZM) require V2; V1 and V1.1 reject them without dropping measures. All geometry
#' columns must be top-level. Column names must be unique ignoring ASCII case,
#' as required by DuckDB's identifier rules.
#'
#' Spatial ordering, ZSTD compression, and a row-group size around 100000 are
#' optional distribution optimizations, not requirements of GeoParquet 2.0.
#' Defaults are not changed automatically when selecting V2.
#' Spatial ordering currently requires a single output file. DuckDB does not
#' preserve the requested order in partitioned output, so combining
#' `parquet_spatial_order = TRUE` with `partitioning` or `PARTITION_BY` is rejected.
#'
#' @return The `path` invisibly.
#' 
#' @seealso [ddbs_drivers()] to list all available GDAL drivers and formats.
#' 
#' @references 
#' This function is inspired by and builds upon the logic found in the 
#' \code{duckdbfs} package (\url{https://github.com/cboettig/duckdbfs}), 
#' particularly its \code{write_dataset} and \code{write_geo} functions.
#' For advanced features like cloud storage (S3) support, the 
#' \code{duckdbfs} package is highly recommended.
#' \url{https://geoparquet.org/releases/v1.1.0/}
#' \url{https://geoparquet.org/releases/v2.0.0/}
#' 
#' @export
#'
#' @examples
#' \dontrun{
#' library(duckspatial)
#' 
#' # Read example data
#' path <- system.file("spatial/countries.geojson", package = "duckspatial")
#' ds <- ddbs_open_dataset(path)
#' 
#' # Auto-detect format from extension
#' ddbs_write_dataset(ds, "output.geojson")
#' ddbs_write_dataset(ds, "output.gpkg")
#' ddbs_write_dataset(ds, "output.parquet")
#'
#' # GeoParquet 2.0 with optional distribution optimizations
#' ddbs_write_dataset(
#'   ds, "output_v2.parquet", geoparquet_version = "V2",
#'   parquet_spatial_order = TRUE, parquet_compression = "zstd",
#'   parquet_compression_level = 15, parquet_row_group_size = 100000
#' )
#' 
#' # Explicit GDAL driver for non-standard extension
#' ddbs_write_dataset(ds, "mydata.dat", gdal_driver = "GeoJSON")
#' 
#' # See available drivers on your system
#' drivers <- ddbs_drivers()
#' writable <- drivers[drivers$can_create == TRUE, ]
#' head(writable)
#' 
#' # CRS override
#' ddbs_write_dataset(ds, "output_3857.geojson", crs = "EPSG:3857")
#' 
#' # Overwrite existing file
#' ddbs_write_dataset(ds, "output.gpkg", overwrite = TRUE)
#' }
ddbs_write_dataset <- function(
    data,
    path,
    gdal_driver = NULL,
    conn = NULL,
    overwrite = FALSE,
    crs = NULL,
    layer = "spatial",
    options = list(),
    partitioning = if (inherits(data, c("tbl_lazy", "duckspatial_df"))) dplyr::group_vars(data) else NULL,
    parquet_compression = NULL,
    parquet_row_group_size = NULL,
    layer_creation_options = NULL,
    quiet = FALSE,
    duckdb_storage_version = duckspatial_storage_default(),
    geoparquet_version = "V1",
    parquet_spatial_order = FALSE,
    parquet_compression_level = NULL
) {
  duckdb_storage_version <- match_duckdb_storage_version(duckdb_storage_version)
  
  # 1. Resolve connection
  if (is.null(conn)) {
    conn <- extract_connection(data)
    if (is.null(conn)) conn <- ddbs_default_conn()
  }
  
  # 2. Ensure DuckDB spatial extension
  ddbs_install(conn, quiet = TRUE)
  ddbs_load(conn, quiet = TRUE)
  
  # 3. Format detection and driver resolution
  ext <- tolower(tools::file_ext(path))
  
  # Determine if native format
  is_parquet <- ext == "parquet"
  is_csv <- ext == "csv"
  is_duckdb <- has_duckdb_file_extension(path)
  is_native <- is_parquet || is_csv || is_duckdb

  if (is_parquet) {
    return(ddbs_write_geoparquet(
      data = data, path = path, conn = conn, overwrite = overwrite, crs = crs,
      options = options, partitioning = partitioning,
      compression = parquet_compression, row_group_size = parquet_row_group_size,
      quiet = quiet, version = geoparquet_version,
      version_explicit = !missing(geoparquet_version),
      spatial_order = parquet_spatial_order,
      compression_level = parquet_compression_level
    ))
  }
  if (!missing(geoparquet_version) || !identical(parquet_spatial_order, FALSE) ||
      !is.null(parquet_compression_level)) {
    cli::cli_abort("GeoParquet version, spatial ordering and compression level require a .parquet output path.")
  }
  
  # For GDAL formats, resolve driver
  driver_name <- NULL
  if (!is_native) {
    # Step 1: Try auto-detection from extension
    driver_from_ext <- get_driver_from_extension(ext)
    
    # Step 2: Use explicit driver if provided
    if (!is.null(gdal_driver)) {
      driver_name <- gdal_driver
      
      # Warn if driver and extension mismatch
      if (!is.null(driver_from_ext) && driver_from_ext != driver_name) {
        expected_ext <- get_extension_for_driver(driver_name)
        if (!is.null(expected_ext)) {
          cli::cli_warn(c(
            "Extension/driver mismatch detected.",
            "i" = "File extension {.val .{ext}} typically maps to driver {.val {driver_from_ext}}.",
            "i" = "You specified driver {.val {driver_name}}, which typically uses {.val .{expected_ext}}.",
            "i" = "Proceeding with your explicit driver choice."
          ))
        }
      }
    } else if (!is.null(driver_from_ext)) {
      # Use auto-detected driver
      driver_name <- driver_from_ext
    } else {
      # Unknown extension, no driver provided
      cli::cli_abort(c(
        "Cannot determine GDAL driver for extension {.val .{ext}}.",
        "i" = "Please specify the driver explicitly using {.arg gdal_driver}:",
        " " = "  ddbs_write_dataset(data, path, gdal_driver = \"GeoJSON\")",
        "i" = "Run {.code ddbs_drivers()} to see all available drivers."
      ))
    }
    
    # Step 3: Validate driver exists and is writable
    available_drivers <- tryCatch({
      ddbs_drivers(conn)
    }, error = function(e) {
      cli::cli_warn("Could not query available GDAL drivers. Proceeding without validation.")
      NULL
    })
    
    if (!is.null(available_drivers)) {
      # Check if driver exists
      driver_info <- available_drivers[available_drivers$short_name == driver_name, ]
      
      if (nrow(driver_info) == 0) {
        # Driver not found - provide helpful error
        writable_drivers <- available_drivers[available_drivers$can_create == TRUE, ]
        cli::cli_abort(c(
          "GDAL driver {.val {driver_name}} is not available on this system.",
          "i" = "Run {.code ddbs_drivers()} to see all available drivers.",
          "i" = "Available writable drivers include:",
          " " = paste("  -", head(writable_drivers$short_name, 10), collapse = "\n")
        ))
      } else if (!driver_info$can_create[1]) {
        # Driver exists but is read-only
        writable_drivers <- available_drivers[available_drivers$can_create == TRUE, ]
        cli::cli_abort(c(
          "GDAL driver {.val {driver_name}} is read-only and cannot be used for writing.",
          "i" = "Run {.code ddbs_drivers()} and check the {.field can_create} column.",
          "i" = "Available writable drivers include:",
          " " = paste("  -", head(writable_drivers$short_name, 10), collapse = "\n")
        ))
      }
    }
  }
  
  # 4. Check for existing file
  if (file.exists(path)) {
    if (!overwrite) {
      cli::cli_abort("File {.path {path}} already exists. Use {.arg overwrite = TRUE} to replace.")
    } else {
      # For GDAL formats, explicit delete is safer/more consistent
      if (!is_native) {
        unlink(path)
      }
      if (is_duckdb) {
        unlink(path)
      }
      # For native CSV, use OVERWRITE_OR_IGNORE below.
    }
  }

  if (is_duckdb) {
    return(ddbs_write_duckdb_dataset(
      data = data,
      path = path,
      layer = layer,
      overwrite = TRUE,
      crs = crs,
      duckdb_storage_version = duckdb_storage_version,
      quiet = quiet
    ))
  }

  # 4b. Auto-detect CRS for GDAL formats; native Parquet is handled above.
  if (is.null(crs) && !is_native) {
      # Try to detect from data
      obj_crs <- tryCatch(ddbs_crs(data, conn = conn), error = function(e) NULL)
      if (!is.null(obj_crs) && !is.na(obj_crs)) {
          # Prefer Authority Code (EPSG:xxxx) if available, else WKT
          # sf crs object
          epsg <- obj_crs$epsg
          if (!is.null(epsg) && !is.na(epsg)) {
              crs <- paste0("EPSG:", epsg)
          } else {
              crs <- obj_crs$wkt
          }
      }
  }
  
  # 5. Logic to generate the SQL source
  # We want the 'source' to be either a table name or (subquery)
  view_name <- NULL
  sql_source <- NULL
  
  if (inherits(data, c("duckspatial_df", "tbl_lazy", "tbl_duckdb_connection"))) {
    # Efficient table name extraction or subquery construction
    # Upstream PR #182: trust source_table only if it matches the query.
    r_name <- tryCatch(dbplyr::remote_name(data), error = function(e) NULL)
    source_table <- attr(data, "source_table")
    if (!is.null(source_table) && !is.null(r_name) && !inherits(r_name, "sql") &&
        as.character(r_name) == source_table) {
      r_name <- source_table
    }
    is_simple_table <- !is.null(r_name) && is.character(r_name)
    
    if (is_simple_table) {
       sql_source <- r_name
    } else {
       sql_source <- paste0("(", dbplyr::sql_render(data, con = conn), ")")
    }
    
    # Strict Remote Validation: introspect types using DESCRIBE
    # We must ensure there is a GEOMETRY column.
    dtypes <- tryCatch({
        DBI::dbGetQuery(conn, glue::glue("DESCRIBE SELECT * FROM {sql_source} LIMIT 0"))
    }, error = function(e) {
        # Fallback if describe fails (complex queries?), though usually works
        NULL
    })
    
    has_geometry_type <- FALSE
    if (!is.null(dtypes) && "column_type" %in% names(dtypes)) {
        has_geometry_type <- any(grepl("GEOMETRY", dtypes$column_type))
    }
    
    if (!has_geometry_type) {
         cli::cli_abort("Input DuckDB table/query does not contain a spatial column of type 'GEOMETRY'.")
    }

    # Sanitize column names for specific drivers (e.g. FID in GeoPackage)
    if (!is.null(driver_name) && driver_name == "GPKG" && !is.null(dtypes)) {
         cols_in_table <- dtypes$column_name
         if (any(toupper(cols_in_table) == "FID")) {
             q_cols_list <- lapply(cols_in_table, function(col) {
                 q <- DBI::dbQuoteIdentifier(conn, col)
                 if (toupper(col) == "FID") return(paste0(q, " AS FID_original"))
                 return(q)
             })
             cols_sql <- paste(unlist(q_cols_list), collapse = ", ")
             sql_source <- glue::glue("(SELECT {cols_sql} FROM {sql_source})")
             cli::cli_alert_warning("Column 'FID' renamed to 'FID_original' to avoid conflict with GeoPackage primary key.")
         }
    }
    
  } else if (inherits(data, c("sf", "data.frame"))) {
    if (!inherits(data, "sf")) {
       cli::cli_abort("Input local data must be an 'sf' object. Plain data.frames are not supported.")
    }
    
    view_name <- ddbs_temp_view_name()
    
    tryCatch({
       # Ensure view doesn't exist (robust check)
       tryCatch(duckdb::duckdb_unregister(conn, view_name), error = function(e) NULL)
       DBI::dbExecute(conn, glue::glue("DROP VIEW IF EXISTS {view_name}"))
       
       if (inherits(data, "sf")) {
           # Explicitly convert to WKB to ensure consistent DuckDB typing (BLOB)
           wkb_col <- attr(data, "sf_column")
           data[[wkb_col]] <- ddbs_sfc_to_wkb(data[[wkb_col]])
           
           # Register the WKB-fied data frame
           duckdb::duckdb_register(conn, view_name, data)
           
           # Cast Blob geometry to GEOMETRY type for spatial formats
           gcol <- attr(data, "sf_column")
           col_names <- setdiff(names(data), gcol)
           
           # Use proper quoting
           q_gcol <- DBI::dbQuoteIdentifier(conn, gcol)
           geom_expr <- glue::glue("ST_GeomFromWKB({q_gcol})")
           
           if (length(col_names) > 0) {
               # Check for potentially conflicting columns (e.g. FID in GeoPackage)
               if (!is.null(driver_name) && driver_name == "GPKG" && any(toupper(col_names) == "FID")) {
                   q_cols_list <- lapply(col_names, function(col) {
                       q <- DBI::dbQuoteIdentifier(conn, col)
                       if (toupper(col) == "FID") return(paste0(q, " AS FID_original"))
                       return(q)
                   })
                   cols_sql <- paste(unlist(q_cols_list), collapse = ", ")
                   cli::cli_alert_warning("Column 'FID' renamed to 'FID_original' to avoid conflict with GeoPackage primary key.")
               } else {
                   q_cols <- DBI::dbQuoteIdentifier(conn, col_names)
                   cols_sql <- paste(q_cols, collapse = ", ")
               }
              subquery <- glue::glue("SELECT {cols_sql}, {geom_expr} AS {q_gcol} FROM {view_name}")
           } else {
              subquery <- glue::glue("SELECT {geom_expr} AS {q_gcol} FROM {view_name}")
           }
           sql_source <- paste0("(", subquery, ")")
           
       } else {
           duckdb::duckdb_register(conn, view_name, data)
           sql_source <- view_name
       }
       
    }, error = function(e) {
       cli::cli_abort("Failed to register local data frame: {e$message}")
    })
    
  } else {
    cli::cli_abort("Unsupported input type: {.cls {class(data)}}")
  }
  
  # 6. Build COPY options (native Parquet is handled above)
  copy_ops <- list()
  if (is_csv) {
      copy_ops$FORMAT <- "CSV"
  } else {
      copy_ops$FORMAT <- "GDAL"
      copy_ops$DRIVER <- driver_name
      if (is.null(layer_creation_options)) {
          layer_creation_options <- "WRITE_BBOX=YES"
      }
      if (!is.null(crs)) {
          copy_ops$SRS <- crs
      }
  }
  
  if (is_native && overwrite) {
      copy_ops$OVERWRITE_OR_IGNORE <- TRUE
  }
  if (!is.null(parquet_compression)) {
      copy_ops$COMPRESSION <- parquet_compression
  }
  if (!is.null(parquet_row_group_size)) {
      copy_ops$ROW_GROUP_SIZE <- as.integer(parquet_row_group_size)
  }
  if (!is.null(partitioning) && length(partitioning) > 0) {
     p_cols <- paste(partitioning, collapse = ", ")
     copy_ops$PARTITION_BY <- paste0("(", p_cols, ")")
  }
  if (!is.null(layer_creation_options)) {
      copy_ops$LAYER_CREATION_OPTIONS <- layer_creation_options
  }
  if (length(options) > 0) {
      copy_ops <- utils::modifyList(copy_ops, options)
  }
  
  # 7. Execute COPY
  fmt_opts <- function(ops) {
      parts <- vapply(names(ops), function(n) {
          val <- ops[[n]]
          if (is.logical(val)) {
              val_str <- ifelse(val, "TRUE", "FALSE")
          } else if (is.numeric(val)) {
              val_str <- as.character(val)
          } else {
              if (grepl("^\\(", val)) {
                  val_str <- val 
              } else {
                  val_str <- paste0("'", val, "'")
              }
          }
          paste0(n, " ", val_str)
      }, character(1))
      paste(parts, collapse = ", ")
  }
  
  opt_str <- fmt_opts(copy_ops)
  query <- glue::glue("COPY {sql_source} TO '{path}' ({opt_str})")
  
  tryCatch({
      DBI::dbExecute(conn, query)
  }, finally = {
      if (!is.null(view_name)) {
          duckdb::duckdb_unregister(conn, view_name)
      }
  })
  
  if (!quiet) {
      cli::cli_alert_success("Written to {.path {path}}")
  }
  
  invisible(path)
}

#' Write a dataset to a native DuckDB database file
#' @noRd
ddbs_write_duckdb_dataset <- function(
  data,
  path,
  layer,
  overwrite,
  crs,
  duckdb_storage_version,
  quiet
) {
  target_conn <- ddbs_create_conn(path, duckdb_storage_version = duckdb_storage_version)
  on.exit(ddbs_stop_conn(target_conn), add = TRUE)

  if (!is.null(crs)) {
    if (inherits(data, "sf")) {
      sf::st_crs(data) <- sf::st_crs(crs)
    } else if (inherits(data, c("duckspatial_df", "tbl_lazy", "tbl_duckdb_connection"))) {
      data <- as_duckspatial_df(data, crs = crs)
    }
  }

  ddbs_write_table(
    conn = target_conn,
    data = data,
    name = layer,
    overwrite = overwrite,
    quiet = TRUE
  )
  ddbs_checkpoint_if_possible(target_conn)

  if (!quiet) {
    cli::cli_alert_success("Written to {.path {path}}")
  }

  invisible(path)
}

#' Convert an sf CRS to DuckDB GEOMETRY CRS text for GeoParquet writes
#' @noRd
ddbs_write_dataset_crs_text <- function(crs, conn) {
    if (is.null(crs) || is.na(crs)) {
        return(NULL)
    }

    epsg <- crs$epsg
    if (!is.null(epsg) && length(epsg) > 0 && !is.na(epsg)) {
        return(paste0("EPSG:", as.integer(epsg)))
    }

    wkt <- crs$wkt
    if (is.null(wkt) || length(wkt) == 0 || is.na(wkt) || identical(wkt, "")) {
        cli::cli_abort(
            "DuckDB GeoParquet export requires PROJJSON CRS metadata for custom or non-EPSG CRS values, but the input CRS has no WKT representation."
        )
    }

    projjson <- tryCatch(
        {
            sf::st_as_text(crs, projjson = TRUE)
        },
        error = function(e) {
            cli::cli_abort(
                c(
                    "DuckDB GeoParquet export requires PROJJSON CRS metadata for custom or non-EPSG CRS values.",
                    "x" = "{.fun sf::st_as_text} failed to convert the input CRS to PROJJSON.",
                    "i" = conditionMessage(e)
                )
            )
        }
    )

    if (!grepl("^\\s*\\{", projjson) || !grepl("\\}\\s*$", projjson)) {
        cli::cli_abort(
            c(
                "DuckDB GeoParquet export requires PROJJSON CRS metadata for custom or non-EPSG CRS values.",
                "x" = "{.fun sf::st_as_text} did not return a PROJJSON object."
            )
        )
    }

    projjson
}

#' Helper to extract connection from object
#' @noRd
extract_connection <- function(x) {
    if (inherits(x, c("tbl_duckdb_connection", "duckspatial_df"))) {
        return(dbplyr::remote_con(x))
    }
    if (inherits(x, "tbl_lazy")) {
        con <- dbplyr::remote_con(x)
        if (inherits(con, "duckdb_connection")) return(con)
    }
    NULL
}

#' Map file extension to GDAL driver name
#' @noRd
get_driver_from_extension <- function(ext) {
  ext_map <- list(
    "geojson" = "GeoJSON",
    "json" = "GeoJSON",
    "shp" = "ESRI Shapefile",
    "gpkg" = "GPKG",
    "fgb" = "FlatGeobuf",
    "kml" = "KML",
    "gpx" = "GPX",
    "gml" = "GML",
    "sqlite" = "SQLite",
    "tab" = "MapInfo File",
    "mif" = "MapInfo File"
  )
  ext_map[[tolower(ext)]]
}

#' Get extension for a driver (inverse mapping)
#' @noRd
get_extension_for_driver <- function(driver) {
  driver_to_ext <- list(
    "GeoJSON" = "geojson",
    "ESRI Shapefile" = "shp",
    "GPKG" = "gpkg",
    "FlatGeobuf" = "fgb",
    "KML" = "kml",
    "GPX" = "gpx",
    "GML" = "gml",
    "SQLite" = "sqlite",
    "MapInfo File" = "tab"
  )
  driver_to_ext[[driver]]
}
