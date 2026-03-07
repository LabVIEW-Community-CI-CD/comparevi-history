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
- The action fails closed on `pull_request` and `pull_request_target` events for forked repositories. For public repositories, use comment-gated or maintainer-dispatched workflows for PR diagnostics instead of running the facade directly on fork PR events.
- `comparevi_repository`, `comparevi_ref`, and `invoke_script_path` are maintainer-only overrides. The action rejects them when the PR context is not provably repo-local and trusted, and normal consumer workflows should leave them at their defaults.
- Do not expose this action to untrusted fork pull requests with write-scoped tokens or secrets. `pull_request_target` against a fork is treated as unsafe by default because the facade assumes trusted refs and a trusted runner.
- Hosted smoke coverage in this repo uses an LVCompare stub on `windows-latest`. That proves the facade contract and cross-repo wiring, but it is not a substitute for trusted-runner production use.

## Release mapping

- The default backend mapping is pinned in `comparevi-backend-ref.txt`. Treat that file as the source of truth for the backend commit used by the facade.
- Immutable facade tags such as `v1.0.0`, `v1.0.1`, and later patch tags should each map to a single reviewed backend ref through that file.
- The moving major tag `v1` should point to the latest compatible facade release after smoke passes.

## Release workflow

- Use `.github/workflows/release.yml` to automate backend pin bumps and facade publication.
- Dispatch it with:
  - `backend_ref`: branch, tag, or commit in `LabVIEW-Community-CI-CD/compare-vi-cli-action`
  - `immutable_tag`: new immutable facade tag such as `v1.0.2`
  - `major_tag`: moving compatibility tag, normally `v1`
  - `publish`: `false` for smoke-only rehearsal, `true` for a real release from `main`
- The workflow resolves `backend_ref` to a commit SHA, runs both local and external smoke against that candidate backend, and uploads a release-plan artifact before any publish step runs.
- When `publish: true`, the workflow then updates `comparevi-backend-ref.txt`, creates the immutable tag, publishes GitHub Release notes with the mapped backend ref, and finally moves `v1`.
- Failure before the final major-tag step leaves `v1` unchanged.

## Repository policy

- The lightweight baseline for `main` is:
  - `lint` from `.github/workflows/ci.yml`
  - `smoke-local` from `.github/workflows/smoke.yml`
  - `smoke-external` from `.github/workflows/smoke.yml`
- `smoke.yml` runs on pull requests to `main`, pushes to `main`, and manual dispatch so the public facade contract is covered before merge and after publish.
- `release.yml` validates itself on pull requests that touch release plumbing and remains the only path that should publish immutable tags or advance `v1`.
- The branch protection source of truth is `.github/branch-protection-main.json`.
- Apply or refresh the policy with:

```bash
gh api repos/LabVIEW-Community-CI-CD/comparevi-history/branches/main/protection \
  --method PUT \
  --input .github/branch-protection-main.json
```

- The policy intentionally relies on required status checks instead of required reviewer gates so the manual release workflow can update `comparevi-backend-ref.txt` and tags after smoke passes.

## Notes

- The facade is a thin wrapper over `compare-vi-cli-action`; consumers should treat the pinned backend ref as part of the release contract.
- Tracking epic: https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/841
