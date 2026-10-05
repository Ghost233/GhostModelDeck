# r41: identity-preserving fixed-revision download redirects

## Scope and baseline

- Started on `main` at `2c97ae267e25b6a32f59ea804169423eae851a28` with a clean tree.
- Focused public business seam: `ModelDownloader.downloadPackage`; only downloader implementation, its permanent tests, and this evidence document changed.
- #15 remains active. This fix unblocks a parent-owned real MLX retry; it does not complete #15/#16, establish nativeReady, install an engine, or run a model. No actual HF model transfer was performed here.
- Frozen r40 preflight and the parent's r41 RED probe output remain untouched. No dependency, settings, source weights, discovery, scanner, UI, chat, council, engine, Harness, network, or container configuration changes.

## Defect and implementation

Dart's default automatic redirect path creates the next request with default `Accept-Encoding: gzip`; copying only missing headers does not restore the original `identity`. With raw-byte verification and resume, accepting decoded gzip would change the byte domain and invalidate Range semantics. Compression rejection remains intact.

A private typed response helper now disables automatic redirects and rebuilds each GET with `Accept-Encoding: identity`, plus the original `Range` and `If-Range` on resumed transfers. Only these transfer headers are explicitly rebuilt: no Authorization/Cookie headers are copied. Credential-bearing redirect destinations are rejected. Both relative and absolute redirects remain supported.

- Five redirects are allowed, matching the previous `HttpClientRequest.maxRedirects` default: an initial request plus five subsequent requests. A sixth redirect response fails without making a seventh request.
- Missing/invalid Location, repeated URI cycles, non-HTTP(S) targets, empty hosts, target user-info, and HTTPS-to-HTTP downgrade are rejected. Explicit HTTP loopback fixtures remain supported. HTTPS downgrade prevention is a deterministic implementation guard; no real TLS downgrade fixture was run.
- Every hop remains associated with `_request` so cancellation aborts the actual current request, not the original auto-follow request. Cancellation is checked before and after awaited stages. Request acquisition, header response, and intermediate cancellation each have a 30-second stage bound.
- Intermediate response bodies are owned through the existing `_body` iterator and cancelled, not drained as unbounded network content. The original operation/client/body cleanup ownership remains in place.
- Final raw-byte length, fixed commit, ETag/Range, SHA-256/Git blob verification, staging identity, installation/no-overwrite behavior are unchanged.

## Permanent public tests

All added tests use actual loopback HTTP I/O and the public package interface, not private helper mocks.

- `package redirects preserve identity and verified raw bytes`: actual 307 plus `HttpServer.autoCompress`, records incoming identity on both hops; independently known `abc` SHA-256 and Git blob ID validate installed raw bytes.
- `package follows five redirect statuses and discards intermediate bodies`: 301/302/303/307/308, relative and cross-port absolute destinations, all six identity requests, intermediate non-model body excluded, no Authorization/Cookie on final request, correct installed bytes.
- `package redirects fail bounded for <scenario> Location`: missing, invalid, cycle, bound, protocol and credentials; bounded completion, exact request count, no formal file or installation record.
- `package cancellation aborts the active redirected request`: cancels after the second hop arrives while its response headers are withheld; completes promptly, cancelled state, no publication.
- Existing cancelled-fragment regression now exercises `downloadPackage` through actual redirects and autoCompress on initial and resumed transfer. It still verifies retained `abc` fragment, then fixed `abcdef` SHA-256, and now asserts exact identity/Range/If-Range on both hops after reopening.
- Existing lineage, Git blob rejection, shared-file/no-overwrite collisions, resume rejection and retry, cache-at-EOF and selected-sidecar regressions remain.

## Raw check ledger

Container checks use the original unmodified script, normal online dependency resolution, serially with `GMD_TEST_CONTAINER=ghostmodeldeck-checks-r33b`; no offline or `--no-pub` checks.

| Check | Raw evidence ID | Exit | Result |
| --- | --- | --- | --- |
| Permanent focused RED before production edit | `.tooling/container-tests/run-jkEBzX` | 1 | Expected installed, actual failed: `来源返回了压缩内容，无法验证文件字节` |
| Permanent focused GREEN | `.tooling/container-tests/run-H6FJgU` | 0 | 1 passed |
| Initial expanded downloader suite | `.tooling/container-tests/run-cTptsp` | 0 | 20 passed |
| Parent's unchanged public loopback probe, GREEN invocation | `.tooling/gmd-hf-redirect-green-r41.json` | 0 | installed; initial identity, redirected identity; correct `abc` |

| Final downloader targeted suite | `.tooling/container-tests/run-zTLgIm` | 0 | 21 passed |
| Strict format: `format --output=none --set-exit-if-changed lib test benchmarks` | `.tooling/container-tests/run-MW6pCK` | 0 | 56 files, 0 changed |
| Static analysis: `analyze` | `.tooling/container-tests/run-6Kq59Y` | 0 | No issues found |
| Full regression suite: `test` | `.tooling/container-tests/run-gOj9mP` | 0 | 200 passed |
| Final scoped diff whitespace check | `git diff --check` | 0 | No whitespace errors |

The four final check exit files were read individually and all contain `0`. Their serial orchestration also exited 0. All relevant background jobs were collected; the container slot is released. These are fresh checks of this implementation, not the prior baseline 191 tests or prior 56/0 format result.

Exact final commands (each container invocation ran serially):

```sh
GMD_TEST_CONTAINER=ghostmodeldeck-checks-r33b ./scripts/test-container.sh test test/model_downloader_test.dart
GMD_TEST_CONTAINER=ghostmodeldeck-checks-r33b ./scripts/test-container.sh format --output=none --set-exit-if-changed lib test benchmarks
GMD_TEST_CONTAINER=ghostmodeldeck-checks-r33b ./scripts/test-container.sh analyze
GMD_TEST_CONTAINER=ghostmodeldeck-checks-r33b ./scripts/test-container.sh test
```

RED/focused GREEN used the same test command with `--plain-name 'package redirects preserve identity and verified raw bytes'`. The unchanged public probe was invoked with `/Users/ghost233/flutter/bin/cache/dart-sdk/bin/dart run .tooling/gmd-hf-redirect-regression-r41.dart green`; it is supplemental host I/O evidence, not a replacement for the Flutter checks above.

## Limitations

Loopback probe and Flutter acceptance verify this I/O fix, not real HF CDN behavior, actual MLX package installation, native engine availability or model inference. The parent must perform the real retry separately and record new evidence without rewriting frozen failed preflight history.
