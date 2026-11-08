# Diagnostics run against unchanged main production source.
suppressPackageStartupMessages(pkgload::load_all(".", quiet = TRUE))
cat("R:", as.character(getRversion()), "DuckDB:", as.character(packageVersion("duckdb")), "\n")
passed <- logical()
check <- function(label, expression) {
  tryCatch({
    force(expression)
    cat("PASS:", label, "\n")
    passed[label] <<- TRUE
  }, error = function(e) {
    cat("FAIL:", label, " | ", conditionMessage(e), "\n")
    passed[label] <<- FALSE
  })
}
conn <- ddbs_create_conn()
p1 <- sf::st_sfc(sf::st_point(c(8, 50)), sf::st_point(c(9, 51)), crs = 4326)
p2 <- sf::st_transform(p1, 3857)
multi <- sf::st_sf(id = 1:2, secondary = p1, active = p2, sf_column_name = "active")
check("F1 persistent two geometry columns", {
  ddbs_write_table(conn, multi, "f1_write", quiet = TRUE)
  typ <- DBI::dbGetQuery(conn, "DESCRIBE f1_write")
  stopifnot(all(c("secondary", "active") %in% typ$column_name))
  stopifnot(all(grepl("^GEOMETRY", typ$column_type[match(c("secondary", "active"), typ$column_name)])))
})
check("F1 Arrow view two geometry columns", {
  ddbs_register_table(conn, multi, "f1_view", quiet = TRUE)
  typ <- DBI::dbGetQuery(conn, "DESCRIBE f1_view")
  stopifnot(all(c("secondary", "active") %in% typ$column_name))
  stopifnot(all(grepl("^GEOMETRY", typ$column_type[match(c("secondary", "active"), typ$column_name)])))
})
check("F1 as_duckspatial_df from sf preserves secondary geometry", {
  lazy <- as_duckspatial_df(multi, conn = conn)
  typ <- DBI::dbGetQuery(conn, paste0("DESCRIBE ", attr(lazy,"source_table")))
  stopifnot(all(grepl("^GEOMETRY", typ$column_type[match(c("secondary", "active"), typ$column_name)])))
  stopifnot(identical(attr(lazy, "sf_column"), "active"))
})
DBI::dbExecute(conn, "CREATE TABLE f2_zero (geom GEOMETRY('EPSG:3857'))")
DBI::dbExecute(conn, "CREATE TABLE f2_null (geom GEOMETRY('EPSG:4326'))")
DBI::dbExecute(conn, "INSERT INTO f2_null VALUES (NULL)")
DBI::dbExecute(conn, "CREATE TABLE f2_first_null (geom GEOMETRY('EPSG:4326'))")
DBI::dbExecute(conn, "INSERT INTO f2_first_null VALUES (NULL), (ST_Point(8,50))")
check("F2 zero rows typed CRS", {
  stopifnot(identical(sf::st_crs(ddbs_crs("f2_zero", conn = conn))$epsg, 3857L))
})
check("F2 all NULL typed CRS", {
  stopifnot(identical(sf::st_crs(ddbs_crs("f2_null", conn = conn))$epsg, 4326L))
})
check("F2 NULL-first typed CRS", {
  stopifnot(identical(sf::st_crs(ddbs_crs("f2_first_null", conn = conn))$epsg, 4326L))
})
check("F2 empty generic geometry remains unknown", {
  DBI::dbExecute(conn, "CREATE TABLE f2_generic (geom GEOMETRY)")
  stopifnot(is.na(ddbs_crs("f2_generic",conn = conn)))
})
check("F4 collect both native geometry columns", {
  DBI::dbExecute(conn, paste0("CREATE TABLE f4_native AS SELECT 1 AS id, ",
                             "ST_Point(8, 50)::GEOMETRY('EPSG:4326') AS secondary, ",
                             "ST_Point(1000, 2000)::GEOMETRY('EPSG:3857') AS active"))
  lazy <- as_duckspatial_df("f4_native", conn = conn, geom_col = "active", crs = 3857)
  out <- dplyr::collect(lazy)
  stopifnot(inherits(out, "sf"), identical(attr(out, "sf_column"), "active"),
            inherits(out[["active"]], "sfc"), inherits(out[["secondary"]], "sfc"),
            identical(sf::st_crs(out[["secondary"]])$epsg, 4326L),
            identical(sf::st_crs(out[["active"]])$epsg, 3857L))
})
check("F4 raw returns WKB for both columns", {
  lazy <- as_duckspatial_df("f4_native", conn = conn, geom_col = "active", crs = 3857)
  out <- dplyr::collect(lazy, as = "raw")
  stopifnot(all(vapply(out[c("secondary", "active")], function(x) is.list(x) && is.raw(x[[1]]), logical(1))))
})
check("F4 tibble drops both geometry columns", {
  lazy <- as_duckspatial_df("f4_native", conn = conn, geom_col = "active", crs = 3857)
  out <- dplyr::collect(lazy, as = "tibble")
  stopifnot(identical(names(out), "id"))
})
check("F3 GeoParquet primary column and absent CRS default", {
  wkb <- sf::st_as_binary(p1)
  tab <- arrow::Table$create(
    id = 1:2,
    geometry = arrow::Array$create(wkb, type = arrow::binary()),
    geom = arrow::Array$create(wkb, type = arrow::binary()))
  md <- list(version = "1.1.0", primary_column = "geom",
    columns = list(geometry = list(encoding = "WKB", geometry_types = list("Point"), crs = NULL),
                   geom = list(encoding = "WKB", geometry_types = list("Point"))))
  json <- jsonlite::toJSON(md, auto_unbox = TRUE, null = "null")
  tab <- tab$ReplaceSchemaMetadata(list(geo = json))
  pth <- tempfile(fileext = ".parquet")
  arrow::write_parquet(tab, pth)
  ds <- ddbs_open_dataset(pth, conn = conn)
  stopifnot(inherits(ds,"duckspatial_df"), identical(attr(ds,"sf_column"), "geom"),
    identical(sf::st_crs(ds), sf::st_crs("OGC:CRS84")))
})
cat("Summary:", sum(passed), "/", length(passed), "passed\n")
try(ddbs_stop_conn(conn), silent = TRUE)
