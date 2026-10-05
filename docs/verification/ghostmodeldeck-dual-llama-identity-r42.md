# #15 M3 — dual managed llama.cpp installation and runtime identity

## Scope and boundary

Started on main `3ea602cf35c5de3acd6dc1c217830b6ffdf0853f`; final slice is based on parent `8afec61de12029251d9110738ca5cd785542d416` (parent M2/HF/residual-writer work and concurrently added shared-JEV asset proofs retained). This slice keeps JEV b11381 and adds the fixed standard v0.5.0 candidate to **the same** production EngineCatalog and existing GUI/lifecycle. It does not implement oMLX, HTTP gateway/SDK, new chat UI, score/noul, or native model acceptance. #15 is not closed; #16–19 are unchanged. No dependencies, weights, settings, downloader/library/scanner/chat/council/protocol modules, network/container configuration, or parent proof files were changed.

The actual existing management caller is [EnginePage](../../lib/engine_page.dart), not an `engines_page.dart` file. Production [main](../../lib/main.dart) constructs both LlamaEngine providers under the existing catalog/use registry; the existing LibraryPage → ModelRunDialog selection routes through `providerFor` to the selected release. No global replacement, router, separate catalog, or future-engine abstraction was introduced.

## Curated facts, not runtime readiness

| Meaning | JEV managed installation | Standard managed installation |
| --- | --- | --- |
| Stable catalog installation ID | `official-llama-b11381` (unchanged) | `official-llama-v0.5.0` |
| Curated label | `b11381` | `v0.5.0` |
| Actual artifact tag/root | `b11381` / `llama-b11381` | `b11146` / `llama-b11146` |
| Expected build | 11381 | 11146 |
| Curated commit | `836d57176dc699a726c55418e4f96b8ca628e1bf` | `7fe450e19305b828c199d602c23a8337aaa1f03b` |
| Curated observed-binary expectation | `0.5.0-dev`, Darwin arm64 | `0.5.0-dev`, Darwin arm64 |
| Archive size | 11925693 bytes | 11189714 bytes |
| Archive SHA-256 | `ea92f83904a1a1d76752581acbb87c7099ae1a3ac37cc6a634b1648d707dc341` | `1ad3f9eff80edb9dbef4259ad564d1720612ef7eea48fa4afed0e54f5f3d5711` |

Fixed sources: [JEV b11381 archive](https://github.com/ggml-org/llama.cpp/releases/download/b11381/llama-b11381-bin-macos-arm64.tar.gz) and [standard b11146 same-commit archive](https://github.com/ggml-org/llama.cpp/releases/download/b11146/llama-b11146-bin-macos-arm64.tar.gz). These are curated from the existing [native version preflight](ghostmodeldeck-llama-native-version-preflight.md) and [machine-readable record](ghostmodeldeck-llama-native-version-preflight.json), not newly researched/upgraded. `v0.5.0` only has the 7-byte nightly-tag redirect metadata; b11146 is its same-commit artifact, not an upgrade. The nonexistent `docs/research/llama-release-install-preflight.md` is not evidence.

`LlamaRelease` now separates label, artifact root, expected build and optional exact expected binary semantic version. Legacy custom b11381 releases still derive an integer build only from the bounded `^b([0-9]+)$` rule; semantic labels require explicit build metadata. There is no `tag.substring(1)` semantic-version inference. Legacy `officialEngine`, `officialId`, `installOfficial`, and `EngineRegistration.sha256` retain their original ownership/digest meanings. New registration fields distinguish `archiveSha256` (managed archive) and `binarySha256` (validated executable); linked entries have no managed archive digest/release provenance.

## Installation and runtime evidence

The existing full bundle inventory, marker/source/hash/architecture/signature checks are reused. New markers record artifact root and expected build. Old fixed-b11381 markers remain readable; semantic-tag markers must contain their explicit metadata. Observed binary identity must match the stored marker and the curated build/commit/platform (and semantic version where explicitly pinned), not incidental diagnostic text or Metal initialization logs. Invalid/corrupt content is not replaced or deleted implicitly. Refresh discovering invalid installation content clears live generation capabilities/props and seals/cancels its requests while retaining owned-process protection; repaired files cannot resurrect old generation evidence. Peer readiness is unaffected. Installation success is **not** model Ready.

Each LlamaInstance separates stable installation ID, owned process service-run ID, model inference-instance ID, and native alias. The alias is exposed as observed only after matching `/props`; process PID and restricted child environment are reported only when EngineChild actually provides them. Fixtures/unknown values remain null. Binary/version/digest snapshots correspond to successful validation, not tag guesses. Generation-specific runtime identity guards remain in force. One owned llama-server process per model is preserved.

The existing capabilities are unchanged (`choiceProbability`, `textGeneration`); no score/noul caps are added. Curated standard source is not a System One provider: it cannot acquire JEV readiness from model/release names or compatibility filtering. Actual readiness still requires the owned model, bound props/request and successful evidence for that generation. All-provider stop, shutdown admission seal and shutdown enumerate both managed providers plus linked registrations; one stop failure does not abandon peers. Removal/unlink owns only the selected installation/registration, refuses live use, and preserves peers and external files.

## Test design and red/green evidence

Tests invoke public LlamaEngine, EngineCatalog, EnginePage and LibraryPage/ModelRunDialog entry points, using only process/child adapters, local real HTTP servers, and real temporary files/archives. They do not mock catalog, installation, capability, or selection state. Fixture success is **not** native macOS installation or model proof.

- Initial semantic release RED: `bash-305`, `run-PjiLkl`, exit 1, `引擎 archive 目录不匹配`. GREEN `bash-306`, `run-Sm1vY7`, exit 0.
- Second managed selection RED: `bash-308`, `run-wlg26F`, exit 1, `引擎登记已变化`. Catalog GREEN `bash-310`, `run-hbSimx`, 7 tests, exit 0.
- Public production GUI/process coverage: selected standard download/install/removal from EnginePage; LibraryPage → dialog → catalog → standard process executable; ordinary text on standard without JEV caps; legacy JEV decisions; two managed + linked run/service/PID/alias/generation identities; stop failure peer enumeration, recycle and global admission seal; selected removal and unlink preserving live peers/external files.
- Both releases: marker/reopen (including changed diagnostic logs with unchanged typed binary identity), exact observed version, complete inventory, unexpected files, changed executable hash, refused corrupt replacement, and distinct archive/executable digest fields. Standard rejects false release semantic version, wrong build/commit/platform under the unchanged production **10-second** version gate.
- Intermediate fixture failures retained: `run-ni7k2S` (pending second refresh), `run-OCwQ0e` / `run-CelFmK` (busy dialog pumpAndSettle), `bash-317` / `run-cHDGRk` exit 1 after SIGTERM of the exact stalled test worker. Fixture issues: busy progress animation made `pumpAndSettle` inappropriate while the confirmation was open; reverse animation/event ordering was corrected. Parent additionally found the final peer `File.exists` awaited outside `tester.runAsync`, a real filesystem await in the fake-async zone; that predicate is preserved inside `runAsync`. Both fixture I/O and frame ordering are corrected without weakening production-path assertions. These are not passing proof.

Additional REDs: live changed-binary capability invalidation `bash-326` / `run-2A7mIH`, exit 1 (`Expected: empty`, actual `textGeneration`); parsed identity instead of diagnostic-text equality `bash-341` / `run-B0qkIn`, exit 1 for both releases (`Expected: installed`, actual `failed`). Both are covered by the complete green regression. Targeted production-path GREEN `bash-331` / `run-m2YvW7`, 19 tests, exit 0. Intermediate analyzer `bash-339` / `run-S5TkO1`, exit 1 (two info diagnostics), and formatting `bash-344` / `run-jxVUKM`, exit 1 (one changed test) are corrected, not counted as green gates.

## Final online verification

All checks use the unchanged original script, **serially**, with `GMD_TEST_CONTAINER=ghostmodeldeck-checks-r33b`, normal online resolution, no `--offline` or `--no-pub`. No other agent ran this owned slot. Completed raw runs are retained under `.tooling/container-tests/`.

| Check | Job | Raw run ID | Actual result |
| --- | --- | --- | --- |
| Complete regression before final formatting-only export | `bash-342` | `run-VbBE1R` | 212 tests passed; exit 0 |
| Final strict format, entire `lib test benchmarks` tree | `bash-348` | `run-rof3be` | 56 files, 0 changed; exit 0 |
| Final full analyzer | `bash-349` | `run-sQDig4` | No issues found; exit 0 |
| Final complete regression, exact formatted source | `bash-351` | `run-PVXhSR` | 212 tests passed; exit 0 |

All 201 prior regressions are retained, with 11 additional public-path cases. Parent M2 generation/residual/natural-exit/SSE cancellation guards and existing desktop layout checks remain green. Source changes are confined to [LlamaEngine](../../lib/llama_engine.dart), [EngineCatalog](../../lib/engine_catalog.dart), [main](../../lib/main.dart), [EnginePage](../../lib/engine_page.dart), and their public [catalog tests](../../test/engine_catalog_test.dart), [management tests](../../test/engine_page_test.dart), [execution tests](../../test/model_run_dialog_test.dart), [archive fixture](../../test/fixtures/engine_archive.dart). No change to the existing ModelRunDialog implementation was needed. Scoped diff whitespace validation also passes.

## Native boundary / remaining M4

No native private installation or model run was performed in this slice. Existing b11146 original production 10-second version preflight failed in Metal initialization. The separate reused-scratch 120-second diagnostic (14.364464084006613 seconds, exit 0) is **not** a cold-run/gate/install proof. Production timeout remains 10 seconds; no release upgrade or silent timeout relaxation is made. The standard candidate may therefore remain blocked during actual Mac installation despite green fixtures. Report any future native failure as a blocked candidate rather than accepting a mock pass.

M4 still owns actual native model load/props/bound text and JEV choice/score/noul evidence and broader #15 acceptance. Native Release/Mac GUI validation is not replaced by container tests.
