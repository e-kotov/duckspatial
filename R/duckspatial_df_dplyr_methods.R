#' dplyr methods for duckspatial_df
#'
#' These methods use dplyr's extension mechanism (dplyr_reconstruct) to
#' properly preserve spatial metadata through operations.
#'
#' @name duckspatial_df_dplyr
#' @keywords internal
NULL

# =============================================================================
# Core Extension: dplyr_reconstruct
# =============================================================================

#' @rdname duckspatial_df_dplyr
#' @export
#' @importFrom dplyr dplyr_reconstruct
dplyr_reconstruct.duckspatial_df <- function(data, template) {
  # Get the base classes from data
  base_classes <- class(data)
  
  # Reconstruct proper class hierarchy based on template
  # Template has: duckspatial_df, tbl_duckdb_connection, tbl_dbi, tbl_sql, tbl_lazy, tbl
  template_classes <- class(template)
  
  # Use template classes but only if data is likely a lazy table
  # (dplyr verbs on tbl_lazy usually return tbl_lazy)
  if (inherits(data, "tbl_sql")) {
    # Set class to match template structure
    # Ensure duckspatial_df is at the top
    if (!"duckspatial_df" %in% template_classes) {
        # Should not happen if template is duckspatial_df, but safe guard
        template_classes <- c("duckspatial_df", template_classes)
    }
    class(data) <- template_classes
  }
  
  # Restore spatial attributes from template
  # NOTE: We deliberately do NOT copy source_table here.

  # The source_table attribute is an optimization hint for get_query_list()
  # that allows direct table reference when the lazy query is unmodified.
  # However, dplyr_reconstruct is called AFTER dplyr verbs modify the query,
  # so copying source_table would cause get_query_list() to use the original
  # table instead of the modified lazy query (losing filters, selects, etc).
  #
  # By not setting source_table, get_query_list() will use sql_render() to
  # create a temporary view from the full lazy query, preserving all operations.
  attr(data, "sf_column") <- attr(template, "sf_column")
  attr(data, "crs") <- attr(template, "crs")
  
  data
}

# =============================================================================
# collect - Special handling for geometry conversion
# =============================================================================

#' Collect a duckspatial_df with flexible output formats
#'
#' @param x A duckspatial_df object
#' @param ... Additional arguments passed to dplyr::collect
#' @param as Output format: "sf" (default), "tibble" (no geometry), 
#'   "raw" (WKB bytes), or "geoarrow" (geoarrow_vctr)
#' @return Collected data in the specified format
#' @rdname ddbs_collect
#' @export
#' @importFrom dplyr collect
#' @importFrom rlang :=
collect.duckspatial_df <- function(x, ..., as = NULL) {
  if (is.null(as)) {
    as <- getOption("duckspatial.output_type", "sf")
    if (as == "duckspatial_df") as <- "sf"
  }
  as <- match.arg(as, c("sf", "tibble", "raw", "geoarrow"))

  active <- attr(x, "sf_column") %||% "geom"
  x_lazy <- x
  class(x_lazy) <- setdiff(class(x_lazy), "duckspatial_df")
  fields <- colnames(x_lazy)
  if (!active %in% fields) return(dplyr::collect(x_lazy, ...))

  conn <- dbplyr::remote_con(x_lazy)
  query <- as.character(dbplyr::sql_render(x_lazy))
  desc <- tryCatch(
    DBI::dbGetQuery(conn, paste0("DESCRIBE ", query)),
    error = function(e) NULL
  )
  if (is.null(desc)) {
    geom_cols <- active
    geom_types <- stats::setNames("GEOMETRY", active)
  } else {
    types <- stats::setNames(desc$column_type, desc$column_name)
    geom_cols <- names(types)[grepl("^GEOMETRY(\\(|$)|WKB_BLOB",
                                    types, ignore.case = TRUE)]
    geom_cols <- unique(c(geom_cols, active))
    geom_cols <- intersect(fields, geom_cols)
    geom_types <- types[geom_cols]
  }

  if (as == "tibble") {
    return(dplyr::collect(dplyr::select(x_lazy, -dplyr::all_of(geom_cols)), ...))
  }

  # DuckDB's internal GEOMETRY blobs are not WKB; convert each typed column.
  typed <- geom_cols[grepl("^GEOMETRY(\\(|$)", geom_types, ignore.case = TRUE)]
  if (length(typed)) {
    replacements <- lapply(typed, function(col) {
      quoted <- as.character(DBI::dbQuoteIdentifier(conn, col))
      dbplyr::sql(paste0("ST_AsWKB(", quoted, ")"))
    })
    names(replacements) <- typed
    x_lazy <- dplyr::mutate(x_lazy, !!!replacements)
  }

  collected <- dplyr::collect(x_lazy, ...)
  if (as == "raw") return(tibble::as_tibble(collected))

  # A rendered dbplyr SELECT may erase CRS parameters from its DESCRIBE
  # type, even when the unmodified source table declares GEOMETRY('<CRS>').
  # Consult the source schema only if it still matches the lazy query.
  source_types <- NULL
  source_table <- attr(x, "source_table")
  if (!is.null(source_table) && is.character(source_table) &&
      length(source_table) == 1L) {
    source_desc <- tryCatch(
      DBI::dbGetQuery(conn, paste0("DESCRIBE ", sql_table(source_table))),
      error = function(e) NULL
    )
    if (!is.null(source_desc)) {
      source_types <- stats::setNames(
        source_desc$column_type, source_desc$column_name
      )
    }
  }

  crs_map <- lapply(geom_cols, function(col) {
    # An explicitly supplied active CRS (or the original sf CRS) wins over
    # DuckDB's normalized authority spelling. Secondary columns have no
    # such R attribute, so recover their own CRS from the schema.
    if (identical(col, active) && !is.null(attr(x, "crs"))) {
      return(sf::st_crs(attr(x, "crs")))
    }
    declared <- ddbs_crs_from_geometry_type(geom_types[[col]])
    if (is.na(declared) && !is.null(source_types) &&
        col %in% names(source_types)) {
      declared <- ddbs_crs_from_geometry_type(source_types[[col]])
    }
    if (!is.na(declared)) return(declared)
    sf::st_crs(NA)
  })
  names(crs_map) <- geom_cols

  if (as == "geoarrow") {
    for (col in geom_cols) {
      geom_data <- collected[[col]]
      if (!inherits(geom_data, "geoarrow_vctr")) {
        attributes(geom_data) <- NULL
        crs <- crs_map[[col]]
        geo_crs <- if (!is.na(crs)) {
          if (!is.na(crs$epsg)) paste0("EPSG:", crs$epsg) else crs$proj4string
        } else NULL
        if (!is.null(geo_crs) && (length(geo_crs) == 0 || is.na(geo_crs) ||
                                  !nzchar(geo_crs))) geo_crs <- NULL
        collected[[col]] <- geoarrow::as_geoarrow_vctr(
          wk::new_wk_wkb(geom_data),
          schema = geoarrow::geoarrow_wkb(crs = geo_crs)
        )
      }
    }
    return(tibble::as_tibble(collected))
  }

  # Convert secondary geometries first; convert_to_sf_wkb constructs the sf
  # object with the active column without discarding any other sfc columns.
  for (col in setdiff(geom_cols, active)) {
    collected[[col]] <- convert_wkb_to_sfc(collected[[col]], crs_map[[col]])
  }
  convert_to_sf_wkb(collected, crs = crs_map[[active]], x_geom = active)
}

# =============================================================================
# compute - Force execution while staying lazy
# =============================================================================

#' Force computation of a duckspatial_df
#'
#' Executes the accumulated query and stores the result in a DuckDB temporary
#' table. The result remains lazy (a `duckspatial_df`) but points to the
#' materialized data, avoiding repeated computation of complex query plans.
#'
#' This is useful when you want to:
#' - Cache intermediate results for reuse across multiple subsequent operations
#' - Simplify complex query plans before heavy operations like spatial joins
#' - Force execution at a specific point without pulling data into R memory
#'
#' @param x A `duckspatial_df` object
#' @param name Optional name for the result table. If NULL, a unique temporary
#'   name is generated.
#' @param temporary If TRUE (default), creates a temporary table that is
#'   automatically cleaned up when the connection closes.
#' @param ... Additional arguments passed to [dplyr::compute()]
#' @return A new `duckspatial_df` pointing to the materialized table, with
#'   spatial metadata (CRS, geometry column) preserved.
#' @rdname duckspatial_df_dplyr
#' @export
#' @importFrom dplyr compute
#' @examples
#' \dontrun{
#' library(dplyr)
#'
#' # Complex pipeline - compute() caches intermediate result
#' result <- countries |>
#'   filter(POP_EST > 50000000) |>
#'   ddbs_filter(argentina, predicate = "touches") |>
#'   compute() |>  # Execute and cache here
#'   select(NAME_ENGL, POP_EST) |>
#'   ddbs_join(rivers, join = "intersects")
#'
#' # Check query plan - should reference the cached table
#' show_query(result)
#' }
compute.duckspatial_df <- function(x, name = NULL, temporary = TRUE, ...) {
  # Extract spatial metadata before compute
  crs <- attr(x, "crs")
  geom_col <- attr(x, "sf_column")
  
  # Strip our class to delegate to dbplyr's compute.tbl_sql
  class(x) <- setdiff(class(x), "duckspatial_df")
  
  # Execute via dbplyr
  result <- dplyr::compute(x, name = name, temporary = temporary, ...)
  
  # Get the new table name
  new_source <- tryCatch(
    as.character(dbplyr::remote_name(result)),
    error = function(e) NULL
  )

  # Get the new connection
  new_conn <- tryCatch(
    dbplyr::remote_con(result),
    error = function(e) NULL
  )
  
  # Re-wrap as duckspatial_df with preserved metadata
  new_duckspatial_df(
    result, 
    crs = crs, 
    geom_col = geom_col, 
    source_table = new_source,
    source_conn = new_conn
  )
}





# =============================================================================
# Passthrough verbs — geometry unchanged, use dplyr_reconstruct pattern
# =============================================================================


#' @rdname duckspatial_df_dplyr
#' @export
#' @importFrom dplyr select
select.duckspatial_df <- function(.data, ...) {
  atts <- attributes(.data)
  
  class(.data) <- setdiff(class(.data), "duckspatial_df")
  
  # Strip geometry, select requested cols, re-add geometry as WKB
  res <- dplyr::select(.data, ..., dplyr::all_of(atts$sf_column))
  
  new_duckspatial_df(
    x            = res,
    crs          = atts$crs,
    geom_col     = atts$sf_column,
    source_table = NULL,
    source_conn  = atts$source_conn,
    create_view  = TRUE
  )
}



#' @rdname duckspatial_df_dplyr
#' @export
#' @importFrom dplyr filter
filter.duckspatial_df <- function(.data, ...) {
  atts <- attributes(.data)
  class(.data) <- setdiff(class(.data), "duckspatial_df")
  res <- NextMethod()
  new_duckspatial_df(
    x            = res,
    crs          = atts$crs,
    geom_col     = atts$sf_column,
    source_table = NULL,
    source_conn  = atts$source_conn,
    create_view  = TRUE
  )
}



#' @rdname duckspatial_df_dplyr
#' @export
#' @importFrom dplyr arrange
arrange.duckspatial_df <- function(.data, ...) {
  atts <- attributes(.data)
  class(.data) <- setdiff(class(.data), "duckspatial_df")
  res <- NextMethod()
  new_duckspatial_df(
    x            = res,
    crs          = atts$crs,
    geom_col     = atts$sf_column,
    source_table = NULL,
    source_conn  = atts$source_conn,
    create_view  = TRUE
  )
}



#' @rdname duckspatial_df_dplyr
#' @export
#' @importFrom dplyr rename
rename.duckspatial_df <- function(.data, ...) {
  atts <- attributes(.data)
  
  # Check if geometry column is being renamed
  dots <- rlang::enquos(...)
  new_geom_col <- atts$sf_column
  for (nm in names(dots)) {
    if (rlang::as_name(dots[[nm]]) == atts$sf_column) {
      new_geom_col <- nm
      break
    }
  }
  
  class(.data) <- setdiff(class(.data), "duckspatial_df")
  res <- NextMethod()
  new_duckspatial_df(
    x            = res,
    crs          = atts$crs,
    geom_col     = new_geom_col,
    source_table = NULL,
    source_conn  = atts$source_conn,
    create_view  = TRUE
  )
}



#' @rdname duckspatial_df_dplyr
#' @export
#' @importFrom dplyr slice
slice.duckspatial_df <- function(.data, ...) {
  atts <- attributes(.data)
  class(.data) <- setdiff(class(.data), "duckspatial_df")
  res <- NextMethod()
  new_duckspatial_df(
    x            = res,
    crs          = atts$crs,
    geom_col     = atts$sf_column,
    source_table = NULL,
    source_conn  = atts$source_conn,
    create_view  = TRUE
  )
}



#' @rdname duckspatial_df_dplyr
#' @export
#' @importFrom utils head
head.duckspatial_df <- function(x, n = 6L, ...) {
  atts <- attributes(x)
  class(x) <- setdiff(class(x), "duckspatial_df")
  res <- NextMethod()
  new_duckspatial_df(
    x            = res,
    crs          = atts$crs,
    geom_col     = atts$sf_column,
    source_table = NULL,
    source_conn  = atts$source_conn,
    create_view  = TRUE
  )
}


#' @rdname duckspatial_df_dplyr
#' @export
#' @importFrom dplyr glimpse
glimpse.duckspatial_df <- function(x, width = NULL, ...) {
  # Preserve spatial metadata
  crs <- attr(x, "crs")
  geom_col <- attr(x, "sf_column")
  bbox <- st_bbox(x)
  geomtype <- ddbs_geometry_type(x, by_feature = FALSE) |> 
    as.character()

  # Strip class to delegate to dplyr's glimpse.tbl_lazy
  class(x) <- setdiff(class(x), "duckspatial_df")

  # Header
  cat(cli::col_white("# A duckspatial lazy spatial table\n"))
  cat(cli::col_white("#"), cli::col_blue("\u25cf CRS:"), cli::col_white(ddbs_format_crs(crs)), "\n")
  cat(cli::col_white("#"), cli::col_blue("\u25cf Geometry column:"), cli::col_white(geom_col), "\n")
  cat(cli::col_white("#"), cli::col_blue("\u25cf Geometry type:"), cli::col_white(geomtype), "\n")
  cat(cli::col_white("#"), cli::col_blue("\u25cf Bounding box:"), 
      cli::col_white(sprintf("xmin: %.5g ymin: %.5g xmax: %.5g ymax: %.5g", 
                              bbox["xmin"], bbox["ymin"], bbox["xmax"], bbox["ymax"])), "\n")
  cat(cli::col_white("# Data backed by DuckDB (dbplyr lazy evaluation)\n"))
  cat(cli::col_white("# Use ddbs_collect() or st_as_sf() to materialize to sf\n"))
  cat(cli::col_white("#\n"))

  # Execute via dplyr
  NextMethod()

  invisible(x)
}





# =============================================================================
# Transforming verbs — may change geometry, use new_duckspatial_df pattern
# =============================================================================

#' @rdname duckspatial_df_dplyr
#' @export
#' @importFrom dplyr mutate
mutate.duckspatial_df <- function(.data, ...) {
  atts <- attributes(.data)
  class(.data) <- setdiff(class(.data), "duckspatial_df")
  res <- NextMethod()
  new_duckspatial_df(
    x            = res,
    crs          = atts$crs,
    geom_col     = atts$sf_column,
    source_table = NULL,
    source_conn  = atts$source_conn,
    create_view  = TRUE
  )
}



#' @rdname duckspatial_df_dplyr
#' @export
#' @importFrom dplyr count
count.duckspatial_df <- function(x, ..., wt = NULL, sort = FALSE, name = NULL) {
  # count() aggregates — intentionally drops spatial class (no geometry)
  class(x) <- setdiff(class(x), "duckspatial_df")
  NextMethod()
}



#' @rdname duckspatial_df_dplyr
#' @export
#' @importFrom dplyr distinct
distinct.duckspatial_df <- function(.data, ..., .keep_all = FALSE) {
  crs <- attr(.data, "crs")
  geom_col <- attr(.data, "sf_column")
  class(.data) <- setdiff(class(.data), "duckspatial_df")
  res <- NextMethod()

  ## if geometry column is in the table, return duckspatial_df
  ## otherwise, return a lazy tbl
  if (geom_col %in% colnames(res)) {
    class(res) <- c("duckspatial_df", class(res))
    attr(res, "sf_column") <- geom_col
    attr(res, "crs") <- crs
    res
  } else {
    res
  }
}





# =============================================================================
# Join methods - preserve spatial class from left side
# =============================================================================
# Note: dbplyr join methods typically return tbl_lazy.
# Our dplyr_reconstruct should handle class restoration if dbplyr calls it.
# But often generic joins dispatch to dbplyr methods directly.
# Let's enable generic join methods just in case to verify attributes.

# #' @rdname duckspatial_df_dplyr
# #' @export
# #' @importFrom dplyr left_join
# left_join.duckspatial_df <- function(x, y, by = NULL, copy = FALSE, 
#                                       suffix = c(".x", ".y"), ...,
#                                       keep = NULL, na_matches = c("na", "never"),
#                                       relationship = NULL) {
#   # Strip class to avoid infinite recursion if NextMethod doesn't strip it?
#   # Actually NextMethod works fine.
#   out <- NextMethod()
  
#   # If out lost the class (common with dbplyr), restore it
#   if (!inherits(out, "duckspatial_df")) {
#       # Re-wrap
#       class(out) <- c("duckspatial_df", class(out))
#       attr(out, "sf_column") <- attr(x, "sf_column")
#       attr(out, "crs") <- attr(x, "crs")
#   }
  
#   out
# }

# #' @rdname duckspatial_df_dplyr
# #' @export
# #' @importFrom dplyr inner_join
# inner_join.duckspatial_df <- function(x, y, by = NULL, copy = FALSE, 
#                                        suffix = c(".x", ".y"), ...,
#                                        keep = NULL, na_matches = c("na", "never"),
#                                        relationship = NULL) {
#   out <- NextMethod()
#   if (!inherits(out, "duckspatial_df")) {
#       class(out) <- c("duckspatial_df", class(out))
#       attr(out, "sf_column") <- attr(x, "sf_column")
#       attr(out, "crs") <- attr(x, "crs")
#   }
#   out
# }

#' @rdname duckspatial_df_dplyr
#' @export
#' @importFrom dplyr left_join
left_join.duckspatial_df <- function(x, y, by = NULL, ...) {
  atts <- attributes(x)
  class(x) <- setdiff(class(x), "duckspatial_df")
  if (inherits(y, "duckspatial_df")) {
    class(y) <- setdiff(class(y), "duckspatial_df")
  }
  res <- NextMethod()
  new_duckspatial_df(
    x            = res,
    crs          = atts$crs,
    geom_col     = atts$sf_column,
    source_table = NULL,
    source_conn  = atts$source_conn,
    create_view  = TRUE
  )
}



#' @rdname duckspatial_df_dplyr
#' @export
#' @importFrom dplyr inner_join
inner_join.duckspatial_df <- function(x, y, by = NULL, ...) {
  atts <- attributes(x)
  class(x) <- setdiff(class(x), "duckspatial_df")
  if (inherits(y, "duckspatial_df")) {
    class(y) <- setdiff(class(y), "duckspatial_df")
  }
  res <- NextMethod()
  new_duckspatial_df(
    x            = res,
    crs          = atts$crs,
    geom_col     = atts$sf_column,
    source_table = NULL,
    source_conn  = atts$source_conn,
    create_view  = TRUE
  )
}



#' @rdname duckspatial_df_dplyr
#' @export
#' @importFrom dplyr right_join
right_join.duckspatial_df <- function(x, y, by = NULL, ...) {
  atts <- attributes(x)
  class(x) <- setdiff(class(x), "duckspatial_df")
  if (inherits(y, "duckspatial_df")) {
    class(y) <- setdiff(class(y), "duckspatial_df")
  }
  res <- NextMethod()
  new_duckspatial_df(
    x            = res,
    crs          = atts$crs,
    geom_col     = atts$sf_column,
    source_table = NULL,
    source_conn  = atts$source_conn,
    create_view  = TRUE
  )
}



#' @rdname duckspatial_df_dplyr
#' @export
#' @importFrom dplyr full_join
full_join.duckspatial_df <- function(x, y, by = NULL, ...) {
  atts <- attributes(x)
  class(x) <- setdiff(class(x), "duckspatial_df")
  if (inherits(y, "duckspatial_df")) {
    class(y) <- setdiff(class(y), "duckspatial_df")
  }
  res <- NextMethod()
  new_duckspatial_df(
    x            = res,
    crs          = atts$crs,
    geom_col     = atts$sf_column,
    source_table = NULL,
    source_conn  = atts$source_conn,
    create_view  = TRUE
  )
}





# =============================================================================
# Grouping and aggregating methods
# =============================================================================

.strip_spatial_attrs <- function(x) {
  attr(x, "sf_column")    <- NULL
  attr(x, "crs")          <- NULL
  attr(x, "source_table") <- NULL
  attr(x, "source_conn")  <- NULL
  x
}


#' @rdname duckspatial_df_dplyr
#' @export
#' @importFrom dplyr group_by
group_by.duckspatial_df <- function(.data, ..., .add = FALSE, .drop = dplyr::group_by_drop_default(.data)) {
  NextMethod()
}

#' @rdname duckspatial_df_dplyr
#' @export
#' @importFrom dplyr ungroup
ungroup.duckspatial_df <- function(x, ...) {
  atts <- attributes(x)
  class(x) <- setdiff(class(x), "duckspatial_df")
  res <- NextMethod()
  new_duckspatial_df(
    x            = res,
    crs          = atts$crs,
    geom_col     = atts$sf_column,
    source_table = NULL,
    source_conn  = atts$source_conn,
    create_view  = TRUE
  )
}

#' @rdname duckspatial_df_dplyr
#' @export
#' @importFrom dplyr summarise
summarise.duckspatial_df <- function(.data, ...) {
  atts <- attributes(.data)
  geom_col <- atts$sf_column

  # Check if geometry column is preserved in the summary by name only
  dots <- rlang::enquos(...)
  geom_preserved <- geom_col %in% names(dots)

  class(.data) <- setdiff(class(.data), "duckspatial_df")
  res <- NextMethod()

  if (geom_preserved) {
    new_duckspatial_df(
      x            = res,
      crs          = atts$crs,
      geom_col     = geom_col,
      source_table = NULL,
      source_conn  = atts$source_conn,
      create_view  = TRUE
    )
  } else {
    cli::cli_warn(c(
      "Geometry column {.field {geom_col}} was dropped by {.fn summarise}.",
      "i" = "Use a spatial aggregate like {.fn {geom_col} = ddbs_union({geom_col})} to preserve geometry.",
      "i" = "Result is no longer a {.cls duckspatial_df}."
    ))
    .strip_spatial_attrs(res)
  }
}