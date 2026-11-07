# GeoParquet simplification candidate

## Scope and source identities

This is a behavior-preserving revision of fork PR #7, with a separately tested
V1.1 increment corresponding to PR #8. All work is confined to
`e-kotov/duckspatial`. The reference branches are unchanged; no PR has been merged
or submitted upstream.

| Source | Commit |
| --- | --- |
| Fork/upstream main | `677ed965894f20b5f83bdc6a389f42ccddb6a7ba` |
| Reference #7 | `04c34956cb71d2ab6d23072fc9774e9c4d09bc8d` |
| Simplification candidate | `22de905bc18988c4cd0e56eafe6cb6dba50248ae` |
| Reference #8 | `5bf4d5f988f5b03d02232a9524b006854762ad19` |
| Simplified V1.1 stack | `cefcf492809831d53794bca40220b9915a706857` |
| Final Linux/comprehensive validation harness | `2c1b9922a511425cb4936b966642a3f4e31c1111` |
| Final Windows-only validation harness | `f66add7eb2037f1fe16d9a098a71524c3f5b03b9` |
| Preserved interoperability harness | `233b033d221dc2913d56e2ba431370f50e93e722` |

The candidate is on `simplify/geoparquet-export-20261107`. The compatibility
increment is on `simplify/geoparquet-v11-compatible-20261107`, directly based on
the candidate. The earlier candidate/stack remain available at `1346266` and
`ae40726`; their results are distinguished below from the corrected sources.

Fresh final Linux/interoperability/full checks:
[run 42407894394](https://github.com/e-kotov/duckspatial/actions/runs/42407894394).
The separate Windows-only rerun is
[42408619025](https://github.com/e-kotov/duckspatial/actions/runs/42408619025).
The complete workflow status must not be substituted for the individual results
below: the first run includes an unsuccessful Windows log-printing step.

The earlier extensively validated PR heads `518647c2c685304c26335386876e504339a7a681`
and `c9ad8393c2eaf0d96eee7cedee3af379efff01b3` are historical evidence. Fresh
reference results here use `04c3495` and `5bf4d5f`, including the #847 comment and
restack, and fresh candidate results use `22de905` and `cefcf492`.

## What became simpler

- Local sf and lazy DuckDB input now share one output-projection loop. The input
  branches only discover their fields, geometry columns, CRS, active geometry
  and source query. Local WKB still receives its necessary DuckDB decoding.
- Each geometry column's CRS is converted once and reused for the native cast and
  GeoParquet footer. The older, duplicate CRS conversion helper is removed.
  Native `BOTH`/`NONE` options retain their EPSG-string fast path; they do not
  acquire an unnecessary PROJJSON conversion requirement.
- The existing `sql_ident()` utility replaces the local quoting wrapper, with
  explicit missing-name rejection preserving DBI's previous validation.
- Duplicate partition names are checked once, after case-insensitive resolution
  against actual fields. This retains the stronger check for `part` versus `PART`.
- User help retains argument meanings, defaults, limitations and a simple V2
  example. Repeated metadata implementation explanations are removed. Roxygen2
  8.1.1 regenerated the help; both final sources are checked for regeneration
  consistency. Unrelated non-Parquet comments removed by #7 are restored.

All requested features and original regression assertions are retained, with no
new dependency. Parquet serialization, compression and native statistics remain
in DuckDB; local sf retains its existing input WKB conversion. No lazy dataset
is collected into R; no post-write rewriting or additional data scan was
introduced. Hilbert
ordering retains its existing extent scan and sort.

## Before/after size, separated by purpose

Counts are reproduced by `measure-size.py` and recorded in `size-metrics.json`.
"R code lines" means nonblank source lines not beginning with a comment or
roxygen marker; it includes ordinary R syntax such as braces and string literals.

| Measure | Reference #7 | Candidate | Change |
| --- | ---: | ---: | ---: |
| R code lines across the two affected R files | 728 | 692 | -36 (-4.9%) |
| Net additional R code lines over main | 349 | 313 | -36 (-10.3%) |
| Entire `R/io_geoparquet.R` | 412 | 403 | -9 |
| Entire `R/io_write_dataset.R` | 650 | 600 | -50 |
| Public writer roxygen block | 166 | 133 | -33 |
| Net additional roxygen lines over main | 62 | 29 | -33 (-53.2%) |
| Public help words, excluding roxygen prefixes | 1,074 | 796 | -278 |
| Net additional help words over main | 502 | 224 | -278 (-55.4%) |
| Generated `.Rd` | 214 | 181 | -33 |
| GeoParquet regression files | 4 | 5 | +1 |
| GeoParquet regression lines | 724 | 875 | +151 |

The two R files and generated help shrink by 92 total lines. The complete
candidate has **59 more lines overall**, because 151 lines of focused tests were
added. The reduction is in production code and help, not in the test contract.
Regular comments across the two R files increase from 82 to 90 because unrelated
comments from main were restored. No production implementation was moved into
another file to make these numbers smaller.

All 66 existing files under `tests/testthat` are unchanged, including all 64
`test-*` files and the helper/setup files. The four required #7 regression files
are byte-identical, and the V1.1 stack also preserves #8's original V1.1 file
byte-for-byte. New tests cover native `BOTH`/`NONE`, quoted names and metadata,
option precedence, failed-export cleanup, and missing versus literal `NA` names.

## Fresh validation results

### Paired package regressions

Each source is installed into a separate library in the same runner environment,
and its actual loaded namespace path is checked. The source SHA, clean checkout,
original test-file hashes and complete dependency versions are recorded. Tests
run in separate supervised R processes; a completion marker without a real
successful exit does not count as a pass.

| Source | Linux passing assertions | Windows passing assertions |
| --- | ---: | ---: |
| Reference #7 | 221 | 221 |
| Candidate | 250 | 250 |
| Reference #8 | 307 | 307 |
| Simplified V1.1 stack | 336 | 336 |

All eight suites have **zero failures, errors, warnings and skips**, and each R
process exits with status **0**. On both operating systems, the candidate's
additional 29 assertions also pass unchanged against each reference installation,
in two separately supervised processes with actual exit 0. All six R test
processes on each operating system exit successfully. This checks that the new tests preserve
reference behavior rather than merely describing the revised implementation.
Complete installed-dependency lists match across all four sources.

### Independent exported-file validation

The preserved 34-file fixture family is used without dropping assertions. The
V1/V2 implementation selects its 22 applicable physical files (11 per version);
the V1.1 stack uses all 34 (11 V1, 12 V1.1, 11 V2). Both reference sources generate
their own fresh files in the same environment. **All 112 physical files pass**
the independent PyArrow/Shapely/PyProj checks. The 22-file candidate comparison
and 34-file stack comparison both pass for schema, metadata, active/secondary
geometries, CRS, coordinates, dimensions, row groups, native statistics and
compression. These results establish equivalence for the tested contracts and
fixtures; they are not a proof for every possible input or of a mathematically
minimal implementation.

Physical-order validation includes the 6,000-point fixture across row groups
`[2048, 2048, 1904]` and every other fixture requesting spatial ordering. All
**50 independent order checks** pass across reference and candidate sets.
They verify nondecreasing independently calculated Hilbert indices when the
extent is nondegenerate and the NULL/EMPTY suffix; ties have no imposed order.
Zero-row and all-missing fixtures exercise the corresponding empty-order cases.

GeoPandas reads every file and successfully writes and rereads every file at its
original GeoParquet version. The core validator reports no failures:

| Source set, per implementation | Physical files | Core rules passed | Core rules skipped |
| --- | ---: | ---: | ---: |
| V1/V2 reference or candidate | 22 | 228 | 212 |
| V1/V1.1/V2 reference or stack | 34 | 346 | 334 |

These core skips are disclosed, not counted as passes. For each 22-file set,
177 are inapplicable, 22 cannot be tested from a file alone, 11 concern a native
CRS parameter absent from V1.x, one concerns custom PROJJSON that the core
validator cannot compare without a CRS library, and one concerns an unknown
axis order. The corresponding 34-file counts are 274, 34, 23, one and two.
Separate PyProj checks validate the custom CRS and coordinate expectations.

**GDAL Parquet interoperability remains unverified**: the available GDAL 3.12.4
build has no Parquet reader. Its absence is not reported as a successful test.

### Full package checks

Full checks use `R CMD check --no-manual --as-cran`, including the full unchanged
package test suite. All four full-package jobs finish successfully. The final
candidate and stack each pass on all four platforms below.

| Platform | Candidate `22de905` | Stack `cefcf492` |
| --- | --- | --- |
| Linux, R 4.6.2 release | OK; 3,555 passes | OK; 3,641 passes |
| Linux, R-devel 2026-11-06 r90845 | OK; 3,555 passes | OK; 3,641 passes |
| Linux, R 4.5.3 oldrel | OK; 3,555 passes | OK; 3,641 passes |
| macOS, R 4.6.2 release | OK; 3,555 passes | OK; 3,641 passes |

The fresh reference #7 and #8 full Linux release checks pass with 3,526 and
3,612 assertions in the same job as the candidate and stack. Revised full-suite
counts increase by exactly the 29 new assertions, with no original assertion
removed. All ten full checks have zero test failures, 148 test warnings and two
existing skips. Their warning messages/locations and skip reasons all match the
reference, not just their counts.
The skips are in `test-ddbs_interpolate_aw.R:227` and
`test-duckspatial_df_dplyr_methods.R:197`. These testthat warnings are distinct
from the overall `R CMD check` status, which is **OK**.

No fresh full Windows package check is claimed. The previous full Windows
failure remains unresolved; this work neither restarts that investigation nor
introduces speculative Windows fixes. Fresh targeted Windows assertion success
and successful process exit are recorded above, separately from historical
targeted results and full-package results.

### Exact environment

The paired Linux run uses R 4.6.2, DuckDB R/native 2.0.0 (engine source
`d54cbbe3df`) and Spatial extension `a3dbcd1781`. Its key R dependencies are DBI
1.3.0, sf 1.1-3, dbplyr 2.6.0, dplyr 1.2.1, Arrow 26.0.0, geoarrow 0.4.4, wk
0.9.5, jsonlite 2.0.0, testthat 3.3.2, roxygen2 8.1.1 and rcmdcheck 1.4.0.
Python is 3.12.16, with PyArrow 26.0.1, Shapely 2.2.0, PyProj 3.8.0, GeoPandas
1.2.0, Pyogrio 0.13.0 and geoparquet-validator 0.3.1. Complete package and session
records are retained in the run artifacts; these version lists are observed,
not inferred from dependency constraints.

The final Linux paired artifact is `13587957933`, with verified ZIP SHA-256
`bdeeb7da95f0e0161a67f15ff12a38fdc4386ef997ca4496b0f7887f4d12a3ce`.
Both candidate and stack also pass fresh generated-help consistency checks.

Windows uses R 4.6.2 ucrt with the same DuckDB engine, Spatial extension and key
R package versions listed above; its Python interpreter is 3.12.10. Its complete
dependency comparison also passes for all four installations. The final Windows artifact is `13589100030`, with
verified ZIP SHA-256
`a87c0d481b7aeb17934ca2fdd9005d9c37b81fb9403ecb0bcf0713efc0caada4`.

The full-check environments are Ubuntu 24.04.5 x86_64 and macOS Tahoe 26.7.2
aarch64. Their four provenance sets record the same key R package versions,
DuckDB engine and Spatial extension listed above. All 14 full-check/provenance
archives have verified SHA-256 digests, and the packaged GeoParquet code, help
and tests match the exact source commits. `validation-results.json` preserves
the compact machine-readable results, dependency records, source-file hashes,
artifact identities and checksum verification for the final runs.

## V1.1 compatibility

The adapted increment remains small: accept V1.1, use the same measured-checked
WKB path, decode WKB for Hilbert ordering, include V1.1 in managed metadata, and
emit metadata version `1.1.0`. It adds no helper or dependency. Its original
210-line regression file is unchanged. The production GeoParquet increment is
11 inserted and 10 removed lines, including comments.

GeoParquet **1.0 (`V1`) remains the default** in both candidates. V1.1 and V2 are
opt-in. Native DuckDB storage-version settings are unchanged.

## Complexity retained for concrete reasons

The earlier [delegation comparison](https://github.com/e-kotov/duckspatial/blob/experiment/direct-duckdb-geoparquet-comparison-20261107/.github/upstream-validation/experiment/RESULTS.md)
and [native SQL controls](https://github.com/e-kotov/duckspatial/blob/experiment/geoparquet-v2-rootcause-20261107/.github/geoparquet-rootcause/RESULTS.md)
are reused as prior evidence about failure ownership, not counted as fresh
candidate validation. Ordinary typed geometries, ordinary renaming and multiple
properly typed native geometry columns already work through DuckDB. Secondary
local sf conversion is a package responsibility; measured-footer omission and
zero-row-footer omission are separate native limitations. Those observations
justify retaining specific adapter behavior, not every line of the old design.

| Retained mechanism | Requirement or reproduced failure |
| --- | --- |
| Explicit `geo` footer | Measured V2 omission in Spatial #847, zero-row native footer omission, active-geometry selection and explicit unknown CRS semantics |
| Conversion of every local sfc column | The original writer mishandles secondary sf geometry columns; native DuckDB handles properly typed columns |
| Rendered lazy query and native type inspection | Filtering, renaming and transformation must export the actual query, without stale source-table or CRS attributes |
| CRS recovery from types and legacy fallback | NULL-first and zero-row inputs still need CRS; legacy storage cannot encode it in native geometry types |
| Streaming measured-geometry rejection | V1/V1.1 must reject M/ZM without silently discarding measures or adding a preliminary data scan |
| V2 unknown-CRS safeguard | The current native V2 writer does not faithfully preserve explicit unknown CRS |
| Partition parser and ASCII case matching | Existing COPY identifier-list forms, quoted names and case-insensitive duplicate/geometry-key rejection |
| Hilbert bounds guards and `PRESERVE_ORDER` | Empty, NULL, degenerate and zero-row inputs; physical ordering despite unordered connection defaults |
| COPY option validation and quoting | Existing option precedence, reserved metadata, scalar/finite requirements and identifier behavior |

The inline [Spatial #847](https://github.com/duckdb/duckdb-spatial/issues/847)
comment remains beside the workaround. It states that fixing #847 alone is not
sufficient to remove metadata handling: empty files, all geometry declarations,
primary selection and unknown WKB CRS also need correct native behavior.

## Evidence and corrected intermediate attempts

1. Documentation runs [42405589894](https://github.com/e-kotov/duckspatial/actions/runs/42405589894)
   and [42406216866](https://github.com/e-kotov/duckspatial/actions/runs/42406216866)
   used roxygen2 8.1.1. Exact downloaded artifact bytes are checked in. Candidate
   `.Rd` SHA-256: `e577d9b22d2931f190a39707f8e7e551f0added4561ab65e2342a311eca867de`;
   stack: `03a691a13a6cfd05710ecff1096e668633426d77579aa8aeb6378d3a531292aa`.
2. Initial validation [42406592732](https://github.com/e-kotov/duckspatial/actions/runs/42406592732)
   tested earlier candidate `1346266` and stack `ae40726`. Independent validation
   passed for all 112 generated files, both 22/34-file equivalence comparisons
   passed, and the initial candidate's full checks passed on four platforms.
   The overall run failed: provenance CSV serialization encountered a list-valued
   field, a test-launcher preflight selected no original regression files, and
   Windows checkout line-ending conversion broke the raw-byte manifest check.
   These are harness failures, not original-suite successes. The final harness
   fixes the scalar query and filename preflight and preserves LF checkout
   bytes on Windows without relaxing any assertion.
3. A source review identified a real simplification regression. Executable
   [probe 42407264649](https://github.com/e-kotov/duckspatial/actions/runs/42407264649)
   confirmed that reference #7 rejects a missing local attribute name whereas
   the first candidate writes it as the literal `NA`. Both allow a literal
   `"NA"` name. Commit `22de905` restores the rejection in the existing local
   validation guard and adds eight assertions. All case-level cleanup and
   connection checks in the probe passed. Malformed geometry-renaming controls
   with stale sf attributes are recorded separately and are not treated as
   valid supported inputs.
4. In final run `42407894394`, the Windows reference #7 suite passed all 221
   assertions with actual exit 0, then Python's cp1252 log printer raised a
   `UnicodeEncodeError`. The remaining Windows sources did not run in that job.
   Harness `f66add7` enables UTF-8 interpreter output and explicit UTF-8 log
   reads, then runs only the Windows comparison. No package code, original
   assertion, process-exit requirement or Windows native behavior is changed.

The original four interop scripts and process-exit supervisor from `233b033`
remain byte-identical with recorded SHA-256 hashes. Derived harness copies add
supported-version selection only: 22 V1/V2 physical files for #7 and all 34 for
the stack. Existing assertions are retained. Additional independent checks
verify physical ordering for all ordered fixture families, including the
NULL/EMPTY suffix, without imposing an order among ties.

The source heads of development PRs #5/#6 are preserved at
`bc6c22c9a3e41a7d2959d8678ea15f1388e06202` and
`ca51dfb2a9a441f828056b010f460924308cc304`; reference PRs #7/#8 remain at the
SHAs listed above. Their branches and validation histories are not rewritten.
Closed integration PR #9 remains closed. No integration branch, upstream #182,
or storage-documentation work from #185/#187 was imported.

## Recommendation

**Adopt the simplification candidate**, with the tested V1.1 increment available
as the next step. The production reduction is modest but substantive: the
shared projection and CRS conversion remove repeated maintenance points, and
the shorter help keeps the public contract clear. Documentation-only changes
would leave those avoidable code duplicates in place. The added tests preserve
the compatibility boundaries exercised by the simplification, including the
missing-name regression found and fixed during this work.

Keep the documented metadata, CRS, dimensionality, identifier and ordering
safeguards. Their removal would require evidence that the corresponding
requirements are satisfied by a smaller implementation. The passing tests and
independent file checks support adopting this candidate within the tested
environment and contract; they do not prove that no further simplification is
possible.
