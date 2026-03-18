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
- Emits `comparevi-history/changed-vi-discovery@v2` as the dynamic changed-VI discovery receipt for automatic PR
  diagnostics that operate on raw repo-relative paths without a checked-in target catalog.
- Emits `comparevi-history/pr-run@v2` as the aggregate pull-request diagnostics receipt for the dynamic changed-VI PR
  surface, including `selectedTargets`, artifact index paths, and sticky-comment publication inputs.
- Emits `comparevi-history/pr-preview-manifest@v1` as the normalized preview-image manifest for dynamic PR diagnostics,
  index galleries, and sticky-comment preview publication.
- Emits `comparevi-history/review-bundle@v1` as the canonical compiled review graph for pair-level normalization,
  reviewer interpretation, and renderer inputs.
- Publishes `comparevi-history/review-compiler-release@v1` as the self-contained review-compiler release manifest for
  immutable GitHub Release assets.
- Emits `comparevi-history/pr-comment-publication@v1` as the `workflow_run` publication receipt for sticky PR comments.
- Emits `comparevi-history/agent-canary-policy@v1` as the repo-owned governance contract for same-repo canary proof
  lanes that exercise the PR diagnostics surface without touching production VIs.
- Emits `comparevi-history/agent-canary-evaluation@v1` as the `workflow_run` evaluation receipt for agent-canary
  publication proofs.
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
- `review-bundle.json` (`comparevi-history/review-bundle@v1`)
- `pr-run.json` (`comparevi-history/pr-run@v1`)
- `pr-preview-manifest.json` (`comparevi-history/pr-preview-manifest@v1`)
- `pr-comment.md`
- `pr-step-summary.md`

Agent-canary proof workflows emit one additive publication-evaluation receipt alongside the action outputs:

- `agent-canary-evaluation.json` (`comparevi-history/agent-canary-evaluation@v1`)

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

## Automatic pull request diagnostics workflows

Trusted consumer repositories can expose automatic PR diagnostics for changed VIs through the standard dynamic-path PR
surface:

- execution reusable workflow:
  [`./.github/workflows/pull-request-diagnostics-auto.yml`](.github/workflows/pull-request-diagnostics-auto.yml)
- publication reusable workflow:
  [`./.github/workflows/pull-request-diagnostics-publish.yml`](.github/workflows/pull-request-diagnostics-publish.yml)
- thin consumer execution wrapper:
  [`docs/examples/comparevi-history-pull-request-diagnostics-auto.yml`](docs/examples/comparevi-history-pull-request-diagnostics-auto.yml)
- thin consumer publication wrapper:
  [`docs/examples/comparevi-history-pull-request-diagnostics-publish.yml`](docs/examples/comparevi-history-pull-request-diagnostics-publish.yml)
- checked-in dynamic PR policy source:
  [`docs/examples/comparevi-history-pr-policy-v2.json`](docs/examples/comparevi-history-pr-policy-v2.json)

The standard changed-VI PR surface is intentionally policy-driven and consumer-thin:

- the execution workflow discovers changed `.vi` files from the live pull request context and writes
  `changed-vi-discovery.json` (`comparevi-history/changed-vi-discovery@v2`)
- `discovery.selectionMode = dynamic-paths`, so changed files do not need to exist in
  `.github/comparevi-history-targets.json`
- the trusted PR policy stays on the pull request base checkout, not the candidate head checkout
- the trusted consumer-local hosted NI Linux adapter stays on the pull request base checkout, not the candidate head
  checkout
- the candidate head checkout supplies the repository root and file content for execution
- `selectedTargets[]` records the deterministic synthetic target id, normalized repo-relative path, explicit public mode
  list, and resolved `sourceBranchRef` from the pull request base
- `maxChangedViCount = 10` is the default fail-closed overflow contract for the standard dynamic PR surface
- the execution workflow keeps `NoisePolicy=include` so artifact-hosted evidence is unsuppressed
- each selected target reuses the existing `request.json`, `public-run.json`, `shared-evidence.json`, and
  reviewer-facing artifact paths without inventing a second backend execution contract
- the execution workflow aggregates those per-target runs into `pr-run.json`, `pr-preview-manifest.json`,
  `pr-comment.md`, `pr-step-summary.md`, `index.md`, and `index.html`
- the aggregate index surfaces are image-first and can show bounded base/head previews from the real compare-report
  PNGs already produced by the backend
- the publication workflow runs on `workflow_run`, downloads the execution artifact bundle, and creates or updates one
  sticky PR comment without checking out or executing candidate PR code
- when preview pairs exist, the publication workflow writes a bounded preview-image surface to a repo-owned branch and
  embeds those previews in the sticky PR comment as the reviewer-facing entrypoint
- same-repo pull requests can auto-run immediately
- fork pull requests can auto-run on the read-only `pull_request` execution workflow and then publish the sticky PR
  comment from the privileged `workflow_run` publisher

This keeps consumer repositories thin while giving reviewers one stable entrypoint:

- the PR comment is the sticky entrypoint
- the sticky PR comment can include a bounded base/head preview gallery for selected comparisons
- the full unsuppressed review surface stays in the artifact-hosted `index.md` and `index.html`
- execution remains bundle-backed and platform-owned
- consumer repositories own only the checked-in policy file, branch trigger wiring, and permissions policy

## Agent-canary evaluation workflow

Trusted consumer repositories can add one governed same-repo-only canary proof lane on top of the automatic PR
diagnostics/publication surface:

- evaluator reusable workflow:
  [`./.github/workflows/pull-request-diagnostics-canary-evaluate.yml`](.github/workflows/pull-request-diagnostics-canary-evaluate.yml)
- thin consumer evaluation wrapper:
  [`docs/examples/comparevi-history-agent-canary-evaluate.yml`](docs/examples/comparevi-history-agent-canary-evaluate.yml)
- checked-in canary policy source:
  [`docs/examples/comparevi-history-agent-canary-policy.json`](docs/examples/comparevi-history-agent-canary-policy.json)

The canary lane is intentionally narrow:

- same-repo only
- one long-lived draft PR, not a stream of throwaway PRs
- branch prefix `agent-canary/`
- required label `agent-canary`
- a dedicated canary VI path instead of production VIs
- no auto-merge

The evaluator consumes publication receipts and artifact contents only:

- it downloads the publication artifact from `CompareVI History Pull Request Diagnostics Publish`
- it resolves that publication artifact from the completed publisher run instead of requiring the consumer to predict a
  publisher-artifact name from the `workflow_run` payload
- it reads `pr-comment-publication.json`, `pr-run.json`, `changed-vi-discovery.json`, `pr-preview-manifest.json`,
  `pr-comment.md`, `index.md`, and `index.html`
- it verifies the changed-VI count, selected-target count, canonical canary path, explicit public modes, raw
  `noisePolicy = include`, sticky comment publication, preview publication, and `artifact-index` reviewer surface
- the checked-in canary policy can also declare reviewer-surface invariants through `reviewerSurfaceContract`, including
  required workspace sections, required reviewer surfaces, exact evidence links, and bounded comment preview cards
- it emits `agent-canary-evaluation.json` (`comparevi-history/agent-canary-evaluation@v1`)
- it fails closed for canary regressions and skips cleanly for non-canary PRs

This keeps the canary lane machine-readable and bounded:

- the long-lived draft PR remains the durable proof surface
- the sticky PR comment remains the reviewer entrypoint
- the full evidence stays artifact-hosted
- human feature PRs remain unaffected by autonomous mutation in this pilot

### Legacy catalog-matched PR diagnostics workflow

The earlier catalog-matched PR surface remains available and additive through the reusable workflow
[`./.github/workflows/pull-request-diagnostics.yml`](.github/workflows/pull-request-diagnostics.yml) plus a thin
consumer wrapper such as
[`docs/examples/comparevi-history-pull-request-diagnostics.yml`](docs/examples/comparevi-history-pull-request-diagnostics.yml)
and a checked-in PR policy such as
[`docs/examples/comparevi-history-pr-policy.json`](docs/examples/comparevi-history-pr-policy.json).

That legacy slice remains intentionally narrower:

- target ids still live in `.github/comparevi-history-targets.json`
- only PR-policy-eligible catalog targets whose `path` matches a changed `.vi` path are executed
- cross-repository and fork pull requests fail closed by producing a blocked discovery receipt instead of executing the
  backend unless a maintainer-triggered caller explicitly sets `allow_trusted_fork_execution: true` and the checked-in
  PR policy allows `trust.forkBehavior = maintainer-dispatch`
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

## Local review facade

For local-first reviewer iteration, use
[`scripts/Invoke-CompareVIHistoryLocalReview.ps1`](scripts/Invoke-CompareVIHistoryLocalReview.ps1).
It keeps the NI Linux execution plane from the trusted local fast loop, but compiles the same reviewer bundle and
workspace shape that the automatic PR diagnostics surface publishes.

The canonical local receipt is `local-review.json` (`comparevi-history/local-review@v1`).
The script also writes PR-shaped compatibility projections so the local and hosted surfaces share one bundle layout:

- `local-review-pr-policy.json`
- `changed-vi-discovery.json`
- `pr-target-runs-manifest.json`
- `review-bundle.json`
- `pr-preview-manifest.json`
- `pr-run.json`
- `pr-comment.md`
- `pr-step-summary.md`
- `index.md`
- `index.html`
- `local-review-summary.md`

The default results root is:

- `tests/results/local-review`

The primary local human review surface is `index.html`.
`pr-comment.md` and the other PR-shaped receipts are compatibility projections so local iteration and hosted PR runs
stay on one deterministic bundle shape.

Two selection modes are supported:

- explicit paths:

```powershell
pwsh -NoLogo -NoProfile -File scripts/Invoke-CompareVIHistoryLocalReview.ps1 `
  -ConsumerRepositoryRoot C:\dev\labview-icon-editor `
  -ViPath 'Tooling/deployment/VIP_Post-Install Custom Action.vi'
```

- git diff between base and head refs:

```powershell
pwsh -NoLogo -NoProfile -File scripts/Invoke-CompareVIHistoryLocalReview.ps1 `
  -ConsumerRepositoryRoot C:\dev\labview-icon-editor `
  -BaseRef develop `
  -HeadRef HEAD
```

The local review facade keeps the PR-review defaults:

- explicit public modes only: `attributes`, `front-panel`, `block-diagram`
- `noise_policy=include`
- fail closed above `maxChangedViCount = 10`
- pair-level review workspace and pair pages

By default the facade resolves the latest immutable `comparevi-history` release and downloads the self-contained review
compiler asset for the current host runtime. Override that canonical released compiler path only when you intentionally
need a local compiler build:

- packaged default: latest immutable release asset
- packaged override: `-CompilerPath <path>` or `COMPAREVI_HISTORY_REVIEW_COMPILER_PATH=<path>`

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
- `tests/fixtures/reviewer-workspace-v1` is the canonical reviewer workspace golden baseline for PR diagnostics against
  the synthetic PR31-shaped fixture

This keeps the first corpus pilot deterministic and unsuppressed without inventing repo-wide generation before the
single-VI evidence contracts have stabilized.

## Compiled review bundle compiler

The canonical review graph is compiled by the .NET project
[`src/CompareVIHistory.ReviewCompiler/CompareVIHistory.ReviewCompiler.csproj`](src/CompareVIHistory.ReviewCompiler/CompareVIHistory.ReviewCompiler.csproj).
PowerShell remains the orchestration layer, but the typed compiler is now the source of truth for pair-level review
normalization.

Use [`scripts/Invoke-CompareVIHistoryReviewBundleCompiler.ps1`](scripts/Invoke-CompareVIHistoryReviewBundleCompiler.ps1)
to drive the compiler from workflow scripts:

- default path: source project via `dotnet run`
- packaged override: `-CompilerPath <path>` or `COMPAREVI_HISTORY_REVIEW_COMPILER_PATH=<path>`
- the override can point at either the extracted executable itself or an extracted runtime directory that contains the
  stable executable name

The immutable GitHub Release publishes self-contained assets for the compiler:

- `comparevi-history-review-compiler-v<version>-win-x64.zip`
- `comparevi-history-review-compiler-v<version>-linux-x64.zip`
- `comparevi-history-review-compiler-release.json` (`comparevi-history/review-compiler-release@v1`)
- `SHA256SUMS.txt`

After unzipping the Linux asset on a non-Windows host, restore the executable bit before invoking it directly:

```bash
chmod +x ./comparevi-history-review-compiler
./comparevi-history-review-compiler --version
```

The canonical compiled review-bundle golden baseline lives in `tests/fixtures/review-bundle-v1`.
It freezes the normalized `review-bundle.json` output independently from the reviewer workspace golden baseline in
`tests/fixtures/reviewer-workspace-v1`.

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

Automatic PR diagnostics consumers can check in either of two PR policy contracts, depending on which PR surface they
want to expose:

- legacy catalog-matched policy:
  [`docs/examples/comparevi-history-pr-policy.json`](docs/examples/comparevi-history-pr-policy.json)
  (`comparevi-history/pr-policy@v1`)
- standard dynamic changed-VI policy:
  [`docs/examples/comparevi-history-pr-policy-v2.json`](docs/examples/comparevi-history-pr-policy-v2.json)
  (`comparevi-history/pr-policy@v2`)

Consumer repos should copy the chosen pattern into `.github/comparevi-history-pr-policy.json` and keep automatic PR
policy there:

- `comparevi-history/pr-policy@v1`
  - include/exclude path globs for changed VI discovery
  - allowed target ids for automatic PR execution
  - maximum changed-VI count per run
  - unmatched changed-VI fail-closed behavior
  - public mode narrowing for reviewer surfaces
  - branch-budget defaults and no-diff artifact policy
  - reviewer comment and step-summary emission toggles
  - trust defaults for fork PR blocking or maintainer-dispatched fallback eligibility
- `comparevi-history/pr-policy@v2`
  - `discovery.selectionMode = dynamic-paths`
  - `includePaths = ["**/*.vi"]`
  - `excludePaths = []`
  - `maxChangedViCount = 10`
  - `overflowBehavior = block`
  - `execution.publicModes = ["attributes","front-panel","block-diagram"]`
  - `execution.noisePolicy = include`
  - `execution.history.sourceBranchRefStrategy = pull-request-base`
  - `execution.history.keepArtifactsOnNoDiff = true`
  - `reviewerSurface.emitCommentBody = true`
  - `reviewerSurface.emitStepSummary = true`
  - `reviewerSurface.fullSurface = artifact-index`
  - `trust.forkBehavior = hosted-auto`

## Trust boundaries

- Treat this action as a trusted-runner workflow primitive. Real VI History diagnostics should run only on trusted
  maintainer-controlled runners, either on self-hosted Windows with the backend prerequisites already installed or
  through a hosted NI Linux container path wired by a repo-local adapter such as
  `Tooling/Invoke-CompareVIHistoryHostedNILinux.ps1`.
- The single-run action still fails closed on `pull_request` and `pull_request_target` events for forked repositories.
  For public repositories, do not run the action directly on untrusted fork PR events.
- The legacy catalog-matched PR diagnostics reusable workflow still blocks fork and other cross-repository pull
  requests unless a maintainer-triggered caller explicitly enables the documented fallback path.
- The standard dynamic changed-VI PR surface splits execution and publication:
  - `pull_request` execution runs with read-only permissions, resolves the trusted base checkout plus candidate head
    checkout, and uploads the full artifact-hosted review surface
  - `workflow_run` publication runs with `actions: read`, `contents: write`, and `pull-requests: write`, downloads the
    execution artifact, publishes bounded preview images to a repo-owned branch, and updates one sticky PR comment
    without checking out or executing candidate PR code
- That split keeps fork PR support compatible with GitHub's read-only `pull_request` token model while preserving a
  reviewer-facing sticky PR comment through the privileged publisher.
- Public reviewer surfaces accept only explicit scoped modes: `attributes`, `front-panel`, and `block-diagram`.
  Aggregate aliases such as `default`, `full`, and `all` are not part of the public platform contract.
- Consumer-ready public PR diagnostics templates are published in `docs/SAFE_PR_DIAGNOSTICS_TEMPLATES.md`.
- Reviewer-facing consumers should use `public-comment-path`, `public-step-summary-path`, `public-run-path`, and
  `shared-evidence-path` instead of rebuilding evidence from raw backend manifests. Automatic PR diagnostics also expose
  `changed-vi-discovery.json` and `pr-run.json` for aggregate pull-request automation. The standard dynamic path also
  uses `selectedTargets[]`, `index.md`, `index.html`, and `comparevi-history/pr-comment-publication@v1` for sticky PR
  comment publication.
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
