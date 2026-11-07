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
ddbs_geoparquet_cast <- function(expr, crs, projjson, conn, version) {
  # V1 uses ordinary WKB BLOB columns and explicit geo metadata.
  if (version == "V1") {
    # GeoParquet 1.0 permits XY/XYZ, but not measured WKB. Check while
    # streaming the COPY query rather than scanning the input a second time.
    geom <- paste0("CAST(", expr, " AS GEOMETRY)")
    message <- DBI::dbQuoteString(conn, paste0(
      "GeoParquet 1.0 does not support measured (M/ZM) geometries; ",
      "use geoparquet_version = 'V2'."
    ))
    return(paste0("ST_AsWKB(CASE WHEN ST_HasM(", geom, ") THEN error(",
                  message, ") ELSE ", geom, " END)"))
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
  } else if (version != "V2" && !is.na(crs$epsg)) {
    # Preserve the native BOTH/NONE compatibility modes' authority strings.
    paste0("EPSG:", as.integer(crs$epsg))
  } else {
    as.character(jsonlite::toJSON(projjson, auto_unbox = TRUE,
                                 null = "null", digits = NA))
  }
  if (is.null(text)) return(paste0("CAST(", expr, " AS GEOMETRY)"))
  # Assign output CRS without reprojection or mutation of source.
  paste0("CAST(CAST(", expr, " AS GEOMETRY) AS GEOMETRY(",
         DBI::dbQuoteString(conn, text), "))")
}

#' @noRd
ddbs_geoparquet_metadata <- function(projjson, primary, version) {
  columns <- lapply(projjson, function(crs) {
    list(encoding = "WKB", geometry_types = character(),
         crs = crs)
  })
  # Unknown types and no file-wide bbox also describe partitions correctly;
  # DuckDB supplies native statistics for each row group.
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
        paste0(sql_ident(name), ": ",
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
ddbs_geoparquet_partition_names <- function(partitioning) {
  if (!is.character(partitioning) || length(partitioning) != 1L ||
      is.na(partitioning)) return(partitioning)
  text <- trimws(as.character(partitioning))
  if (!startsWith(text, "(")) return(partitioning)
  # Older callers supplied COPY's parenthesized identifier list. Parse only
  # identifiers, so the usual column/geometry validation still applies.
  identifier <- paste0('\"(?:[^\"]|\"\")*\"|',
                       '(?:[A-Za-z_]|[^\\x00-\\x7F])',
                       '(?:[A-Za-z0-9_$]|[^\\x00-\\x7F])*')
  pattern <- paste0("^\\([[:space:]]*(?:", identifier,
                    ")(?:[[:space:]]*,[[:space:]]*(?:", identifier,
                    "))*[[:space:]]*\\)$")
  if (!grepl(pattern, text, perl = TRUE)) {
    cli::cli_abort("{.code options$PARTITION_BY} must be column names or a parenthesized column-name list.")
  }
  tokens <- regmatches(text, gregexpr(identifier, text, perl = TRUE))[[1L]]
  vapply(tokens, function(token) {
    if (!startsWith(token, '\"')) return(token)
    gsub('\"\"', '\"', substr(token, 2L, nchar(token) - 1L), fixed = TRUE)
  }, character(1), USE.NAMES = FALSE)
}

#' @noRd
ddbs_write_geoparquet <- function(data, path, conn, overwrite, crs, options,
                                  partitioning, compression, row_group_size,
                                  quiet, version, version_explicit,
                                  spatial_order, compression_level) {
  resolved <- ddbs_geoparquet_options(options, version, version_explicit)
  version <- resolved$version
  options <- resolved$options
  managed_metadata <- version %in% c("V1", "V2")
  if (!is.logical(spatial_order) || length(spatial_order) != 1L || is.na(spatial_order)) {
    cli::cli_abort("{.arg parquet_spatial_order} must be TRUE or FALSE.")
  }
  if (!is.character(path) || length(path) != 1L || is.na(path) || !nzchar(path)) {
    cli::cli_abort("{.arg path} must be a single non-empty path.")
  }
  if (!is.null(options$PARTITION_BY)) {
    partitioning <- ddbs_geoparquet_partition_names(options$PARTITION_BY)
    options$PARTITION_BY <- NULL
  }
  if (!is.null(partitioning) && (!is.character(partitioning) || anyNA(partitioning) ||
                               any(!nzchar(partitioning)))) {
    cli::cli_abort("{.arg partitioning} must contain unique, non-missing column names.")
  }
  if (spatial_order && length(partitioning)) {
    cli::cli_abort(c(
      "DuckDB cannot guarantee spatial ordering for partitioned output.",
      "i" = "Write without partitioning or set {.code parquet_spatial_order = FALSE}."
    ))
  }
  if (spatial_order && !is.null(options$PRESERVE_ORDER)) {
    preserve <- options$PRESERVE_ORDER
    if (!is.atomic(preserve) || length(preserve) != 1L || is.na(preserve) ||
        !tolower(trimws(as.character(preserve))) %in% c("true", "t", "yes", "1")) {
      cli::cli_abort("{.arg parquet_spatial_order} requires {.code PRESERVE_ORDER = TRUE}; omit this COPY option or set it to TRUE.")
    }
  }
  if (file.exists(path) && !overwrite) {
    cli::cli_abort("File {.path {path}} already exists. Use {.arg overwrite = TRUE} to replace.")
  }

  override <- if (!is.null(crs)) ddbs_geoparquet_crs(crs) else NULL
  local_sf <- inherits(data, "sf")
  if (local_sf) {
    # Registration repairs name collisions, which could silently select the
    # wrong original column. Reject them before registering.
    folded_names <- chartr("ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz",
                           names(data))
    if (anyDuplicated(folded_names)) {
      cli::cli_abort("Column names must be unique ignoring ASCII case for DuckDB GeoParquet export.")
    }
    primary <- attr(data, "sf_column", exact = TRUE)
    geometry <- names(data)[vapply(data, inherits, logical(1), what = "sfc")]
    crses <- stats::setNames(lapply(geometry, function(name) sf::st_crs(data[[name]])), geometry)
    if (!is.null(override)) crses[[primary]] <- override
    registered <- as.data.frame(data)
    for (name in geometry) registered[[name]] <- ddbs_sfc_to_wkb(data[[name]])
    view <- ddbs_temp_view_name()
    duckdb::duckdb_register(conn, view, registered)
    on.exit(duckdb::duckdb_unregister(conn, view), add = TRUE)
    source <- sql_ident(view)
    fields <- names(registered)
  } else if (inherits(data, c("duckspatial_df", "tbl_lazy", "tbl_duckdb_connection"))) {
    if (!identical(conn, dbplyr::remote_con(data))) {
      cli::cli_abort("Parquet export must use the input lazy table's DuckDB connection.")
    }
    # source_table can be stale after filtering, renaming or joins.
    source <- paste0("(", dbplyr::sql_render(data, con = conn), ")")
    types <- DBI::dbGetQuery(conn, paste0("DESCRIBE SELECT * FROM ", source))
    # Enum labels, CRS text and STRUCT field names can contain "GEOMETRY[]".
    # Strip quoted text before identifying actual geometry types.
    type_tokens <- gsub("'(?:[^']|'')*'|\"(?:[^\"]|\"\")*\"", "",
                        types$column_type, perl = TRUE)
    is_geometry <- grepl("^GEOMETRY(\\(\\))?$", type_tokens)
    nested <- grepl("\\bGEOMETRY(?:\\(\\)|(?=\\[|[[:space:]]*[,)]|$))",
                    type_tokens, perl = TRUE) & !is_geometry
    if (any(nested)) {
      cli::cli_abort("GeoParquet geometry columns must be top-level, not nested in structs or lists.")
    }
    geometry <- types$column_name[is_geometry]
    if (!length(geometry)) {
      cli::cli_abort("Input DuckDB table/query does not contain a spatial column of type 'GEOMETRY'.")
    }
    primary <- attr(data, "sf_column", exact = TRUE)
    has_active <- !is.null(primary) && primary %in% geometry
    if (!has_active) primary <- geometry[[1L]]
    crses <- stats::setNames(lapply(geometry, function(name) {
      if (identical(name, primary) && !is.null(override)) return(override)
      ddbs_geoparquet_native_crs(conn, types$column_type[match(name, types$column_name)])
    }), geometry)
    # Native CRS overrides stale R attributes. Legacy storage cannot store CRS
    # in its geometry types, so only it may fall back to the R attribute.
    if (is.null(override) && has_active && is.na(crses[[primary]]) &&
        inherits(data, "duckspatial_df") && ddbs_storage_is_legacy(conn)) {
      stored <- attr(data, "crs", exact = TRUE)
      if (!is.null(stored)) {
        crses[[primary]] <- ddbs_geoparquet_crs(stored)
      }
    }
    fields <- types$column_name
  } else if (inherits(data, "data.frame")) {
    cli::cli_abort("Input local data must be an 'sf' object. Plain data.frames are not supported.")
  } else {
    cli::cli_abort("Unsupported input type: {.cls {class(data)}}")
  }

  # Match DuckDB's ASCII case-insensitive identifiers before validating keys.
  partition_index <- match(
    chartr("ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz", partitioning),
    chartr("ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz", fields)
  )
  if (anyNA(partition_index)) {
    cli::cli_abort("Unknown partition column(s): {.val {partitioning[is.na(partition_index)]}}.")
  }
  partitioning <- fields[partition_index]
  if (anyDuplicated(partitioning)) {
    cli::cli_abort("{.arg partitioning} must contain unique column names (ignoring ASCII case).")
  }
  if (length(intersect(partitioning, geometry))) {
    cli::cli_abort("Geometry columns cannot be used as partition keys.")
  }
  # Some readers use column order instead of primary_column.
  fields[fields %in% geometry] <- c(primary, setdiff(geometry, primary))
  # Reuse each CRS definition for the native type and footer metadata.
  projjson <- lapply(crses, function(crs) {
    if (!managed_metadata && !is.na(crs$epsg)) return(NULL)
    ddbs_geoparquet_projjson(crs)
  })
  expressions <- stats::setNames(sql_ident(fields), fields)
  for (name in geometry) {
    expr <- expressions[[name]]
    if (local_sf) expr <- paste0("ST_GeomFromWKB(", expr, ")")
    expressions[[name]] <- ddbs_geoparquet_cast(
      expr, crses[[name]], projjson[[name]], conn, version)
  }
  select <- paste0(unname(expressions), " AS ", sql_ident(fields), collapse = ", ")
  query <- paste0("SELECT ", select, " FROM ", source)
  if (spatial_order) {
    geom <- paste0("_ddbs_src.", sql_ident(primary))
    bounds_geom <- sql_ident(primary)
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
  # An ORDER BY query alone is insufficient if the connection or COPY options
  # permit the Parquet writer to reorder rows. Also rejects incompatible
  # multi-file writer modes through DuckDB's own COPY validation.
  if (spatial_order) copy$PRESERVE_ORDER <- TRUE
  if (length(partitioning)) {
    copy$PARTITION_BY <- DBI::SQL(paste0("(", paste(sql_ident(partitioning), collapse = ", "), ")"))
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
  if (managed_metadata) {
    # Explicit metadata covers measured V2 (duckdb/duckdb-spatial#847):
    # https://github.com/duckdb/duckdb-spatial/issues/847
    # Remove only when native COPY also preserves zero-row files, all geometry
    # columns/primary selection and unknown V1 CRS. A #847 fix alone is insufficient.
    # NONE disables automatic metadata; V2 keeps native types/statistics.
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
      projjson, primary, if (version == "V2") "2.0.0" else "1.0.0"
    )
    copy$KV_METADATA <- metadata
  }
  opts <- ddbs_geoparquet_copy_options(conn, copy)
  DBI::dbExecute(conn, paste0("COPY (", query, ") TO ",
                             DBI::dbQuoteString(conn, path), " (", opts, ")"))
  if (!quiet) cli::cli_alert_success("Written to {.path {path}}")
  invisible(path)
}
