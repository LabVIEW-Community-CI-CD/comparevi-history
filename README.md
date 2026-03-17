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
- Emits `comparevi-history/shared-evidence@v1` as the canonical cross-entrypoint evidence receipt that both curated PR
  diagnostics and manual exploration can share without sharing policy wrappers.
- Emits `comparevi-history/changed-vi-discovery@v1` as the changed-VI discovery receipt for automatic PR diagnostics.
- Emits `comparevi-history/pr-run@v1` as the aggregate pull-request diagnostics receipt that points reviewers and
  downstream processors at per-target public-run and shared-evidence surfaces.
- Renders reviewer-facing markdown from the bundled helper resolved through `tooling-path` instead of copied inline
  consumer scripts.
- Verifies the downloaded bundle against the published release digest before extraction.
- Uses the repo-pinned backend release tag in `comparevi-backend-ref.txt` unless `comparevi_ref` is explicitly
  overridden.
- Falls back to a backend source checkout only for trusted maintainer overrides that target unreleased refs.

## Public platform boundary

- Consumer repositories define what to inspect and what automatic PR behavior is allowed through checked-in target catalogs and PR policy files.
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
- `shared-evidence-path`
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
- `mode-summary-json-path`
- `flag-list`
- `history-report-md`
- `history-report-html`

`tooling-path` points to either the extracted `CompareVI.Tools` bundle root or, for trusted maintainer fallbacks only,
 the temporary backend checkout path.

Manual exploration workflows emit additive planning receipts alongside the action outputs:

- `shared-evidence.json` (`comparevi-history/shared-evidence@v1`)
- `revision-catalog.json` (`comparevi-history/revision-catalog@v1`)
- `chunk-plan.json`
- `chunk-receipts/`
- `exploration-run.json` (`comparevi-history/exploration-run@v1`)
- `evidence-graph.json` (`comparevi-history/evidence-graph@v1`)
- `index.md`
- `index.html`
- `timeline.md`
- `timeline.html`
- `manual-vi-exploration-bundle.zip`
- `bundle-manifest.json`

Automatic pull-request diagnostics workflows emit additive PR-scope receipts alongside the action outputs:

- `changed-vi-discovery.json` (`comparevi-history/changed-vi-discovery@v1`)
- `pr-target-runs-manifest.json`
- `pr-run.json` (`comparevi-history/pr-run@v1`)
- `pr-comment.md`
- `pr-step-summary.md`

Corpus/downstream-processing pilots can also emit additive processing receipts:

- `downstream-processor-summary.json` (`comparevi-history/downstream-processor-summary@v1`)

## Manual VI exploration workflow

Trusted consumer repositories can expose arbitrary repo-relative `.vi` exploration through the reusable workflow
[`./.github/workflows/manual-vi-exploration.yml`](.github/workflows/manual-vi-exploration.yml) plus a thin consumer
wrapper such as
[`docs/examples/comparevi-history-manual-vi-exploration.yml`](docs/examples/comparevi-history-manual-vi-exploration.yml).

The current execution slice stays additive on top of the discovery-first baseline:

- operator supplies `vi_path`
- the platform validates the selected path fail-closed
- trusted manual exploration now defaults to raw execution: `modes=full` plus `noise_policy=include`
- the platform emits `revision-catalog.json` for the selected ref lineage
- the platform plans deterministic chunk receipts/manifests
- the platform executes planned chunks serially through the consumer's trusted hosted NI Linux adapter
- the platform keeps unsuppressed LVCompare output in-band and surfaces deterministic metadata summaries for capture
  artifacts such as images instead of collapsing them into generic noise counts
- the platform emits `exploration-run.json` as the top-level execution and aggregation receipt
- the platform emits `shared-evidence.json` as the shared machine-readable evidence core that manual exploration and
  curated PR diagnostics can both surface
- the platform emits `evidence-graph.json` as the canonical unsuppressed evidence contract for downstream processing
- the platform keeps `categoryCounts` semantic and emits structured `comparisonPairs` separately so HTML-rendered
  compare identity fragments remain machine-readable instead of leaking into category keys
- the canonical evidence graph also surfaces continuity segments/breaks, chunk execution outputs, preview images, and
  render/artifact surfaces explicitly instead of leaving downstream tooling to scrape presentation-only reports
- the platform writes `index.md` and `index.html` as the primary human review surfaces for manual exploration
- the primary index surfaces navigate deterministically by continuity segment, mode, comparison pair, and chunk before
  dropping into the deeper timeline and per-chunk reports
- the GitHub step summary stays a bounded teaser surface and points reviewers back to the richer static index/gallery
- the platform also writes `timeline.md` and `timeline.html` for the deeper chunk-by-chunk timeline view
- the platform packages the timeline, receipts, and per-chunk reports into one deterministic bundle
- existing curated `target_spec_path` plus `target_id` workflows remain unchanged

When bundle packaging fails after execution succeeded, the platform preserves the receipts, leaves the loose artifacts
available, and degrades the final exploration run instead of hiding the packaging failure.

Because reusable workflows do not automatically expose the called workflow repository as a local checkout, the consumer
wrapper should keep `platform_ref` aligned with the same release ref used in the `uses:` pin.

## Automatic pull request diagnostics workflow

Trusted consumer repositories can expose automatic PR diagnostics for changed VIs through the reusable workflow
[`./.github/workflows/pull-request-diagnostics.yml`](.github/workflows/pull-request-diagnostics.yml) plus a thin
consumer wrapper such as
[`docs/examples/comparevi-history-pull-request-diagnostics.yml`](docs/examples/comparevi-history-pull-request-diagnostics.yml)
and a checked-in PR policy such as
[`docs/examples/comparevi-history-pr-policy.json`](docs/examples/comparevi-history-pr-policy.json).

The current first slice stays intentionally narrow:

- the platform discovers changed `.vi` files from the live pull request context and writes `changed-vi-discovery.json`
- the trusted target catalog and trusted PR policy stay on the pull request base checkout, not the candidate head checkout
- the trusted consumer-local hosted NI Linux adapter stays on the pull request base checkout, not the candidate head
  checkout
- the candidate head checkout supplies the repository root and file content for execution
- only PR-policy-eligible catalog targets whose `path` matches a changed `.vi` path are executed
- same-repo pull requests can auto-run immediately
- cross-repository and fork pull requests fail closed by producing a blocked discovery receipt instead of executing the
  backend
- each matched target reuses the existing `request.json`, `public-run.json`, `shared-evidence.json`, and reviewer
  artifact path without inventing a second backend execution contract
- the workflow aggregates those per-target runs into `pr-run.json`, `pr-comment.md`, and `pr-step-summary.md`
- publication of pull-request comments remains a later policy slice; this first workflow writes the deterministic
  comment body but does not post it automatically

This keeps consumer repositories thin while the automatic PR surface stabilizes:

- target ids still live in `.github/comparevi-history-targets.json`
- PR path filters, allowlists, mode narrowing, branch-budget defaults, and reviewer-surface toggles live in `.github/comparevi-history-pr-policy.json`
- execution remains bundle-backed and platform-owned
- reviewer-facing consumers get stable receipt and markdown paths before comment publication policy is widened

## Local manual exploration fast loop

For report iteration on a trusted maintainer machine, use
[`scripts/Invoke-CompareVIHistoryManualExplorationFastLoop.ps1`](scripts/Invoke-CompareVIHistoryManualExplorationFastLoop.ps1).
It reuses the released backend pin, the existing request/public-run receipts, and the consumer's trusted
`Tooling/Invoke-CompareVIHistoryHostedNILinux.ps1` adapter instead of inventing a separate local artifact shape.

The default results root is:

- `tests/results/ref-compare/history-exploration/local-fast-loop`

The local fast loop writes:

- `revision-catalog.json`
- `history/public/request.json`
- `history/public/public-run.json`
- `history-summary.json`
- `history-report.md`
- `history-report.html`
- `local-fast-loop.json`
- `local-fast-loop-summary.md`
- `mode-summary.json`

Example against the first proving consumer:

```powershell
pwsh -NoLogo -NoProfile -File scripts/Invoke-CompareVIHistoryManualExplorationFastLoop.ps1 `
  -ConsumerRepositoryRoot C:\dev\labview-icon-editor `
  -ConsumerRef develop `
  -ViPath 'Tooling/deployment/VIP_Post-Install Custom Action.vi'
```

The script resolves the released backend bundle by default. For unreleased backend iteration, pass `-ToolingRoot`
explicitly instead of relying on maintainer-only source-checkout fallback behavior.

For faster local iteration, maintainers can still pass existing backend bounds such as `-MaxPairs`, but the local loop
keeps the hosted artifact contract and does not replace the hosted workflow as the source of truth.
Its defaults now match the raw manual exploration surface: `-Mode full` and `-NoisePolicy include`.

## Corpus evidence indexing

For corpus-scale deterministic processing, use
[`scripts/Write-CompareVIHistoryCorpusIndex.ps1`](scripts/Write-CompareVIHistoryCorpusIndex.ps1) to aggregate
existing `shared-evidence.json` and `evidence-graph.json` receipts into one machine-readable corpus manifest.

The writer is intentionally contract-first:

- it consumes an explicit evidence list instead of generating repo-wide evidence in this slice
- it writes `corpus-index.json` as the top-level manifest (`comparevi-history/corpus-index@v1`) for many VI targets
- it paginates targets into `pages/corpus-page-*.json` (`comparevi-history/corpus-page@v1`) so downstream processors can resume by page ordinal
- it writes `downstream-processing-manifest.json` (`comparevi-history/downstream-processing-manifest@v1`) so other tooling can consume the evidence contract without scraping
  `index.md`, `index.html`, `timeline.md`, or `timeline.html`
- [`scripts/Write-CompareVIHistoryDownstreamProcessorSummary.ps1`](scripts/Write-CompareVIHistoryDownstreamProcessorSummary.ps1)
  consumes only `downstream-processing-manifest.json` plus `pages/corpus-page-*.json` and writes
  `downstream-processor-summary.json` (`comparevi-history/downstream-processor-summary@v1`) for deterministic program
  consumption
- it fails closed if the explicit evidence list spans multiple consumer repositories or refs
- it keeps completeness machine-readable at corpus level and page level instead of hiding degradation behind summary text

The current continuation contract is deliberately simple:

- ordering: `target-path-asc`
- unit kind: `corpus-page`
- continuation mode: `page-ordinal`
- page boundaries are deterministic from the explicit evidence list plus `-PageSize`
- incomplete targets remain in the corpus index and are marked as incomplete instead of being dropped

Minimum viable pilot after the single-VI evidence model is stable:

- consumer: `LabVIEW-Community-CI-CD/labview-icon-editor-demo`
- selection strategy: explicit evidence list built from successful manual exploration runs
- initial seed targets:
  - `Tooling/deployment/VIP_Post-Install Custom Action.vi`
  - `Tooling/deployment/VIP_Pre-Install Custom Action.vi`
- page size: `2`
- downstream tools should consume `comparevi-history/shared-evidence@v1`,
  `comparevi-history/evidence-graph@v1`, `comparevi-history/corpus-page@v1`, and
  `comparevi-history/downstream-processing-manifest@v1` directly
- the first downstream processor stays page-ordinal resumable and surfaces strict page inventory, target inventory,
  completeness/degradation counts, preview-image totals, and next-page continuation metadata without markdown and HTML
  scraping
- `tests/fixtures/corpus-pilot-v1` is the canonical pilot contract baseline for golden artifact tests against the
  released corpus receipts

This keeps the first corpus pilot deterministic and unsuppressed without inventing repo-wide generation before the
single-VI evidence contracts have stabilized.
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

## Pull request policy

Automatic PR diagnostics consumers should also check in a PR policy using `comparevi-history/pr-policy@v1`. The example source of truth in this repository is [`docs/examples/comparevi-history-pr-policy.json`](docs/examples/comparevi-history-pr-policy.json). Consumer repos should copy that pattern into `.github/comparevi-history-pr-policy.json` and keep automatic PR policy there:

- include/exclude path globs for changed VI discovery
- allowed target ids for automatic PR execution
- maximum changed-VI count per run
- unmatched changed-VI fail-closed behavior
- public mode narrowing for reviewer surfaces
- branch-budget defaults and no-diff artifact policy
- reviewer comment and step-summary emission toggles
- trust defaults for fork PR blocking

## Trust boundaries

- Treat this action as a trusted-runner workflow primitive. Real VI History diagnostics should run only on trusted
  maintainer-controlled runners, either on self-hosted Windows with the backend prerequisites already installed or
  through a hosted NI Linux container path wired by a repo-local adapter such as
  `Tooling/Invoke-CompareVIHistoryHostedNILinux.ps1`.
- The action fails closed on `pull_request` and `pull_request_target` events for forked repositories. For public
  repositories, use comment-gated or maintainer-dispatched workflows for PR diagnostics instead of running the facade
  directly on fork PR events.
- Automatic PR diagnostics reusable workflows should only auto-run on same-repo `pull_request` events. Fork and other
  cross-repository pull requests should block and point reviewers at maintainer-dispatched or comment-gated trusted
  flows instead of executing the backend automatically.
- Public reviewer surfaces accept only explicit scoped modes: `attributes`, `front-panel`, and `block-diagram`.
  Aggregate aliases such as `default`, `full`, and `all` are not part of the public platform contract.
- Consumer-ready public PR diagnostics templates are published in `docs/SAFE_PR_DIAGNOSTICS_TEMPLATES.md`.
- Reviewer-facing consumers should use `public-comment-path`, `public-step-summary-path`, `public-run-path`, and
  `shared-evidence-path` instead of rebuilding evidence from raw backend manifests. Automatic PR diagnostics also expose
  `changed-vi-discovery.json` and `pr-run.json` for aggregate pull-request automation.
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
- When `publish: true`, the workflow now verifies that `main` already contains the required `comparevi-backend-ref.txt`
  and published-template changes for the requested release. If readiness says preparation is still required, merge a
  prep PR first and rerun the workflow from `main`.
- Publish also requires the current `main` tip to stay unchanged through smoke. If `main` advances before the publish
  job runs, rerun the release workflow so the immutable tag maps to the exact `main` commit that passed smoke.
- Once `main` is already aligned, the workflow creates the immutable tag, publishes GitHub Release notes with the
  mapped backend release tag and source SHA, and finally moves `v1`.
- Failure before the final major-tag step leaves `v1` unchanged.

## Repository policy

- The lightweight baseline for `main` is:
  - `lint` from `.github/workflows/ci.yml`
  - `smoke-local` from `.github/workflows/smoke.yml`
  - `smoke-external` from `.github/workflows/smoke.yml`
- `smoke.yml` runs on pull requests to `main`, pushes to `main`, and manual dispatch so the public platform contract is
  covered before merge and after publish.
- `.github/workflows/published-consumer-validation.yml` validates the released `v1` tag and the latest immutable facade
  tag against a checked-out external consumer repository by writing a temporary
  `.github/comparevi-history-targets.json` catalog and consuming the action-owned public outputs from that synthesized
  target.
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
  workflow can publish tags from already-reviewed `main` after smoke passes, while repo-content updates still flow
  through normal pull requests.

## Notes

- `comparevi-history` is the canonical consumer-facing VI history platform boundary.
- `compare-vi-cli-action` remains the backend bundle and execution contract below it.
- Consumer repositories should stay thin: checked-in target catalogs, workflow trigger wiring, and repo-local policy.
- For unreleased backend testing, maintainers may still override `comparevi_ref` in a trusted context. That path is
  intentionally explicit and source-coupled.
- Tracking epic: https://github.com/LabVIEW-Community-CI-CD/comparevi-history/issues/24
- Platform RFC: [`docs/VI_HISTORY_EXPLORATION_PLATFORM_RFC.md`](docs/VI_HISTORY_EXPLORATION_PLATFORM_RFC.md)
- PR integration RFC:
  [`docs/COMPAREVI_HISTORY_PR_INTEGRATION_SURFACE_RFC.md`](docs/COMPAREVI_HISTORY_PR_INTEGRATION_SURFACE_RFC.md)
