# comparevi-history

Short-name GitHub Action facade for advanced Compare VI History workflows.

Primary caller syntax:

```yaml
- uses: actions/checkout@v5
  with:
    fetch-depth: 0

- uses: LabVIEW-Community-CI-CD/comparevi-history@v1
  with:
    target_path: path/to/file.vi
```

## What it does

- Requires the caller repository to already be checked out.
- Acquires `LabVIEW-Community-CI-CD/compare-vi-cli-action` internally.
- Runs the existing `Compare-VIHistory.ps1` backend against the caller repository.
- Forwards the existing history output contract so downstream workflows can consume manifest/report paths.
- Uses the repo-pinned backend default in `comparevi-backend-ref.txt` unless `comparevi_ref` is explicitly overridden.

## Inputs

| Input | Required | Default | Notes |
| --- | --- | --- | --- |
| `target_path` | Yes |  | Repository-relative VI path to inspect. |
| `start_ref` | No | `HEAD` | Start branch/tag/commit. |
| `end_ref` | No |  | Optional end ref. |
| `max_pairs` | No |  | Optional cap on adjacent commit pairs. |
| `max_signal_pairs` | No | `2` | Optional cap on surfaced signal pairs. |
| `noise_policy` | No | `collapse` | `include`, `collapse`, or `skip`. |
| `mode` | No | `default` | Comma/semicolon list of compare modes. |
| `results_dir` | No | `tests/results/ref-compare/history` | Relative to the caller repository root unless absolute. |
| `repository_root` | No |  | Optional caller repository root when checkout is not at `github.workspace`. |
| `comparevi_repository` | No | `LabVIEW-Community-CI-CD/compare-vi-cli-action` | Backend tooling repository. |
| `comparevi_ref` | No |  | Backend ref override. If omitted, the action uses the repo-pinned default in `comparevi-backend-ref.txt`, then falls back to action ref and `develop`. |
| `render_report` | No | `true` | Render markdown/html history reports. |
| `report_format` | No | `html` | `html`, `xml`, or `text`. |
| `fail_fast` | No | `false` | Stop after first diff. |
| `fail_on_diff` | No | `false` | Fail the step when any diff is found. |
| `quiet` | No | `false` | Reduce compare output. |
| `detailed` | No | `true` | Enable detailed history output. |
| `keep_artifacts_on_no_diff` | No | `false` | Preserve compare artifacts on no-diff runs. |
| `include_merge_parents` | No | `false` | Walk merge parents alongside the mainline. |
| `compare_timeout_seconds` | No |  | Optional per-compare timeout passed to the backend. |
| `invoke_script_path` | No |  | Optional override for LVCompare invocation (for example a stub in tests). |

## Outputs

The facade forwards the underlying history outputs from `compare-vi-cli-action`, including:

- `comparevi-ref`
- `tooling-path`
- `repository-root`
- `manifest-path`
- `results-dir`
- `mode-count`
- `total-processed`
- `total-diffs`
- `stop-reason`
- `target-path`
- `category-counts-json`
- `bucket-counts-json`
- `mode-manifests-json`
- `mode-list`
- `flag-list`
- `history-report-md`
- `history-report-html`

## Trust boundaries

- Treat this action as a trusted-runner workflow primitive. Real VI History diagnostics should run only on Windows runners that you control and that already satisfy the LabVIEW/LVCompare prerequisites of the backend tooling.
- Do not expose this action to untrusted fork pull requests with write-scoped tokens or secrets. For public repositories, prefer comment-gated or maintainer-dispatched workflows for PR diagnostics.
- `comparevi_repository` and `comparevi_ref` are escape hatches for maintainers and smoke coverage. Leave them at their defaults in normal consumer workflows so the action stays on the reviewed backend pin.
- Hosted smoke coverage in this repo uses an LVCompare stub on `windows-latest`. That proves the facade contract and cross-repo wiring, but it is not a substitute for trusted-runner production use.

## Release mapping

- The default backend mapping is pinned in `comparevi-backend-ref.txt`. The current default is `371b9b9d802903fb12cb8deb3fd8a297dc95f09c` from `LabVIEW-Community-CI-CD/compare-vi-cli-action`.
- Immutable facade tags such as `v1.0.0`, `v1.0.1`, and later patch tags should each map to a single reviewed backend ref through that file.
- The moving major tag `v1` should point to the latest compatible facade release after smoke passes.
- When updating the backend pin:
  1. Change `comparevi-backend-ref.txt`.
  2. Run the facade smoke workflow so both local and external paths validate the pinned backend.
  3. Cut a new immutable tag in `comparevi-history`.
  4. Move `v1` to that same commit.

## Notes

- The facade is a thin wrapper over `compare-vi-cli-action`; consumers should treat the pinned backend ref as part of the release contract.
- Tracking epic: https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/841
