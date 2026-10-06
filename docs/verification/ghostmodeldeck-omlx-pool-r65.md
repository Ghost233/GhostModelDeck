# oMLX owned model pool (M3a) — public source + TDD acceptance, r65

Date: 2026-10-06. Environment: SERIAL Linux container `ghostmodeldeck-checks-r33b` (Flutter/Dart toolchain), host macOS Apple Silicon.
Baseline HEAD: `202f8f2` (r63 native acceptance). Source under test: commit `85ed680` (`feat(engine): owned foreground oMLX model pool with pinned-only enablement (#16 M3a)`), exactly 4 files: `lib/omlx_engine.dart`, `lib/engine_catalog.dart`, `test/omlx_pool_test.dart` (new), `test/omlx_engine_test.dart`.
Scope: #16 M3a = public business layer + public TDD only. Native pool acceptance (real `omlx-cli serve`, real models, Metal inference) is **M3b**, executed by a separate agent after release — deliberately not run here.

## VERDICT: PASS (M3a scope) — RED→GREEN chain intact, all three gates green on the committed tree

The pool is implemented on the existing `OmlxEngine` (now `implements EngineRuntime`) and reached green strictly through the public seams (`EngineRuntime`, `EngineCatalog.runtimeFor`) plus OS-process/HTTP/filesystem boundary doubles. No business fakes, no second pool algorithm, no private-method tests, no test-only runtime.

### Gate runs (all inside `ghostmodeldeck-checks-r33b`, artifacts under `.tooling/container-tests/`)

| gate | run ID | result |
|---|---|---|
| RED evidence — `analyze` on test-first tree | run-cu2n2g | exit 1, 111 issues, all undefined pool API in `test/omlx_pool_test.dart` |
| targeted pool tests (debug chain) | run-ALIb1k → run-unprMD → run-ilNS4e → run-KsYdtC | 14/14 passing on run-KsYdtC (exit 0) |
| format `--output=none --set-exit-if-changed lib test benchmarks` | run-kmqXUU (2 changed) → repaired → run-76kRTQ | **0 changed, exit 0** |
| analyze | run-RnVy0m | **No issues found, exit 0** |
| full test suite | run-midVlZ | **352/352 passing, exit 0** (baseline 338 + 14 new; nothing removed) |

Format repair followed the documented flow (no host-side formatter): files `docker cp`'d in, `PATH=/opt/flutter/bin dart format` inside the container, base64 retrieval, per-file SHA-256 verified (`lib/omlx_engine.dart ba2a5d9d…40935`, `test/omlx_pool_test.dart 6730f04e…8d881c`) before writing back, then re-gated to 0 changed. Debug-chain fixes were test-orchestration only (fake-IO stat exit code for the builder-path negative probe; idempotent signal completers in the HTTP double; `asFuture` semantics; `LibraryException`→`OmlxException` wrap; fallback-lie hook timing) plus one message-fidelity improvement (probe failure carries the protocol reason).

## Criteria coverage (public TDD, mapped to r49 §7 drafts 1–8 and M3a checklist)

All assertions below ran green inside the container against real `HttpServer` boundary doubles (raw TCP clients for 401 checks) and a fake child-process boundary; no real oMLX binary, model weight, or `~/.omlx` was touched.

1. **Single process, two instances**: two verified chat models share exactly one owned pool process; CLI argv frozen as `serve --model-dir <root> --host 127.0.0.1 --port <owned> --base-path <owned base> --no-hf-cache`; single login per pool generation.
2. **Unloaded/loading/failed/non-chat never Ready**: `status` rows with `loaded=false`, permanent `is_loading`, load-failure 400, and non-chat artifacts all fail before Ready; instance stays `failed` with no live residue.
3. **Credential matrix**: settings.json written 0600 in a 0700 owned base; strong random per-generation `api_key`/`signing_secret`; bearer required for `/v1`, `omlx_admin_session` cookie for `/admin`; raw unauthenticated clients get 401; credentials rotate on pool regeneration; no `GET /admin/api/global-settings` dump is ever issued (POST + nested `model.model_fallback` readback only).
4. **Pin/fallback/readback**: pin-only `PUT /admin/api/models/{id}/settings {is_pinned:true}`; `POST /admin/api/global-settings {model_fallback:false}` with nested readback enforced (a lying readback fails pool start); physical `POST /v1/models/{id}/load`; status row identity (`id`/`model_path` canonical, `loaded`, `!is_loading`, `pinned`) plus short-text probe required before Ready; stale preloaded pins are unpinned+unloaded at pool start.
5. **stop(A) isolation**: admission seals synchronously, in-flight A work is cancelled (`OmlxRequestKind.cancelled`), drain completes, native unload targets only A, B stays ready and still serves.
6. **Late resurrection refused**: natural service exit revokes every Ready instance (generation/identity check), late requests are rejected `notReady`, and a new generation starts cleanly with fresh credentials.
7. **Residual retry / natural exit**: failed unload keeps a `failed`+live residual row that a repeated `stop()` retries; recycle escalates SIGTERM→(timeout)→SIGKILL, retires the owned base, and a failed recycle keeps the pool retryable.
8. **Sensitive projection hygiene / no leaks**: no exception, snapshot, log-text, or `RuntimeInstance` field ever contains either credential (asserted by string scan over every error surface, including a server that embeds secrets in its 4xx bodies); profile rows (`source_model_id == null`) never yield Ready.
9. **Catalog seam**: `EngineCatalog.runtimeFor(omlxId)` returns the pool after `link()`; during `stopManaged()` recycle a late `runtimeFor`+`startRuntime` is refused; legacy `providerFor`/Council/schema1 APIs unchanged (suite regression green).
10. **SSE real protocol path**: streamed deltas arrive in order, real `finish`+`usage`+`[DONE]` produce the terminal `TextResult`; missing usage or missing `[DONE]` fails `invalidResponse` instead of fabricating accounting; mid-stream cancellation aborts without a fabricated terminal frame.

## What remains unproven (expected at M3a)

- Native pool execution: real `omlx-cli serve` lifecycle, real model load/unload, real inference, Metal residency — **M3b native acceptance**, not run here by design.
- Real-service compatibility of the exact admin/v1 wire shapes against a live oMLX 0.7.0 server (the doubles implement the r49 contract verbatim; any upstream drift surfaces first in M3b).
- UI wiring of the new `runtimeFor` capability beyond the catalog seam tests.

## Evidence notes

Run artifacts: `.tooling/container-tests/run-{cu2n2g,ALIb1k,unprMD,ilNS4e,KsYdtC,kmqXUU,76kRTQ,RnVy0m,midVlZ}/` (source tarballs, job scripts, result logs, exit codes). Credentials never entered argv, env, receipts, logs, DTOs, or assertion texts; the pool redacts both secrets to `***` on every outward message path. Git tree was clean before and after the docs-only commit of this report; the source commit contains only the 4 authorized files.
