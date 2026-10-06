# Native MCP listener, typed tools and reusable recycle/restart — r48

## Verdict and source binding

**PASS for this bounded native verification scope; #15 remains OPEN.** This is real native Kev/Laya inference through the existing HTTP MCP listener, followed by reusable managed-model recycle and explicit restart. It is not synthetic listener data, fixture-only proof, a #17 gateway/#18 SDK run, native GUI or Release acceptance.

- Observation began `2026-10-06T01:13:18.369687Z` on current main `16a3bb283785706fddb6bb941d7fb3ca21fcc149`; the same HEAD was observed afterward. The earlier exploratory HEAD was `055be54387332f69250c13fe295700c024db3c3a`; the parent committed its disjoint JEV documentation before this native launch.
- Tracked production/test/dependency/script paths were clean both before and after. Exact `lib`, `test`, `benchmarks`, [pubspec.yaml](</Users/ghost233/Ghost233Code/GhostModelDeck/pubspec.yaml>), [pubspec.lock](</Users/ghost233/Ghost233Code/GhostModelDeck/pubspec.lock>) and `scripts` git object IDs are embedded in the [curated JSON](</Users/ghost233/Ghost233Code/GhostModelDeck/docs/verification/ghostmodeldeck-native-mcp-recycle-r48.json>). The probe did not write product code, tests, dependencies, configuration, profiles, weights or existing installation inventory.
- Ran the actual host `/Users/ghost233/flutter/bin/cache/dart-sdk/bin/dart`, normal `dart run`, existing package resolution, no offline mode, SDK installation, container or fallback. The native phase had a finite **480-second whole budget**. Production load120/version10/request10 budgets and launch parameters were unchanged.
- Existing full private installation reused read-only: [installed llama-server](</private/var/folders/gz/qn4bw9mn1rd25_61tzh2r7b80000gn/T/gmd-native-dual-install-r47-8buXBF/engines/b11381/llama-server>), executable SHA256 `6a072f8bf308ea28144476441d25760ee01b84ed102f86be4662d21ace8d72a6`. Observed version: `0.5.0-dev`, build11381, commit prefix `836d57176`, Darwin arm64. The release remains commit `836d57176dc699a726c55418e4f96b8ca628e1bf`; managed archive and executable digests are not conflated. No reinstall or linked-registration copy.

## Public graph and physical selection

The production graph is one `ModelLibrary` → one `ModelUseRegistry` → installed `LlamaEngine` → `EngineCatalog` → `CouncilController` → `CouncilMcpServer`. [The probe](</Users/ghost233/Ghost233Code/GhostModelDeck/.tooling/gmd_native_mcp_r48.dart>) uses the existing [native I/O recorder](</Users/ghost233/Ghost233Code/GhostModelDeck/.tooling/gmd_native_dual_install_r45.dart#L9-L60>), whose operations delegate real OS process execution and exit observation; importing it does not execute its `main`.

The production metadata scanner read the common `ggml-org` root without full-hashing unselected assets. Exactly the two explicit discovered IDs were passed to `ModelLibrary.verify`; startup reverified those selected assets through the same library. No snapshot, manual fake asset, properties or Ready injection occurred.

| Selected physical asset | Bytes | SHA256 |
|---|---:|---|
| [Kev Q8_0](</Users/ghost233/.lmstudio/models/ggml-org/Kev-0.8B-GGUF/Kev-0.8B-Q8_0.gguf>) | 812406304 | `27278f34eb3273bceea4c053dc50dd61a5161da21a718c4aacdf8fd5830771d0` |
| [Laya Q8_0](</Users/ghost233/.lmstudio/models/ggml-org/Laya-GGUF/Laya-Q8_0.gguf>) | 449397600 | `c06528c5746d3bb8baa72a27938be95abbfd0b226f8471e8a9e365ed0bb066d2` |

Both are structurally complete and full-content verified; **sourceVerified stays false**. This does not manufacture HF revision/license/provenance receipts. Before/after SHA256, canonical path, device/inode/size/mode/modification/change identity match. The independent Python curator reread both whole physical files, confirmed the same hashes/stat identities and unchanged nanosecond metadata across its own hash read. No weight copy, write or deletion.

## Actual MCP HTTP evidence

The existing [CouncilMcpServer](</Users/ghost233/Ghost233Code/GhostModelDeck/lib/council_mcp.dart#L28-L57>) bound a fresh ephemeral loopback listener at **`http://127.0.0.1:53827/mcp`**, with the same real Council/controller/catalog and running models.

1. Actual HTTP `initialize` requested and negotiated legacy `2025-11-25`, HTTP200, server identity `ghostmodeldeck`; its actual `mcp-session-id` was retained for subsequent requests. `notifications/initialized` returned HTTP202.
2. Actual `tools/list` returned HTTP200 and the input/output schemas for both **`consult_jev_council`** and additive **`consult_jev_council_batch`**.
3. Actual legacy choice tool and mixed Choice/Score/Noul batch each returned HTTP200, `isError=false`, `status=ok`, `scope=ensemble`, **two actual successful seats**. Their text JSON equals their structured DTO, and those DTOs equal the same controller's computed results. Seat instance/PID/port/physical asset identity matches the owned native graph, not server-fabricated responses.
4. An intentionally incomplete modern `2026-07-28` stateless request preserved the actual transport guard: HTTP400, RPC `-32602`, **`Missing required request metadata: io.modelcontextprotocol/protocolVersion`**. The application/server was not changed to make this probe work. This is a real negative guard result, **not a successful modern-client compatibility claim**; full modern metadata was not supplied.

[Raw JSON](</Users/ghost233/Ghost233Code/GhostModelDeck/.tooling/gmd_native_mcp_r48_raw.json>) records every actual HTTP request method/body/header and response status/header/raw/decoded payload, including session/protocol and error fields. The [curated JSON](</Users/ghost233/Ghost233Code/GhostModelDeck/docs/verification/ghostmodeldeck-native-mcp-recycle-r48.json>) embeds this complete record, all upstream native raw responses, startup capability evidence, process commands, observer events and cleanup.

### Real two-seat results

| Native model | PID / port / generation | Legacy `change` probability | Batch Score expected index | Batch Noul scalar |
|---|---|---:|---:|---:|
| Kev | `23853 / 53802 / 1` | 0.9579914483651194 | 1.6601896367559141 | 0.8879935263326443 |
| Laya | `23859 / 53817 / 2` | 0.9199170848097484 | 1.7120145508143534 | 0.8736187047487243 |

- Each run separately earned `choiceProbability`, `scoreProbability` and `noulScalar` via its actual owned startup calls, rather than deriving support from health/name/metadata or one question type.
- Legacy raw responses: actual input_tokens49/69, output_tokens0. Batch actual input_tokens130/145, output_tokens0; exact requested answer set and owned response model IDs.
- Legacy equal-weight `change` aggregate: **0.938954266587434**, votes2, disagreement0.
- Mixed batch Choice `change`: **0.9579277149953458**, votes2, disagreement0. Exact finite normalized candidate probabilities are retained without repair.
- Score rubric has indices0/1/2. Aggregate expected index **1.6861020937851339** = `Σ i*p_i`, ordinal spread **0.05182491405843925**; it is not argmax or a normalized score.
- Noul arithmetic mean **0.8808061155406843**, raw scalar spread **0.014374821583920006**. Only scalar Noul is exposed; no synthesized distribution, votes or confidence.
- Some upstream raw Choice/Score answers contain their own `confidence` field. The record preserves raw bytes honestly; the application and curator do not treat that field as correctness/calibration, success weight or an acceptance metric. No quality, model-independence, confidence or speed claim follows from this one context.

## Reusable native recycle and explicit restart

Used the public **[EngineCatalog.stopManaged()](</Users/ghost233/Ghost233Code/GhostModelDeck/lib/engine_catalog.dart#L364-L380>)**, which calls the existing provider's [reusable stopManaged](</Users/ghost233/Ghost233Code/GhostModelDeck/lib/llama_engine.dart#L1646-L1686>). `ManagerLifecycle.shutdown` was not repurposed as recycle.

- Before recycle, plan-only `ModelLibrary.prepareDeletion` for each selected model failed with real in-use protection. No delete was called.
- Recycle revoked both live instances' admission/capabilities; afterward both are stopped, no-live, no active requests, not accepting and with empty capability sets. Both owned native PIDs exited **0**, and binding their exact owned ports53802/53817 succeeded.
- After recycle, `prepareDeletion` for both selected IDs succeeded as a **plan only**, demonstrating released protection while preserving physical files. It was never executed.
- The listener deliberately stayed active across this **provider-resource recycle** to observe a cold tool call. The actual tool response was HTTP200 with `isError=true`, `status=failed`, `scope=none`, two `not_ready` seats, null probabilities/aggregate, and no implicit process reload. This tests reusable catalog/provider recycle, **not the later SDK whole-service recycle contract that also stops public listeners**.
- Explicitly starting Kev through the **same** provider created a new actual PID **23877**, port **53867**, new instance/service identity and strictly higher generation **3**. All three capabilities were freshly earned for this generation.
- Explicit `selectSeats` selected the single available restarted run. Both actual HTTP tools returned `ok / single_model`, one real successful seat. Legacy aggregate/votes/top choices/disagreement are null; batch aggregates are `{}`. No two-seat assertion is made for this single-model response.

## Settled ownership, deterministic validation and checks

Final public teardown closed the MCP listener, shut down Council and catalog/provider, and waited on captured process exits. **All seven captured PIDs exited0**: model PIDs23853,23859,23877 and actual version-check subprocesses23847,23848,23858,23869. Independent `ps` checks found each absent; rebinding **all four ports53802,53817,53827,53867** succeeded. No cleanup errors, force-kill fallback or foreign process operation occurred. The installed bundle and selected model files remain available for the parent.

| Check | Actual result |
|---|---|
| Native public probe, managed job `bash-462` | exit0, raw `success=true`, budget not expired; job collected |
| Probe strict host format | 1file / 0changed, exit0 |
| Deterministic independent curator | **157 checks PASS**, exit0 |
| Diff whitespace/source cleanliness | clean; no product/source changes |
| New full container analyze/test, GUI/Release | not run by this read-only verification; prior formal gates remain separate evidence |

Raw SHA256: **`4ba2274d0a6a3c60baea29716cc674d949015a86b483ed2cb7851713c912aed6`**. [Curator](</Users/ghost233/Ghost233Code/GhostModelDeck/.tooling/gmd_native_mcp_r48_curator.py>) validates real HTTP/Council equality, exact owned model identity/usage, probability scalars, expected index/means/spreads, protection/recycle/restart, clean bound source and independently settled PIDs/ports/files. Its first run failed on a **curator-only count assumption** (`Both native initial PIDs exited on reusable stopManaged`): native `run(--version)` delegates to the recorder's `start`, so version subprocesses are correctly included in `children`. The curator was corrected to classify actual `--model` commands while still verifying **every** captured child; [first diagnostic](</Users/ghost233/Ghost233Code/GhostModelDeck/.tooling/gmd_native_mcp_r48_curator.log>) and [passing rerun](</Users/ghost233/Ghost233Code/GhostModelDeck/.tooling/gmd_native_mcp_r48_curator_second.log>) are retained. Native evidence was not rerun, edited or repaired.

Remaining gaps: native concurrent-admission/held-spawn/stop-failure races were not exercised here and are not claimed from fixtures. This scope does not close #15 or perform #17 gateway, #18 SDK, Codex/external-client, final native GUI, Release or broad acceptance. Read-only probe preparation follows the existing [engineering boundary](</Users/ghost233/Ghost233Code/GhostModelDeck/docs/engineering.md#L44-L50>); normal full application gates were not duplicated for two new verification docs and an ignored native probe.
