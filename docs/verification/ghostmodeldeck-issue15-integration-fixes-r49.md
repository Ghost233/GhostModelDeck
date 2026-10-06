# Issue #15 narrow integration fixes — r49

## Source and ownership

- Initial source: clean `main`, `e5f76ae8409e67f2971e152e2674a9238dfb8870`, verified before edits. Inputs: [final intermediate audit](/tmp/gmd-issue15-integration-review-r48.md), [public TDD handoff](/tmp/gmd-issue15-integration-fix-handoff-r48.md), repository engineering/domain/spec instructions and TDD/codebase-design skills.
- Exclusive writer for five production files and directly relevant public tests. Original `scripts/test-container.sh` ONLINE checks ran SERIAL in `ghostmodeldeck-checks-r33b`; no offline/no-pub options, replacement runner, concurrent container jobs or native model invocations.
- Intervening parent commit `d022c92e56e56074e5591b803986057342727689` contains only SDK-consumer r51 verification Markdown/JSON. Inspected and preserved; no owned source/test overlap.
- Scoped commits: `5f3d54dc271b245cae88cba978f9b6fbacb043be` Council publication; `2cc14881c1668338d8ce7c9ba032f1f765820b80` catalog recycle; `5c318d624937c5a3ac525ced8cf13bb8336a1eca` emitted config; `f8f64ef7e855a5f92380dcd34c81341bab7e68c1` bounded nonstream ordering test. Final evidence commit additionally gives the existing widget regression an explicit transition name.

## Public REDs, minimal changes and GREENs

### Whole-catalog admission and late enrollment

Public tests in [model_run_dialog_test.dart](../../test/model_run_dialog_test.dart) use actual `EngineCatalog` / `LlamaEngine.start`, real loopback readiness HTTP, and the existing `EngineProcessIO` / `EngineChild` I/O adapter. No mock of catalog/provider business behavior.

1. Start A and B; capture A using `providerFor` before recycling. Hold B's child exit with a Completer; observe A's stopped publication. A new start through the **captured A reference** returned a new `LlamaInstance`, contrary to the expected exception: RED `run-U1V8qg`, exit 1. B's admission is also checked, and no extra process spawn is allowed.
2. After the initial aggregate-hold change, deliberately leave late-enrollment coordination absent for its RED. Preaccept `catalog.link` and hold its version inspection at command I/O; recycle existing providers. Releasing inspection enrolled a provider whose public start returned a new live child: RED `run-zLLjD8`, exit 1.
3. Keep accepted inspection held, release B, await B's stopped publication and one event-loop turn. Aggregate recycle had already settled (`Expected: false`, `Actual: <true>`, `catalog must drain preaccepted enrollment`): RED `run-iHLzQJ`, exit 1. This is a deterministic held-I/O schedule, not a wall-clock ordering heuristic.

Minimal implementation in [engine_catalog.dart](../../lib/engine_catalog.dart) and [llama_engine.dart](../../lib/llama_engine.dart): provider-owned start-admission holds cover captured references; catalog holds them for its entire coalesced recycle, starts every initial provider recycle immediately, drains preaccepted catalog work, enrolls/holds late providers, waits their stops, and releases holds in `whenComplete`. New catalog work is rejected while recycling, rather than extending the drain indefinitely. Existing provider cancellation/generation/stop implementation is unchanged. Holds do not retroactively reject accepted starts: those remain owned by the provider recycle.

GREEN `run-8d4Wo8`, exit 0, six public runtime/widget tests. The late-enrollment regression now keeps the aggregate pending after both initial children settle and rejects a late provider's start. Post-recycle starts have increasing generations, and standalone per-provider recycle remains reusable. Existing failed-residual/retry/removal/terminal-shutdown assertions remain present and pass in the full suite.

### Latest Council publication, preserving history

[CouncilPage public widget regression](../../test/council_page_test.dart) drives the actual controls and actual `CouncilController`/engine loopback requests: Score → Choice → Noul → Choice. Each Choice request completes with independently expected `accept: 0.5, reject: 0.5` and current request context; widget must display that Choice, not older typed output. Reverse Choice → Noul must display Noul, not the old Choice. Both history slots remain retained.

RED `run-fYwR3e`, exit 1: controller had the completed Choice DTO, but actual page had zero widgets with `综合评分` because permanent batch precedence selected the old batch. [council.dart](../../lib/council.dart) now records `CouncilResultKind` at successful publication; [council_page.dart](../../lib/council_page.dart) selects by that discriminator. No wall-clock ordering, history erasure or new GUI algorithm. GREEN `run-Hnsaw6`, exit 0, five widget tests.

Additional failed evidence `run-aEwV5f` is retained: extending the previously typed-only responsive test to Choice at 400px and text scale 2 exposed a Choice result-table horizontal RenderFlex overflow. No UI redesign is included. Original typed Score/Noul 400px/2x assertions remain unchanged; new Choice transitions run at the existing 1200px/2x desktop size. This is a known layout limitation outside this publication fix, not a cleared finding.

### Emitted Codex configuration

[Public configuration/listener test](../../test/council_mcp_test.dart) checks empty config before/after listener lifetime, actual running endpoint, exact generated block and tool discovery using the real MCP SDK listener. RED `run-D3APvH`, exit 1: actual `enabled_tools` had only `consult_jev_council`, while expected block also included `consult_jev_council_batch`.

One-line change in [council_mcp.dart](../../lib/council_mcp.dart) emits both actual toolnames. URL, legacy tool/protocol, `enabled = true`, startup timeout 10 and tool timeout 20 are preserved. GREEN `run-oKVEQO`, exit 0, eleven MCP tests including modern and legacy clients. No actual Codex invocation.

### Nonstream text completion: hypothesis remains unproven

One bounded supported public test in [llama_engine_test.dart](../../test/llama_engine_test.dart) holds a real loopback response at existing HTTP I/O, cancels before response, requires `DecisionFailureKind.cancelled`, no new `lastTextResult`, and drained active requests. Then a normal completion succeeds; cancellation after returned success does not erase that result or readiness. GREEN on unchanged text production logic: `run-BKzHCQ`, exit 0.

This does **not** schedule cancellation after internal decode but before publication. No deterministic supported public seam for that exact window was established; no business seam was manufactured, and exploration stopped. The claimed nonstream terminal publication race remains **not proven**, not a defect inferred from missing streaming/typed symmetry. Production text generation was not changed.

## Final original ONLINE gates

Source content for these gates is the four scoped milestones plus the descriptive widget-test rename; documentation only follows. `229` passing tests = original source225 plus two catalog schedules, one emitted-config test and one bounded nonstream test. No tests or old assertions removed/weakened.

```sh
GMD_TEST_CONTAINER=ghostmodeldeck-checks-r33b ./scripts/test-container.sh format --output=none --set-exit-if-changed lib test
GMD_TEST_CONTAINER=ghostmodeldeck-checks-r33b ./scripts/test-container.sh analyze
GMD_TEST_CONTAINER=ghostmodeldeck-checks-r33b ./scripts/test-container.sh test
```

| Gate | runId / exit | Result | Captured log |
|---|---|---|---|
| Strict format | `run-mhejaE` / 0 | 57 files, 0 changed | [format](/tmp/gmd-r49-final-format.log) |
| Full analyze | `run-dAgtyF` / 0 | No issues found | [analyze](/tmp/gmd-r49-final-analyze.log) |
| Full test | `run-YuxYHE` / 0 | 229 tests passed | [test](/tmp/gmd-r49-final-test.log) |

For each run, original transferred source archive, SHA-verified result log, exit file and generated job remain under `.tooling/container-tests/<runId>/`. These source-bound container/loopback results are not new native binary/model proofs and do not generalize to every concurrent race.

## All retained execution evidence

Each run below has its original [.tooling/container-tests](../../.tooling/container-tests) evidence, and the outer captured log is linked. All calls finished; no background jobs remained.

| Purpose | runId | Exit | Log |
|---|---|---|---|
| Council public RED | `run-fYwR3e` | 1 | [RED](/tmp/gmd-r49-council-red.log) |
| Council fix exposed narrow Choice layout overflow | `run-aEwV5f` | 1 | [retained failure](/tmp/gmd-r49-council-green.log) |
| Council transitions GREEN | `run-Hnsaw6` | 0 | [GREEN](/tmp/gmd-r49-council-green2.log) |
| Captured-provider RED | `run-U1V8qg` | 1 | [RED](/tmp/gmd-r49-catalog-red.log) |
| Initial catalog GREEN | `run-uTr5YU` | 0 | [GREEN](/tmp/gmd-r49-catalog-green.log) |
| Isolated milestone format preparation | `run-rOmA4X` | 0 | [format](/tmp/gmd-r49-format-milestone.log) |
| Late-link admission RED without late coordination | `run-zLLjD8` | 1 | [RED](/tmp/gmd-r49-late-link-red.log) |
| Accepted-enrollment drain RED without late coordination | `run-iHLzQJ` | 1 | [RED](/tmp/gmd-r49-late-drain-red.log) |
| Complete catalog GREEN | `run-8d4Wo8` | 0 | [GREEN](/tmp/gmd-r49-catalog-green2.log) |
| Emitted allow-list RED | `run-D3APvH` | 1 | [RED](/tmp/gmd-r49-codex-red.log) |
| Complete MCP GREEN | `run-oKVEQO` | 0 | [GREEN](/tmp/gmd-r49-codex-green.log) |
| Bounded nonstream hypothesis probe | `run-BKzHCQ` | 0 | [probe](/tmp/gmd-r49-nonstream-probe.log) |
| Isolated full format preparation | `run-ETG3tl` | 0 | [format](/tmp/gmd-r49-format-prep.log) |
| First full strict format | `run-5W6l3I` | 0 | [format](/tmp/gmd-r49-full-format.log) |
| First full analyze | `run-07qStZ` | 0 | [analyze](/tmp/gmd-r49-full-analyze.log) |
| First full test, 229 passed | `run-nKhwoM` | 0 | [test](/tmp/gmd-r49-full-test.log) |

Final gates are the three additional runs in the preceding table. Temporary preparation patches/files were not delivered or added to the repository. An exploratory direct formatter invocation only touched the isolated transferred container source; final strict format and all gates used the original runner. Repository changes were made through read/edit/write, not formatter overwrites.

## Settlement and limits

- All checks ended within a five-minute foreground wait; no long-running background check required polling. Full final gates and every relevant execution result are collected. Source and SERIAL slot are released after final evidence commit.
- Historical successful native scoped proofs remain bound to their historical source. r49 does not relabel them as proof of these concurrent schedules; independent parent review decides whether further native proof is required.
- #15 stays OPEN. No issue close/report, push, Teams, native-model/binary/SDK/dependency/settings/config/profile/DNS/container configuration edits, worktrees or temporary branches. Future #16–19 untouched.
- Remaining: unproven internal nonstream completion race and the observed narrow Choice/2x layout limitation; no broad refactor or redesign attempted.
