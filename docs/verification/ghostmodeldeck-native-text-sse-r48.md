# Real native ordinary GGUF text, SSE, cancellation and peer isolation

## Actual public business path

Source `fff82a36792f4baadf497dbd468e2cbf2c7411f9`, clean production/test/dependency tree. The host invoked existing production `ModelLibrary.scan(verifyFiles:true)`, actual standard `LlamaEngine.refreshInstallation/start/generateText/streamText/stop/shutdown` and real `NativeEngineProcessIO`. The recording decorator delegates real OS operations; no fixture server, fabricated probabilities/capabilities or implicit model loading was used. This is independent native evidence, not final GUI/Release or future standard gateway #17 validation.

Explicit fixed HF asset: Qwen/Qwen2.5-0.5B-Instruct-GGUF@9217f5db79a29953eb74d5343926648285ec7e67, `qwen2.5-0.5b-instruct-q4_k_m.gguf`,491400032B/SHA256 `74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db`. Reused the [actual downloaded receipt/weight](ghostmodeldeck-gguf-live-asset-validation-r38.md), not old user configuration. Fresh complete production scan and each startup's public verification earned complete chat integrity/full fingerprints/sourceVerifiedtrue; file bytes and receipt identity remain distinct from runtime Ready.

Actual standard installation from [production HTTPS installation proof](ghostmodeldeck-native-dual-https-install-r47.md): b11146/fixed7fe450e19305b828c199d602c23a8337aaa1f03b, binary SHA256 `41df13c126456f8e5fab2057c86a790067a85ea1dfd8fbc0071cc45fbba56262`. Native launch args include MTL0/GPU layers99, context/batch/ubatch4096 and parallel1. No alternate device flags, derivative binary, startup/request budget adjustment or environment shortcut was introduced.

## Observed success and strict separation

Observed `2026-10-06T01:06:01.078595Z`:

| Instance | Actual PID / loopback port | Generation | Earned capability |
| --- | --- | --- | --- |
| A `jev-aa52365e1e085ab5a24ff34a8e55f86423e59a556130bd4f` |21159 /52409 |1 |textGeneration only |
| B `jev-0e8f04191dd9c6ab2545f86a4ab40ae7ac55a550904529b5` |21352 /52487 |2 |textGeneration only |

Both actual `/props` aliases, distinct installation/service/instance identities, verified executable hash and restricted environment keys were captured. The historical internal alias prefix `jev-` is **not** JEV compatibility evidence. Both ordinary instances lacked choiceProbability/scoreProbability/noulScalar, and the public typed decision call was rejected `notReady` before treating text as probabilities.

- A actual nonstream request returned **“Hello! How can I assist you today?”**, finish`stop`, actual10 completion tokens and exact owned model alias.
- A actual streamed request returned32 completion tokens, finish`length` at the explicitly requested limit, nonempty ocean text, actual upstream data events including `[DONE]`, and the public completion only after body EOF. Captured deltas exactly equal terminal text; every JSON event binds A's alias. This does not claim a complete sentence or instruction-following quality score.
- Consumer canceled a separate2048-token stream after the first nonempty delta. No successful terminal result was published; public activeRequests became0 and A remained Ready. A subsequent actual10-token request succeeded. This demonstrates native consumer cancellation/drain; it is not a wire packet capture or quantitative server-FIN latency claim.
- Stopping A reclaimed52409 without changing B's PID/port/generation/Ready. B then produced its own actual10-token response, and public `prepareDeletion` still rejected the shared weight as in use. After B stopped, a deletion **plan only** succeeded, showing no stale reservation; **no model file was deleted**.
- Both owned model children and recorded version commands exited0 via production shutdown, without forced cleanup. Both ports refused fresh connections at the independent curator. Weight size/mode/modified/change timestamps remained identical before/after the native phase; independent curator rehashed the physical491400032B file and verified its own device/inode/stat stability.

## Frozen evidence and limits

[Curated full raw proof](ghostmodeldeck-native-text-sse-r48.json) embeds actual model props, request JSON responses, normalized upstream SSE data events, cancellation/peer snapshots, owned PID exits and raw record SHA256. Independent validation recomputes content/usage/model binding from JSON/events, verifies positive actual token counts, upstream finish/DONE/delta equality, only-text capabilities and physical SHA256. Parent collected `bash-447` exit0; curator exit0.

[Probe](../../.tooling/gmd_native_text_r48.dart), [raw JSON](../../.tooling/gmd-native-text-r48.json), [raw log](../../.tooling/gmd-native-text-r48.log), [exit0](../../.tooling/gmd-native-text-r48.exit), [curator](../../.tooling/gmd_curate_native_text_r48.py). A separate JEV native probe may have shared GPU compilation resources; timing output is observational, not a universal speed or reliability claim.

No native MCP/standard gateway/SDK/window/GUI/recycle-all-during-start/final Release A01–A12 acceptance is inferred from this slice. Those additional assertions require their own real execution evidence. #15 remains open pending integration review and remaining native coverage; original failures and prior fixture/online225-test evidence remain unchanged.
