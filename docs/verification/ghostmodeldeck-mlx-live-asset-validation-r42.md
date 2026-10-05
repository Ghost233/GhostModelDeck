# Fixed MLX package: live download passed, architecture classification remains unknown

## Scope and stage verdict

The r42 host probe used the production HF browser, package selection, downloader and `ModelLibrary.scan(verifyFiles: true)` after redirect fix `3022cdeb2cfd79703e76c9f9d9a01f9afc3fe515`. It used normal HTTPS, a fresh owned temporary library and unchanged fixed-content verification. No offline mode, existing user model/settings migration, engine installation, inference or Ready claim occurred.

| Stage | Actual result |
| --- | --- |
| Fixed online metadata and indexed selection | Passed |
| Production nine-file download/installation | Passed; `download_status=installed`, no download error |
| File lengths, weight SHA256, companion Git blobs, receipt | Passed; independently rehashed again by curator |
| Scanner source/full fingerprints | Verified |
| Architecture tensor-layout completeness | **Unknown**; current generic Safetensors branch intentionally does not establish it |
| Runtime/native compatibility and Ready | Not tested |
| Overall guarded host probe | **Exit 1**, because architecture completeness was required but not earned |

The previous r40 compressed-content failure is preserved in [its preflight record](ghostmodeldeck-mlx-download-preflight-r40.md). The repaired downloader transferred and verified `merges.txt` and all remaining fixed assets without accepting compressed ranges or weakening source checks. The new failure is not a download/DNS failure and does not establish model incompatibility.

## Fixed assets and current records

- Repository: `mlx-community/Qwen2.5-0.5B-Instruct-4bit`.
- Revision: `a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3`.
- Nine installed files: `model.safetensors`, `model.safetensors.index.json`, `config.json`, `tokenizer.json`, `tokenizer_config.json`, `special_tokens_map.json`, `added_tokens.json`, `vocab.json`, `merges.txt`.
- Exact total: **289,598,797 bytes**; weight **278,064,920 bytes**, SHA256 `ddffab9cbc7bf6dde941c6724841eeca8981fcfa81ca20ff8efff1396326d153`.
- Installation ID: `af98c8306ff83949860f1b5a932c24bf79063d8ee184ad1ce0e31065de5f1672`.
- Receipt SHA256: `dfdae9154f80a5a35a429c664769396ce6e9afc6af02736f668bdae40dde9d37`.
- Actual canonical library: `/private/var/folders/gz/qn4bw9mn1rd25_61tzh2r7b80000gn/T/gmd-real-mlx-r42-p0rh2W`. Temporary persistence is not promised; verify actual files again before reuse.
- Observation: `2026-10-05T19:41:40.320439Z`; end-to-end probe **295.786 seconds**, including metadata, transfer, hashes and scan. This is not a general throughput benchmark.

Scanner reported asset `e97a5c0b85551f8f4da39fd7e033974bbb9ea1f0a7585ff6dd482e0c5a24d63b`, `Safetensors`, `chat`, `qwen2`, validated configuration label `4bit · group 64`, all nine returned files and verified source/fingerprints. It also correctly retained `integrity=unknown`, diagnostic `架构必要 tensor 布局尚未核验`, and `engine_capability=awaitingVerification`.

## Evidence and next work

[Curated JSON](ghostmodeldeck-mlx-live-asset-validation-r42.json) embeds the complete failed guarded probe, its original SHA256, stage verdict and independently rechecked receipt. Raw ignored artifacts are `.tooling/gmd-live-mlx-assets-r42.dart`, `.log`, `.json`; the independent curator is `.tooling/gmd-curate-mlx-live-r42.py`. Managed job `bash-281` was collected with exit 1. The curator completed with exit 0 after rehashing all nine physical assets, checking companion Git blob IDs, receipt entries and exact total.

Current ordinary Safetensors classification in `lib/model_library.dart` deliberately assigns unknown architecture completeness. Next establish a narrowly supported Qwen2 MLX tensor/config/dtype/quantization layout through public scan red/green tests and real structural evidence. Preserve unknown architectures, file/index/receipt guards and the distinction from runtime Ready. Do not merely mark every chat config complete or change the probe to accept unknown. The already installed bytes can be rescanned; another weight download is not needed for that work. Real oMLX bundle/runtime/model loading and Chat/SSE, JEV three-primitive evidence and final Release acceptance remain separate pending stages.
