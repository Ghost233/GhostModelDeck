# oMLX native install acceptance — r61

Date: 2026-10-06. Host: macOS 27.0.1, Apple Silicon (M5 Pro), real native execution (not the Linux container).
Baseline main: `1edba8c2db6aac9e43fec3cd80796fffe1d034e8` (clean tree before and after; this report is the only committed change).
Accepted source: [oMLX installer](../../lib/omlx_engine.dart) at M2 (`d6b2459`) + F1 (`4d0da99`), per [r58 delivery](ghostmodeldeck-omlx-installation-r58.md) and the human-approved [launch policy A](../research/omlx-wrapper-launch-policy-r54.md).

## VERDICT: FAILED at the install transaction (r57 step 3) — nothing installed, evidence frozen

The production `OmlxEngine.install()` was executed for real against the pre-verified cached official DMG (830879938 bytes, SHA-256 `2e3bb06ac6ee7f50986ba1417e909d432ccd2be471db752a4a2d3b5651e3bce0`, re-verified before use) through a recording adapter that delegated every call to the real `NativeOmlxProcessIO` (zero simulation; recorder: `.tooling/gmd_omlx_install_recorder_r61.dart`). The installer **failed closed in three independent, deterministic ways**. No bypass, chmod of ancestors, re-sign, flag injection, custom bootstrap, or system-Python fallback was attempted, per policy A and the acceptance charter. The step-4 assertions (installed receipt, refresh identity) are unreachable; there is nothing to retain for M3/M4.

### Failure 1 — private-directory ancestor gate vs. `/private/tmp` (sticky-bit blindness)

Parent `/private/tmp`: the installer's `stat -f '%u:%g:%Lp:%HT'` probe prints mode `777` for `/private/tmp` — `%Lp` does not report the sticky bit — so the `trustedSticky` exception ([omlx_engine.dart:323-324](../../lib/omlx_engine.dart)) is unreachable and the world-writable bit (`mode & 0o022`) fails closed. 6 native events (`id`/`stat`/`ls`, all exit 0), zero mounts, zero Python, no residual. Log: `.tooling/gmd_omlx_install_recorder_r61_log.attempt2-tmp-sticky-gate.json`.

### Failure 2 — private-directory ancestor gate vs. the production default home path (stock ACL)

Parent `/Users/ghost233` (ancestor of the production default `~/Library/Application Support/GhostModelDeck/engines/omlx`, [main.dart:98-101](../../lib/main.dart)): stock macOS home directories carry the ACL `group:everyone deny delete`; `ls -lde` output is therefore multiline and the conservative parser rejects any ACL. 7 native events, zero mounts/Python, no residual. Log: `.tooling/gmd_omlx_install_recorder_r61_log.home-acl-gate.json`. **Consequence: the production default installation directory can never pass this gate on a stock macOS host.**

### Failure 3 — prelaunch `_bundleOwnership` gate vs. the official artifact itself (deterministic, universal)

On a gate-compatible user-writable ancestor chain (`/private/var/folders/<hash>/T`: all ancestors root/self-owned, not group/other-writable, zero ACLs), the full cached-artifact transaction ran: DMG rehash, private `.install-` workdir, `hdiutil attach` (read-only, plist), diskutil APFS-physical-store ownership mapping, source signature + Gatekeeper assessment, 48734-entry source inventory, whole-app `ditto` copy, inventory equality — **573 recorded native events, all delegate-completed, no timeout ever fired**. It then failed closed inside `_inspect(copied) → _python()` **before the first omlx-cli/python3 launch** (zero `omlx-cli`, zero `python3` events): the `_bundleOwnership` batch check threw because the **official oMLX.app ships 1206 group/other-writable entries** (mode & 0o022 ≠ 0): 1158 files at `0o664` (embedded CPython 3.11 stdlib/runtime, e.g. `LICENSE.txt`, `abc.py`, pkgconfig files) and 48 entries at `0o775` (including `bin/python3.11` and `lib/libpython3.11.dylib`). Full list: `.tooling/gmd_r61_bundle_ownership_offenders.json`. Cleanup was correct: the attach was detached (exit 0) via the ownership-mapped path in the `finally`, no `residualDirectory`, no `ownedDevice`, work dir removed. Log: `.tooling/gmd_omlx_install_recorder_r61_log.canonical.json`.

**Consequence: with the official 0.7.0 DMG, `_bundleOwnership` can never pass on any host — the M2 installer cannot complete any real installation as shipped.** This is a gate-semantics/artifact mismatch for the source owner to resolve (e.g. predicate scope, upstream artifact permissions, or an explicit accepted-exception list); it is not an acceptance-executor decision.

## Independent artifact verification (executor's own commands, read-only mount — NOT installer claims)

The same DMG was mounted read-only by the executor and checked independently (transcript: `.tooling/gmd_r61_artifact_verification.txt`):

- `codesign --verify --deep --strict` — valid on disk, satisfies Designated Requirement (exit 0). `spctl --assess --type execute` — accepted, `source=Notarized Developer ID` (exit 0).
- Identity: `CFBundleIdentifier=app.omlx`, `CFBundleShortVersionString=0.7.0`, `CFBundleVersion=2987`, `TeamIdentifier=PSK5Q5T46L`. App Mach-O universal (x86_64 arm64).
- Embedded interpreter: `cpython-3.11/bin/python3.11` is Mach-O arm64; a bounded (60 s watchdog) read-only execution reported Python **3.11.10**, machine **arm64**, prefix inside the bundle. This was an artifact check only — the production probe never ran.
- All 5 symlinks are relative and contained (`python`/`python3` → `python3.11`, pkgconfig aliases, `framework-mlx-base/bin/python_` → `../../cpython-3.11/bin/python`).
- Deterministic full inventory (type/mode/uid/gid/size/SHA-256 per entry, link targets verbatim): **48,734 entries** (matches the r53 scratch count), digest `3c140819ca7a250b9673fa5becdb2c63b5c59a005314f8cd1e42132710dbf375`, frozen at `.tooling/gmd_r61_mounted_inventory.json`.
- Executor detach followed the same ownership discipline: mount → `APFSPhysicalStores` = `disk16s2` → whole disk `disk16` re-verified before `hdiutil detach /dev/disk16` (exit 0); mount point removed; no residual.

## Budgets revalidated in final source

CLI (`omlx-cli`) 60 s / Python 120 s (l.587), `ditto` 180 s (l.847), stat/ls/id 10 s, default native 120 s (l.266, covers codesign/spctl/plutil/hdiutil attach/diskutil), detach 60 s (l.1008). The recorder's per-call elapsed times show every one of the 573 canonical-run subprocesses completed well inside budget (slowest: detach ≈ 10.8 s). No kill/drain ever occurred.

## What this acceptance proves

1. The production installer is genuinely fail-closed on this host: three distinct conservative gates fired exactly as designed, with bounded native calls, correct cleanup, and zero partial state (no residuals, no owned devices, no published directories).
2. The official artifact itself is authentic and intact: notarized, deep-strict signature valid, expected identities, contained symlinks, Python 3.11.10 arm64, byte-level inventory frozen.
3. The M2 installer **cannot install the official 0.7.0 artifact on stock macOS** as shipped: (a) `_bundleOwnership` rejects 1206 official group-writable entries — universal, host-independent; (b) the ancestor gate rejects both stock candidate roots (`%Lp` sticky blindness for `/private/tmp`; `deny delete` ACL on home directories).

## What remains unproven

- Successful end-to-end install, publish, marker write, and `refreshInstallation` identity (step 4 unreachable).
- `omlx-cli --version`, the production Python identity/dependency probe, and the Metal `[[19,22],[43,50]]` calculation under policy-A gates (zero-Python evidence retained; r53's historical scratch evidence is not this transaction).
- The HTTPS download route (cached-artifact route was used and labelled as such; zero download events recorded).
- Model pool, serving, Ready, and all M3+ scope.

## Evidence bundle

Deterministic curator `.tooling/gmd_r61_evidence_curator.py` hashed all frozen artifacts into `.tooling/gmd_r61_evidence.json`; evidence digest `c6b72fb7231d3281075ad46ebdfa3874c84070714c0c4ee94cae67b386118438`. All evidence files are gitignored under `.tooling/`. No tracked source was modified; no GitHub/issue operations were performed; no removal was executed (nothing was installed).
