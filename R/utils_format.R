
#' Detect file format from path or URL
#'
#' @param path Character string used as path or URL
#' @return Character string: "parquet", "sf", or other extension
#' @noRd
get_file_format <- function(path) {
  # 1. Handle S3 URIs -> assume parquet default if no extension
  if (grepl("^s3://", path)) {
    # Check if it has an extension
    ext <- tools::file_ext(path)
    if (ext == "") return("parquet")
  }
  
  # 2. Get extension
  ext <- tolower(tools::file_ext(path))
  
  # 3. Check for specific extensions
  if (ext %in% c("parquet")) {
    return("parquet")
  }
  if (ext %in% c("duckdb", "db", "ddb")) {
    return("duckdb")
  }
  if (ext == "shp") {
     return("shp")
  }
  if (grepl("osm\\.pbf$", path) || ext == "osm.pbf") {
     return("osm.pbf")
  }
  
  # 4. Check for known spatial extensions -> "sf" (handled by ST_Read)
  # This list aligns with formats commonly handled by GDAL/ST_Read
  spatial_exts <- c("shp", "gpkg", "fgb", "json", "geojson", "kml", "gpx")
  if (ext %in% spatial_exts) {
    return("sf")
  }
  
  # 5. Default fallback
  if (ext == "") {
    # If no extension, we return "unknown" to trigger auto-detection logic
    return("unknown")
  }
  
  # Return the extension purely for information/fallback usage
  return(ext)
}

duckdb_file_extensions <- function() {
  c("duckdb", "db", "ddb")
}

has_duckdb_file_extension <- function(path) {
  if (!is.character(path) || length(path) != 1) {
    return(FALSE)
  }
  tolower(tools::file_ext(path)) %in% duckdb_file_extensions()
}

duckdb_file_info <- function(path) {
  result <- list(
    exists = FALSE,
    size = NA_real_,
    valid = FALSE,
    empty = FALSE
  )

  if (!is.character(path) || length(path) != 1 || grepl("^[[:alpha:]][[:alnum:].+-]*://", path)) {
    return(result)
  }

  if (!file.exists(path)) {
    return(result)
  }

  info <- file.info(path)
  result$exists <- TRUE
  result$size <- info$size
  result$empty <- isTRUE(result$size == 0)

  if (is.na(result$size) || isTRUE(info$isdir) || result$size < 12) {
    return(result)
  }

  con <- file(path, "rb")
  on.exit(close(con), add = TRUE)
  bytes <- readBin(con, "raw", n = 12)

  result$valid <- length(bytes) >= 12 && identical(bytes[9:12], charToRaw("DUCK"))
  result
}

#' Get CRS from Parquet metadata
#' 
#' @param path Path to parquet file
#' @param conn DuckDB connection
#' @return crs object or NULL
#' @noRd
# Read only GeoParquet footer metadata; do not materialize feature rows.
get_parquet_geometry_metadata <- function(path, conn) {
  safe_path <- DBI::dbQuoteString(conn, path)
  query <- glue::glue(
    "SELECT value FROM parquet_kv_metadata({safe_path}) ",
    "WHERE decode(key) = 'geo' LIMIT 1"
  )
  res <- tryCatch(DBI::dbGetQuery(conn, query), error = function(e) NULL)
  if (is.null(res) || nrow(res) == 0L || is.null(res$value[[1]])) {
    return(NULL)
  }
  tryCatch(
    jsonlite::fromJSON(rawToChar(res$value[[1]]), simplifyVector = FALSE),
    error = function(e) NULL
  )
}

get_parquet_crs <- function(path, conn, geom_col = NULL) {
  meta <- get_parquet_geometry_metadata(path, conn)
  if (is.null(meta)) return(NULL)
  geom_col <- geom_col %||% meta$primary_column
  if (is.null(geom_col) || !geom_col %in% names(meta$columns)) return(NULL)

  col_meta <- meta$columns[[geom_col]]
  # GeoParquet: omitted CRS defaults to CRS84; explicit null is unknown.
  if (!"crs" %in% names(col_meta)) return(sf::st_crs("OGC:CRS84"))
  crs_data <- col_meta$crs
  if (is.null(crs_data)) return(sf::st_crs(NA))

  if (is.list(crs_data)) {
    authority <- crs_data$id$authority
    code <- crs_data$id$code
    if (!is.null(authority) && !is.null(code)) {
      result <- tryCatch(sf::st_crs(paste0(authority, ":", code)),
                         error = function(e) sf::st_crs(NA))
      if (!is.na(result)) return(result)
    }
    crs_data <- jsonlite::toJSON(crs_data, auto_unbox = TRUE, digits = NA)
  }
  tryCatch(sf::st_crs(crs_data), error = function(e) sf::st_crs(NA))
}

#' Map extension to common GDAL driver names
#' @noRd
get_driver_map <- function() {
  list(
    # Native / Common
    parquet = "parquet",
    csv = "CSV",
    
    # GDAL Spatial
    shp = "ESRI Shapefile",
    gpkg = "GPKG",
    fgb = "FlatGeoBuf",
    json = "GeoJSON",
    geojson = "GeoJSON",
    kml = "KML",
    gml = "GML",
    gpx = "GPX",
    sqlite = "SQLite",
    tab = "MapInfo File",
    mif = "MapInfo File",
    geojsonl = "GeoJSON",
    mvt = "MVT",
    dgn = "DGN",
    gdb = "OpenFileGDB", 
    gxt = "Geoconcept",
    xml = "GML"
  )
}

#' Get driver name from format/extension
#' @noRd
get_driver_name <- function(fmt) {
  map <- get_driver_map()
  if (fmt %in% names(map)) {
    return(map[[fmt]])
  }
  return(NULL)
}

#' Check if format implies spatial data
#' @noRd
is_spatial_format <- function(fmt) {
  # GDAL formats usually imply spatial data.
  spatial_formats <- c("shp", "gpkg", "fgb", "json", "geojson", "kml", "gpx")
  
  # Check if extension is one of these
  if (fmt %in% spatial_formats) return(TRUE)
  
  # Check driver map (excluding native formats which we handle separately or aren't strictly spatial)
  map <- get_driver_map()
  map$parquet <- NULL
  map$csv <- NULL
  
  driver <- get_driver_name(fmt)
  if (!is.null(driver) && driver %in% unlist(map)) return(TRUE)
  
  return(FALSE)
}
