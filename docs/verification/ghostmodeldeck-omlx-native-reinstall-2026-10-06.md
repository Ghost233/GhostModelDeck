# oMLX native re-install acceptance — r62

Date: 2026-10-06. Host: macOS 27.0.1, Apple Silicon (M5 Pro), real native execution (not the Linux container).
Baseline HEAD: `ad1597260663b2af38378aec07135f342ac7facf` (clean tree before and after; this report is the only committed change).
Fix under test: `7f6d9af3c5768140f4a85166d584511b012cfbee` (#20 three launch-gate fixes; see [gate-fix report](ghostmodeldeck-omlx-gate-fix-2026-10-06.md)). Prior acceptance: [r61 FAILED](ghostmodeldeck-omlx-native-install-2026-10-06.md).

## VERDICT: FAILED — new defect D at the production Python identity probe; gates A/B/C fixes verified natively

The production `OmlxEngine.install()` was re-executed natively against the re-verified cached official DMG (830879938 B, SHA-256 `2e3bb06ac6ee7f50986ba1417e909d432ccd2be471db752a4a2d3b5651e3bce0`) through the r62 recording adapter (`.tooling/gmd_omlx_install_recorder_r62.dart`; delegates every call to the real `NativeOmlxProcessIO`; r62 addition: verbatim truncated stdout/stderr retained as failure evidence). **All three r61 defects are fixed and natively confirmed; the transaction now dies one step later**, at the dependency-metadata assertion inside `_inspect` → `_python()` identity probe. No bypass, ancestor chmod, re-sign, custom bootstrap, or system-Python fallback was attempted. Nothing was published; cleanup was exact in every run; there is nothing to retain for M3/M4.

### Defect D (new, host-independent): probe requires `omlx` dist-info that the official artifact does not ship

Both full native runs (canonical2 under `/private/tmp`, home-acl under `/Users/ghost233`) reached the production identity probe after **all** gates passed, and `python3 -s -c <identityProbe>` exited 1 in ~1.7 s with stderr frozen in the logs:

```
importlib.metadata.PackageNotFoundError: No package metadata was found for omlx
```

The traceback shows the probe died at its line 12 (`md.version("omlx")`, asserted `== '0.7.0'` at [omlx_engine.dart:670](../../lib/omlx_engine.dart)) — i.e. **all imports (`omlx`, `mlx.core`, `mlx_lm`, `fastapi`, `transformers`) and the Metal GPU matmul had already executed successfully**. Executor's differential check on the **pristine read-only-mounted bundle** (no ditto, no chmod, production-equivalent env) reproduces exactly: imports + Metal OK (`gpu=[[19.0, 22.0], [43.0, 50.0]]`), `omlx.__version__ == '0.7.0'`, `md.version('omlx')` → `PackageNotFoundError`. Static cause: the 48,734-entry bundle contains ~160 `*.dist-info` dirs (mlx-0.32.2, mlx_lm-0.31.4.dev132+g94cdcae13, fastapi-0.142.2, transformers-5.17.0 present) but **no `omlx-*.dist-info`/egg-info/PKG-INFO**; `omlx` ships only as a plain source package `Contents/Resources/omlx/` (`_version.py: __version__ = "0.7.0"`). This is the same structural class as r61 defect A (production probe assumes an artifact fact that never holds), never observed before because `_bundleOwnership` always failed first. Resolution belongs to the source owner (e.g. probe reads `omlx.__version__`, or upstream ships metadata); it is not an acceptance-executor decision.

## r61 defect re-verification (all three fixes natively confirmed)

| r61 defect | r62 native result |
|---|---|
| B: `%Lp` sticky blindness vs `/private/tmp` | FIXED — canonical2 root parent `/private/tmp` passed the ancestor gate (r61 failed at 6 events; r62 ran 1141) |
| C: home `group:everyone deny delete` ACL rejected | FIXED — home-acl run with root parent `/Users/ghost233` passed the gate (r61 failed at 7 events; r62 ran 1141) |
| A: `_bundleOwnership` vs 1206 official group/other-writable entries | FIXED — ditto + manifest equality + `chmod -R go-w` on the private staging copy (event idx 24, exit 0), then the full post-chmod `_bundleOwnership` batch stat/ls sweep passed (all exit 0) |

## Criteria results (all measured, none inferred)

- **(a) install() completes: FAILED.** Both full runs threw at the identity probe (defect D). No receipt, no marker, no publish; `refreshInstallation` unreachable (0 refresh events).
- **(b) permission normalization: VERIFIED** (production gate + independent spot check; no published copy exists to sample). Production: post-chmod `_bundleOwnership` passed over the full bundle. Independent: executor's own `ditto`+`chmod -R go-w` scratch copy — 26/26 deterministic offender sample normalized (`bin/python3.11` 0o775→0o755, `libpython3.11.dylib` 0o775→0o755, 0o664→0o644 stdlib), full-bundle `find ! -type l -perm +022` sweep = **0 remaining** (`.tooling/gmd_r62_iv_modes_before.json` / `_after.json`).
- **(c) signature valid after chmod: VERIFIED.** Production: `_signature(copied)` post-chmod — codesign `--verify --deep --strict` exit 0 (2.12 s), spctl `--assess` exit 0 (2.34 s), identity `app.omlx`/`PSK5Q5T46L` (events idx 41–44). Independent executor re-check on its own post-chmod copy: codesign OK, spctl `accepted, source=Notarized Developer ID`, same identities.
- **(d) production CLI/Python/Metal under policy-A gates: PARTIAL.** `omlx-cli --version` exit 0, stdout exactly `'0.7.0\n'` (both full runs). Python imports + Metal matmul executed inside the gated production probe (probe reached the metadata line; pristine-mount differential confirms `[[19.0,22.0],[43.0,50.0]]`). The identity probe as a whole FAILED at `md.version('omlx')` — criterion (d) cannot be marked passed.
- **(e) failure semantics: VERIFIED.** Corrupt-DMG attempt (size-identical, 1 byte flipped, SHA `b86ccb8f…f621`): **zero native events**, immediate fail-closed at `_verifyArtifact`, nothing published, no residual/owned device. Both failed full installs: attach detached via ownership-mapped path (exit 0, ≈10.9 s), work dir removed, `residualDirectory`/`ownedDevice` null; all four executor roots verified empty (0 entries) and removed; `hdiutil info` shows no residual mounts. The installed-bundle "already exists" retry path was not exercised (nothing ever installed).

## Online gates (container ghostmodeldeck-checks-r33b, Linux — not native acceptance)

format run-U5r2XL: 62 files / 0 changed; analyze run-X8WUNb: no issues; full test run-0OHpN8: **338/338 passed**. r57 step 2 (F1 scanner) was settled before #16 closure; not re-executed here.

## What this acceptance proves

1. The #20 gate fixes are effective on real macOS: sticky `/private/tmp`, stock home deny-ACL, and official-bundle ownership normalization all pass natively; `chmod -R go-w` fully normalizes the 1206 offenders and does not break the notarized signature.
2. The production transaction is genuinely fail-closed and cleanup-exact under a real mid-transaction failure: bounded native calls (1141 events, zero timeouts, zero download events on the cached route), detach verified, zero partial state.
3. **The installer still cannot complete with the official 0.7.0 DMG as shipped** — defect D is universal and host-independent.

## What remains unproven

Successful end-to-end install/publish/marker/`refreshInstallation` identity; full production identity-probe pass; HTTPS download route; model pool/serving/Ready and all M3+ scope.

## Evidence bundle

Deterministic curator `.tooling/gmd_r62_evidence_curator.py` → `.tooling/gmd_r62_evidence.json`; **evidence digest `926a136e67f18568ce7af1dcd242f2ea50c49dfbe32b35e9f925789841279b52`**. Files (SHA-256 in evidence JSON): recorder source; 4 recorder logs (`canonical`, `canonical2`, `corrupt-dmg`, `home-acl`); independent-verification transcript `.tooling/gmd_r62_independent_verification.txt`; mode samples before/after chmod. All evidence files are gitignored under `.tooling/` (digests recorded here per charter). No tracked source was modified; no GitHub/issue operations; no removal executed (nothing installed); no offline mode used.
