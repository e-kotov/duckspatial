# Clean GeoParquet contributions — validation and readiness

Assessment date: 7 November 2026. All changes and validation branches are in
`e-kotov/duckspatial`. No upstream repository was changed and no PR was merged.
Development PRs #5 and #6 remain open at their original reviewed heads.

## Contributions and exact source identities

| Contribution | Base | Head | Scope |
| --- | --- | --- | --- |
| [PR #7](https://github.com/e-kotov/duckspatial/pull/7) | `main`, `677ed965894f20b5f83bdc6a389f42ccddb6a7ba` | `518647c2c685304c26335386876e504339a7a681` | Existing one-commit, eight-file GeoParquet V1/V2 contribution; no code changes in this session |
| [PR #8](https://github.com/e-kotov/duckspatial/pull/8) | `feat/geoparquet-v2-upstream`, `518647c2c685304c26335386876e504339a7a681` | `c9ad8393c2eaf0d96eee7cedee3af379efff01b3` | One direct child commit; five files; +252/-33 |

PR #8 adds `geoparquet_version = "V1.1"` to the shared WKB path. V1 remains the
default (1.0.0), V1.1 writes 1.1.0 WKB, and V2 retains native 2.0.0 geometry
annotations/statistics. Unknown CRS, multiple and active geometry, lazy-query
export, dimension restrictions, partitioning and ordering safeguards are reused.
There is no second writer, new dependency, optional native V1.1 coordinate
encoding, bbox covering, production resource refactor or permanent new workflow
in either clean contribution.

The only PR #8 files are `R/io_geoparquet.R`, `R/io_write_dataset.R`,
`man/ddbs_write_dataset.Rd`, `tests/testthat/test-geoparquet-v11.R` and `NEWS.md`.
Independent review and an explicit changed-path comparison confirmed that none
of PR #5's unrelated production/test cleanup or diagnostic tooling was imported.
The published tree `942c9ed8e6b6188ed104c69632fae264d3b724f6` is identical to the
locally reviewed candidate; only its commit metadata differs.

## Windows diagnosis

See [the detailed Windows findings](windows-findings.md) for the complete
artifact identities, verified hashes, native-call checkpoints and limitations.

The original PR #7 failure after 42 seconds has no completed test summary,
assertion error, native exception code or dump. It is not established to be a
shutdown deadlock. The original matrix checked merge
`31d7e48f35e7ea18608eba82b86447bd2f1027c1`, whose tree
`9eeed494eaa5b244d5465c449378c1528e3e3afe` was verified identical to PR #7's head.

Fresh diagnostic [run 42374598976](https://github.com/e-kotov/duckspatial/actions/runs/42374598976)
uses harness `ea38505f452fe4ca59dde7c879159cdd71f2f5f9` and explicitly checks
each source SHA and clean tracked files. It establishes:

- Unchanged `main` can crash in the inherited AWS-extension test with an actual
  access violation (`0xC0000005`). Its last marker is `rapi_disconnect ENTER`,
  nested during `INSTALL aws` execution. The source contains no GeoParquet
  contribution. This closely matches the original short failure, but identity
  of the original C++ fault remains an inference.
- PR #7's isolated GeoParquet suite passed 221 expectations, with no failures,
  warnings or skips, and actual process exit 0. Its unchanged extension subset
  also exited 0; the native failure is not deterministic.
- PR #7's complete suite returned 3,542 passing expectations, zero failures or
  errors, 142 test warnings and three existing skips. PR #5 returned 3,588
  passes, zero failures or errors, 142 warnings and two skips. Both completed
  unload and final GC, requested exit 0, and then failed to exit. The supervisor
  terminated each after the 30-second grace period and correctly reported
  failure. Assertions completing does not make either a successful full check.
- The earlier independently captured DBI/DuckDB-only native installation crash
  and symbolized native shutdown dump were reused. Five new DBI/DuckDB-only
  installation controls all exited 0, so this run does not establish a new
  deterministic standalone crash reproducer.

No necessary GeoParquet production fix is supported. The baseline extension
reproduction does not exercise PR #5's two changed production result-cleanup
functions. PR #5's cleanup also demonstrably does not resolve the full-suite
shutdown symptom. The optional-extension fixtures have inherited missing
cleanup/wrong-extension defects, but their precise causal role remains unproved;
they are separate maintenance candidates, not an established fix to import here.

Confidence is high in the observed baseline native access violation and both
post-test exit failures. Confidence is lower in assigning the original short
failure to the exact same native fault; its artifact cannot prove that. No
fresh native dump was captured, and no new C++ root-cause claim is made.

## Fresh final-stack validation

[Run 42375149571](https://github.com/e-kotov/duckspatial/actions/runs/42375149571)
uses diagnostic harness `233b033d221dc2913d56e2ba431370f50e93e722`, but checks out
and verifies the exact contribution source
`c9ad8393c2eaf0d96eee7cedee3af379efff01b3`. The harness and package are separate
directories. Windows diagnostics are outside the package source. The ordinary
package check's build arguments and warning/error gates are preserved.

| Full package check | Result | Complete test summary |
| --- | --- | --- |
| Ubuntu release, R 4.6.2 | **R CMD check OK**, process completed | 3,612 passes, 0 failures, 148 testthat warnings, 2 existing skips |
| Ubuntu devel, r90845 (2026-11-06) | **R CMD check OK**, process completed | Same counts |
| Ubuntu oldrel, R 4.5.3 | **R CMD check OK**, process completed | Same counts |
| macOS release, R 4.6.2 | **R CMD check OK**, process completed | Same counts |
| Windows release, standard R CMD check | **Cancelled at the configured 30-minute deadline; R CMD check unfinished** | 3,616 passes, zero failures, 148 test warnings, three existing skips; final `proc.time()` printed, no completed check status |
| Windows release, supervised full suite | **Failed actual process exit** | 3,628 passes, zero failures/errors, 142 test warnings, three existing skips; quit hang |

All four successful check logs report no R CMD check warnings, errors or notes.
Their 148 testthat warnings come from existing non-GeoParquet tests. The two
skips are the pre-existing interpolation and dplyr compute-plan skips. Each
complete test log includes the final `proc.time()` output. This distinction
between suite warnings and package-check status is intentional.

All four result ZIPs were independently downloaded, hash-verified and their
`00check.log` and complete `testthat.Rout` inspected:

| Artifact | Platform | Verified SHA256 |
| --- | --- | --- |
| `13575148825` | Ubuntu devel | `4002926476f5df5c3cfdc2f94a41c041a9daa6182d73000ba98ebd413fddb30a` |
| `13575741285` | Ubuntu release | `29b986a2cf3ec27e015dbd44157918f8333d6511a7a1324b0ab97e8f992c4fb9` |
| `13575741305` | Ubuntu oldrel | `d435625fdd2ef830cbe508fc0d063e4d4bc931e68f56da2ef729d9ea2e1c9460` |
| `13575478344` | macOS release | `49a7ff0f7cf01d2f2c0eeb4953d50e705946b3405c1e7cbc8e2213dc66bcd11f` |

The standard Windows job `128411098531` ended with GitHub conclusion
`cancelled` at the configured 30-minute deadline. Its `00check.log` has every
pre-test check OK and ends at `* checking tests ...`, without a final status.
Its complete `testthat.Rout` reports 3,616 passes, zero failures, 148 test
warnings and three existing skips, followed by final `proc.time()` output
(elapsed 416.31 seconds). These passing assertions are not a completed package
check. The cancellation log does not itself identify a native fault site.

The normal Windows check artifact `13575054922` was downloaded and verified:
11,007,699 bytes, SHA256
`96a24499574af32e28a8e962d0a625ed46e8b05c68c2fa1b0a21194d3d4428c5`.
The separately isolated GeoParquet artifact `13575449214` was also verified:
252,994 bytes, SHA256
`e0bdf66a6ec02de0d16546442d083a2729542fe3ae17370022506fe79bda017b`.
Its CSV confirms 307 passes and zero failures, warnings, errors or skips;
its supervisor records actual exit 0, no termination and 52.015 seconds elapsed.

The final stack's separate [bounded Windows full-suite run
42376122552](https://github.com/e-kotov/duckspatial/actions/runs/42376122552)
uses harness `33c384448ea1fa9333e95e1e08414816609d3912` and exact source
`c9ad8393c2eaf0d96eee7cedee3af379efff01b3`. It completed every evaluated assertion
at 13:22:46.516 UTC, returned from explicit unload and GC, and requested exit 0
at 13:22:47.115 UTC. The process did not exit within the 30-second grace period.
The supervisor terminated it and reported `quit-hang`, exit 1. That exit 1 is
forced termination, not an assertion failure or a native access-violation code.
The full result CSV contains 3,628 passes, zero failures/errors, 142 warnings and
three existing skips. Its GeoParquet rows contain exactly 307 passes and no
warnings, skips, failures or errors. The separately isolated Windows
GeoParquet step also completed successfully under the actual-process-exit gate.

The [bounded Windows artifact](https://github.com/e-kotov/duckspatial/actions/runs/42376122552/artifacts/13576057304)
is `13576057304`, size 3,225,142 bytes, verified SHA256
`895f4ca5c8128dd534ce8684f3707b5a538dd4a74b201cd63496a96aa67f9af8`.
It contains the full result CSV, checkpoints, process trees, stdout/stderr and
supervisor result. Event-log matches were LoadPerf counter notices, not native
Application Error evidence. No fresh native dump or new native fault site is
claimed. Thus the V1.1 stack reproduces the observed post-test exit failure; it
has not fixed or hidden the inherited Windows limitation.

The Linux GeoParquet subset passed **307 expectations, zero failures, warnings
or skips**. Fresh fixtures generated from the same source produced **34 physical
Parquet files: 11 V1, 12 V1.1 and 11 V2**. Independent checks passed in CI and
were repeated locally after verifying the artifact ZIP, source SHA and every
physical file's digest.

| Independent validation | Actual result |
| --- | --- |
| PyArrow physical schema and metadata | All 34 files passed; V1/V1.1 geometry is unannotated WKB `BYTE_ARRAY`, V1.1 metadata version is exactly `1.1.0`; V2 native annotation/statistics agree with metadata |
| Shapely values and dimensions | All 34 files passed; exact expected point/nonpoint values, Z/M/ZM where supported, NULL/empty distinctions and zero rows |
| PyProj | Known/custom/unknown CRS semantics and transformed coordinates passed; semantic custom-CRS agreement independently checked |
| Physical spatial order | Each version's 6,000-ID sequence matches an independent Hilbert calculation across row groups of 2,048 / 2,048 / 1,904 rows |
| GeoPandas 1.2.0 | All 34 reads and 34 same-version write/read round-trips passed, including secondary geometries and measured V2 values |
| Core conformance, validator 0.3.1 | 34 files passed; 346 passing core outcomes, zero failing outcomes, 334 recorded skips; no sampling |
| GDAL via Pyogrio | Unavailable: GDAL 3.12.4 in the installed build has no Parquet reader |

The core validator's 334 skips comprise 274 not-applicable rules, 23 absent
native CRS parameters in V1.x, 34 HTTP media-type checks not testable on a local
file, two unknown-CRS axis-order checks, and one custom-CRS comparison requiring
a CRS library. The separate PyProj check covers the latter comparison. These
are not 334 successful checks. Optional covering columns are not claimed.

Coverage includes native sf, lazy filtering/renaming/transformation, active and
secondary geometries, custom and unknown CRS, NULL/empty/zero-row inputs,
XY/XYZ/XYM/XYZM behavior, partition files and Hilbert ordering. R regression tests
also verify rejection of measured V1/V1.1, unknown-CRS V2 and partitioned ordering.

Independent reader versions were PyArrow 26.0.1, Shapely 2.2.0, PyProj 3.8.0,
GeoPandas 1.2.0 and Pyogrio 0.13.0. The Linux regression process used R 4.6.2.

The [fresh interoperability artifact](https://github.com/e-kotov/duckspatial/actions/runs/42375149571/artifacts/13575577292)
is `13575577292`, ZIP SHA256
`34e81d736d84c341c846c52c4bb9cb4f07bfae5583956fe73155861b62667132`.
It contains the physical fixtures, exact source SHA, test-result CSV, R session
information, Python versions and per-file core-conformance reports/digests.

## Upstream compatibility

The following remained open and unmerged at review time. Upstream `main` was
still `677ed965894f20b5f83bdc6a389f42ccddb6a7ba`.

| Upstream contribution | Reviewed head | Effect on these contributions |
| --- | --- | --- |
| [#184 discussion](https://github.com/Cidree/duckspatial/issues/184) | Issue | Explicit opt-in V2 and V1.1 WKB match the discussion; no expanded scope is required |
| [#182](https://github.com/Cidree/duckspatial/pull/182) | `003f5c56433ca3913998fee5d241311e61e4cbc6` | Complementary lazy-query fixes; tested three-way file merges are clean. Preserve its non-Parquet source-table guard and our rendered-query Parquet path |
| [#185](https://github.com/Cidree/duckspatial/pull/185) | `1de6fd736e88acf1a21b327158e8d49581cde30f` | Its Windows matrix is still failing. Fuller test output is not a demonstrated native fix. Current diff also includes axis-order and storage changes |
| [#187](https://github.com/Cidree/duckspatial/pull/187) | `ec0d277938096ee53fce6ed84f251ee7ab82e45c` | Storage-version changes are independent of GeoParquet versions; one predictable roxygen conflict if merged first |

If #185/#187 lands first, retain upstream's `@template duckdb_storage_version`
and all our GeoParquet parameters/details, then regenerate help. Preserve the
storage-version documentation improvements and update the introductory default
storage narrative consistently; do not restore the old inline template content.
No upstream changes have been imported unnecessarily, and no combined runtime
test of the still-unmerged upstream PRs is claimed.

## Readiness recommendation

Both clean contributions are suitable for maintainer code review with the
explicit inherited Windows limitation. They are not an all-platform-green or
unrestricted merge-ready result. Both remain draft in the fork; no upstream PR
was opened. A successful, reliably exiting full Windows check or explicit
maintainer acceptance of the documented pre-existing Windows failure remains the
merge gate. No confirmed GeoParquet correctness defect or necessary package
production fix was found.

The original short failure's precise native fault remains unresolved; the
baseline access violation and fresh post-test hangs are observed facts. GDAL
Parquet interoperability is an explicit unverified check, not a claimed pass.
Before eventual upstream submission, refresh upstream heads, preserve the
storage documentation template if adopted, and retain #182's compatible lazy
query protections. No additional GeoParquet feature work is recommended.

The [scope audit](scope-audit.json) records exact ancestry and all excluded PR
#5 paths. The [local verification summary](local-validation-summary.json)
records the downloaded artifact identity, script digests, successful local
process exits and reader counts.
