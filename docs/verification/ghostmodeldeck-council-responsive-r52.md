# Council responsive vote-label repair — r52

## Scope and status

- Started on clean `main`, HEAD `6ac66a256695f1ec313af0285d343e4ceed9855b`; prior r49/r51 integration and verification evidence was preserved.
- Owned changes are limited to [Council page](<../../lib/council_page.dart>), [Council page tests](<../../test/council_page_test.dart>) and this new report. No controller, protocol, catalog, engine, settings, native shell, container setup or external model/client changes.
- **#15 remains OPEN.** This is a public widget/layout RED→GREEN repair, not native macOS/MCP verification or Release acceptance. Parent must independently confirm and conduct postfix native verification. #16–19/final GUI Release remain pending.

## Public seam and fixture

The new 20-case matrix drives the actual CouncilPage ID/label inputs and consultation button, CouncilController, EngineCatalog, installed/running fixture seats and typed HTTP response decoding. The existing [runtime fixture](<../../test/fixtures/council_runtime.dart>) substitutes only external process and loopback HTTP I/O; business modules are not mocked, no private method is invoked, and no Council result DTO is injected.

Each case installs two verified fixture models, selects both live seats, enters `accept` and either `reject` or `reject_with_a_long_public_choice_identifier`, retaining existing labels `低 / 不成立` and `高 / 成立`. The external response maps the fixture's `reject` choice/probability key to that submitted ID. Actual published scores are exactly 0.5/0.5, top choices include both IDs, and both vote texts, labels, 50.0% values and tie chips must remain present. Two HTTP consultation requests and zero killed children are asserted.

The matrix requires the same real Noto CJK font baseline as the existing desktop layout fixture: `JEV_LAYOUT_FONT` override or `/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc`. Missing font fails setup rather than silently using Ahem. The Noto family applies only to new matrix widget themes; all five prior tests and their assertions remain, including latest Score→Choice→Noul→Choice at 400px/2x.

Page widths are 647, 879 and 880px at scales 1/1.5/2, plus diagnostic 400px/2x. Each widget viewport is 900px tall to isolate horizontal constraints, **not** to simulate the native minimum height. Exceptions are checked before results, after input/scroll-to-consultation and after publication. Nothing is suppressed or filtered.

## Geometry and RED findings

Unchanged shell geometry gives page width `900 − 188 − 1 − 64 = 647` at minimum native window width 900. The Council split starts at page width 880 (native window width 1133). At this split the input/result widths are approximately 390.91/469.09, then their 40px horizontal card padding yields approximately 350.91/429.09. A wider window crossing the split can therefore produce a narrower result card than stacked page879. These are source-derived constraints, not a measured native screenshot.

Correctly scoped RED: `run-WuJDt7`, exit1, 16 pass/4 fail. Input stages passed in every case. All ten short-ID geometries passed under Noto, including diagnostic400/2. The legal longer identifier failed only at the published result stage:

| Page width | Text scale | Actual thrown error |
|---:|---:|---|
|647|2|`A RenderFlex overflowed by 87 pixels on the right.`|
|880|1.5|`A RenderFlex overflowed by 101 pixels on the right.`|
|880|2|`A RenderFlex overflowed by 265 pixels on the right.`|
|400 diagnostic|2|`A RenderFlex overflowed by 334 pixels on the right.`|

All other long-ID cases passed. Earlier retained raw diagnostics identify the result vote/tie `Row` at [Council page:531–544](<../../lib/council_page.dart#L531-L544>), not an input row. This proves a public widget-surface failure at native-derived widths; it does **not** establish that a real macOS user/session encountered it. The original 400/2 candidate is not dismissed by the native minimum, and its old font-dependent observation is not misrepresented as a newly reproduced short-ID Noto failure.

## Minimal production repair

The vote label now uses `Expanded(Text(...))` and an 8px gap instead of an unbounded Text and Spacer. The existing trailing tie/winner chip and all output values remain unchanged. The label wraps within the remaining row space with no new ellipsis, max-lines restriction, hidden output, reduced font/scale, fixture widening, breakpoint change or UI redesign. No deeper business-module changes were needed.

## Complete run ledger

All runs used the unchanged original `GMD_TEST_CONTAINER=ghostmodeldeck-checks-r33b scripts/test-container.sh`, normal ONLINE pub resolution; never `--offline`, `--no-pub` or a replacement harness. Each run's raw [container evidence directory](<../../.tooling/container-tests/>) retains `source.tar.gz`, `job.sh`, `result.log` and `exit`. Host transcript logs are linked below. Every command/job completed and was collected synchronously; there are no outstanding background jobs.

| Run | Check / outcome | Exit | Raw container log | Host transcript |
|---|---|---:|---|---|
|run-3yHowg|First RED attempt: 20 failing cases; mistaken label count (Text plus EditableText), with real overflow diagnostics also retained|1|[raw](<../../.tooling/container-tests/run-3yHowg/result.log>)|[transcript](</tmp/gmd-r52-choice-red.log>)|
|run-S4xKXL|Second RED attempt: label ancestor finder excluded Text itself; 20 failing cases; overflow diagnostics retained|1|[raw](<../../.tooling/container-tests/run-S4xKXL/result.log>)|[transcript](</tmp/gmd-r52-choice-red-corrected.log>)|
|run-WuJDt7|Correct Text.data label finder; meaningful RED matrix16 pass/4 actual overflow failures|1|[raw](<../../.tooling/container-tests/run-WuJDt7/result.log>)|[transcript](</tmp/gmd-r52-choice-red-final.log>)|
|run-xZl12T|Minimal repair, focused all25 pass before final formatting/import cleanup|0|[raw](<../../.tooling/container-tests/run-xZl12T/result.log>)|[transcript](</tmp/gmd-r52-focused-green.log>)|
|run-5kZaKS|Strict format58 files/1 would change (new test)|1|[raw](<../../.tooling/container-tests/run-5kZaKS/result.log>)|[transcript](</tmp/gmd-r52-strict-format.log>)|
|run-9kvYqU|Apply Dart format to owned test only; copied formatted owned file back and verified bytes|0|[raw](<../../.tooling/container-tests/run-9kvYqU/result.log>)|[transcript](</tmp/gmd-r52-format-apply.log>)|
|run-UX4KWj|Interim strict format58 files/0 changed|0|[raw](<../../.tooling/container-tests/run-UX4KWj/result.log>)|[transcript](</tmp/gmd-r52-strict-format-final.log>)|
|run-8lCAhH|Analyzer1 info: unnecessary `dart:typed_data` import; removed because services exports ByteData|1|[raw](<../../.tooling/container-tests/run-8lCAhH/result.log>)|[transcript](</tmp/gmd-r52-analyze.log>)|
|run-KTeHw5|Final strict format58 files/0 changed|0|[raw](<../../.tooling/container-tests/run-KTeHw5/result.log>)|[transcript](</tmp/gmd-r52-strict-format-settled.log>)|
|run-PU0gzZ|Final analyze: No issues found|0|[raw](<../../.tooling/container-tests/run-PU0gzZ/result.log>)|[transcript](</tmp/gmd-r52-analyze-settled.log>)|
|run-qr4bXR|Final full suite249 passed|0|[raw](<../../.tooling/container-tests/run-qr4bXR/result.log>)|[transcript](</tmp/gmd-r52-full-tests.log>)|
|run-bi7mE4|Final focused25 passed, including all20 matrix cases and all5 previous behavior tests|0|[raw](<../../.tooling/container-tests/run-bi7mE4/result.log>)|[transcript](</tmp/gmd-r52-focused-settled.log>)|

The first two label assertion mistakes were corrected by selecting actual result Text widgets by `Text.data`, not weakening label visibility assertions or discarding framework exceptions. The analyzer's exact finding was `The import of 'dart:typed_data' is unnecessary because all of the used elements are also provided by the import of 'package:flutter/services.dart'. Try removing the import directive` (`unnecessary_import`).

## Final-source binding

SHA256 of final [Council page](<../../lib/council_page.dart>):
`280807969ca1867855f775b89d4c487f7149b0613e7cf468b2fbce7e26e4e798`

SHA256 of final [Council page test](<../../test/council_page_test.dart>):
`7285222dda7db17dd6c8ed9c0223c9331c61a23628fb6bc71e0f6001abd2b6e9`

Python byte-for-byte tar-member comparison verified **all 58 Dart files** in every final archive against the exact final workspace bytes, including both owned files above:

| Final run | Source archive SHA256 |
|---|---|
|run-KTeHw5|`573174d6c1210f3f6be4079dd89e54fa26281bd49924335080485c9eb1f41790`|
|run-PU0gzZ|`eaf3a70b38fb33be1d891c3914ef25b9f4fabcd9aaa1652786a9102b559080f2`|
|run-qr4bXR|`54985c32a5da11a6864c441f3d4f550def773afb7784b1414e6a0cfd779125fb`|
|run-bi7mE4|`de5f233745f406984554183df85fb79d849e9d2ad4ab7a5b4e34aff863de3fce`|

Archive hashes differ because filesystem metadata can differ; actual final Dart members match exactly. `git diff --check` passed. Scoped commit/clean tree and SOURCE+SERIAL release are reported at settlement; no branch/worktree/stash/reset/clean or remote operations were performed.
