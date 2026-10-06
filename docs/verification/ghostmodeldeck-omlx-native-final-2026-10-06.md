# oMLX native final install acceptance — r63

Date: 2026-10-06. Host: macOS 27.0.0, Apple Silicon, real native execution (not the Linux container).
Baseline HEAD: `5637d8fcd2c53faa72417d439ad0dba982e233b0` (clean tree before and after; this report is the only committed change).
Fix under test: `6e897eb7224ffc13f5f089d5996e89c7ce2f3474` (#21 identity-probe fix; see [probe-fix report](ghostmodeldeck-omlx-probe-fix-2026-10-06.md)). Prior acceptance: [r62 FAILED at defect D](ghostmodeldeck-omlx-native-reinstall-2026-10-06.md).

## VERDICT: PASS — production install completes natively on both chains; defect D true GREEN

The production `OmlxEngine.install()` was executed natively against the re-verified cached official DMG (830879938 B, SHA-256 `2e3bb06ac6ee7f50986ba1417e909d432ccd2be471db752a4a2d3b5651e3bce0` — re-hashed before use) through the r63 recording adapter (`.tooling/gmd_omlx_install_recorder_r63.dart`; delegates every call to the real `NativeOmlxProcessIO`, zero simulation; r63 addition: field-by-field receipt identity comparison over the full `toJson()` maps). No bypass, ancestor chmod, re-sign, custom bootstrap, or system-Python fallback was attempted. No removal path was executed; both installed bundles are retained.

Runs (cached-artifact route; zero download events in every run):

| run | root parent | install events | refresh events | assertions | result |
|---|---|---|---|---|---|
| canonical | `/private/tmp` | 2256 | 1111 | 0 failures, exit 0 | PASS |
| home-acl | `/Users/ghost233` | 2256 | 1111 | 0 failures, exit 0 | PASS |
| corrupt-dmg | `/private/tmp` | **0** | 0 | fail-closed as designed | PASS |

Retained installed bundles: `/private/tmp/gmd_omlx_native_acceptance_r63-wSAl7q/0.7.0/oMLX.app` and `/Users/ghost233/gmd_omlx_native_acceptance_r63-zyPjn2/0.7.0/oMLX.app`. The batches of exit-1 `stat` events in the logs are the production gate's expected negative probes (`/Users/cryingneko` builder path absent on this host).

## Criteria results (all measured, none inferred)

- **(a) install() completes + refreshInstallation identity: VERIFIED.** Both full runs reached `status == installed` with a full receipt (`release 0.7.0`, `build 2987`, `bundleManifestSha256 e1054cc4bd98ddca00425ea6b5791c7275983da892e9375961b56d98d8dd98c3`, `entries 48734`, `sizeBytes 1639023231`, `dmgSha256 2e3bb06a…bce0`, `python 3.11.10`, `architecture arm64`), `residualDirectory == null`, `ownedDevice == null`. A **new** engine instance's public `refreshInstallation()` returned `installed` with the receipt **field-by-field equal** across all 8 `toJson()` fields (frozen `receiptFieldComparison` in both logs). The home-acl receipt is byte-identical to the canonical receipt.
- **(b) permission normalization: VERIFIED.** Production `chmod -R go-w` ran on the private staging copy (canonical idx 24, exit 0) and the full post-chmod `_bundleOwnership` sweep passed. Independent executor check on the retained published copy: 30/30 deterministic sample from `.tooling/gmd_r61_bundle_ownership_offenders.json` (seed 6300) shows 0 group/other-writable; full-bundle `find ! -type l -perm +022` sweep = **0 remaining** on both retained copies (`.tooling/gmd_r63_iv_modes_after.json`).
- **(c) signature valid after chmod: VERIFIED.** Production: codesign `--verify --deep --strict` and spctl `--assess` exit 0 on the mounted source (idx 19–21), the post-chmod staging copy (idx 41–43, 1136–1138) and the published copy (idx 1161–1163, 2252–2254). Independent executor re-check on the retained published copy: codesign `--verify --deep --strict` exit 0; `Identifier=app.omlx`, `TeamIdentifier=PSK5Q5T46L`; spctl `accepted, source=Notarized Developer ID, origin=Developer ID Application: Heejun Kim (PSK5Q5T46L)` (`.tooling/gmd_r63_independent_verification.txt`).
- **(d) production CLI / Python identity probe / Metal: VERIFIED.** `omlx-cli --version` exit 0 with stdout exactly `'0.7.0\n'` (idx 596 staging, idx 1714 published, both runs). The full production identity probe exited 0 three times per run — staging pre-publish (idx 1135), published post-publish (idx 2251), and inside `refreshInstallation` (refresh idx 1106): python `3.11.10`, architecture `arm64`, versions five-tuple `omlx 0.7.0` (now read via `omlx.__version__`), `mlx 0.32.2`, `mlx-lm 0.31.4.dev132+g94cdcae13`, `fastapi 0.142.2`, `transformers 5.17.0`, and the explicit GPU-stream Metal matmul `"gpu": [[19.0, 22.0], [43.0, 50.0]]`. **Defect D is true GREEN natively** — the exact probe that exited 1 with `PackageNotFoundError` in both r62 runs now passes end-to-end.
- **(e) failure semantics: VERIFIED.** Corrupt-DMG attempt (executor-owned copy, size-identical 830879938 B, one byte flipped inside the last 1 MiB, SHA-256 `361ebc6ef40307ad7e738499fab5d4c5867292a914bdccfd8fc4b3311d0632a9`; the original artifact was not touched): **zero native run/download events**, immediate fail-closed `OmlxException` at `_verifyArtifact` (`oMLX 安装验证失败或取消；原生输出已丢弃`), state `failed`, receipt null, `residualDirectory`/`ownedDevice` null, nothing published, no mount ever occurred, and the scratch root was verified empty (0 entries) and removed.

## Defect B/C chain regression

Both launch-gate link chains pass natively in r63: canonical root parent `/private/tmp` (sticky-bit chain, defect B) and home-acl root parent `/Users/ghost233` (stock `group:everyone deny delete` ACL chain, defect C) each ran the full 2256-event install to `installed` with zero assertion failures.

## What this acceptance proves

1. With #20 (gates A/B/C) and #21 (defect D) fixes, the production `OmlxEngine.install()` completes end-to-end on real macOS with the official 0.7.0 DMG as shipped: private copy, receipt publish, installation marker, and `refreshInstallation` identity on a fresh instance.
2. Permission normalization survives to the published copy and does not break the notarized signature; the fail-closed corrupt-artifact path stays exact (0 native events, zero partial state).

## What remains unproven

HTTPS download route (cached-artifact route only); model load/serving/Ready and all M3+ scope; the installed-bundle "already installed" retry path and the removal path (deliberately not executed).

## Evidence bundle

Deterministic curator `.tooling/gmd_r63_evidence_curator.py` → `.tooling/gmd_r63_evidence.json`; **evidence digest `f84260574d633382a7f00b62f1836be3a13e6ebaa44ed4ab6a6c9b2b3f9597d2`**. Files (SHA-256 in evidence JSON): r63 recorder source; 3 recorder logs (`canonical`, `home-acl`, `corrupt-dmg`); independent-verification transcript; permission mode sample. All evidence files are gitignored under `.tooling/` (digests recorded here per charter). No tracked source was modified; no GitHub/issue operations; no removal executed; no offline mode used.
