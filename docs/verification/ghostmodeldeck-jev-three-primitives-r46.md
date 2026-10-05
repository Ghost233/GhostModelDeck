# M4 typed three primitives r46 — implementation record

## Scope and design (before implementation)

Current-main baseline `fa1a7abf26316354d14ed9a5f500ad3793d34aa0` follows delivered M3 `e1cb11b4325a8c526641711a02f7fcc9eae010ba`. This slice keeps the existing authoritative engine/catalog/Council graph and legacy `DecisionRequest`, `DecisionResult`, `consult_jev_council` call and choice page behavior. No new HTTP listener, cloud SDK, downloader, model scanner, catalog/engine-management rewrite, Chat UI or #17 implementation.

The fixed local `/v1/systemone` contract is described in [preflight](<../research/jev-typed-protocol-preflight.md>). Plans were proposals, not existing interfaces. Public seams are typed protocol construction/parsing, owned `LlamaEngine.decideBatch`, shared `CouncilController.consultBatch`, existing MCP `/mcp`, and existing Council controls. Only process/child/loopback/files are substituted in tests; no controller/protocol/business state mocks.

- Typed batch has immutable String state and keyed validated questions. Choice retains 2–255 named options; score ordered 2–10 nonempty level descriptions; noul explicit false/true descriptions, only Kev/Laya head semantics. No LEV inference.
- Exact answer set, type, owned response model, zero output tokens, finite probability distributions normalized within `0.0001`, score numeric-string legend and probability keys matching the ordered rubric. Score is expected ordinal index `Σ i*p_i` in `[0,n−1]`, not mode/normalized score. Noul is finite `[0,1]` scalar, no probabilities/confidence accepted or synthesized.
- Typed streaming explicitly rejected at request construction/entry. Response body capped before UTF8/JSON. Resource ceilings are application limits, not upstream model context/quality guarantees: at most 32 questions, 256 KiB encoded request and 1 MiB response (headroom for 32×255 distributions/legends plus owned envelopes; no unbounded socket accumulation). Legacy shape stays unchanged.
- Each capability earned by its own validated owned response, never health/metadata/choice inference. Startup keeps proven choice when an independent score/noul probe fails. Owned props/path/PID/generation, existing M2 permit/cancel/drain guards remain authoritative.
- Seat is atomic for a batch (upstream returns whole answer set or error). Same successful seats apply to independent questions. Preserve existing quorum: 2+ valid seats ensemble, 1 single-model with raw answers and no aggregate, 0 failed/none with no fabricated values; all selected successful=`ok`, some=`partial`.
- Equal weights over successful seats only. Choice mean distribution and existing votes/tie/disagreement behavior. Score mean distribution and derive expected index; identical ordered rubric is inherent in one snapshotted request. Noul scalar arithmetic mean only. For observable differences required by spec110–115, report score `ordinal_spread` and noul `scalar_spread` = successful-seat max−min in their original units (descriptive range, not confidence/calibration). With fewer than two successful seats no aggregate/spread. No cross-question ranking, confidence weighting, fake noul distributions or score/noul votes. Text and structured render one computed DTO.

## Execution evidence

Original ONLINE serial slot `GMD_TEST_CONTAINER=ghostmodeldeck-checks-r33b`:

| Public slice | RED | GREEN |
|---|---|---|
| Typed protocol | `bash-362`, `run-wGOfXm`, exit1 (new types absent) | `bash-363`, `run-6rd5zg`, exit0 |
| Owned engine batch/capabilities | `bash-364`, `run-zvZERS`, exit1 (batch/capabilities absent) | `bash-365`, `run-VtznAp`, exit0, protocol+engine+legacy Council 52 tests |
| Protocol negatives, probe isolation, engine cancel/drain/byte cap | added after first GREEN | `bash-367`, `run-jdh197`, exit0, 45 protocol+engine tests |

Raw evidence is under ignored `.tooling/container-tests/` and is not native inference proof. `bash-369` / `run-Rd02Sh` formatting exit0 formatted the four requested protocol/engine files; one mistyped nonexistent fixture path was reported and is **not** credited as checked. Correct paths subsequently checked separately. Formatted remote copies read back through base64 into owned host source paths (Socktainer remote-to-host `docker cp` reported path not found).

First protocol+engine green commit: `c19428ef050500ff9465009979daedc0b6fc588a` on main. Council/MCP/page integration is implemented; final ONLINE strict format/analyze/full gates GREEN below. Final integration SHA is recorded in the durable progress handoff after commit. No whole #15 acceptance claim.

| Integration slice | RED | GREEN |
|---|---|---|
| Public mixed Council | `bash-375`, `run-o487fq`, exit1 (consultBatch absent) | `bash-376`, `run-9qWS1o`, exit1 exposed a nonexistent DecisionBatchResult.toJson call; corrected to render real answer objects |
| Existing MCP typed discovery | `bash-377`, `run-3xD645`, exit1 (typed tool absent; also test I/O success-mask ordering corrected) | `bash-378`, `run-2XbOjf`, exit0, 26 Council/MCP/page tests including legacy regressions |
| Typed deadline/cancel/late recovery | shared lifecycle regression after integration | `bash-379`, `run-i7q0Kg`, exit0, one public round test |
| Actual score/noul controls at200% text | `bash-384`, `run-oVuvey`, exit1: RenderFlex overflow52px right | `bash-385`, `run-bQIyQP`, exit0: minimal flexible label fix, 1200×900 and400×800 layouts |

## Caller and DTO decisions

- MCP preserves the exact legacy tool name/input/output schema and choice execution branch. Additive `consult_jev_council_batch` uses the actual existing `/mcp` transport and shared controller; no new HTTP API. Separate discovery avoids the proposal's ambiguous legacy-versus-v2 arguments or breaking legacy output validation. Typed tool schema_version is 1 in its separate namespace; its questions object matches the fixed local wire. Stream=true and wrong request shapes return structured invalid_input errors. Text is JSON serialization of exactly the structured computed DTO, including failures.
- Default CouncilPage remains the legacy choice branch. Its selector exposes ordered score levels (2–10, visible ordinal indices) and false/true noul descriptions, submitting through the same `consultBatch` as MCP, not a test-only facade. Aggregate display reads computed results; raw per-seat identity, answers, source wire and errors remain inspectable. Noul scalar is never displayed as confidence or a client-invented probability map. Single-seat views explicitly have no ensemble aggregate.
- Typed result validates only consumed choice/score fields; optional upstream confidence is not exposed or used as a success/weight/calibration signal. Missing confidence does not break legacy producers. Noul strictly forbids all additional answer fields, including confidence/probabilities/legend. Exact questions/usage/input_tokens/owned model are mandatory for the new typed branch.
- Expectation-consistency uses absolute tolerance `0.0001`, the existing distribution tolerance; no rounding/renormalization repair. Choice argmax tie tolerance remains `1e-12`. App bounds differ from tentative planning numbers to use one simple whole-request budget rather than arbitrary per-descriptor Unicode limits; encoded request bound is 256 KiB before owned model envelope, at most32 questions, response1 MiB before decoding. No claims about upstream token fit.
- Engine fixed a public post-await cancellation publication race in the legacy decision path as part of preserving M2: terminal token/current-generation check before installing a result. Typed dispatch uses the same permit/cancellation/drain/identity ownership and independently earned capability checks. New tests use held external loopback responses; late results cannot update the completed consultation or contaminate the next one.
- Widget tests tap the real existing controls and verify computed score/noul summaries through real production catalog/engine/Council paths, with only external process/loopback/files substituted. These are not native desktop visual or real-weight inference acceptance.

## Formal gates (original ONLINE serial container)

- Slot: `GMD_TEST_CONTAINER=ghostmodeldeck-checks-r33b`; original `scripts/test-container.sh`, normal dependency resolution, no offline/no-pub substitutes.
- Strict `format --output=none --set-exit-if-changed lib test benchmarks`: latest `bash-390`, `.tooling/container-tests/run-ysuWvc`, exit0,58 files,0 changed (after lint-block fix).
- Full `analyze`: `bash-389`, `.tooling/container-tests/run-ZV1K2S`, exit1 reported12 `curly_braces_in_flow_control_structures` infos in typed protocol. All12 corrected using braces only, no ignores/semantics changes; repeated `bash-391`, `.tooling/container-tests/run-LQesyK`, exit0: No issues found.
- Full normal ONLINE `test`: `bash-392`, `.tooling/container-tests/run-ScCcxp`, exit0,223 tests passed. Host raw `exit` file independently reads0; original script's source/result transfer checks remain intact. All jobs collected; no alternate/offline/no-pub formal runner.
- Final `git diff --check` clean; current main remains first green `c19428ef050500ff9465009979daedc0b6fc588a` before integration commit. All58 Dart files in lib/test/benchmarks were byte-compared to each of the three final gate archives and matched final source. Archive SHA256: format `0fe745862251dcaf74e00ddc7785a4e229083c4c812a30e67ac792da84fe146d`; analyze `84a56dfe0f5d64e8615b2def49356d07703367d0fac0e77f476854467b0a681a`; test `ae58fb83d9cce71a4027b0d9d1f71b26fefd4a73535fe6bc4928b796756bf46e`.
- Exact integration SHA/job/run/exit/limits carried in durable progress after named-owned-path commit. IDs are harness jobs, not native inference or acceptance.
- Container widget200% layout at1200×900/400×800 is not native desktop screenshot, keyboard/focus, real-model Ready or Release acceptance. No calibrated-confidence/quality claim.

## Limits

#15 remains OPEN. Native parent proof [private-install record](<ghostmodeldeck-native-private-install-r46.md>) reports STANDARD genuine native original 10-second version timeout, exited PID −15, not installed; JEV b11381 genuinely installed/reopened in its own temporary directory but no model load/Ready. Original 10-second gate unchanged. This slice does not run host native/install/model commands or alter user weights. Mock wiring does not establish native inference, latency, quality, calibration, or committee benefit.
