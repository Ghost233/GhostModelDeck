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

First green commit and Council/MCP/page integration pending; final ONLINE strict format/analyze/full gates pending. No whole #15 acceptance claim.

## Limits

#15 remains OPEN. Native parent proof [private-install record](<ghostmodeldeck-native-private-install-r46.md>) reports STANDARD genuine native original 10-second version timeout, exited PID −15, not installed; JEV b11381 genuinely installed/reopened in its own temporary directory but no model load/Ready. Original 10-second gate unchanged. This slice does not run host native/install/model commands or alter user weights. Mock wiring does not establish native inference, latency, quality, calibration, or committee benefit.
