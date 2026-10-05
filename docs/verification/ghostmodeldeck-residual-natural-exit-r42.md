# #15 follow-up: failed residual natural exit (r42)

## Scope and baseline

- Baseline: clean `main` at `3022cdeb2cfd79703e76c9f9d9a01f9afc3fe515`, after both prior writers settled; parent reported 200 full tests online.
- Owned changes only: [llama_engine.dart](../../lib/llama_engine.dart), [llama_engine_test.dart](../../test/llama_engine_test.dart), this note. No downloader, chat protocol, Council, UI, fixture, dependency, container configuration, or other-repository changes.
- Used the original [test-container.sh](../../scripts/test-container.sh), online dependency resolution and exclusive SERIAL `GMD_TEST_CONTAINER=ghostmodeldeck-checks-r33b`. Parent HOST production MLX download and asset files were not accessed, probed or cancelled.

## Confirmed public defect

The exit watcher recorded the child exit code but excluded every run sealed by `_seal`, including a failed stop whose future had already returned. Thus the public failed/live residual and owned model-file protection could remain after its child naturally exited.

The regression starts two distinct instance IDs/PIDs/generations through the existing `EngineProcessIO`/`EngineChild` seam and real loopback HTTP. A's kill throws `StateError('owned stop refused')`; the returned stop failure leaves A failed/live, capability-empty, non-admitting, drained and protected. Only afterwards does A's exit Completer finish with code 17. An `engine.changes` failed/no-live observation synchronizes assertions, without private calls or scheduling sleeps. Its timeout bounds a missing observable event, not a race-timing assertion.

Assertions retain A's stop-error diagnostic and actual exit code, zero requests, empty capabilities, rejected admission, and identity; B remains Ready/callable/live with its original PID/generation. Because B uses the same asset, deletion must stay blocked until B stops. Deletion then becomes possible without retrying A. A subsequent managed recycle must not rewrite the dead residual's failure diagnostic or attempt its refused kill again.

## Minimal reconciliation

- The authoritative existing watcher handles a current sealed run only when its public status is already failed; normal in-flight stopping retains its caller-owned terminal publication.
- An already sealed residual is not resealed (which would transiently publish stopping and clear its diagnostic). Its actual death is published as failed/no-live, with the stop failure preserved and exit code appended.
- After draining, current run/generation and failed residual status are rechecked before removing the unused residual run and reservation. A retry that has resumed stopping keeps ownership; stale run completion cannot clean another run or peer.
- The existing shared model-use registry performs protection reconciliation. Cancellation/drain-before-kill, request release idempotence and SSE paths are unchanged.
- The adjacent ordinary-text post-await cancellation candidate was not changed or claimed fixed.

## Actual checks

All invocations below used the original online script and the r33b SERIAL slot.

| Check | Raw job | Evidence directory | Actual result |
| --- | --- | --- | --- |
| New public targeted RED, before implementation | `bash-283` | `.tooling/container-tests/run-78ULbB` | Exit 1: `TimeoutException after 0:00:02.000000: Future not completed`; no natural-exit public reconciliation |
| First engine regression iteration | `bash-285` | `.tooling/container-tests/run-CQd31e` | Exit 1: 37 passed / 1 failed; redundant residual resealing published `stopping` rather than terminal `failed`. Corrected by avoiding reseal and observing the explicit failed/no-live terminal state. |
| Final engine GREEN regression | `bash-286` | `.tooling/container-tests/run-6Diyrg` | Exit 0: all 38 tests passed, including residual explicit retry, spontaneous exit, normal cancel/drain stop, late-spawn/peer isolation and SSE regressions |
| First strict format | `bash-289` | `.tooling/container-tests/run-juFIhG` | Exit 1: 56 files checked; only the added owned test required Dart formatting |
| Formatter output acquisition (not a strict check) | `bash-290` | `.tooling/container-tests/run-uAl1Ty` | Exit 0: exact formatter output for the owned test; applied only to its new test block |
| Final strict format | `bash-292` | `.tooling/container-tests/run-o4Vvfr` | Exit 0: 56 files, 0 changed |
| Whole-project analyze | `bash-294` | `.tooling/container-tests/run-ZISZsR` | Exit 0: `No issues found!` |
| Full online suite | `bash-295` | `.tooling/container-tests/run-aC4O80` | Exit 0: all 201 tests passed (baseline 200 + new regression) |

## Limits

This is deterministic public engine lifecycle evidence with a controlled process adapter and actual loopback transport. It is not native llama.cpp/MLX inference, two actual engine versions, three JEV primitives, desktop or Release acceptance. #15 remains open. The parent's separate production download/generation evidence is not claimed by this slice.
