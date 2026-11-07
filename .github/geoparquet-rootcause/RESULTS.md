# GeoParquet V2 failure ownership: native DuckDB vs duckspatial vs R

**Run:** https://github.com/e-kotov/duckspatial/actions/runs/42401643880
**Experimental branch:** `experiment/geoparquet-v2-rootcause-20261107`
**Scope:** 15 identical SQL queries, V1 and V2 each, written directly with Python DuckDB 2.0.0 and R DBI/duckdb, *without using duckspatial or sf*, independently inspected by PyArrow. Source + actual Parquet files, schemas and `native-comparison.json` are preserved in the CI artifact `geoparquet-v2-native-rootcause`.

**Result: 30/30 output pairs have identical inspected metadata/geometry-column structure between Python and R.** This rules out the R DBI interface as the cause *for these cases*. It does not establish that every R or Arrow conversion is correct.

| Scenario | Native DuckDB V2 | Responsibility / implication |
|---|---|---|
| Single typed XY geometry, EPSG:3857 | `geo` present, correct CRS | DuckDB works |
| Two typed geometry columns, different CRSes | `geo` names both, first primary | DuckDB works; if older duckspatial loses secondary `sf` geometry, inspect its input-conversion pipeline |
| Simple renamed typed geometry | `geo` names both, renamed first primary | DuckDB works; renaming itself is **not** a demonstrated core bug |
| First row NULL, second row non-NULL | Both geometries and primary preserved | DuckDB works; NULL-first is not the explanation |
| Zero rows, one or two typed geometry columns | **`geo` missing** in V1 and V2 | Native DuckDB issue, independently reproducible with R and Python |
| Single M/ZM geometry (typed or untyped) | **`geo` missing** in V1 and V2 | Native DuckDB behavior; tracked for V2 in [Spatial #847](https://github.com/duckdb/duckdb-spatial/issues/847) |
| Mixed XY and XYM rows in primary `shape`, plus ordinary secondary `other` | `geo.columns` includes **only `other`** and `primary_column` is incorrectly `other` | **Confirmed native DuckDB measured-geometry behavior**, not a generic rename defect |
| Same mixed source with M row filtered out before COPY | Both columns and `shape` primary correctly present | Only rows actually written influence this omission; filtering is not itself broken |
| Unqualified `GEOMETRY` with projected-looking coordinates | `geo.columns.geometry.crs` omitted | DuckDB native convention; GeoParquet missing CRS implies CRS84. **Do not interpret this as proof DuckDB knew coordinates were projected.** A package with an *unknown* CRS must prevent mislabeling |
| Ordinary typed nonpoint LINESTRING | Correct `geo`, EPSG:3857 | DuckDB works |

## Comparison to the original duckspatial export (prior experiment)

The [direct-delegation comparison](https://github.com/e-kotov/duckspatial/actions/runs/42399449548) used original package `677ed965` versus enhanced `c9ad8393`. Its separate comparison artifact corroborates:

- **Original-package preprocessing:** for local `sf` with multiple geometry columns, only the active column goes through WKB conversion and reconstruction (`R/io_write_dataset.R` in original main). The secondary was not retained as a declared GeoParquet geometry and differed from the enhanced output. Native DuckDB handles multiple *properly typed* columns, as the pure SQL controls prove. This is a package conversion responsibility, not a general DuckDB inability.
- **CRS override:** original writer ignored explicit `crs = NA` for Parquet. Baseline exported EPSG:4326 while enhanced V1 recorded `crs: null`; a package API semantics bug, not an intrinsic DuckDB issue.
- **Mixed dimensional lazy geometry / wrong primary:** previously looked like a geometry-selection or rename problem. The new native SQL control reproduces precisely the M-containing primary omitted in `geo.columns`, causing the secondary to be selected as primary. This case belongs to the DuckDB measured-geometry writer behavior.
- **Zero-row files:** previously ambiguous between original sf conversion and native writer. Now reproduced in pure native SQL, so the metadata omission originates in DuckDB.

## Maintenance notes for clean upstream proposal PRs #7 and #8

Both PRs include an inline reference to [duckdb/duckdb-spatial#847](https://github.com/duckdb/duckdb-spatial/issues/847) at the `GEOPARQUET_VERSION = 'NONE'` + explicit `KV_METADATA$geo` path in `R/io_geoparquet.R`. This annotation is **comment-only** and preserves all previously tested production behavior.

Do **not** remove the full explicit metadata path automatically when #847 is resolved. A future simplification must also prove correct zero-row metadata, active/secondary geometry declarations, known/unknown CRS and no data loss on local `sf` conversion. The fix to #847 only addresses the measured-geometry subset.

No modification or PR was made to any upstream repository; this experiment is in `e-kotov/duckspatial` only.
