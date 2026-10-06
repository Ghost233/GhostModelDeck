# r47 — approved standard installation version-command budget implementation

## Scope and decision

Implemented on current `main`, starting clean `98f33e0`, after the explicitly human-approved measurement-first decision in [r47 decision](ghostmodeldeck-standard-version-budget-r47.md) and [raw measurement/decision](ghostmodeldeck-standard-version-budget-r47.json). This is **not** a derivative artifact, readiness change, generic timeout relaxation, or native installation acceptance.

The parent diagnostic measured six actual version calls: first `33.084519s`, repeat `0.08753s`; other fresh paths `1.5444s / 0.1690s` and `1.2053s / 0.1173s`, with the fixed identity and all PIDs exited. Fresh paths are **not cold-cache evidence**. The approved finite `60s` applies only to curated standard `b11146 / v0.5.0`; default JEV and other release descriptors retain `10s`.

## Minimal code change

- [LlamaRelease](../../lib/llama_engine.dart#L14-L40) adds typed `Duration installationVersionTimeout`, default `Duration(seconds: 10)`, preserving existing/custom constructor callers.
- [Curated standard descriptor](../../lib/llama_engine.dart#L190-L204) explicitly opts into `Duration(seconds: 60)`.
- Only [_version](../../lib/llama_engine.dart#L2206-L2240), shared by public installation and refresh identity verification, consumes the release budget. Nonpositive explicitly supplied durations fail closed before executing the native version command. The const-compatible descriptor constructor itself does not throw; validation occurs when `_version` is used.
- No model startup/request/capability/SSE/cancel/drain limit changed. Tar retains `30s`. Semantic-version/build/commit/platform/exit validation, archive identity, inventory/hash/signature/marker/provenance, source/backend, peer protections and typed/generation capability behavior are unchanged.
- [Public installer tests](../../test/llama_engine_test.dart#L19-L195) capture the actual I/O adapter timeout argument for installation and fresh-engine refresh: standard `[60s,60s]`, JEV `[10s,10s]`, and legacy custom descriptor `[10s,10s]`. Test fixtures substitute archive bytes/source while copying curated identity **and budget**; [archive fixture](../../test/fixtures/engine_archive.dart) is reused unchanged. Tests reject zero/negative budgets and retain failure behavior for timeout, nonzero native exit and wrong semantic version/build/commit/platform. Timeout installation cannot publish an executable or managed target; refresh timeout cannot retain an installed executable. No model instance is started by these tests.

## Native timeout and cancellation behavior (unchanged)

[NativeEngineProcessIO.run](../../lib/llama_engine.dart#L282-L305) waits for native exit using the supplied timeout. On timeout it sends SIGTERM, waits up to `2s`, escalates to SIGKILL if necessary, awaits exit and stdout/stderr drain, then rethrows the timeout. These awaited cleanup steps mean `60s` is the version **exit-wait budget**, not a promise that all cleanup finishes within exactly `60s`.

There is no immediate command-cancellation parameter in this I/O seam. [Shutdown](../../lib/llama_engine.dart#L1738-L1764) marks shutdown/cancels existing engine cancellation tokens and waits for the serial `_operations` chain; an already-running installation/version command completes or reaches its command timeout and cleanup before that chain settles. This implementation does **not** promise immediate user cancellation of a native version command or alter existing model/request cancellation semantics.

## Actual serial original normal ONLINE evidence

All commands used `GMD_TEST_CONTAINER=ghostmodeldeck-checks-r33b ./scripts/test-container.sh`, without offline/no-pub substitutions, on the original container and serially. Each long check had a `300000ms` caller limit. Retained raw run directories contain `source.tar.gz`, `job.sh`, `result.log`, and `exit` under `.tooling/container-tests/` (local ignored evidence, not committed).

| Stage | Actual script arguments | Raw run | Exit / observation |
|---|---|---|---|
| Behavioral RED | `test test/llama_engine_test.dart --plain-name 'installation version budget'` | `run-BQYs14` | `1`: actual standard install/refresh `[10s,10s]` vs expected `[60s,60s]`; typed default-only scaffold, before standard opt-in/budget use |
| Focused first GREEN | same | `run-El1EPR` | `0`: standard60/JEV10/legacy10 actual timeout capture |
| Invalid-budget RED | `test test/llama_engine_test.dart --plain-name 'rejects nonpositive explicit durations'` | `run-9ASv2H` | `1`: invalid zero budget erroneously accepted before validation |
| Complete focused GREEN | `test test/llama_engine_test.dart` | `run-P7r4qy` | `0`: all `44` engine tests passed, including both new tests and existing lifecycle/typed/SSE/peer protections |
| Final strict format | `format --output=none --set-exit-if-changed lib test benchmarks` | `run-xpVe7t` | `0`: `58` files, zero changed |
| Final analyze | `analyze` | `run-QA3BBr` | `0`: no issues found |
| Final full original suite | `test` | `run-tVCHmC` | `0`: all `225` tests passed |

Both RED failures were inspected and addressed by their minimal behavior changes before GREEN. Earlier formatting runs `run-DdVTq4` and `run-aFkxkR` succeeded, but a `docker cp` formatter-output transport attempt produced zero-length owned files. This was detected immediately; `run-rRJ8L7` strict-format exit `1` against those damaged transport inputs is **not** an accepted gate. The owned files were restored from the retained preformat source archive, reformatted, and the final strict-format/analyze/full suite above ran against restored complete inputs. Final `git diff --check` passed. No unrelated path was changed by recovery.

## Limits and handoff

No native installation, native model, source-weight/profile/settings/DNS/container mutation, derivative artifact, Ready change, issue operation or remote operation was performed. Adapter-based tests are wiring/failure-regression evidence, **not simulated native success or timing evidence**. The parent performs a new real standard installation only after implementation final settlement; complete native release acceptance remains outstanding and **#15 remains OPEN**. M4 `c19428e / c099103` remains settled; source/serial r33b is released at final handoff.

Actual delivered paths: [engine implementation](../../lib/llama_engine.dart), [engine public tests](../../test/llama_engine_test.dart), and this new verification document. Existing decision/raw/native proofs are not rewritten. Durable local progress: `/tmp/gmd-version-budget-implementation-r47-progress.md`.
