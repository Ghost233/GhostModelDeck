# GhostModelDeck MLX index F1 — all-invalid nonempty weight_map (2026-10-06)

- Base: main `96d0c321603d0f4c2822106d1ccfc8fe44e994d8` (clean).
- Fix: main `4d0da994ebef239ee232e9c5fad171ce7b43b7ec`
  (`fix(library): reject conventional index maps not bound to the weight`).
- Defect source: queued review `/tmp/gmd-mlx-eligibility-review-r55.md` +
  `/tmp/gmd-mlx-index-followup-r55.md` (F1/P2, standard E02).
- Scope: `lib/model_library.dart` + `test/model_library_test.dart` only
  (plus this report). No engine/catalog/config/dependency changes.

## Defect

`lib/model_library.dart` indexed grouping (pre-fix 1302–1323) bundles every
nonempty `weight_map`, selecting only references that resolve to discovered
weights. An all-invalid map (numeric value, missing shard, traversal escape)
selects nothing, so the real weight file stays unconsumed and is rebundled
without `indexPath`. The conventional-index fallback (pre-fix 1117–1122) then
attached the same index but only rejected a non-Map or **empty** map, so the
second artifact carried the real weight plus an unvalidated index and scanned
**falsely complete**, while the first bundle remained an incomplete
index-only phantom.

## Fix

The fallback now validates every `weight_map` entry against the bundle: each
entry must resolve to this weight's own discovered file and name one of its
tensors; otherwise the artifact is `corrupt` with the existing diagnostic
`<name>.index.json 索引映射无效`. A fully valid map never reaches the
fallback — indexed grouping consumes its weight first — so valid indexed
packages (including the r55 real nine-file proof), split packages, variant
separation, and receipt isolation are unchanged.

## RED (immutable, pre-fix snapshot)

1. Prepared probe `.tooling/gmd_mlx_index_regression_r56.dart red` on clean
   `96d0c321`: exit 1, `invalid_complete_count: 3` (numeric / missing /
   traversal each produced one falsely complete artifact containing
   `model.safetensors` + the invalid index, `diagnostics: []`); valid-control
   complete ×1. Evidence: `.tooling/gmd-mlx-index-red-r56.json`.
2. Public regression tests added to `test/model_library_test.dart`, then the
   unchanged container gate on the pre-fix tree:
   `GMD_TEST_CONTAINER=ghostmodeldeck-checks-r33b ./scripts/test-container.sh test`
   → run `run-sHYnKa`, exit 1, 334 tests / exactly 4 failures:
   - `Qwen2 nonempty index with numeric value cannot complete the real weight`
   - `Qwen2 nonempty index with missing shard cannot complete the real weight`
   - `Qwen2 nonempty index with traversal escape cannot complete the real weight`
   - `conventional index naming only another weight keeps variants separate`
   Each failed `Expected: AssetIntegrity.corrupt / Actual: complete`.
   The mixed valid/invalid guard passed pre-fix as designed.
   - `source.tar.gz` sha256 `165626690997d655fc29e0a7d0994d4c7c28c129fc3c6858d35044f2d28ea496`
   - `result.log` sha256 `b2acc336599293d14b5e21f0a2627572f974c71a06019ed22ccc8b292ca255d9`
   - Snapshot verified pre-fix: extracted `lib/model_library.dart` (2011
     lines) contains the old container-only fallback at 1117–1122.

## GREEN (post-fix, all three gates on the same frozen snapshot)

All runs ONLINE in container `ghostmodeldeck-checks-r33b` via the unchanged
`scripts/test-container.sh` (per-run remote/local tar sha256 matched by the
script itself):

| Gate | Run | Exit | Result | source.tar.gz sha256 | result.log sha256 |
| --- | --- | --- | --- | --- | --- |
| format | `run-fgRPvj` | 0 | 62 files, 0 changed | `b1358790a6270d1fc57ba00a3ba9a40100b8fe8a38142997cb410bfd62a90b9e` | `78166cf81d804f39b4400e6a03db6218ce7484746bbdf0220d2a55080d39e1d4` |
| analyze | `run-ERGX6K` | 0 | No issues found | `9daeeef7ebdeff57a78d7d69ad88bcbe7bc38b931a572638143da12c7b3561eb` | `989ad97ba4eebcbcc470e42260e19e60a2e26e40a5a42ddb40110cad6c57af38` |
| test | `run-dQFhl9` | 0 | **334/334 passed** (329 baseline + 5 new) | `335d0fa09dfad315e05ef0321d87c1992568d439ab83af1b2f2ec22d29708cf8` | `90f1dd04ed26c43bdf2cebb983e309b5d6692ac455d3b5bd240d1fd677dd44c4` |

New public tests (5): the three all-invalid cases (a: numeric `42`,
b: missing shard, c: traversal `../outside.safetensors`) each assert no
complete artifact for the real weight — the affected artifact is `corrupt`
with the index attached as evidence, the index-only phantom is `incomplete`
with `索引引用的权重文件缺失`, capability stays `awaitingVerification`;
a mixed valid/invalid map stays `incomplete`; an index naming only another
real weight keeps variants separate (other variant never laundered complete).

Probe re-run on the fixed HEAD `4d0da994` (clean tree):
`dart run .tooling/gmd_mlx_index_regression_r56.dart green` → exit 0,
`invalid_complete_count: 0`, valid-control still complete with identical
expectations. Evidence: `.tooling/gmd-mlx-index-green-r56.json`.

## Source binding (current bytes = Git blob = every GREEN archive)

sha256 of file contents, identical across worktree, `git show HEAD:<path>`,
and the extracted members of `run-fgRPvj` / `run-ERGX6K` / `run-dQFhl9`
`source.tar.gz`:

- `lib/model_library.dart`:
  `2c1e4a8b2cd5f26eb6694fc205b02044c085b3fce71886947f69b9d8fef2376e`
- `test/model_library_test.dart`:
  `7bb2ac9e031a1fedd8e20326c72e0abf9d64d8d261acffeb5f7e6c3f0471a789`

Untouched gate inputs sampled identical too (`pubspec.yaml`
`d3a3a03c…baa88d`, `analysis_options.yaml` `fa6b57f2…c3f98`).

## Consistency with the r55 real-package proof

The r55 structural verification (real 289598797-byte nine-file
mlx-community/Qwen2.5-0.5B-Instruct-4bit @a5339a4 scanning
complete/chat/qwen2/Safetensors 4bit G64, awaitingVerification) is not
contradicted: its fully valid `weight_map` is consumed by indexed grouping
before the fallback exists, and all 329 baseline tests — including every
indexed, split, unindexed, receipt-isolation and unknown-profile scan —
pass unchanged on the fixed snapshot.
