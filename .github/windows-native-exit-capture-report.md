# Windows native shutdown capture

## Finding

The DBI/DuckDB-only reproduction hangs during Windows process shutdown inside
the MinGW/C++ runtime statically bundled in `spatial.duckdb_extension`.
Its static cleanup deletes the pthread key used for C++ `thread_local`
destructors, then waits for a key-table reader to finish. The dump contains
only one remaining R thread, and the lock still records one outstanding
reader. This identifies the native wait site; it does not identify which
earlier thread left that reader count outstanding.

No duckspatial, testthat, sf, or Arrow namespace was loaded. The reproduction
performs GeoJSON/Shapefile operations, not GeoParquet export. Its checks,
owned-connection cleanup, explicit driver shutdown, and final GC all return
before `quit(save = "no", status = 0)`.

## Evidence and provenance

- [Capture run 42314733984](https://github.com/e-kotov/duckspatial/actions/runs/42314733984).
- Capture workflow/source commit: `955a6fe159c9aefe067e8dfd4d9997b548f04f05`
  on `debug/windows-exit-validation-20261106`.
- [Artifact 13550570990](https://github.com/e-kotov/duckspatial/actions/runs/42314733984/artifacts/13550570990),
  named `windows-native-exit-capture-1`: 52 files, 196,937,717 compressed bytes.
- Artifact ZIP SHA256:
  `d0a923d4039166bc988ec44ccb0d2eb59747cd63da1fc507ee9300cb439449d8`.
- Full native R dump: `raw--all--base--t0-native/pid-6496.dmp`,
  363,038,440 bytes, SHA256
  `78e2305c29e4f1e54fc02fa174599ea3e07e7e818f246ddc6ca8ff968349e8ec`.
- Exact extension SHA256:
  `3de3f298b4dcaa10f3e081d6ff1e411cf44d487d19317be28bd20303494a1415`.
- Runtime: R 4.6.2 UCRT, DBI 1.3.0, DuckDB 2.0.0, Windows build 26100;
  runner image `windows-2025-vs2026`, version `20261103.298.1`.
- PR #5 head remains `bc6c22c9a3e41a7d2959d8678ea15f1388e06202`.
  This standalone capture did not run the package suite or change PR code.

The artifact contains the exact R, DuckDB and spatial binaries, dump hashes,
checkpoint logs, process trees, CDB commands, live capture logs and subsequent
offline native stack analysis. GitHub artifact retention is 30 days.

## Validation

The capture used the PID reported by `Sys.getpid()` rather than assuming the
PATH `Rscript.exe` launcher was the native R process. Native R was PID 6496;
its launcher chain was Rscript PID 8288, cmd PID 8228, then native R PID 6496.

Before reproduction, the same CDB command was tested on a disposable process.
It wrote a valid dump, completed its commands, detached without killing the
process, and its heartbeat resumed. Live capture used noninvasive `-pv` and
explicit `qd`; the earlier rejected `-pd` option was removed.

All three real dumps have valid MDMP headers, confirmed successful dump writes
and completed command scripts. All three offline analyses completed. The
downloaded ZIP digest and every member's CRC were independently checked.
Independent parsing of the full R dump confirms PID 6496, one thread (TID 212),
active thread status, no thread dump errors, and an instruction pointer in
`ntdll!NtWaitForMultipleObjects`.

The exit-0 request was logged at 2026-11-06 23:55:20.455 UTC. The dump was
written at 23:55:51 UTC, after the 30-second grace period. The process remained
alive after debugger detach. Both wrapper stacks simply wait for their child
processes. This is a real native R shutdown hang.

The default-thread reproduction hung on its first attempt in this run.
The paired `threads = 1` control exited 0 in 6.031 seconds. The workflow
correctly reports **failure** for the hang. Successful evidence capture is
not a passing Windows package check, and this control does not establish a
guaranteed workaround.

## Symbolized wait stack

The stack traverses Windows `ExitProcess` and `LdrShutdownProcess`, then the
spatial DLL's detach/static-cleanup path. The exact preserved spatial binary
contains COFF symbols and partial DWARF. GNU `nm`, `addr2line` and disassembly
independently resolve these CDB offsets:

| Spatial RVA | Function |
| --- | --- |
| `0x125d` | `__DllMainCRTStartup+0x5d` |
| `0x117c` | `_CRT_INIT+0x16c` |
| `0x3e6238f` | `__tcf_0+0xf`, C++ TLS cleanup-key destructor |
| `0x1901d46` | `pthread_key_delete+0x36` |
| `0x1900522` | `pthread_rwlock_wrlock+0x102` |
| `0x18fecfc` | `pthread_cond_wait+0x1dc` |
| `0x18fe6c6` | `do_sema_b_wait+0x76` |
| `0x18fe388` | `do_sema_b_wait_intern+0x48` |

The final frames enter `WaitForMultipleObjects` and
`NtWaitForMultipleObjects`. CDB's automated classification is
`APPLICATION_HANG_HungIn_LoaderLock`; the symbolized stack narrows that broad
classification to the pthread key-table reader-completion wait.

Disassembly of `__tcf_0` loads `(anonymous namespace)::key` and calls
`pthread_key_delete`. Its neighboring COFF symbols identify GCC's
`__cxa_thread_atexit` fallback compilation unit. GCC 10.4's
[`atexit_thread.cc`](https://github.com/gcc-mirror/gcc/blob/releases/gcc-10.4.0/libstdc%2B%2B-v3/libsupc%2B%2B/atexit_thread.cc)
defines this cleanup-key destructor. Embedded runtime DWARF paths identify
GCC 10.4.0 / mingw-w64-v9.0.0.

In that runtime, [`pthread_key_delete`](https://github.com/mingw-w64/mingw-w64/blob/v9.0.0/mingw-w64-libraries/winpthreads/src/thread.c)
takes `_pthread_key_lock` in write mode. The captured return address in
[`rwlock.c`](https://github.com/mingw-w64/mingw-w64/blob/v9.0.0/mingw-w64-libraries/winpthreads/src/rwlock.c)
is the condition wait for outstanding readers to finish.

## Lock state in the dump

The spatial module's loaded base was `0x7ffb6d330000`. Its
`_pthread_key_lock` storage at `0x7ffb712938f0` points to `0x2d3c61e69d0`.
Using the verified Windows x64 layout in
[`rwlock.h`](https://github.com/mingw-w64/mingw-w64/blob/v9.0.0/mingw-w64-libraries/winpthreads/src/rwlock.h),
the recorded fields are:

| Field | Recorded value |
| --- | --- |
| `valid` | `0xBAB1F0ED`, live rwlock signature |
| `busy` | `1` |
| `nex_count` | `0` |
| `nsh_count` | `1` |
| `ncomplete` | `-1` |

The C++ cleanup TLS key at `0x7ffb71297760` is `1`. The read count and negative
completion count agree with the captured writer waiting for one reader to
complete, while the dump lists only the exiting thread.

For reproducible offline symbolization, the binary's preferred image base
is `0x2922e0000`: add the table's RVA to that base before calling GNU
`addr2line`. Do not pass an ASLR runtime address directly. DWARF coverage is
partial; unresolved source filenames must not override the COFF symbols and
verified disassembly.

## Limits and next action

The capture locates this reproduction's native shutdown defect in the spatial
extension's bundled C++/MinGW runtime. A read-lock left outstanding during
thread/process teardown is strongly supported. The dump cannot establish
which earlier thread acquired it, why its release was lost, or whether every
historical Windows crash/timeout has this same cause.

The observed mechanism is compatible with reported MinGW shutdown deadlocks,
including [MinGW issue 1017](https://sourceforge.net/p/mingw-w64/bugs/1017/),
but identity with that issue or a specific existing fix is not established.
The next engineering step is an upstream DuckDB spatial/Windows runtime
investigation using this reproducer, exact binary, dump and lock state, then
validation of a dependency fix against both the standalone workload and the
full Windows package check. No production thread defaults or test gates were
changed to obtain this evidence.
