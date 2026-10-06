# Real native dual installation through production HTTPS

## Purpose and source

Reverify both exact candidates after the explicitly approved, measured **installation version-command budget** change. Source `f2bb58b732ec008f985286b459c711cc98ea9953`; source/test/dependencies were clean and the budget writer settled before execution. The host probe invoked actual production `LlamaEngine.install()` **without verifiedArchive, fixture bytes or URL override**, then `refreshInstallation()`. `RecordingNativeIO` delegates all process operations to actual `NativeEngineProcessIO`; it records actual owned PIDs, output, elapsed time and exits rather than inventing native results.

Observed `2026-10-06T00:57:10.600796Z`. New private root `/private/var/folders/gz/qn4bw9mn1rd25_61tzh2r7b80000gn/T/gmd-native-dual-install-r47-8buXBF`, separate from earlier diagnostic and failed-install roots. Fresh paths **do not establish cold OS/Metal/compiler caches**; all previous failed history remains intact. No source, backend, environment workaround, official artifact or identity acceptance was changed.

## Actual results

| Candidate | Production source | Archive fingerprint | Actual executable | Command budget / observed install+reopen |
| --- | --- | --- | --- | --- |
| Standard label v0.5.0 / artifact b11146 | [fixed official HTTPS asset](https://github.com/ggml-org/llama.cpp/releases/download/b11146/llama-b11146-bin-macos-arm64.tar.gz) | 11189714B; SHA256 `1ad3f9eff80edb9dbef4259ad564d1720612ef7eea48fa4afed0e54f5f3d5711` | SHA256 `41df13c126456f8e5fab2057c86a790067a85ea1dfd8fbc0071cc45fbba56262`; actual0.5.0-dev/build11146/commit7fe450e19/Darwin arm64 |60s;17.099s and0.064s, both exit0 |
| JEV b11381 | [fixed official HTTPS asset](https://github.com/ggml-org/llama.cpp/releases/download/b11381/llama-b11381-bin-macos-arm64.tar.gz) |11925693B; SHA256 `ea92f83904a1a1d76752581acbb87c7099ae1a3ac37cc6a634b1648d707dc341` | SHA256 `6a072f8bf308ea28144476441d25760ee01b84ed102f86be4662d21ace8d72a6`; actual0.5.0-dev/build11381/commit836d57176/Darwin arm64 |10s unchanged;3.415s and0.014s, both exit0 |

Both production states were installed, with explicit distinct installation IDs `official-llama-v0.5.0` and `official-llama-b11381`. Actual semantic versions remain **0.5.0-dev**, not blindly rewritten to the curated standard label. Both full installation inventories passed production reopen validation; archive and actual executable hashes are separately preserved. Tar list/extract budgets remain30s. Each installation held **zero model instances**.

The independent bundled-Python curator then read both physical installation markers, checked source URLs/commits/archive hashes against the raw trace, rehashed every regular inventory file and each executable, verified all declared symlink text and containment in that installation directory, and bound the exact raw JSON SHA256. All recorded owned child processes exited0; no model processes, listeners, external process termination or residual were introduced. This is not a general speed benchmark, percentile/SLO guarantee or signature/notarization assessment.

## Evidence and unchanged scope

- [Frozen raw/marker/full independently validated inventories](ghostmodeldeck-native-dual-https-install-r47.json).
- [Probe](../../.tooling/gmd_native_dual_install_r47.dart), [raw output](../../.tooling/gmd-native-dual-install-r47.json), [raw log](../../.tooling/gmd-native-dual-install-r47.log), [exit0](../../.tooling/gmd-native-dual-install-r47.exit), [independent curator](../../.tooling/gmd_curate_native_install_r47.py). Parent collected job `bash-440` completedexit0; curator exit0.
- [Measurement-first approval and explicit finite budget decision](ghostmodeldeck-standard-version-budget-r47.md), [implementation/public RED→GREEN and225 online tests](ghostmodeldeck-standard-version-budget-implementation-r47.md).
- [Original genuine10s standard failure](ghostmodeldeck-native-private-install-r46.md) remains a failed historical attempt, not overwritten/relabelled. The17.099s actual install check here itself would exceed that old bound.

**This earns only actual private installation and reopen/version/inventory evidence. It does not earn model Ready, text/SSE, legal JEV choice/score/Noul, MCP/SDK/window, final Release or full #15 completion.** Recheck these actual directories before subsequent native model reuse; use new output prefixes and keep user weights read-only. Normal online operation remains required; no offline-mode substitution occurred.
