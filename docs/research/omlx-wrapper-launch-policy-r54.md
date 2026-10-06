# Human-confirmed oMLX official-wrapper launch policy

## Decision and authorization boundary

On 2026-10-06 (Asia/Shanghai), the human answered `omlx-launch-policy` choosing the recommended **unchanged official wrapper + strict prelaunch checks + private cwd/environment** option. This is not permission for a custom `-I/-S` bootstrap, signed edits, re-signing, system/Homebrew Python fallback, or relaxed identity/Ready gates.

The official complete signed app remains unchanged. Reject **before any wrapper/embedded-Python invocation**, including information/help/version/preflight commands, when the known builder path exists, is a lexical or dangling symlink, has ambiguous permissions/lookup status, or relevant ancestors allow another untrusted local user to create/redirect it. A following-symlinks `exists()` boolean alone is insufficient. Recheck immediately before each launch; controlled tests must not create or modify the real builder user's directories.

Use a private owned non-model/non-download cwd and a constructed nonsecret environment, not inherited PYTHONPATH/DYLD/user settings. An absent builder path and approved private cwd are explicit narrowly accepted search-path exceptions. **This is not full hermeticity, an OS sandbox, or a TOCTOU-free guarantee.** Same-user/administrator tampering is outside the accepted guarantee; this exclusion must not silently extend to other local principals.

## Why checks must precede execution

The [native prerequisite](<../verification/ghostmodeldeck-omlx-native-prerequisite-r53.md>) found a signed `sitecustomize.py` adding `/Users/cryingneko/Workspace/omlx/omlx/packaging/_export/cpython-3.11/lib/python3.11/site-packages`. The original wrapper exports its bundled Python paths and execs embedded Python `-m omlx.cli`; wrapper arguments are CLI arguments, not interpreter flags.

Python `site.addsitedir` can execute `.pth` import lines before any later import/module audit. `-I` does not imply `-S`, and the chosen policy does not substitute a custom launcher. Historical contained imports do not undo prior `.pth` execution or prove all future lazy imports. See the [exact source-backed brief](</tmp/gmd-omlx-python-launch-isolation-r54.md>) and [operational decision](</tmp/gmd-omlx-wrapper-launch-policy-r54.md>).

## Required evidence, not yet implemented acceptance

Production install/link/start entrypoints must apply actual platform ownership/writability/path evidence fail-closed, prove zero wrapper/Python spawn for rejected cases through public I/O-boundary tests, and retain honest failure/resource ownership. No real foreign builder paths may be created/chmodded/deleted for a test.

Later native acceptance must exercise the final production installer/provider and this launch gate, complete signatures/inventory/runtime identity, protected auth settings, foreground owned pool, fixed model/text/SSE, cancellation and owned PID/port closure. Credentials must never enter argv/environment/logs/proofs. The native tiny Metal prerequisite and structural package completeness are not substitutes for this proof.

#16 remains OPEN. This decision documents approved policy only; implementation and native verification are separate milestones.
