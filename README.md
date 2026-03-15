# comparevi-history

Consumer-facing VI history platform surface for LabVIEW repositories. `comparevi-history` owns the public orchestration
contract, while `compare-vi-cli-action` remains the pinned backend tooling bundle provider.

Primary consumer syntax:

```yaml
- uses: actions/checkout@v5
  with:
    fetch-depth: 0

- uses: LabVIEW-Community-CI-CD/comparevi-history@v1
  with:
    target_spec_path: .github/comparevi-history-targets.json
    target_id: vip-post-install-custom-action
    reviewer_surface: manual
```

Legacy direct invocation remains available for maintainers:

```yaml
- uses: LabVIEW-Community-CI-CD/comparevi-history@v1
  with:
    target_path: path/to/file.vi
```

## What it does

- Requires the caller repository to already be checked out.
- Downloads the pinned `CompareVI.Tools` release bundle from `LabVIEW-Community-CI-CD/compare-vi-cli-action` for
  normal runs.
- Normalizes a consumer-owned target-spec request into `comparevi-history/request@v1`.
- Invokes the existing backend history facade and preserves `comparevi-tools/history-facade@v1` as the backend
  summary surface.
- Emits `comparevi-history/public-run@v1` plus stable public artifact paths for comments, step summaries, and replay.
- Renders reviewer-facing markdown from the bundled helper resolved through `tooling-path` instead of copied inline
  consumer scripts.
- Verifies the downloaded bundle against the published release digest before extraction.
- Uses the repo-pinned backend release tag in `comparevi-backend-ref.txt` unless `comparevi_ref` is explicitly
  overridden.
- Falls back to a backend source checkout only for trusted maintainer overrides that target unreleased refs.

## Public platform boundary

- Consumer repositories define what to inspect through a checked-in target catalog.
- `comparevi-history` defines how the public history surface resolves requests, runs the backend, and renders reviewer
  artifacts.
- `compare-vi-cli-action` defines how the backend tooling executes and keeps `comparevi-tools/history-facade@v1`
  backward compatible.

## Inputs

| Input | Required | Default | Notes |
| --- | --- | --- | --- |
| `target_spec_path` | No |  | Consumer-owned target catalog path. Preferred for public workflows. |
| `target_id` | No |  | Target identifier from the consumer target catalog. |
| `target_path` | No |  | Legacy repository-relative VI path. Prefer `target_spec_path` plus `target_id`. |
| `start_ref` | No | `HEAD` | Start branch/tag/commit. |
| `end_ref` | No |  | Optional end ref. |
| `source_branch_ref` | No |  | Optional source branch ref for branch-budget enforcement. |
| `max_branch_commits` | No |  | Optional maximum source-branch commit budget. |
| `max_pairs` | No |  | Optional cap on adjacent commit pairs. |
| `max_signal_pairs` | No | `2` | Optional cap on surfaced signal pairs. |
| `noise_policy` | No | `collapse` | `include`, `collapse`, or `skip`. |
| `mode` | No |  | Comma/semicolon list of compare modes. Public workflows must use only `attributes`, `front-panel`, and `block-diagram`. |
| `results_dir` | No | `tests/results/ref-compare/history` | Relative to the caller repository root unless absolute. |
| `repository_root` | No |  | Optional caller repository root when checkout is not at `github.workspace`. |
| `consumer_repository` | No |  | Consumer repository slug recorded in the normalized request receipt. |
| `consumer_ref` | No |  | Consumer ref recorded in the normalized request receipt. |
| `reviewer_surface` | No | `none` | `none`, `manual`, or `comment-gated`. |
| `reviewer_issue_number` | No |  | Issue number for comment-gated reviewer surfaces. |
| `reviewer_pull_request_number` | No |  | Pull request number for manual reviewer surfaces. |
| `reviewer_is_fork` | No |  | Whether the reviewer surface is operating on a fork head. |
| `container_image` | No |  | Execution plane/container string included in rendered reviewer outputs. |
| `comparevi_repository` | No | `LabVIEW-Community-CI-CD/compare-vi-cli-action` | Backend tooling repository. Repository overrides are maintainer-only and require an explicit `comparevi_ref`. |
| `comparevi_ref` | No |  | Backend release tag or maintainer-only backend ref override. If omitted, the action uses the repo-pinned backend release tag in `comparevi-backend-ref.txt`. |
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

The action preserves the existing backend outputs and adds the public platform receipts:

- `comparevi-ref`
- `tooling-path`
- `repository-root`
- `consumer-repository`
- `consumer-ref`
- `target-id`
- `target-spec-path`
- `target-path`
- `request-path`
- `public-run-path`
- `public-comment-path`
- `public-step-summary-path`
- `manifest-path`
- `results-dir`
- `history-summary-json`
- `mode-count`
- `total-processed`
- `total-diffs`
- `stop-reason`
- `final-status`
- `final-reason`
- `category-counts-json`
- `bucket-counts-json`
- `mode-manifests-json`
- `requested-mode-list`
- `executed-mode-list`
- `mode-list`
- `mode-summary-markdown`
- `flag-list`
- `history-report-md`
- `history-report-html`

`tooling-path` points to either the extracted `CompareVI.Tools` bundle root or, for trusted maintainer fallbacks only,
 the temporary backend checkout path.

## Consumer target catalog

Public consumers should check in a target catalog using `comparevi-history/consumer-targets@v1`. The example source of
truth in this repository is [`docs/examples/comparevi-history-consumer-targets.json`](docs/examples/comparevi-history-consumer-targets.json).
Consumer repos should copy that pattern into `.github/comparevi-history-targets.json` and keep only policy/config there:

- target identifiers
- repository-relative VI paths
- explicit public modes (`attributes`, `front-panel`, `block-diagram`)
- optional branch-budget policy
- optional reviewer-surface hints

Do not copy backend renderers or repo-local history execution logic into consumer repositories.

## Trust boundaries

- Treat this action as a trusted-runner workflow primitive. Real VI History diagnostics should run only on trusted
  maintainer-controlled runners, either on self-hosted Windows with the backend prerequisites already installed or
  through a hosted NI Linux container path wired by a repo-local adapter such as
  `Tooling/Invoke-CompareVIHistoryHostedNILinux.ps1`.
- The action fails closed on `pull_request` and `pull_request_target` events for forked repositories. For public
  repositories, use comment-gated or maintainer-dispatched workflows for PR diagnostics instead of running the facade
  directly on fork PR events.
- Public reviewer surfaces accept only explicit scoped modes: `attributes`, `front-panel`, and `block-diagram`.
  Aggregate aliases such as `default`, `full`, and `all` are not part of the public platform contract.
- Consumer-ready public PR diagnostics templates are published in `docs/SAFE_PR_DIAGNOSTICS_TEMPLATES.md`.
- Reviewer-facing consumers should use `public-comment-path`, `public-step-summary-path`, `public-run-path`, and
  `history-summary-json` instead of rebuilding comments from raw backend manifests.
- `comparevi_repository`, `comparevi_ref`, and `invoke_script_path` are maintainer-only overrides. The action rejects
  them when the PR context is not provably repo-local and trusted, and normal consumer workflows should leave them at
  their defaults.
- When `comparevi_ref` targets a published backend release tag, the action stays on the bundle path. When a maintainer
  points `comparevi_ref` at an unreleased branch/commit/SHA, the action falls back to a source checkout for that
  explicit override only.
- Do not expose this action to untrusted fork pull requests with write-scoped tokens or secrets. `pull_request_target`
  against a fork is treated as unsafe by default because the platform assumes trusted refs and a trusted runner.
- The published PR-diagnostics templates in `docs/SAFE_PR_DIAGNOSTICS_TEMPLATES.md` prefer `ubuntu-latest` plus a
  serial `docker pull` of `nationalinstruments/labview:2026q1-linux`, because that matches the fork-ready hosted-runner
  path validated in downstream consumers.
- Hosted smoke coverage in this repo uses an LVCompare stub on `windows-latest`. That proves the contract and cross-repo
  wiring, but it is not a substitute for trusted-runner production use.

## Release mapping

- The default backend mapping is pinned in `comparevi-backend-ref.txt`. Treat that file as the source of truth for the
  backend release tag used by the platform.
- The pinned backend release must publish a `CompareVI.Tools-v<release-version>.zip` asset and its embedded
  `comparevi-tools-release.json` metadata.
- For hosted NI Linux diagnostics, the pinned backend release must also publish
  `consumerContract.hostedNiLinuxRunner`, `consumerContract.historyFacade`, and
  `consumerContract.diagnosticsCommentRenderer`.
- Immutable facade tags such as `v1.0.0`, `v1.0.1`, and later patch tags each map to a single reviewed backend release
  tag through `comparevi-backend-ref.txt`.
- The moving major tag `v1` should point to the latest compatible facade release after smoke passes.

## Release workflow

- Use `.github/workflows/release.yml` to automate backend pin bumps and facade publication.
- Dispatch it with:
  - `backend_ref`: backend release tag to pin, or another backend ref that already resolves to a published
    `CompareVI.Tools` bundle
  - `immutable_tag`: new immutable facade tag such as `v1.2.3`
  - `major_tag`: moving compatibility tag, normally `v1`
  - `publish`: `false` for smoke-only rehearsal, `true` for a real release from `main`
- The workflow resolves `backend_ref` to a backend release tag plus source SHA, runs both local and external smoke
  against that candidate bundle-backed backend, and uploads a release-plan artifact before any publish step runs.
- When `publish: true`, the workflow then updates `comparevi-backend-ref.txt`, creates the immutable tag, publishes
  GitHub Release notes with the mapped backend release tag and source SHA, and finally moves `v1`.
- Failure before the final major-tag step leaves `v1` unchanged.

## Repository policy

- The lightweight baseline for `main` is:
  - `lint` from `.github/workflows/ci.yml`
  - `smoke-local` from `.github/workflows/smoke.yml`
  - `smoke-external` from `.github/workflows/smoke.yml`
- `smoke.yml` runs on pull requests to `main`, pushes to `main`, and manual dispatch so the public platform contract is
  covered before merge and after publish.
- `.github/workflows/published-consumer-validation.yml` validates the released `v1` tag and the latest immutable facade
  tag against `ni/labview-icon-editor` by default, while still allowing aligned downstream forks to override the
  consumer repository/ref explicitly.
- `release.yml` validates itself on pull requests that touch release plumbing and remains the only path that should
  publish immutable tags or advance `v1`.
- The branch protection source of truth is `.github/branch-protection-main.json`.
- `branch-protection-drift.yml` runs weekly and on maintainer dispatch to compare the live `main` protection settings
  with `.github/branch-protection-main.json`, upload the expected/live snapshots, and fail with a remediation command if
  drift is detected.
- The drift workflow prefers a repo secret named `COMPAREVI_BRANCH_PROTECTION_TOKEN` and falls back to `GITHUB_TOKEN`.
  If the fallback token cannot read branch protection, the workflow fails with instructions to configure the secret.
- Apply or refresh the policy with:

```bash
gh api repos/LabVIEW-Community-CI-CD/comparevi-history/branches/main/protection \
  --method PUT \
  --input .github/branch-protection-main.json
```

- The policy intentionally relies on required status checks instead of required reviewer gates so the manual release
  workflow can update `comparevi-backend-ref.txt` and tags after smoke passes.

## Notes

- `comparevi-history` is the canonical consumer-facing VI history platform boundary.
- `compare-vi-cli-action` remains the backend bundle and execution contract below it.
- Consumer repositories should stay thin: checked-in target catalogs, workflow trigger wiring, and repo-local policy.
- For unreleased backend testing, maintainers may still override `comparevi_ref` in a trusted context. That path is
  intentionally explicit and source-coupled.
- Tracking epic: https://github.com/LabVIEW-Community-CI-CD/compare-vi-cli-action/issues/841
