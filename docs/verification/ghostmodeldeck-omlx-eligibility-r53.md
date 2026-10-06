# #16 M0/M1 — common runtime projection and Qwen2 structural eligibility

## Scope and acceptance limit

This is the first authorized slice of #16, not full #16 acceptance. Initial clean current `main` was `27a7ebe87edec6890941e318277e56c373f59ef7` (parent `b339190eacec57965a898bdaacfb7fdee8035499`). M0 focused green commit: `607a15c891c566d103a57e79440386a07e42fa11`.

No oMLX installation, pool, auth, registration migration, SDK, downloader, dependency, native bootstrap, real model execution, Chat listener, model/settings mutation or global-state change is included. Existing F32 downloader fixture remains unchanged and is not structural model proof. No issue is closed by this slice.

## M0: one catalog and one runtime owner

[Common runtime interface](<../../lib/engine_runtime.dart>) exposes only current needs: family, immutable instance/status/capability observations, start, text generation, stop, admission hold, aggregate recycle and shutdown. `DecisionCancellation` moved verbatim and is re-exported by [the legacy llama module](<../../lib/llama_engine.dart>) so its public callers continue to compile.

`EngineCatalog.runtimeFor` and common `EngineRun` observations use the **same registered LlamaEngine objects** returned by legacy `providerFor`; there is no second manager, copied mutable running map, request permit owner or synthetic business provider. `LlamaEngine` implements the interface through projection/delegation to its existing lifecycle/text implementation. Existing IDs, default constructors, schema1 persistence and JEV operations remain unchanged. All-provider synchronous admission holds, accepted operation draining, late enrollment, cleanup failures and residual-process ownership remain in their original owner.

Only the library run row needed common status/stop plus an optional legacy JEV-result projection. Council's family/capability predicate rejects a future oMLX registration **before** legacy provider lookup. Text-generation capability alone never supplies a typed seat. No speculative installer/pool/protocol fields were added. Proposed plan signatures were not treated as existing APIs: `runtimeInstances`/`startRuntime` avoid replacing legacy `state.instances`/`startInstance` contracts.

Public process/HTTP/GUI/catalog tests exercise real production entrypoints with external process/HTTP fixtures; no test-only business provider or facade is injected.

## M1: narrow complete graph, never RuntimeReady

[Production scanner](<../../lib/model_library.dart>) retains validated Safetensors dtype alongside existing shape observations. Existing header byte widths, contiguous ranges, bounds, duplicate tensors, indexes, companions, receipts and fingerprint checks remain authoritative.

Accepted graph is explicitly tied `Qwen2ForCausalLM`/`qwen2`, uniform affine 4-bit/group64, U32 packed weights and F16 scales, quantization biases, ordinary biases and norms. A missing mode is supported because the pinned MLX implementation defaults to affine; explicit affine is tested too. Positive typed configuration, finite positive RMS/rope parameters, rotary/head/KV divisibility and input packing/group divisibility are checked before graph construction. Every required tensor name, rank, dimension, dtype and layer is checked. Unexpected tensors, other architectures, untied embeddings, alternate/mixed quantization or BF16/F32 floating profiles remain unknown. `torch_dtype` is not evidence of serialized dtype.

For logical `[R,K]`, required `.weight` is U32 `[R,K/8]`, `.scales` and `.biases` F16 `[R,K/64]`. Embedding has the same triplet. All layers require q/k/v/o and gate/up/down triplets, q/k/v ordinary `.bias`, and both norms; final model norm is required. Exact count is `4 + 26*L`, not a count-only acceptance shortcut. The independent observed fixed graph has L24/H896/I4864/A14/KV2/D64/V151936: **628 tensors (169 U32 + 459 F16)**. Its source metadata was read previously; this slice does not rescan or execute the parent's canonical native model root.

[New serialized fixture](<../../test/fixtures/qwen2_mlx_layout.dart>) uses L1/H64/I64/A2/KV1/D32/V4/G64: **30 tensors (8 U32 + 22 F16)**. Zero payload validates real serialized structure, not runnable weights or quality. Additional two-layer and 24-tiny-layer variants check full-layer/name logic, including the independently expected 628/169/459 counts.

Missing/malformed supported graph cannot be complete. Successful layout never upgrades earlier unknown/corrupt/incomplete evidence. A RED test exposed an invalid conventional index being ignored: it is now recorded/validated only when its exact basename identifies the current weight, without attaching unrelated variant indexes. Required primary tokenizer/config and ordinary nonempty chat template are checked; unfamiliar tokenizer representation remains unknown. Optional companions are optional without a receipt; a matched receipt can require them. There is **no universal nine-file rule**.

Every artifact remains `EngineCapability.awaitingVerification`, including structurally complete, fingerprint-verified and source-verified artifacts. Structural completeness does not prove compatibility, inference, production install, hermeticity or Ready.

### Independent source basis

- [Pinned mlx-lm Qwen2](https://github.com/ml-explore/mlx-lm/blob/94cdcae13b266c337bcaca09b97b9c5a9c0e2cde/mlx_lm/models/qwen2.py): q/k/v ordinary bias, biasless output/MLP, tied embeddings and all-layer graph.
- [Pinned MLX quantized modules](https://github.com/ml-explore/mlx/blob/v0.32.2/python/mlx/nn/layers/quantized.py): affine default 64/4, separate ordinary linear bias and quantization bias.
- [Pinned native checks](https://github.com/ml-explore/mlx/blob/v0.32.2/mlx/ops.cpp): U32 packed weight, matched scale/bias shape and packing/group relationship.
- [Pinned loader](https://github.com/ml-explore/mlx-lm/blob/94cdcae13b266c337bcaca09b97b9c5a9c0e2cde/mlx_lm/utils.py): strict loading plus alternate/per-module profiles deliberately outside this slice.

## Public RED/GREEN evidence

All jobs used the original [online container runner](<../../scripts/test-container.sh>) with `GMD_TEST_CONTAINER=ghostmodeldeck-checks-r33b`; no `--offline`, `--no-pub`, replacement runner or weakened gate. Evidence directories below are workspace-relative ignored local artifacts.

| Public experiment | RED / finding | GREEN |
|---|---|---|
| M0 common catalog/runtime/GUI chain | `run-Gwr4V1`, absent interface/family lookup (exit1); corrected the new test to existing Iterable input | `run-o9MLDp`, 83 tests (exit0) |
| M1 full U32/F16 scan/verify | `run-KRTbD9`, expected complete, actual unknown (exit1) | `run-p4uqiV`, positive test (exit0) |
| Mixed floating precision | `run-oL5enm`, expected unknown, actual incomplete (exit1) | `run-HVaFbR`, expanded 47 tests (exit0) |
| Earlier unknown header/unindexed grouping | `run-udjZKA`, expected unknown, actual incomplete (exit1) | `run-vrFVHP`, expanded 71 tests (exit0) |
| Malformed conventional index | `run-dPfUFX`, expected corrupt, actual complete (exit1) | `run-vrFVHP`, all scanner tests green (exit0) |
| Earlier unknown grouping/bounded primary companion | `run-k8SVCd`, expected unknown, actual incomplete (exit1) | Final full suite below |

The first M0 green attempt `run-StjEXn` had 83 successful tests but failed for a nonexistent guessed test filename; corrected suite is the green evidence above, not that failed invocation. The first full analyzer `run-84AHZp` found 17 diagnostics: M0 override annotations/unused legacy UI import/redundant assertion and M1 flow-control braces. They were fixed in owned files; gates were not weakened. First full test `run-FAy59C` had 309 successes and one unchanged downloader-fixture failure (expected unknown, actual incomplete). Floating-only F32/BF16 is now classified as unsupported before requiring packed-affine graph parameters; the old fixture/expectation was preserved verbatim. Focused scanner/package compatibility then passed. A further public RED (`run-k8SVCd`) showed primary requirements must also retain earlier unknown grouping/oversized companion observations; these checks now preserve that verdict rather than replacing it with incomplete.

[Public scanner tests](<../../test/model_library_test.dart>) cover every required name in two layers with independent missing/rank/dtype mutations; unsupported/config/divisibility cases; indexed/unindexed single/split files; payload truncation/byte width/overlap/out-of-range/duplicate shards; missing/routed/malformed index; primary/optional/malformed companions; complete/missing-nine-file receipts and digest mismatch; unchanged scanned bytes; scan then selective verification. Existing general GGUF/Laya/adapter/source isolation/deletion regressions remain intact. Synthetic receipts test hash plumbing, not external provenance or runnable model authenticity.

## Final gates and source binding

Final original ONLINE gates passed **serially** on the same final source:

| Gate | Result | Archive evidence |
|---|---|---|
| `format --output=none --set-exit-if-changed lib test benchmarks` | exit0, 60 files, **0 changed** | `run-k1h872` |
| `analyze` | exit0, **0 issues** | `run-aJs1EF` |
| `test` | exit0, **311/311** (249 original baseline plus 62 new public cases) | `run-RiksGa` |

All 70 archived regular files (source/test/benchmarks plus pubspec/config/lock) match the final committed Git blobs and working files byte-for-byte; archived path sets are also checked, not merely modified files. The dependency/config/runner and old F32 fixture bytes remain identical to the initial commit. Documentation is outside the runner archive. Gate archive hashes differ because tar metadata differs; exact file-content/path equality is the source binding.

| Archive | SHA-256 |
|---|---|
| [Strict format source](<../../.tooling/container-tests/run-k1h872/source.tar.gz>) | `e5e056126f0e1209311230803b4c4836232c7b08a41e110399e7e50826485bea` |
| [Analyze source](<../../.tooling/container-tests/run-aJs1EF/source.tar.gz>) | `8e86d2ffded52ee33d603a4be3d7e801867d7b4063ae2be70e377536bd06c685` |
| [Full test source](<../../.tooling/container-tests/run-RiksGa/source.tar.gz>) | `d3006a3e233075617fdc84dedf1c5b1e361f7723950854485bd9150888b154d5` |

Machine-readable post-commit source binding: [r53 binding record](</tmp/gmd-m0-m1-source-binding-r53.json>). Final operational handoff: [r53 progress](</tmp/gmd-issue16-m0-m1-progress-r53.md>). These local ignored artifacts are evidence records, not runtime/model acceptance. Final suite includes the last primary-evidence precedence RED→GREEN case; focused scanner/package compatibility also passed 86 tests at `run-zoDE83`.

## Remaining cuts

M2 must independently decide signed native runtime/bootstrap/hermeticity; this slice does not mitigate or re-sign the absent original builder path. Existing native prerequisites prove full-copy signatures/CLI/CPython/MLX GPU, but production installation/Ready and hermeticity remain false. Then actual oMLX registration/pool/request ownership/auth/text callers and real model/scanner/native/Release acceptance belong to later authorized cuts. Parent can recheck the preserved canonical Qwen2 installation after this SOURCE/SERIAL slot is released. No speed, semantic-model, full #16 or runtime-readiness claim is made.
