# Can GeoParquet support be delegated entirely to DuckDB?

**Experiment:** 7 November 2026. This is a characterization experiment, not a production PR. Frozen input source: original main `677ed965894f20b5f83bdc6a389f42ccddb6a7ba`, enhanced stack `c9ad8393c2eaf0d96eee7cedee3af379efff01b3`; the fixture definitions came unchanged from the existing independently checked interop harness.

**Successful final GitHub Actions run:** https://github.com/e-kotov/duckspatial/actions/runs/42399449548

**Downloaded fixture and machine-readable comparison artifact:** https://github.com/e-kotov/duckspatial/actions/runs/42399449548 (artifact `geoparquet-minimal-vs-enhanced`; contains `comparison.json`, `comparison.csv`, `comparison.md`, per-lane write logs and physical files).

All lanes used the same input scenarios. The test compares three export pathways:

1. **Enhanced:** clean PR #8 `ddbs_write_dataset()` with V1, V1.1 and V2, and the optional layout controls requested in the fixture.
2. **Legacy delegation:** unchanged pre-PR `ddbs_write_dataset()` with only `options = list(GEOPARQUET_VERSION = version)` plus corresponding existing COPY controls.
3. **Direct SQL:** `COPY (rendered lazy SELECT) TO ... (FORMAT PARQUET, GEOPARQUET_VERSION ...)`, without the package's geometry/CRS normalization. Not applicable to local R `sf` inputs without prior conversion.

## Confirmed results

| Lane | Successful cases | Failed | Not applicable | Of successful cases, metadata and values matched enhanced |
|---|---:|---:|---:|---:|
| Enhanced | 31/31 | 0 | 0 | Reference |
| Legacy delegation | 20/31 | 11 | 0 | 9/20 |
| Direct SQL | 10/15 eligible | 5 | 16 | 6/10 |

The enhanced output generated 34 physical files (partitioning produces additional files), and all passed the existing independent PyArrow/Shapely/PyProj semantic/physical-file validator, including three-row-group Hilbert-order checks. The validator was copied *unchanged* from the previously reviewed harness.

### Why delegation alone is insufficient for the full feature claim

- **GeoParquet 1.1:** 11/11 legacy requests fail with a DuckDB binder error: `Expected geoparquet_version 'NONE', 'V1' or 'BOTH'`. The five eligible raw-SQL V1.1 requests fail the same way. The enhanced 1.1 WKB path succeeded. This is a genuine functionality gap, not an optional wrapper preference.
- **Unknown CRS:** with an explicit R `crs = NA` override in V1, the enhanced output recorded **unknown CRS** (`crs: null`), while the original writer emitted **EPSG:4326**, so the requested metadata semantics were not honored.
- **Multiple geometry columns:** legacy V1 and V2 both omit the secondary geometry from the GeoParquet `geo.columns` block, and the comparison detected a mismatch in the secondary geometry's stored values. Partitioned variants share this problem. Data-model fidelity is not obtained by the version switch alone.
- **Lazy geometry selection:** the renamed `shape` column is missing from the delegated writer's GeoParquet geometry metadata in mixed lazy inputs. The delegated file instead selects the secondary `other` as its `primary_column`. This occurred with V1 and V2 NULL cases, and with V2 mixed-dimension cases; the direct SQL writer shows the same issue.
- **Empty datasets:** the legacy writer produced files but no `geo` footer metadata for either V1 or V2 empty `sf` inputs, whereas enhanced output retained the full schema/CRS metadata.
- **Mixed nonpoint/measured geometries:** delegated V2 produced a file with no `geo` metadata in the nonpoint case, whereas the enhanced file had the expected metadata.
- **Simple typed geometries:** multiple ordinary V1/V2 cases **were semantically identical** without the enhanced wrapper. This confirms that DuckDB already does much of the heavy lifting.

### What this does *not* prove

The direct and legacy lanes are intentionally minimal, not hypothetical minimal **corrected** wrappers. The results demonstrate why merely passing `GEOPARQUET_VERSION` is insufficient for some inputs, but they **do not prove that every helper, validation branch, or line of code in PR #7 is necessary**. For example, Hilbert ordering and compression-level controls remain optional and separable from core GeoParquet correctness. Nor does any difference in physical row ordering count as an error here.

CRS definitions were compared semantically using PyProj, geometry contents with Shapely, and metadata/schema with PyArrow. The comparison does not establish full interoperability of legacy output with every GIS reader or revalidate a new all-platform R CI matrix.

## Maintainer implication

Keep GeoParquet 1.1 and actual geometry/CRS/active-column correctness logic. Consider moving optional Hilbert ordering and compression controls into a separate PR if an upstream maintainer strongly prefers narrower review scope. A shorter correct V2 implementation *may* be possible, but **a trivial pass-through is not equivalent to the reviewed stack** on the tested scenarios.

Original PR #5/#6/#7/#8 and `Cidree/duckspatial` were not modified. No PR merged or submitted upstream.
