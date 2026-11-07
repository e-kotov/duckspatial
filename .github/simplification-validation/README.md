# GeoParquet simplification validation

This branch contains validation tooling only. Production candidates and the
unchanged #7/#8 references are checked out separately at the exact SHAs in
`sources.json`; no validation files are added to either contribution.

## Running

Push changes to `validation/geoparquet-simplification-20261107`. The workflow
uses `sources.json` to choose a stage:

- `documentation`: regenerate the candidate's help with roxygen2 8.1.1, and
  publish the generated `.Rd` plus the diff as an artifact and in the job log.
  The stack SHA is not required in this stage.
- `validate`: compare the final candidate and V1.1 stack against the unchanged
  #7/#8 reference SHAs. Set both final source SHAs before triggering this stage.
- `probe`: characterize missing, empty and quoted identifiers against the
  unchanged #7 and candidate, in isolated installed packages. This diagnostic
  records behavior differences; it does not replace the regression checks.

The paired Linux and Windows jobs install all package dependencies once, then
install each of the four source packages into separate libraries. The original
regression files are checked for byte identity. All GeoParquet tests run in
fresh R processes, with actual process exit required. The new options tests
also run separately against each installed reference package.

Linux runs the independent PyArrow/Shapely/PyProj, GeoPandas, available GDAL and
GeoParquet core validators on fresh physical files. GDAL without a Parquet
driver is explicitly reported as unverified. Reference and candidate output
are also compared for schema, metadata, coordinates, dimensions, row groups,
native statistics, compression and the promised physical Hilbert order.
Every ordered fixture also independently checks the NULL/EMPTY-last suffix and
nondecreasing Hilbert indices for nondegenerate extents, without constraining
ties. Each isolated installation's actual library path is recorded and checked;
the additional contract tests verify the loaded reference namespace path.

Full package checks run on Linux release/devel/oldrel and macOS release for both
candidate and stack. Linux release additionally checks both unchanged reference
packages in the same job. The known Windows full-package failure is not
reinvestigated; fresh Windows results cover the unchanged targeted regressions
and actual exit only, and cannot establish a passing full Windows check.

## Preserved harness and version selection

The original four interop files and exit supervisor are copied byte-for-byte
from `233b033d221dc2913d56e2ba431370f50e93e722`. Their original paths and SHA-256
digests are in `preserved-harness.json` and checked on every validation run.

The derived `interop/` copies add only explicit fixture-version selection,
controlled by `GEOPARQUET_FIXTURE_VERSIONS`. The original default remains all
three versions and 34 files. #7 supports V1/V2, so it generates and validates
exactly 22 physical files (11 each); the V1.1 stack validates all 34 files
(11 V1, 12 V1.1, 11 V2). The expected file count changes with the selected
versions. All original schema, value, CRS, dimension, NULL/EMPTY, statistics,
ordering and cross-reader assertions remain in place for every selected file.

No original package test is deleted, skipped, relaxed or rewritten. Source
identities, R session/package versions, DuckDB/Spatial versions, Python package
versions, subprocess commands, actual exit codes, all fixture bytes and every
independent validation result are retained in workflow artifacts.
