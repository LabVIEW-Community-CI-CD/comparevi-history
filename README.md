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
| `comparevi_ref` | No |  | Backend ref override. If omitted, the action tries its own ref first and falls back to `develop`. |
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

## Notes

- This action is intended for trusted Windows runners that already satisfy the LabVIEW/LVCompare requirements of the backend tooling.
- The current facade is a thin wrapper over `compare-vi-cli-action`; release/version mapping between this repo and the backend repo should be treated as explicit operational policy.
- Tracking epic: https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/841
