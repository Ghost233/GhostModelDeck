# Standard installation version-command budget — explicit measured decision

## Approval and evidence

The user explicitly selected **measurement first, then an installation-command budget adjustment**, retaining the official artifact rather than rebuilding a derivative. This does not approve weakening model Ready, actual identity checks, request acceptance, or inference timeouts.

On source `c09910348fe00739c33239eb99ad98a5dd8b5ef2`, a bounded diagnostic extracted the complete fixed official b11146 archive into **three separate fresh paths** and ran each exact native binary's `--version` twice, serially, with only the production PATH/HOME/TMPDIR environment whitelist. Archive11189714B/SHA256 `1ad3f9eff80edb9dbef4259ad564d1720612ef7eea48fa4afed0e54f5f3d5711`; each executable SHA256 `41df13c126456f8e5fab2057c86a790067a85ea1dfd8fbc0071cc45fbba56262`. No source/binary/backend patch or undocumented environment workaround was used.

| Fresh path | First invocation at that path | Repeat | Result |
| --- | ---: | ---: | --- |
| 1 | 33.084519s | 0.087531s | Both exit0, actual0.5.0-dev/build11146/commit7fe450e19/Darwin arm64 |
| 2 | 1.544436s | 0.169037s | Both exit0, same identity |
| 3 | 1.205266s | 0.117290s | Both exit0, same identity |

All six owned PIDs exited. The diagnostic bound was60s per command; no timeout occurred. **Fresh paths do not establish cold OS/Metal/compiler caches.** Earlier compiler attempts are known; these six samples are not a timing distribution or general performance guarantee. See [frozen raw measurements and decision](ghostmodeldeck-standard-version-budget-r47.json), [retained raw JSON](../../.tooling/gmd-version-measure-r47.json), and [diagnostic script](../../.tooling/gmd_version_measure_r47.py). Job `bash-397` collected exit0 is a diagnostic execution success, not application installation success.

## Minimal implementation decision

Adopt an explicit **60-second installation-version-command budget only for the curated standard b11146/v0.5.0 release**. Keep the existing default10s for JEV and other release descriptors.60s covers all six observed commands with roughly1.81× the maximum observed duration; that is finite headroom on this machine/sample, not a proven percentile or universal bound. It avoids source/byte provenance changes and retains actual backend initialization. A release-specific typed descriptor is preferable to a global timeout increase or guessed environment shortcut; the fixed standard declaration must opt in explicitly.

The version command must still exit0 and satisfy the same parsed semantic version/build/commit/platform checks. Full source/archive/executable/marker/inventory verification remains unchanged. Native timeout still performs owned SIGTERM/finite wait/SIGKILL if needed and drains output. Exceeding60s still **fails installation**, never counts as success. Existing JEV timing and all model startup, text/typed request, cancellation/late-result and Ready evidence are unchanged. Installation cancellation/UI behavior must remain explicit and bounded; do not claim immediate native-command cancellation if the interface only bounds it by the command timeout.

## Required reverification / unchanged failed history

At creation this document is a design decision, **not an implemented or accepted installation**. Implement with public installer/refresh I/O RED→GREEN tests asserting standard60s/JEV10s and unchanged rejection behavior, original strict format/analyze/full online gates. Then use a new output prefix/fresh private root for actual production install/reopen of both candidates and actual owned PID cleanup. Retain [the genuine original10s installation failure](ghostmodeldeck-native-private-install-r46.md) and all prior standalone preflight/diagnostic records verbatim; do not overwrite or relabel them. The sampled backend registry/Metal startup explains why version output can take time, not permanent model incompatibility.

No model load, capability Ready, typed/Chat/SSE, GUI/MCP/SDK or Release acceptance is established by these measurements. #15 remains open. No automatic120s adoption, warmed-cache shortcut as acceptance, inferred Ready, source upgrade, silent JEV fallback or device-env leakage is permitted.
