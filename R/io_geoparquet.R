# GeoParquet export helpers. Geometry serialization, compression, partitioning
# and native geospatial statistics remain entirely in DuckDB.

#' @noRd
ddbs_geoparquet_version <- function(version, native = FALSE) {
  choices <- if (native) c("V1", "V2", "BOTH", "NONE") else c("V1", "V2")
  if (!is.character(version) || length(version) != 1L || is.na(version) ||
      !toupper(version) %in% choices) {
    cli::cli_abort("{.arg geoparquet_version} must be one of {.val {choices}}.")
  }
  toupper(version)
}

#' @noRd
ddbs_geoparquet_options <- function(options, version, version_explicit) {
  if (!is.list(options) || (length(options) &&
      (is.null(names(options)) || anyNA(names(options)) ||
       any(!grepl("^[A-Za-z_][A-Za-z0-9_]*$", names(options)))))) {
    cli::cli_abort("{.arg options} must be a named list of COPY options.")
  }
  names(options) <- toupper(names(options))
  if (anyDuplicated(names(options))) {
    cli::cli_abort("{.arg options} contains duplicate COPY options (ignoring case).")
  }
  version <- ddbs_geoparquet_version(version)
  if (!is.null(options$GEOPARQUET_VERSION)) {
    option_version <- ddbs_geoparquet_version(options$GEOPARQUET_VERSION, native = TRUE)
    if (version_explicit && !identical(version, option_version)) {
      cli::cli_abort("Conflicting {.arg geoparquet_version} and {.code options$GEOPARQUET_VERSION}.")
    }
    version <- option_version
    options$GEOPARQUET_VERSION <- NULL
  }
  if (!is.null(options$FORMAT) && !identical(toupper(options$FORMAT), "PARQUET")) {
    cli::cli_abort("A {.file .parquet} path requires {.code FORMAT = 'PARQUET'}.")
  }
  options$FORMAT <- NULL
  list(version = version, options = options)
}

#' @noRd
ddbs_geoparquet_crs <- function(crs) {
  result <- tryCatch(sf::st_crs(crs), error = function(e) {
    cli::cli_abort("Cannot interpret the output CRS: {conditionMessage(e)}")
  })
  # NA is an intentional unknown CRS, not a licence to invent WGS84.
  if (is.na(result) && !(length(crs) == 1L && is.atomic(crs) && is.na(crs)) &&
      !(inherits(crs, "crs") && is.na(crs))) {
    cli::cli_abort("Cannot interpret the output CRS.")
  }
  result
}

#' @noRd
ddbs_geoparquet_native_crs <- function(conn, type) {
  if (identical(toupper(type), "GEOMETRY")) return(sf::st_crs(NA))
  # Query the type, not the first feature: empty tables and NULL first rows must
  # retain their CRS too. The type string comes from DuckDB DESCRIBE, not input.
  value <- DBI::dbGetQuery(conn, paste0(
    "SELECT ST_CRS(CAST('POINT(0 0)' AS ", type, ")) AS crs"
  ))$crs[[1L]]
  if (is.na(value) || !nzchar(value) || tolower(value) == "srid:0") {
    return(sf::st_crs(NA))
  }
  ddbs_geoparquet_crs(value)
}

#' @noRd
ddbs_geoparquet_projjson <- function(crs) {
  if (is.na(crs)) return(NULL)
  text <- sf::st_as_text(crs, projjson = TRUE)
  result <- tryCatch(jsonlite::fromJSON(text, simplifyVector = FALSE),
                     error = function(e) NULL)
  if (!is.list(result) || is.null(result$type)) {
    cli::cli_abort("GeoParquet export requires a valid inline PROJJSON CRS definition.")
  }
  result
}

#' @noRd
ddbs_geoparquet_cast <- function(expr, crs, conn, version) {
  # V1 uses ordinary WKB BLOB columns and explicit geo metadata.
  if (version == "V1") {
    return(paste0("ST_AsWKB(CAST(", expr, " AS GEOMETRY))"))
  }
  if (is.na(crs) && version == "V2") {
    # DuckDB 2.0 cannot construct GEOMETRY('srid:0'). An unqualified
    # GEOMETRY produces a native CRS84 default, conflicting with crs: null.
    cli::cli_abort(c(
      "GeoParquet 2.0 cannot encode an undefined/unknown CRS with this DuckDB writer.",
      "i" = "Use {.code geoparquet_version = 'V1'} or explicitly assign a known {.arg crs}."
    ))
  }
  text <- if (is.na(crs)) {
    NULL
  } else if (version == "V2") {
    as.character(jsonlite::toJSON(ddbs_geoparquet_projjson(crs),
                                 auto_unbox = TRUE, null = "null", digits = NA))
  } else {
    ddbs_write_dataset_crs_text(crs, conn)
  }
  if (is.null(text)) return(paste0("CAST(", expr, " AS GEOMETRY)"))
  # Assign output CRS without reprojection or mutation of source.
  paste0("CAST(CAST(", expr, " AS GEOMETRY) AS GEOMETRY(",
         DBI::dbQuoteString(conn, text), "))")
}

#' @noRd
ddbs_geoparquet_metadata <- function(crses, primary, version) {
  columns <- lapply(crses, function(crs) {
    list(encoding = "WKB", geometry_types = character(),
         crs = ddbs_geoparquet_projjson(crs))
  })
  # An empty geometry_types array explicitly means unknown in the spec. Do not
  # calculate a whole-dataset bbox/type list and incorrectly reuse it for each
  # partition. DuckDB records the actual types/extents per native row group.
  as.character(jsonlite::toJSON(
    list(version = version, primary_column = primary, columns = columns),
    auto_unbox = TRUE, null = "null", digits = NA
  ))
}

#' @noRd
ddbs_geoparquet_copy_options <- function(conn, options) {
  paste(vapply(names(options), function(key) {
    value <- options[[key]]
    if (key == "KV_METADATA") {
      if (!is.list(value) || is.null(names(value)) || anyNA(names(value)) ||
          any(!nzchar(names(value))) || anyDuplicated(names(value)) ||
          any(!vapply(value, function(x) is.character(x) && length(x) == 1L &&
                      !is.na(x), logical(1)))) {
        cli::cli_abort("{.code options$KV_METADATA} must be a named list of strings.")
      }
      entries <- vapply(names(value), function(name) {
        paste0(DBI::dbQuoteIdentifier(conn, name), ": ",
               DBI::dbQuoteString(conn, value[[name]]))
      }, character(1))
      return(paste0(key, " {", paste(entries, collapse = ", "), "}"))
    }
    if (length(value) != 1L || is.na(value)) {
      cli::cli_abort("COPY option {.val {key}} must be a non-missing scalar.")
    }
    literal <- if (inherits(value, "SQL")) {
      as.character(value)
    } else if (is.logical(value)) {
      if (value) "TRUE" else "FALSE"
    } else if (is.numeric(value)) {
      if (!is.finite(value)) cli::cli_abort("COPY option {.val {key}} must be finite.")
      as.character(value)
    } else if (is.character(value)) {
      as.character(DBI::dbQuoteString(conn, value))
    } else {
      cli::cli_abort("Unsupported value for COPY option {.val {key}}.")
    }
    paste(key, literal)
  }, character(1)), collapse = ", ")
}

#' @noRd
ddbs_write_geoparquet <- function(data, path, conn, overwrite, crs, options,
                                  partitioning, compression, row_group_size,
                                  quiet, version, version_explicit,
                                  spatial_order, compression_level) {
  resolved <- ddbs_geoparquet_options(options, version, version_explicit)
  version <- resolved$version
  options <- resolved$options
  if (!is.logical(spatial_order) || length(spatial_order) != 1L || is.na(spatial_order)) {
    cli::cli_abort("{.arg parquet_spatial_order} must be TRUE or FALSE.")
  }
  if (!is.character(path) || length(path) != 1L || is.na(path) || !nzchar(path)) {
    cli::cli_abort("{.arg path} must be a single non-empty path.")
  }
  if (!is.null(options$PARTITION_BY)) {
    if (length(partitioning)) {
      cli::cli_abort("Set partitioning with either {.arg partitioning} or {.code options$PARTITION_BY}, not both.")
    }
    partitioning <- options$PARTITION_BY
    options$PARTITION_BY <- NULL
    if (is.character(partitioning) && length(partitioning) == 1L &&
        grepl("^\\(", partitioning)) {
      cli::cli_abort("Use column names in {.arg partitioning}, not a raw SQL PARTITION_BY expression.")
    }
  }
  if (!is.null(partitioning) && (!is.character(partitioning) || anyNA(partitioning) ||
                               any(!nzchar(partitioning)) || anyDuplicated(partitioning))) {
    cli::cli_abort("{.arg partitioning} must contain unique, non-missing column names.")
  }
  if (file.exists(path) && !overwrite) {
    cli::cli_abort("File {.path {path}} already exists. Use {.arg overwrite = TRUE} to replace.")
  }

  quote_id <- function(x) as.character(DBI::dbQuoteIdentifier(conn, x))
  override <- if (!is.null(crs)) ddbs_geoparquet_crs(crs) else NULL
  if (inherits(data, "sf")) {
    primary <- attr(data, "sf_column", exact = TRUE)
    geometry <- names(data)[vapply(data, inherits, logical(1), what = "sfc")]
    # [.sf can keep the active geometry implicitly; use an ordinary named list.
    crses <- utils::setNames(lapply(geometry, function(name) sf::st_crs(data[[name]])), geometry)
    if (!is.null(override)) crses[[primary]] <- override
    registered <- as.data.frame(data)
    for (name in geometry) registered[[name]] <- ddbs_sfc_to_wkb(data[[name]])
    view <- ddbs_temp_view_name()
    duckdb::duckdb_register(conn, view, registered)
    on.exit(duckdb::duckdb_unregister(conn, view), add = TRUE)
    source <- quote_id(view)
    fields <- names(registered)
    expressions <- utils::setNames(quote_id(fields), fields)
    for (name in geometry) {
      expressions[[name]] <- ddbs_geoparquet_cast(
        paste0("ST_GeomFromWKB(", quote_id(name), ")"), crses[[name]], conn, version)
    }
  } else if (inherits(data, c("duckspatial_df", "tbl_lazy", "tbl_duckdb_connection"))) {
    if (!identical(conn, dbplyr::remote_con(data))) {
      cli::cli_abort("Parquet export must use the input lazy table's DuckDB connection.")
    }
    # Never use source_table here: it can be stale after dplyr filtering,
    # selecting, renaming, or joins that do not have a duckspatial method.
    source <- paste0("(", dbplyr::sql_render(data, con = conn), ")")
    types <- DBI::dbGetQuery(conn, paste0("DESCRIBE SELECT * FROM ", source))
    geometry <- types$column_name[grepl("^GEOMETRY(\\(|$)", types$column_type)]
    if (!length(geometry)) {
      cli::cli_abort("Input DuckDB table/query does not contain a spatial column of type 'GEOMETRY'.")
    }
    # Match nested types, not enum labels or STRUCT attributes named GEOMETRY.
    nested <- grepl("GEOMETRY(\\(|\\)|\\]|,|$)", types$column_type) &
      !types$column_name %in% geometry
    if (any(nested)) {
      cli::cli_abort("GeoParquet geometry columns must be top-level, not nested in structs or lists.")
    }
    primary <- attr(data, "sf_column", exact = TRUE)
    has_active <- !is.null(primary) && primary %in% geometry
    if (!has_active) primary <- geometry[[1L]]
    crses <- utils::setNames(lapply(geometry, function(name) {
      if (identical(name, primary) && !is.null(override)) return(override)
      ddbs_geoparquet_native_crs(conn, types$column_type[match(name, types$column_name)])
    }), geometry)
    # The native query type is authoritative, even when CRS was intentionally
    # cleared. R-side CRS attributes can be stale after dplyr operations.
    # Users may override explicitly with crs = ... above.
    fields <- types$column_name
    expressions <- utils::setNames(quote_id(fields), fields)
    for (name in geometry) {
      expressions[[name]] <- ddbs_geoparquet_cast(quote_id(name), crses[[name]], conn, version)
    }
  } else if (inherits(data, "data.frame")) {
    cli::cli_abort("Input local data must be an 'sf' object. Plain data.frames are not supported.")
  } else {
    cli::cli_abort("Unsupported input type: {.cls {class(data)}}")
  }

  if (length(setdiff(partitioning, fields))) {
    cli::cli_abort("Unknown partition column(s): {.val {setdiff(partitioning, fields)}}.")
  }
  if (length(intersect(partitioning, geometry))) {
    cli::cli_abort("Geometry columns cannot be used as partition keys.")
  }
  # Keep the active geometry first among geometry fields for readers that use
  # column order rather than primary_column, without moving attribute columns.
  fields[fields %in% geometry] <- c(primary, setdiff(geometry, primary))
  expressions <- expressions[fields]
  select <- paste0(unname(expressions), " AS ", quote_id(fields), collapse = ", ")
  query <- paste0("SELECT ", select, " FROM ", source)
  if (spatial_order) {
    geom <- paste0("_ddbs_src.", quote_id(primary))
    bounds_geom <- quote_id(primary)
    if (version == "V1") {
      # V1 selects WKB BLOBs; decode only for spatial ordering.
      geom <- paste0("ST_GeomFromWKB(", geom, ")")
      bounds_geom <- paste0("ST_GeomFromWKB(", bounds_geom, ")")
    }
    bounds <- "_ddbs_bounds._ddbs_extent"
    query <- paste0(
      "WITH _ddbs_src AS NOT MATERIALIZED (", query, "), ",
      "_ddbs_bounds AS (SELECT ST_Extent(ST_Extent_Agg(", bounds_geom,
      ")) AS _ddbs_extent FROM _ddbs_src) ",
      "SELECT _ddbs_src.* FROM _ddbs_src CROSS JOIN _ddbs_bounds ",
      "ORDER BY (", geom, " IS NULL OR ST_IsEmpty(", geom, ")), ",
      "CASE WHEN ", geom, " IS NULL OR ST_IsEmpty(", geom, ") ",
      "OR ", bounds, " IS NULL OR ST_XMin(", bounds, ") >= ST_XMax(", bounds, ") ",
      "OR ST_YMin(", bounds, ") >= ST_YMax(", bounds, ") THEN NULL ELSE ",
      "ST_Hilbert(", geom, ", ", bounds, ") END NULLS LAST"
    )
  }

  copy <- list(FORMAT = "PARQUET", GEOPARQUET_VERSION = version)
  if (overwrite) copy$OVERWRITE_OR_IGNORE <- TRUE
  if (!is.null(compression)) copy$COMPRESSION <- compression
  if (!is.null(row_group_size)) copy$ROW_GROUP_SIZE <- row_group_size
  if (!is.null(compression_level)) copy$COMPRESSION_LEVEL <- compression_level
  copy <- utils::modifyList(copy, options)
  if (length(partitioning)) {
    copy$PARTITION_BY <- DBI::SQL(paste0("(", paste(quote_id(partitioning), collapse = ", "), ")"))
  }
  if (!is.null(copy$ROW_GROUP_SIZE) &&
      (!is.numeric(copy$ROW_GROUP_SIZE) || length(copy$ROW_GROUP_SIZE) != 1L ||
       is.na(copy$ROW_GROUP_SIZE) || !is.finite(copy$ROW_GROUP_SIZE) ||
       copy$ROW_GROUP_SIZE < 1 || copy$ROW_GROUP_SIZE != floor(copy$ROW_GROUP_SIZE))) {
    cli::cli_abort("{.arg parquet_row_group_size} must be a positive integer.")
  }
  if (!is.null(copy$COMPRESSION_LEVEL)) {
    level <- copy$COMPRESSION_LEVEL
    if (!is.numeric(level) || length(level) != 1L || is.na(level) ||
        !is.finite(level) || level != floor(level)) {
      cli::cli_abort("{.arg parquet_compression_level} must be a finite integer.")
    }
    if (is.null(copy$COMPRESSION) || !identical(toupper(copy$COMPRESSION), "ZSTD")) {
      cli::cli_abort("A compression level requires {.code parquet_compression = 'zstd'}.")
    }
  }
  if (version %in% c("V1", "V2")) {
    # NONE disables DuckDB's automatic geo metadata. V2 keeps native geometry
    # logical types/statistics; V1 explicitly selects WKB BLOBs instead.
    copy$GEOPARQUET_VERSION <- "NONE"
    metadata <- copy$KV_METADATA
    if (is.null(metadata)) metadata <- list()
    if (!is.list(metadata) || inherits(metadata, "SQL")) {
      cli::cli_abort("{.code options$KV_METADATA} must be a named list of strings.")
    }
    if (any(tolower(names(metadata)) == "geo")) {
      cli::cli_abort("The {.code geo} metadata key is managed by duckspatial.")
    }
    metadata$geo <- ddbs_geoparquet_metadata(
      crses, primary, if (version == "V2") "2.0.0" else "1.0.0"
    )
    copy$KV_METADATA <- metadata
  }
  opts <- ddbs_geoparquet_copy_options(conn, copy)
  DBI::dbExecute(conn, paste0("COPY (", query, ") TO ",
                             DBI::dbQuoteString(conn, path), " (", opts, ")"))
  if (!quiet) cli::cli_alert_success("Written to {.path {path}}")
  invisible(path)
}
