# Windows CI investigation — clean GeoParquet proposal

## Original failure and its limits

PR #7 head is `518647c2c685304c26335386876e504339a7a681`, based on
`677ed965894f20b5f83bdc6a389f42ccddb6a7ba`. The original
[package check run](https://github.com/e-kotov/duckspatial/actions/runs/42365125605)
checked the pull-request merge `31d7e48f35e7ea18608eba82b86447bd2f1027c1`.

Windows job `128381460527` has a complete `testthat.Rout.fail` in artifact
`13571269105`; the ZIP's verified SHA256 is
`b122b8f7d0ae6f398e3d59b458b7b5190aab23993d3dbc57cd901c97299dac00`.
The test child failed after 42 seconds. Its 27,351-byte output ends after an H3
installation success and the next DuckDB connection-storage message. There is
no failed assertion report, completed test summary, native exception code,
crash dump, or successful-test exit marker. R CMD check continued through
vignette rebuilding and finished with one ERROR.

Thus this artifact does **not** identify a shutdown hang. It shows an abruptly
failed test process. An assertion failure or missing R dependency is not shown.
The exact native cause of the original process failure is not recoverable from
that artifact alone.

## Fresh controlled evidence

Diagnostic-only [run 42374598976](https://github.com/e-kotov/duckspatial/actions/runs/42374598976)
uses harness commit `ea38505f452fe4ca59dde7c879159cdd71f2f5f9`. Each child
asserts its exact source SHA and clean tracked files. The harness preserves the
tests and connection defaults. It traces native entry/return, exports test
results, distinguishes R errors from native termination, and requires actual
exit 0. A successful-test quit request followed by a hang remains failure after
a 30-second grace period.

| Control | Source | Observed result |
| --- | --- | --- |
| PR #7, extension tests | `518647c2c685304c26335386876e504339a7a681` | 24 passes, zero failures/warnings, one existing forced-reinstall skip; completed cleanup and actual exit 0 in 14.704 seconds |
| PR #7, GeoParquet tests | `518647c2c685304c26335386876e504339a7a681` | 221 passes, zero failures/warnings/skips; completed cleanup and actual exit 0 in 44.969 seconds |
| PR #7, full suite | `518647c2c685304c26335386876e504339a7a681` | 3,542 passes, zero failures/errors, 142 warnings, three existing skips; tests, unload and GC returned, then the process hung after requesting exit 0; supervisor termination, **failure** |
| PR #5, full suite | `bc6c22c9a3e41a7d2959d8678ea15f1388e06202` | 3,588 passes, zero failures/errors, 142 warnings, two existing skips; tests, unload and GC returned, then the process hung after requesting exit 0; supervisor termination, **failure** |
| Unchanged main, extension tests | `677ed965894f20b5f83bdc6a389f42ccddb6a7ba` | Access violation `0xC0000005` (3221225477), no R error, no test completion or quit request, in 15.687 seconds |
| Standalone DBI/DuckDB native controls | Harness uses PR #7 checkout; duckspatial and testthat are not loaded | All five children completed and exited 0; this run did not reproduce the old standalone access violation |

### Baseline access violation location

The baseline `main` child reaches the second legacy test named “Community
extensions are installed”, which actually tries AWS. Its final checkpoints are:

```
12:58:38.762 SQL ENTER: INSTALL aws;
12:58:38.762 SQL LEAVE
12:58:38.763 rapi_execute ENTER
12:58:39.000 rapi_disconnect ENTER
```

There is no corresponding disconnect return, and the process exits with
`0xC0000005`. Its stderr ends with the same H3-success/next-connection pattern as
the original PR #7 failure. `R/db_extension.R`, `test-db_extension.R` and
`tests/testthat/setup.R` are byte-identical between this baseline and PR #7.
The original failure and this reproduction therefore have closely matching
symptoms in pre-existing code. Identical underlying native fault is an
inference, not proved by the original artifact.

The nested disconnect marker is consistent with deferred connection
finalization during AWS execution. Those two legacy optional-extension tests
omit explicit connection cleanup and load the default spatial extension instead
of their requested H3/AWS extension. The trace does not identify the connection
pointer or show a native stack, so it does not establish which object was being
finalized or its precise C++ fault site.

The five standalone controls were: spatial anchor with no failing install,
missing-extension installs without spatial, missing-extension installs with a
spatial anchor, AWS installs without spatial, and AWS installs with a spatial
anchor. AWS returned HTTP 404 from both core and community repositories; the
R handlers and explicit disconnects returned successfully. These are useful
negative controls, not proof that the intermittent native defect is fixed.

### Fresh artifact provenance

| Artifact | Verified ZIP SHA256 |
| --- | --- |
| `13574094828`, PR #7 extensions | `eb5797bdb9361aed72331f662ba35b69dd58d48fda345d46b18de18c0b2ac10c` |
| `13575386012`, PR #7 GeoParquet | `c4d5a5ff5a3a104fa94db6e952f516b7038ad45e8420a92e784d6ef1d0e7a45d` |
| `13575261325`, main extensions | `1edb2343554476c08d667a1fe7109d32a1db0e89c43b70e38ee5c94f7ecdfebf` |
| `13574499208`, native controls | `349c705284252b559aa185e89cc289c0c52e4439dd8d0b4ac2e76406e0b5d211` |
| `13575750481`, PR #7 full suite | `cf2508bccf34ffe8d83bb119eb27369175bfbe53cee47621dc05daf3596db10d` |
| `13574584981`, PR #5 full suite | `d3bc172c2221bd6893d298f5d5bb6b663d85f5abf81eaa10f2c270e25d020118` |

### Full-suite shutdown results

PR #7's full test runner returned at `13:05:03.241 UTC`; package unload and
explicit GC returned, and R requested exit 0 at `13:05:03.834 UTC`. It did not
exit within the 30-second grace interval. The before-termination process tree
still contains the native `C:/R/bin/x64/Rscript.exe` PID 7568, its `cmd.exe`
parent, and the PATH Rscript launcher. The supervisor killed that process tree
and recorded failure after 444.907 seconds overall.

PR #5's corresponding full runner returned at `13:06:47.039 UTC`; unload and
GC returned, then R requested exit 0 at `13:06:47.543 UTC`. Its native PID 2088
and launchers likewise remained alive after the grace interval. The supervisor
terminated that process tree and recorded failure after 530.610 seconds overall.

The recorded exit 1 in these two results is termination of a hung process,
not an R assertion failure. Neither is a successful full Windows package check.
Both old and clean implementations show the shutdown symptom, despite PR #5's
additional result/connection/fixture cleanup. This establishes that importing
those changes does not resolve the full-suite shutdown problem. The new runs
did not capture native stacks, so identity with the previously symbolized
runtime wait remains supported by matching behavior rather than newly proved
at instruction-pointer level.

## Existing independent native evidence reused

[Run 42255463824](https://github.com/e-kotov/duckspatial/actions/runs/42255463824)
previously reproduced a failed-install/disconnect access violation with only
DBI 1.3.0 and DuckDB 2.0.0 loaded. Both the spatial-anchor and loaded-spatial
children returned the expected HTTP errors, then exited `-1073741819`
(`0xC0000005`) immediately after `DISCONNECT ENTER`. The corresponding
failed-install child without spatial exited 0. Artifact `13523452904` was
retrieved and its SHA256 independently verified as
`f975bb6555b474a861b2c4b2f90cec9263396d03801d1e740380274ceb3c7990`.
Its exported Event 1000/1001 records are unrelated LoadPerf events, not native
fault-module evidence.

The separate [native shutdown report](https://github.com/e-kotov/duckspatial/blob/fe62f8b04c3e879ed3d143956cf73095302f6f5f/.github/windows-native-exit-capture-report.md)
and preserved dump identify an actual final-exit wait inside Spatial's bundled
C++/MinGW TLS-cleanup runtime. That DBI/DuckDB-only workload completed its checks,
owned cleanup and final GC before requesting exit 0. It performs GeoJSON and
Shapefile operations, not GeoParquet. The fresh extension test reported spatial
version `a3dbcd1781`, the same version in the earlier captured binary's metadata.
The established native shutdown wait is distinct from the earlier test-process
access violation.

## Implications for PR #7

No GeoParquet production fix is justified by these observations. The fresh
GeoParquet subset passes with actual process exit; pre-existing main can fail
before GeoParquet tests. Do not import PR #5's unrelated resource changes merely
to seek a green CI outcome. Comparing complete PR #5 and PR #7 suites cannot
alone identify which omission matters because PR #5 changes extension tests,
fixture cleanup, and two production result-cleanup paths together.

### Confidence and remaining uncertainty

- **Established:** a pre-existing extension-test execution can crash with
  `0xC0000005` after entering native disconnect; PR #7's GeoParquet subset can
  complete with actual exit 0; both PR #5 and #7 full suites can complete all
  evaluated assertions and nevertheless fail to exit.
- **Strong inference:** the original PR #7 short failure belongs to the same
  inherited extension/finalizer native-failure class reproduced on main. Its
  exact underlying C++ fault site is unresolved because no original exception
  code or dump was preserved.
- **Established by earlier standalone capture, not recaptured here:** a separate
  Spatial DLL C++/MinGW TLS-cleanup shutdown wait with an outstanding pthread
  key-table reader. That is a concrete external defect matching the full-suite
  final-exit symptom, not proof that every native failure shares one cause.
- **Not established:** which connection was being disconnected, whether it
  belonged to a legacy optional-extension fixture, or that adding cleanup to
  those two tests fixes the crash. These are separate fixture-maintenance candidates, not grounds for
  changing the GeoParquet contribution.

No production code, test cases, thread defaults or failure gates were changed
on PR #7 in response to this investigation.
