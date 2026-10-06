# oMLX installation-only M2 recovery verification — r58

Date: 2026-10-06. Baseline main: `1d5a0040d04e472913277c90b44cbed90ee65e87`.
Verified source commit: `d6b24596d951d7b707aeba07e7e9514b90f02d16`.
Candidate source tree, before this evidence-only document: `1b67a13825390a98c0fd78c2fa75e05f501067a4`.

## Delivered scope and honest capability

Recovered the failed exclusive M2 writer's existing changes without reset, stash, clean, worktree, or a replacement branch. Only seven authorized source paths were committed:

- [oMLX installer](../../lib/omlx_engine.dart): process/artifact I/O adapters, typed bundle/runtime receipt, installation admission/serialization, inspection, removal and residual ownership.
- [Catalog](../../lib/engine_catalog.dart): actual optional `OmlxEngine` constructor, family-separated registration, installation/link/unlink/removal, aggregate recycle/shutdown integration, all-or-nothing registry parsing.
- [Engine page](../../lib/engine_page.dart), [family labels](../../lib/engine_labels.dart), [main wiring](../../lib/main.dart): the existing catalog/page shows the real installation entry. oMLX does not manufacture a llama.cpp release or binary version. Main only constructs the actual installer; labels remain family labels.
- [Public installer/catalog tests](../../test/omlx_engine_test.dart), [engine-page tests](../../test/engine_page_test.dart).

The entry is installation-only and noncallable: requesting its runtime raises a typed error. It supplies no model pool, serving instance, model capability, endpoint, SDK/gateway, authentication, or Ready claim. Existing llama.cpp/JEV implementations and tests were not replaced. No model-library/downloader, Council, EngineRuntime, dependencies, test-container script/configuration, frozen baselines, other repository, or user weights were changed. No GitHub/issue/Teams/push/Codex operation was performed.

## Implemented native transaction — source inspected, NOT executed here

The production installer accepts only the official release URL for `0.7.0`, build `2987`, DMG size **830879938 bytes**, SHA-256 **2e3bb06ac6ee7f50986ba1417e909d432ccd2be471db752a4a2d3b5651e3bce0**. Provided artifacts are rehashed; there is no fixture digest substitution, hash override or alternate "valid DMG" test path.

The source verifies the unmodified app's original signature (`app.omlx`, Team `PSK5Q5T46L`) and Gatekeeper assessment, full recursive file/directory/link inventory, required bundle resources, whole-app native `ditto` copy and before/after inventory equality. It probes the original wrapper and bundled interpreter, verifies Python `3.11.10`/`arm64`, observed dependency identities and a tiny explicit Metal calculation, and records separate artifact, bundle and runtime identity. These are installation/protocol observations, not text-generation or model-readiness evidence.

Mount cleanup derives the physical APFS store from the actual read-only mount and corroborates the whole disk against attachment/device identities. Detach rechecks the mount/store/whole-device relationship. Finally cleanup never detaches a guessed device or deletes an ambiguous mount directory. Installation publication rollback now checks the exact owned app/metadata range and metadata bytes, not just an app digest before recursively deleting its parent. Managed removal rechecks the original owner-bound plan, receipt, app digest and exact directory range; extra siblings remain unowned. Linked removal has no disk deletion paths and rechecks its digest before persisting an unlink.

Ambiguous ownership is retained as failed/residual, not advertised installed/removable. Private setup failures record their created directory for safe retry. Repaired cleanup can retry after failed aggregate shutdown without reopening admission; pending accepted operations drain before aggregate admission release. Recovery source inspection is not execution evidence for successful real DMG attach/copy/publication, APFS detach failures, published rollback or interrupted native installer transactions.

## Human-approved launch policy and its limits

The approved [wrapper launch policy](../research/omlx-wrapper-launch-policy-r54.md) remains in force. Before **every** wrapper/interpreter launch, the installer lexically checks the baked builder path and ancestors with stat/ACL/ownership evidence; builder-path presence, symlinks, foreign-user writability, ambiguous ACL or permission/parse errors fail closed before Python. It uses a private cwd and from-scratch nonsecret environment, checks full-bundle ownership, then repeats the builder gate immediately before launch. It does not edit the signature/wrapper, re-sign, inject a bootstrap, fall back to a system runtime, or chmod ancestors.

This is **not hermetic**, an OS sandbox, or a TOCTOU-free guarantee. The absent builder path and private cwd are explicitly accepted finite search-path exceptions. Same-user/admin modification is outside this policy's adversary scope; other local users are not excluded. Post-start module-origin observations do not independently make `.pth`/site initialization safe. The source must not be described as universally isolated merely because tests pass.

Historical [native prerequisite evidence](ghostmodeldeck-omlx-native-prerequisite-r53.md) demonstrates scratch relocation/unchanged original signatures and bundled execution, **not this production transaction**. Upstream source comparison was partial: all 519 Python files and 693/770 tracked package files matched the fixed upstream reference, while 77 non-Python kernel/build inputs were absent; whole binary/dependency/source equivalence remains unknown. This recovery performed no native/product Python, mounting or installation execution. Parent-owned real acceptance remains required after source/serial release.

## Public regression evidence

Tests enter the real public installer/catalog/page interfaces. Doubles cover external process/artifact I/O only; filesystem fixtures are not an alternate business implementation. Small fixture apps plus fabricated process observations prove decisions/ownership/UI plumbing, not Apple's signature, actual Metal, or a valid official DMG transaction. Persisted managed-receipt fixtures exercise reopen/removal without pretending the DMG hash was reproduced.

Recovery red/green records, all immutable original online container runs:

| Slice | RED | GREEN / coverage |
|---|---|---|
| Catalog failed shutdown must retry repaired cleanup | `run-GWzCmd` (exit 1) | `run-a1XGk6` (exit 0) |
| Private directory setup must retain cleanup ownership | `run-1QC5nK` (exit 1) | `run-ieR5ID` (exit 0, focused 27) |
| Malformed registry JSON must not disclose raw input | `run-rR0wWn` (exit 1) | `run-NvDzsN` (exit 0, focused 33) |

Final full-suite coverage includes builder presence/ACL/foreign-owner/writability/link/error zero-Python gates and redaction; private cleanup foreign-link preservation and retry; setup failure ownership; shutdown cancellation before receipt publication and permanent admission closure; catalog aggregate installation hold, accepted-late operations and cancelled linked publication; managed removal confirmation/stale/cross-owner/extra-sibling rejection; linked plan owner/digest recheck, no deletion of foreign bytes; schema-1 legacy compatibility and schema-2 only while actual oMLX rows exist, reverting after unlink; atomic malformed mixed-row rejection; receipt/noncallable/noReady page behavior and existing CPP/JEV regressions. Earlier runs and the failed writer's latest focused snapshot are not represented as final-source gates.

## FINAL original ONLINE gates and exact source binding

All three ran **serially** using the unchanged [original script](../../scripts/test-container.sh) with `GMD_TEST_CONTAINER=ghostmodeldeck-checks-r33b`. Each retained normal online `flutter --suppress-analytics pub get`; no offline/no-pub shortcut. All jobs were collected before commit.

| Gate | Immutable run | Actual result | Exit |
|---|---|---|---|
| `format --output=none --set-exit-if-changed lib test benchmarks` | `run-3BX58F` | 62 files, 0 changed | 0 |
| `analyze` | `run-KYagJW` | No issues found | 0 |
| full `test` | `run-xcHB93` | **329 tests passed** | 0 |

An intermediate strict format correctly failed because Docker copy retrieval had silently retained old host bytes; recovery subsequently retrieved exactly seven authorized paths via base64 streams with independent remote/local SHA-256 checks. An intermediate analyzer then reported 33 brace-style infos; only deterministic braces in four authorized paths were fixed, with no suppressions. Final gates above ran after these changes and source freeze, not against those older archives.

Raw evidence is retained under `.tooling/container-tests/<run>/` (`source.tar.gz`, `job.sh`, `result.log`, `exit`). Exact final archive SHA-256 values:

- `run-3BX58F`: `748e684c14cb5dd168322df490336d8c0baca23d58beaf175c17458a4c56ddc4`
- `run-KYagJW`: `1965ccd4093ea8924de1c6a525baa080e22ac3a1b0dd48ef5b1fd448a6a337e2`
- `run-xcHB93`: `c9dd6571257b0d0c2945cdc1652ffb8277aae4a1926df25d7aefa32c02354ca6`

Local [binding JSON](../../.tooling/gmd-m2-final-source-binding-r58.json), SHA-256 `61ad700e6352dfe651a9bf693ae6dc41f4a7481135e1f91a6e6147babe4800fe`, enumerates **all 70 tracked original-script inputs**: **62 Dart files, five tracked fixture/result data files, and all three dependency/config files** ([pubspec.yaml](../../pubspec.yaml), [pubspec.lock](../../pubspec.lock), [analysis_options.yaml](../../analysis_options.yaml)). For every file it records path, size, current SHA-256 and staged Git blob, and verifies current bytes = Git blob bytes = corresponding bytes in **each of all three final archives**. The source commit preserves that exact candidate tree. No old counts/gates were reused.

The two ignored Finder files `benchmarks/.DS_Store` and `test/.DS_Store` are explicitly listed as archive extras and **not counted as source**. A further **231 tracked repository files outside the original archive** were inventoried and proven baseline-identical/current=Git-blob, but are explicitly **not archived or native-tested**. This evidence-only document also lies outside the original archive. Claims therefore cover all original gate inputs, not a fictional whole-repository/native source archive or hermetic dependency build.

## Release boundary and remaining work

The recovery finishes M2 source delivery/formal fixture regressions only. The parent must separately conduct real native installation acceptance after the explicit final source/serial release message. The queued M1 scanner F1 malformed-nonempty-index false-complete follow-up remains outside these scopes and unchanged. This report does not close #16, claim whole-goal completion, refresh frozen baselines, or claim M3/M4/M5/Release acceptance. Final settled HEAD and release state are reported by the recovery's final handoff and the [recovery progress record](</tmp/gmd-issue16-m2-recovery-progress-r58.md>).
