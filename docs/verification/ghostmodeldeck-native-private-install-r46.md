# #15 — actual private CPP installation on delivered M3

## Scope

Observed 2026-10-05T20:48:01Z (2026-10-06 Asia/Shanghai), source `e1cb11b4325a8c526641711a02f7fcc9eae010ba`, clean current main. This is the **production LlamaEngine installer and refresh** with complete previously downloaded official archives, a fresh private temporary installation directory, and real NativeEngineProcessIO. A recording subclass delegates native execution unchanged and records actual commands/PIDs/exits; no process or business mocks. Normal host Dart execution; no offline dependency resolution, no other test slot or engine writer.

The [frozen machine-readable proof](ghostmodeldeck-native-private-install-r46.json) embeds raw results plus their SHA-256, both independently rehashed archives, actual installation marker, and independently rehashed complete JEV inventory. Raw [probe](../../.tooling/gmd_native_dual_install_r45.dart), [log](../../.tooling/gmd-native-dual-install-r45.log), and [JSON](../../.tooling/gmd-native-dual-install-r45.json) are retained. The probe's host analyzer with fatal infos reports [no issues](../../.tooling/gmd-native-dual-install-r45-analyze-clean.log); this is not a replacement for project/native acceptance.

## Actual outcome

| Candidate | Actual outcome |
| --- | --- |
| Standard v0.5.0 / same-commit b11146 | **Failed private installation** at the unchanged 10-second `--version` gate. `TimeoutException after 0:00:10.000000: Future not completed`; observed command 10022 ms including cleanup. Own version child PID 59054 exited -15. No standard final installation published. |
| JEV b11381 | **Installed and reopened** in the new private root. Actual version `0.5.0-dev`, build 11381, commit `836d57176`, Darwin arm64. First native version command 4253 ms; subsequent reopen command 27 ms. These are individual observed command timings, not general performance or cold-cache claims. |

Actual private JEV executable: `/private/var/folders/gz/qn4bw9mn1rd25_61tzh2r7b80000gn/T/gmd-native-dual-install-r45-5BKF80/engines/b11381/llama-server`. Installation ID `official-llama-b11381`. Executable SHA-256 `6a072f8bf308ea28144476441d25760ee01b84ed102f86be4662d21ace8d72a6`, distinct from archive SHA-256 `ea92f83904a1a1d76752581acbb87c7099ae1a3ac37cc6a634b1648d707dc341`. Exact 60-entry bundle inventory—including relative dylib symlinks—independently matches the production marker with no extra files; all symlinks resolve inside the bundle. All **seven observed native child commands exited**, including the timed-out standard child. No unrelated process was stopped.

The standard archive is still the pinned 11189714-byte artifact SHA-256 `1ad3f9eff80edb9dbef4259ad564d1720612ef7eea48fa4afed0e54f5f3d5711`, commit `7fe450e19305b828c199d602c23a8337aaa1f03b`; no substitution, version upgrade, or timeout relaxation occurred.

## Limits and remaining work

Overall probe exit **1** / `success=false` is retained; JEV success does not convert the failed two-candidate probe to a pass. Fresh directory is **not** a fresh GPU/compiler cache: earlier standalone native attempts remain in the [preflight](ghostmodeldeck-llama-native-version-preflight.md). That earlier stack localized a sampled wait to Metal library initialization, and the separate reused-scratch 120-second diagnostic succeeded after 14.364464084006613 seconds; it did not meet the production gate. This new production attempt confirms failure under that gate but does not diagnose a new cause or prove permanent incompatibility.

No model was loaded; instances remained zero. No model Ready, typed choice/score/noul, text/SSE, GUI, HTTP/MCP/SDK, port lifecycle or Release acceptance is claimed. Recorded commands here are tar and version execution; no Apple code-signing or notarization assessment was performed or inferred from a file-format signature. Temporary-path persistence is not guaranteed; recheck files before reuse. #15 and the overall objective remain open. Investigate/explicitly document any candidate remediation before changing code or acceptance budgets; never silently replace this failed proof with a fixture or diagnostic pass.
