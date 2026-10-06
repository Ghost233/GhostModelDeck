# Actual fixed MLX package: structural completeness, not runtime Ready

## Final source and online checks

Production source is `1bb8f6d7d67c7f31415bb38df8dd4c9898bd5d40`, following M0 `607a15c891c566d103a57e79440386a07e42fa11` and M1 `1052c26ded0cb259dfb1fa170fa5f122977925a8`. The implementer settled and released SOURCE/SERIAL before this independent check.

Parent read the final original ONLINE job scripts, logs and zero exit files:

- [Strict format job](<../../.tooling/container-tests/run-k1h872/job.sh>): `format --output=none --set-exit-if-changed lib test benchmarks`; **60 files, 0 changes**.
- [Analyzer log](<../../.tooling/container-tests/run-aJs1EF/result.log>): **No issues found**.
- [Full test log](<../../.tooling/container-tests/run-RiksGa/result.log>): **311 passed** (249 baseline + 62 new public cases).

The [independent curator](<../../.tooling/gmd_curate_mlx_layout_r55.py>) checks all 68 tracked source/config/dependency paths against Git blobs, working bytes and each of the three final source archives, and checks exact path sets and preserved initial dependency/config/runner/F32-fixture bytes. Two pre-existing ignored Finder metadata files are preserved separately; they do not count as committed source. All checks passed. The [implementation report](<ghostmodeldeck-omlx-eligibility-r53.md>) preserves failed attempts, public RED/GREEN and unsupported-profile limits.

## Real package check

After final source settlement, the [production scanner probe](<../../.tooling/gmd_verify_mlx_layout_r54.dart>) completed normally (local job `bash-654`, exit0), observed `2026-10-06T05:27:14.618697Z`. It used the already downloaded fixed package, without redownload or modification:

- Repository `mlx-community/Qwen2.5-0.5B-Instruct-4bit`, revision `a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3`.
- Canonical library `/private/var/folders/gz/qn4bw9mn1rd25_61tzh2r7b80000gn/T/gmd-real-mlx-r42-p0rh2W`.
- Nine files, **289598797 bytes** total; weight **278064920 bytes**, SHA-256 `ddffab9cbc7bf6dde941c6724841eeca8981fcfa81ca20ff8efff1396326d153`.
- Existing artifact `e97a5c0b85551f8f4da39fd7e033974bbb9ea1f0a7585ff6dd482e0c5a24d63b` now earns **complete / chat / qwen2 / Safetensors / 4bit · group 64**, no diagnostics, source and fingerprints verified.
- **Engine capability stays `awaitingVerification`. No Ready is claimed.**

The curator independently reread/rehashed all nine physical files, checked eight companion Git blobs, canonical containment and stable device/inode/size/mode/nanosecond modification/change times during its reads. The production probe separately retained equal before/after file stats. The [frozen JSON](<ghostmodeldeck-mlx-structural-verification-r55.json>) embeds the complete raw result, raw digest, independent gate and physical checks; the [raw log](<../../.tooling/gmd-mlx-layout-verification-r54.log>) and [raw JSON](<../../.tooling/gmd-mlx-layout-verification-r54.json>) remain unchanged.

[Earlier download proof](<ghostmodeldeck-mlx-live-asset-validation-r42.md>) correctly recorded structural UNKNOWN on the older source. That evidence is not rewritten: this new source supplies the narrow tied-Qwen2 affine4/G64 U32/F16 graph validator. Exact graph validation is not a universal nine-file/config/name rule and does not make unsupported architectures or profiles complete.

## Limits and next work

This is structural/file-integrity proof only: no oMLX production install, wrapper launch, authenticated pool, model loading, inference, text/SSE, GUI or Release verification took place. The nine-file count describes this fixed package, not a global acceptance condition. Temporary assets are not promised permanent; recheck before reuse. #16 remains OPEN; its protected official installation and authenticated same-owned-pool lifecycle are next. The [human-confirmed wrapper policy](<../research/omlx-wrapper-launch-policy-r54.md>) prohibits claiming fully hermetic Python paths or introducing a custom bootstrap without authorization.
