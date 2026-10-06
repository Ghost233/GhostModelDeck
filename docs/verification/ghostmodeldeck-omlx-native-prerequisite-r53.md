# oMLX r53 — bounded native private-relocation prerequisite

## Scope and verdict

2026-10-06 native prerequisite for open #16, **not production implementation or acceptance**. Assessed source checkout: `main` at `b339190eacec57965a898bdaacfb7fdee8035499`; tracked workspace was clean before probing and again before curation. #15 completion and historical mount inspection were not substituted for this run. Only the two r53 verification documents are tracked deliverables. No source, tests, dependencies, container, GUI, SDK, issues or other repository were modified. No server, GUI app, pool/auth request, model download/load/inference, or existing MLX weights were used.

**True:** complete official app relocation, original signature verification, copied CLI informational commands, embedded real Python/package containment, and a tiny explicitly GPU-bound MLX operation passed on this host. **False:** fully bundle-hermetic Python search paths, entire tracked upstream package equivalence, production installer acceptance, model inference acceptance, and Ready acceptance. **Unknown:** whole-distribution/dependency/binary equivalence to the fixed source commit.

The [curated JSON](ghostmodeldeck-omlx-native-prerequisite-r53.json) contains every assessed child command, PID, finite timeout, actual exit status/stdout/stderr, sanitized environment, immutable source comparison and raw-evidence SHA256 manifest. It is independent evidence, not a fixture-test result.

## Artifact, environment and ownership

- Cached official [DMG](../../.tooling/engine-artifacts/oMLX-0.7.0-macos26-27.dmg): **830879938 bytes**, SHA256 `2e3bb06ac6ee7f50986ba1417e909d432ccd2be471db752a4a2d3b5651e3bce0`. Device/inode/size/mtime-ns were recorded before and after rehash and were identical.
- Host: macOS **27.0.1**, build **26A434**, arm64; observed Metal device **Apple M5 Pro**, architecture `applegpu_g17s`.
- Fresh canonical owner root: `/private/tmp/gmd_omlx_private_probe_r53-lfvb7ca_`. Read-only mount: `/private/tmp/gmd_omlx_private_probe_r53-lfvb7ca_/readonly-mount`; source app: `/private/tmp/gmd_omlx_private_probe_r53-lfvb7ca_/readonly-mount/oMLX.app`.
- Copied full app: [owned relocated app](/private/tmp/gmd_omlx_private_probe_r53-lfvb7ca_/private/oMLX.app), created by native `ditto --rsrc --extattr --acl`, not a source-script substitute or production managed-engine installation. Frameworks, resources, embedded Python, site-packages, CLI wrapper, symlinks and original signatures were retained. No `/Applications`, Homebrew install, global settings, trust changes or ad-hoc signing.
- Attached mount device **/dev/disk13s1**, whole GUID image **/dev/disk12**, as returned by the owned attach. Before detach, `diskutil info -plist /dev/disk13s1` confirmed the exact recorded device and mount path. `hdiutil detach /dev/disk12` exited **0**; mount app absent afterward. No unrelated device was detached. Scratch copy/raw evidence were intentionally retained, not deleted.

## Native signature, layout and full-copy proof

| Check | Actual result |
| --- | --- |
| `codesign --verify --deep --strict --verbose=2` source app | exit 0; valid on disk, satisfies Designated Requirement |
| Same check relocated app | exit 0 |
| `spctl --assess --type execute --verbose=4` source and relocated app | both exit 0; accepted, `source=Notarized Developer ID` |
| Original signing identity | `Developer ID Application: Heejun Kim (PSK5Q5T46L)`, TeamIdentifier `PSK5Q5T46L`, identifier `app.omlx` |
| App plist | version **0.7.0**, build **2987** |
| Observed binaries | main app universal **x86_64/arm64**; embedded Python **arm64**; only arm64 runtime assessed |
| Inventories | **48734** source entries = **48734** copied entries, exact path/type/file-byte SHA256/mode/symlink-target equality; **0** escaping symlinks |
| Inventory SHA256 | both `5f064a2c0b40c8195d2c1137477eb8d22757103982f24c4f2602b6de81aff688` |
| Final post-runtime full inventory | **48734**, unchanged byte-for-byte and mode/symlink-equivalent |
| Final post-runtime deep/strict signature and Gatekeeper assessment | both exit **0** |

SHA256 identity and Apple signature/trust assessment are **separate checks**, neither inferred from the other. Inventory equality covers byte content/modes/symlinks, not an exhaustive xattr/ACL comparison; native copy requested preservation and actual deep/strict signatures remained valid. Relocated `du -sk`: **1695676 KiB**. This one-host result is not a universal platform guarantee.

## Copied official wrapper and real embedded Python

The actual [copied wrapper](/private/tmp/gmd_omlx_private_probe_r53-lfvb7ca_/private/oMLX.app/Contents/MacOS/omlx-cli) was read before execution: it resolves its own real path, locates bundled resources, sets embedded `PYTHONHOME`, and constructs resource/framework `PYTHONPATH`. The packaged [CLI parser](/private/tmp/gmd_omlx_private_probe_r53-lfvb7ca_/private/oMLX.app/Contents/Resources/omlx/cli.py) establishes top-level `--version` and `serve --help`; these were not guessed.

Only `--help`, `--version`, and `serve --help` ran through the **copied official wrapper**, each exit **0**, no timeout. Version output: **0.7.0**. Help did not enter the serve handler. Actual outputs, including help text, are preserved in JSON.

Child environments were assembled from scratch: system-only `PATH`; owned fresh `HOME`, `TMPDIR`, and XDG cache/config/data directories; `PYTHONDONTWRITEBYTECODE=1`, `PYTHONNOUSERSITE=1`, and locale. No inherited `PYTHONPATH`, `DYLD_*`, user configuration or Python environment was supplied. Direct embedded-Python inspection used the same bundle-only resource/framework paths required by the observed wrapper. It ran the [assessed embedded Python](/private/tmp/gmd_omlx_private_probe_r53-lfvb7ca_/private/oMLX.app/Contents/Resources/Python/cpython-3.11/bin/python3), **not** the dependency Python used solely to orchestrate/hash evidence.

- Python **3.11.10**, Clang **18.1.8**, runtime **arm64**; executable/prefix/base_prefix inside relocated bundle.
- Imported `omlx`, `mlx.core`, `mlx_lm`, `fastapi`, `transformers`: resolved real package paths **all inside the copied complete bundle**.
- Package versions: MLX **0.32.2**, mlx-lm **0.31.4.dev132+g94cdcae13**, FastAPI **0.142.2**, Transformers **5.17.0**.
- Followup audited **850** observed file-backed modules from those imports: **0** outside the copied bundle. Builtin/frozen modules without file paths are not counted. This is observed import containment, not proof about unexecuted lazy imports.

### Explicit false finding: not a fully hermetic search path

The signed bundled [sitecustomize.py](/private/tmp/gmd_omlx_private_probe_r53-lfvb7ca_/private/oMLX.app/Contents/Resources/Python/framework-mlx-base/lib/python3.11/site-packages/sitecustomize.py#L10-L12) contains:

```python
from site import addsitedir
addsitedir('/Users/cryingneko/Workspace/omlx/omlx/packaging/_export/cpython-3.11/lib/python3.11/site-packages')
```

That builder-machine directory remained in runtime `sys.path` despite a sanitized environment; it **does not exist on this host**. The direct `-c` inspection also has the normal empty-string path resolving to the fresh owned working root, not inside the bundle. No imported file-backed module resolved through either external location. The builder path was not removed, patched or suppressed: changing signed package files would violate this probe. Future production planning must address/prove search-path isolation without assuming this scratch result establishes universal hermeticity or loosening signature/Ready requirements.

## Actual tiny Metal operation, not CPU or LLM inference

Actual bundled MLX stub declarations were read before forming this probe. The embedded Python process required `mx.metal.is_available()`, obtained `gpu = mx.default_stream(mx.gpu)`, asserted `gpu.device.type == mx.gpu`, selected GPU default device, entered `mx.stream(gpu)`, ran `mx.matmul(a,b,stream=gpu)`, then `mx.eval(c)` and `mx.synchronize(gpu)`.

Float32 `[[1,2],[3,4]] @ [[5,6],[7,8]]` produced exactly **`[[19,22],[43,50]]`**. Observed stream `Stream(Device(gpu, 0), 0)`, stream device/default device `Device(gpu, 0)`, Metal availability **true**; exit **0**, measured **2.421 seconds** for the combined package/Python/GPU process. This is an explicit Metal/GPU evaluation, not silent CPU fallback, a model execution, performance benchmark, or Ready claim. Raw stderr retains the real `mx.metal.device_info` deprecation warning; it is not hidden or treated as failure.

## Read-only fixed-source binding

Fetched the immutable [upstream Git tree](https://api.github.com/repos/jundot/omlx/git/trees/4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40?recursive=1) via normal network with a finite 60-second network timeout, without checkout/install/execute or authenticated GitHub business operation. Returned tree SHA matched **4d4f5a280bc1739ba2cf39c1cee44fd5cc89cb40** and was not truncated. Compared Git blob identities using `SHA1("blob " + decimal_length + NUL + actual_bundled_bytes)` for every tracked `omlx/` blob.

- **770** tracked package files: **693** present and exactly equal, **77** absent, **0** present-but-changed.
- All **519** tracked Python files are present and exactly equal to the fixed source commit.
- The 77 absent files are custom-kernel C/C++/Objective-C++/Metal/header/CMake/license build inputs; exact paths and fixed blob IDs are preserved in JSON. They prevent claiming **entire tracked-package equivalence**.
- Bundled [engine-commit metadata](/private/tmp/gmd_omlx_private_probe_r53-lfvb7ca_/private/oMLX.app/Contents/Resources/omlx/_engine_commits.json) records mlx-lm `94cdcae13b266c337bcaca09b97b9c5a9c0e2cde`; metadata is not a proof of dependency/binary source equivalence.

This comparison binds the present application package bytes to the fixed source; it does **not** establish generated-kernel/binary, third-party dependency, wrapper/packaging or whole-distribution reproducible-build equivalence. Those remain **unknown**, not inferred from version strings/signatures.

## Finite diagnostics, cleanup and delivery checks

All **22** assessed child processes record actual command/PID/exit/timeout/stdout/stderr in JSON; all exited **0**, **0** timed out, every child was waited/collected. Each owned child starts a new process session; timeout handling would TERM only its owned process group, wait 5 seconds, then KILL only that group if necessary and wait. No timeout required a kill. Command diagnostic limits were **60/120 seconds**, complete-copy limit **180 seconds**; these are bounded prerequisite diagnostics, **not** inferred production/model budgets. No job approached the five-minute long-job check interval; no busy polling/offline fallback. Orchestration jobs `bash-603`, `bash-605`, `bash-608` were all collected with actual exit **0**.

Raw retained evidence is under [owned ignored evidence](../../.tooling/gmd_omlx_private_probe_r53/evidence.json); full source/copied/post-runtime inventories, fetched immutable tree, file comparisons and helper hashes are independently manifested in curated JSON. Progress: [owned progress record](/tmp/gmd-omlx-native-prerequisite-r53-progress.md). No retained scratch content is a production installer.

Deterministic document validation **passed**: JSON roundtrip, **11** raw-file hashes, **22** actual child completion/status records, **10** local Markdown links, required true/false/unknown flags, inventory/source-comparison arithmetic, Python-file equality, explicit GPU result, and exact cleanup device/mount binding. `git diff --check` passed; the staged two-file diff is also checked before commit. Dart/container tests, native app GUI/model tests and SDK tests are **not run**: no such implementation changed, and the requested scope expressly excludes them. No push or issue operation.

**#16 remains open.** This prerequisite supplies native relocation/CLI/Python/Metal evidence and two concrete distribution limitations; production ownership, installation/lifecycle design, security/admission policy, actual model integration and full Ready/Release acceptance remain separate work.
