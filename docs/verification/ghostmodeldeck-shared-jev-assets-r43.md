# Shared JEV assets: fresh structural and full-content verification

## Purpose and limits

Prepare explicitly selected existing Kev and Laya files for later #15 native acceptance, without copying user configuration, old receipts or weights. The host probe invoked the production `ModelLibrary.scan(verifyFiles: true)` on the two containing directories. It did not register either file with the app, install/run an engine, load a model, invoke SystemOne, modify an external process or earn Ready.

This is **real file/structural evidence**, not fixture inference evidence and not final first-phase acceptance. No offline or dependency-mode change was used. The parent probe did not occupy the implementer's SERIAL check container or edit its runtime/catalog/UI scope.

## Actual observations

Observed `2026-10-05T20:05:59.007607Z`:

| File | Bytes | Parsed architecture/type | Structural integrity | Runtime capability |
| --- | ---: | --- | --- | --- |
| `Kev-0.8B-Q8_0.gguf` | 812,406,304 | `qwen35` / `kev` | complete; full fingerprints; no diagnostics | awaitingVerification |
| `Laya-Q8_0.gguf` | 449,397,600 | `modern-bert` / `laya` | complete; full fingerprints; no diagnostics | awaitingVerification |

- Kev actual path: `/Users/ghost233/.lmstudio/models/ggml-org/Kev-0.8B-GGUF/Kev-0.8B-Q8_0.gguf`; SHA256 `27278f34eb3273bceea4c053dc50dd61a5161da21a718c4aacdf8fd5830771d0`.
- Laya actual path: `/Users/ghost233/.lmstudio/models/ggml-org/Laya-GGUF/Laya-Q8_0.gguf`; SHA256 `c06528c5746d3bb8baa72a27938be95abbfd0b226f8471e8a9e365ed0bb066d2`.
- Both hashes match the earlier explicitly recorded expected local files. Size, mode, modification and change timestamps remained identical across production scanning.
- A separate bundled-Python curator rehashed both complete physical files, checked the same lengths/SHA256 values and confirmed device, inode, size, mode, nanosecond modification/change times were unchanged during that independent read.
- Production `source_verified` remained **false** for both. Full file fingerprints and recognized tensor structure do **not** establish a new HF installation receipt, remote provenance, license permissions or native capability. No old receipt was copied to change that flag.

## Durable evidence and remaining acceptance

[Curated JSON](ghostmodeldeck-shared-jev-assets-r43.json) embeds the complete production scan, raw record SHA256, independently rechecked physical identity and stage verdict. Raw ignored probe artifacts are `.tooling/gmd-shared-jev-structural-r43.dart`, `.json`, `.log`; the independent validator is `.tooling/gmd-curate-shared-jev-r43.py`. Both execution steps succeeded; raw `success=true`. These records must remain historical: reverify actual files again before native reuse if they may have changed.

Later native acceptance must bind the explicitly chosen files to the actual owned JEV installation/run, observe the real model identity and ports, separately earn legal choice probabilities, score probabilities/expected index and scalar Noul through actual bounded requests, and verify cancellation, peer isolation and owned teardown. None of those runtime checks is claimed here. Ordinary GGUF text/SSE, oMLX, external API/SDK/window and Release acceptance remain separate pending work.
