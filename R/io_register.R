#' Register an SF Object as an Arrow Table in DuckDB
#'
#' This function registers a Simple Features (SF) object as a temporary Arrow-backed
#' view in a DuckDB database. This is a zero-copy operation and is significantly
#' faster than `ddbs_write_table` for workflows that do not require data to be
#' permanently materialized in the database.
#'
#' @inheritParams ddbs_write_table
#' @returns TRUE (invisibly) on successful registration.
#' @export
#' @examples
#' \dontrun{
#' library(duckdb)
#' library(duckspatial)
#' library(sf)
#'
#' conn <- ddbs_create_conn("memory")
#'
#' nc <- st_read(system.file("shape/nc.shp", package="sf"), quiet = TRUE)
#'
#' ddbs_register_table(conn, nc, "nc_arrow_view")
#'
#' dbGetQuery(conn, "SELECT COUNT(*) FROM nc_arrow_view;")
#'
#' ddbs_stop_conn(conn)
#'}
ddbs_register_table <- function(
    conn,
    data,
    name,
    overwrite = FALSE,
    quiet = FALSE
) {
    # 1. Checks
    dbConnCheck(conn)
    name_list <- get_query_name(name)
    view_name <- name_list$query_name

    # Handle duckspatial_df/tbl_lazy by collecting to sf first
    data_sf <- if (inherits(data, "duckspatial_df")) {
        ddbs_collect(data, as = "sf")
    } else if (inherits(data, "tbl_lazy")) {
        dplyr::collect(data) |> sf::st_as_sf()
    } else if (inherits(data, "sf")) {
        data
    } else if (is.character(data) && length(data) == 1) {
        sf::st_read(data, quiet = TRUE)
    } else {
        cli::cli_abort(
            "{.arg data} must be an {.cls sf} object, {.cls duckspatial_df}, or a readable file path."
        )
    }

    tables_df <- ddbs_list_tables(conn)
    db_tables <- paste0(tables_df$table_schema, ".", tables_df$table_name) |>
        sub(pattern = "^main\\.", replacement = "")
    name_exists <- view_name %in% db_tables
    
    # Prefix only the table component if it's schema-qualified to avoid 
    # broken names like __raw_schema.table. Also, duckdb_register_arrow 
    # doesn't support schema-qualified names, so we use a single component.
    raw_view_name <- paste0("__raw_", gsub("\\.", "_", view_name))

    arrow_views <- try(
        duckdb::duckdb_list_arrow(conn),
        silent = TRUE
    )
    if (inherits(arrow_views, "try-error")) {
        arrow_views <- character(0)
    }
    
    arrow_exists <- view_name %in% arrow_views
    raw_exists <- raw_view_name %in% arrow_views

    if ((name_exists || arrow_exists || raw_exists) && !overwrite) {
        cli::cli_abort(
            "The provided view (or table) name is already present in the database. Please, use `overwrite = TRUE` or choose a different name."
        )
    }

    if (overwrite && (name_exists || arrow_exists || raw_exists)) {
        if (name_exists) {
            match_idx <- which(db_tables == view_name)[1]
            table_type <- tables_df$table_type[match_idx]
            drop_stmt <- if (
                !is.na(table_type) && identical(table_type, "VIEW")
            ) {
                glue::glue("DROP VIEW IF EXISTS {name_list$sql_name};")
            } else {
                glue::glue("DROP TABLE IF EXISTS {name_list$sql_name};")
            }
            DBI::dbExecute(conn, drop_stmt)
            if (isFALSE(quiet)) {
                cli::cli_alert_info("Existing object {view_name} dropped")
            }
        }
        
        # Also clean up any potential hidden raw arrow view
        if (raw_exists) {
            try(duckdb::duckdb_unregister_arrow(conn, raw_view_name), silent = TRUE)
        }
        
        if (arrow_exists) {
            try(
                duckdb::duckdb_unregister_arrow(conn, view_name),
                silent = TRUE
            )
        }
    }

    # 2. Register table
  
    geom_cols <- ddbs_sf_geometry_columns(data_sf)
    column_order <- ddbs_sf_column_order(data_sf)
    wkb <- lapply(geom_cols, function(col) wk::as_wkb(data_sf[[col]]))
    names(wkb) <- geom_cols
    crs <- lapply(geom_cols, function(col) sf::st_crs(data_sf[[col]]))
    names(crs) <- geom_cols

    # Use one consistent per-column Arrow encoding for both size branches.
    geoarrow_schema <- function(col) {
        crs_obj <- crs[[col]]
        geo_crs <- NULL
        if (!is.na(crs_obj)) {
            geo_crs <- if (!is.na(crs_obj$epsg)) {
                paste0("EPSG:", crs_obj$epsg)
            } else {
                crs_obj$proj4string
            }
            if (length(geo_crs) == 0L || is.na(geo_crs) ||
                !nzchar(geo_crs)) geo_crs <- NULL
        }
        geoarrow::geoarrow_wkb(crs = geo_crs)
    }
    schemas <- lapply(geom_cols, geoarrow_schema)
    names(schemas) <- geom_cols

    # Include all geometries when estimating total Arrow batch size.
    n <- nrow(data_sf)
    sample_n <- min(1000L, n)
    sample_bytes <- sum(vapply(wkb, function(geom) {
        sum(vapply(geom[seq_len(sample_n)], length, integer(1)))
    }, numeric(1)))
    avg_bytes <- if (sample_n > 0L) sample_bytes / sample_n else 0
    chunk_size <- if (avg_bytes > 0) {
        max(1000L, floor(register_chunk_target_bytes() / avg_bytes))
    } else {
        max(1000L, n)
    }

    make_batch <- function(indices) {
        df <- as.data.frame(data_sf[indices, , drop = FALSE])
        for (col in geom_cols) {
            df[[col]] <- arrow::as_arrow_array(
                geoarrow::as_geoarrow_array(wkb[[col]][indices], schema = schemas[[col]])
            )
        }
        df[column_order]
    }

    if (n == 0L || n <= chunk_size) {
        arrow_table <- arrow::Table$create(make_batch(seq_len(n)))
    } else {
        starts <- seq.int(1L, n, by = chunk_size)
        batches <- lapply(starts, function(start) {
            indices <- start:min(start + chunk_size - 1L, n)
            arrow::record_batch(make_batch(indices))
        })
        arrow_table <- arrow::RecordBatchReader$create(
            batches = batches, schema = batches[[1]]$schema
        )$read_table()
    }

    ## Register the raw Arrow table under a hidden name
    tryCatch({
        duckdb::duckdb_register_arrow(conn, raw_view_name, arrow_table)
        
        ## Wrap it in a user-facing typed view
        view_type <- if (name_list$schema_name != "main") "VIEW" else "TEMP VIEW"
        expressions <- vapply(column_order, function(col) {
            q_col <- as.character(DBI::dbQuoteIdentifier(conn, col))
            if (!col %in% geom_cols) return(q_col)
            geom_type <- duckdb_geometry_type(conn, crs[[col]])
            paste0(q_col, "::", geom_type, " AS ", q_col)
        }, character(1))
        DBI::dbExecute(conn, glue::glue(
            "CREATE OR REPLACE {view_type} {name_list$sql_name} AS ",
            "SELECT {paste(expressions, collapse = ', ')} ",
            "FROM {sql_ident(raw_view_name)}"
        ))
    }, error = function(e) {
        # Cleanup on failure to avoid stale registrations
        try(duckdb::duckdb_unregister_arrow(conn, raw_view_name), silent = TRUE)
        stop(e)
    })

    ## User feedback
    if (isFALSE(quiet)) {
        cli::cli_alert_success("Temporary view {view_name} registered")
    }

    invisible(TRUE)
}

# ddbs_register_table <- function(
#     conn,
#     data,
#     name,
#     overwrite = FALSE,
#     quiet = FALSE
# ) {
#     # 1. Checks
#     dbConnCheck(conn)
#     name_list <- get_query_name(name)
#     view_name <- name_list$query_name

#     # Handle duckspatial_df/tbl_lazy by collecting to sf first
#     data_sf <- if (inherits(data, "duckspatial_df")) {
#         ddbs_collect(data, as = "sf")
#     } else if (inherits(data, "tbl_lazy")) {
#         dplyr::collect(data) |> sf::st_as_sf()
#     } else if (inherits(data, "sf")) {
#         data
#     } else if (is.character(data) && length(data) == 1) {
#         sf::st_read(data, quiet = TRUE)
#     } else {
#         cli::cli_abort(
#             "{.arg data} must be an {.cls sf} object, {.cls duckspatial_df}, or a readable file path."
#         )
#     }

#     tables_df <- ddbs_list_tables(conn)
#     db_tables <- paste0(tables_df$table_schema, ".", tables_df$table_name) |>
#         sub(pattern = "^main\\.", replacement = "")
#     name_exists <- view_name %in% db_tables
#     arrow_views <- try(
#         duckdb::duckdb_list_arrow(conn),
#         silent = TRUE
#     )
#     arrow_exists <- if (inherits(arrow_views, "try-error")) {
#         FALSE
#     } else {
#         view_name %in% arrow_views
#     }

#     if ((name_exists || arrow_exists) && !overwrite) {
#         cli::cli_abort(
#             "The provided view (or table) name is already present in the database. Please, use `overwrite = TRUE` or choose a different name."
#         )
#     }

#     if (overwrite && (name_exists || arrow_exists)) {
#         if (name_exists) {
#             match_idx <- which(db_tables == view_name)[1]
#             table_type <- tables_df$table_type[match_idx]
#             drop_stmt <- if (
#                 !is.na(table_type) && identical(table_type, "VIEW")
#             ) {
#                 glue::glue("DROP VIEW IF EXISTS {view_name};")
#             } else {
#                 glue::glue("DROP TABLE IF EXISTS {view_name};")
#             }
#             DBI::dbExecute(conn, drop_stmt)
#             if (isFALSE(quiet)) {
#                 cli::cli_alert_info("Existing object {view_name} dropped")
#             }
#         }
#         if (arrow_exists) {
#             try(
#                 duckdb::duckdb_unregister_arrow(conn, view_name),
#                 silent = TRUE
#             )
#         }
#     }

#     # Try to register geoarrow extensions when available
#     try(
#         DBI::dbExecute(conn, "CALL register_geoarrow_extensions();"),
#         silent = TRUE
#     )

#     # 2. Register table
#     df <- sf::st_drop_geometry(data_sf)
#     wkb <- wk::as_wkb(sf::st_geometry(data_sf))

#     # Get original geometry column name
#     geom_col_name <- attr(data_sf, "sf_column")

#     # Use geoarrow to create a geoarrow vector from WKB
#     # Assign to original geometry column name instead of hardcoded "geometry"
#     df[[geom_col_name]] <- geoarrow::as_geoarrow_vctr(
#         wkb,
#         schema = geoarrow::geoarrow_wkb()
#     )

#     # Get the CRS (however, right now it doesnt recognize the CRS and defaults to GEOMETRY 
#     # without SRID, which is not ideal)
#     # data_crs <- get_geometry_type_duckdb(data_sf)
#     data_crs <- ddbs_crs(data_sf)

#     # arrow_table <- tryCatch({
#     #    arrow::Table$create(df)
#     # }, error = function(e) {
#     #    # Fallback to standard WKB (binary) if geoarrow fails
#     #    # (e.g. "NotImplemented: MakeBuilder: cannot construct builder for type geoarrow.wkb")
#     #    df[[geom_col_name]] <- wkb
#     #    arrow::Table$create(df)
#     # })
#     arrow_table <- tryCatch({
#         # Attach CRS to the geometry column via geoarrow type
#         df[[geom_col_name]] <- as_geoarrow_vctr(
#             df[[geom_col_name]],
#             type = geoarrow_wkb(crs = data_crs$input)
#         )
#         arrow::Table$create(df)
#         }, error = function(e) {
#         # Fallback: use raw WKB and embed CRS metadata manually in the field
#         df[[geom_col_name]] <- wkb
#         arrow::Table$create(df)
#     })

#     duckdb::duckdb_register_arrow(conn, view_name, arrow_table)

#     if (isFALSE(quiet)) {
#         cli::cli_alert_success("Temporary view {view_name} registered")
#     }

#     invisible(TRUE)
# }




#' Register an SF Object as an Arrow Table in DuckDB
#'
#' @description
#' `r lifecycle::badge("deprecated")`
#'
#' `ddbs_register_vector()` was renamed to \code{\link{ddbs_register_table}}.
#'
#' @inheritParams ddbs_register_table
#' @returns TRUE (invisibly) on successful registration.
#' @export
#' @keywords internal
ddbs_register_vector <- function(
    conn,
    data,
    name,
    overwrite = FALSE,
    quiet = FALSE) {
    
    lifecycle::deprecate_soft(
        when    = "1.0.0",
        what    = "ddbs_register_vector()",
        with    = "ddbs_register_table()"
    )
    
    ddbs_register_table(
        conn = conn,
        data = data,
        name = name,
        overwrite = overwrite,
        quiet = quiet
    )
}


## Target bytes per Arrow chunk in ddbs_register_table(). A function so that
## tests can lower it with testthat::local_mocked_bindings().
register_chunk_target_bytes <- function() 500 * 1024^2
