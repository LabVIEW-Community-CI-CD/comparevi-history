# Safe PR Diagnostics Templates

These templates show how to use `comparevi-history` safely in public repositories without violating the trust guard.
They now assume a checked-in consumer target catalog, explicit public modes, and action-owned reviewer artifacts instead
of repo-local inline comment renderers.

## Published Templates

- Maintainer-dispatched template:
  [comparevi-history-workflow-dispatch.yml](examples/comparevi-history-workflow-dispatch.yml)
- Legacy automatic PR discovery template:
  [comparevi-history-pull-request-diagnostics.yml](examples/comparevi-history-pull-request-diagnostics.yml)
- Automatic changed-VI execution template:
  [comparevi-history-pull-request-diagnostics-auto.yml](examples/comparevi-history-pull-request-diagnostics-auto.yml)
- Automatic changed-VI publication template:
  [comparevi-history-pull-request-diagnostics-publish.yml](examples/comparevi-history-pull-request-diagnostics-publish.yml)
- Agent-canary evaluation template:
  [comparevi-history-agent-canary-evaluate.yml](examples/comparevi-history-agent-canary-evaluate.yml)
- Comment-gated template:
  [comparevi-history-comment-gated.yml](examples/comparevi-history-comment-gated.yml)
- Example consumer target catalog source:
  [comparevi-history-consumer-targets.json](examples/comparevi-history-consumer-targets.json)
- Example legacy consumer PR policy source:
  [comparevi-history-pr-policy.json](examples/comparevi-history-pr-policy.json)
- Example dynamic consumer PR policy source:
  [comparevi-history-pr-policy-v2.json](examples/comparevi-history-pr-policy-v2.json)
- Example agent-canary policy source:
  [comparevi-history-agent-canary-policy.json](examples/comparevi-history-agent-canary-policy.json)

## Public Mode Contract

The public platform surface accepts only:

```text
attributes,front-panel,block-diagram
```

That bundle is intentional:

- `attributes` surfaces VI attribute drift explicitly.
- `front-panel` isolates front-panel changes that matter in reviewer-facing UI lanes.
- `block-diagram` adds functional and cosmetic block-diagram coverage.

Aggregate aliases such as `default`, `full`, and `all` are not part of the public platform contract.

## Consumer Repository Shape

Consumer repositories should contain only:

- `.github/comparevi-history-targets.json` (checked-in target catalog)
- `.github/comparevi-history-pr-policy.json` (checked-in automatic PR policy)
- workflow trigger wiring and permissions policy
- small repo-local docs explaining what target ids exist and when the history surface should run

Consumer repositories should not contain:

- copied inline PowerShell renderers
- repo-local history execution logic
- direct pins to `compare-vi-cli-action`
- repo-specific forks of the public run/comment/summary schemas

## Use These Patterns

- Use the maintainer-dispatched template when a maintainer wants to inspect a specific pull request on demand.
- Use the automatic changed-VI execution template when you want `pull_request` runs to discover changed `.vi` files and
  run `comparevi-history` automatically for every policy-eligible changed path without copying orchestration logic into
  the consumer repository.
- The standard dynamic PR policy uses `discovery.selectionMode = dynamic-paths`.
- Pair that execution template with the automatic changed-VI publication template so a privileged `workflow_run`
  publisher can create or update one sticky comment from the prepared `pr-comment.md` artifact.
- The publication template also needs `contents: write` because it publishes a bounded preview-image surface to a
  repo-owned branch before updating the sticky comment.
- Add the agent-canary evaluation template only when you want one long-lived draft PR to keep proving the full
  execution plus publication surface through a dedicated same-repo canary lane.
- Use the legacy automatic PR discovery template when you still want catalog-matched target ids to gate the automatic PR
  surface.
- Use the comment-gated template when you want a slash command such as
  `/comparevi-history vip-post-install-custom-action --modes attributes,front-panel,block-diagram`
  to trigger diagnostics from a trusted maintainer comment.
- Run both patterns on trusted maintainer-controlled workflows that pre-pull the hosted NI Linux image serially and use
  a repo-local adapter such as `Tooling/Invoke-CompareVIHistoryHostedNILinux.ps1`.
- Keep the target catalog checked in under `.github/comparevi-history-targets.json` and the automatic PR policy checked in under `.github/comparevi-history-pr-policy.json` so the consumer repo owns inspection policy without owning execution logic.
- Keep the agent-canary policy checked in under `.github/comparevi-history-agent-canary.json` so the repo-owned canary
  lane stays deterministic and machine-readable.

## Fork Adoption and Upstream Alignment

- Treat `ni/labview-icon-editor` as the canonical consumer surface when validating template behavior or comparing
  repository-relative VI paths.
- Downstream forks such as `svelderrainruiz/labview-icon-editor` should keep the workflow files aligned to upstream
  `develop` unless they intentionally diverge on diagnostics policy.
- The published templates are fork-safe by design:
  - the automatic changed-VI execution template resolves the pull request head repository and head SHA from the GitHub
    API, then runs `comparevi-history` against that exact checkout with only read-only `pull_request` permissions
  - the automatic changed-VI publication template runs later on `workflow_run`, downloads the prepared artifact, and
    updates one sticky comment without checking out or executing candidate PR code
  - the legacy catalog-matched template keeps its stricter fork guard and remains opt-in for repos that still want that
    narrower trust posture

## Do Not Use These Patterns

- Do not run the single-run `comparevi-history` action directly from `pull_request` on public fork PRs. The action
  intentionally fails closed there because the event does not prove a trusted runner or trusted refs.
- Do not use `pull_request_target` to run the action automatically against fork content with write-scoped tokens or
  secrets. That crosses the trust boundary the guard is designed to enforce.
- Do not let the `workflow_run` publisher check out or execute candidate PR code. Its only job is to download the
  prepared artifact and update the sticky comment.
- Do not expect the legacy catalog-matched automatic PR discovery template to execute on fork or other cross-repository
  PR heads unless the documented maintainer-dispatch fallback is used.
- Do not pin consumer workflows to branch refs such as `@main`, `@develop`, or unpublished SHAs. Use released facade
  refs only.
- Do not hide the mode list or reviewer renderer inside local wrapper scripts. Public PR diagnostics should resolve the
  bundle-backed renderer via `tooling-path` and consume the action outputs `public-comment-path`,
  `public-step-summary-path`, `public-run-path`, and `history-summary-json`.

## Template Notes

- The maintainer-dispatched template uses `LabVIEW-Community-CI-CD/comparevi-history@v1`. That is the right default
  when you want compatible updates after each reviewed facade release.
- The legacy automatic PR discovery template uses the reusable workflow surface
  `LabVIEW-Community-CI-CD/comparevi-history/.github/workflows/pull-request-diagnostics.yml@v1`. That keeps consumer
  repositories thin and leaves changed-VI discovery, trusted base/head orchestration, and aggregate receipt generation
  inside the platform layer.
- The automatic changed-VI execution template uses the reusable workflow surface
  `LabVIEW-Community-CI-CD/comparevi-history/.github/workflows/pull-request-diagnostics-auto.yml@v1`. That is the
  standard public PR surface for repos that want dynamic-path changed-VI execution.
- The automatic changed-VI publication template uses the reusable workflow surface
  `LabVIEW-Community-CI-CD/comparevi-history/.github/workflows/pull-request-diagnostics-publish.yml@v1`. It exists so
  `workflow_run` can publish the sticky comment with `actions: read`, `contents: write`, and `pull-requests: write`
  without widening the execution workflow token.
- The agent-canary evaluation template uses the reusable workflow surface
  `LabVIEW-Community-CI-CD/comparevi-history/.github/workflows/pull-request-diagnostics-canary-evaluate.yml@v1`. It
  exists so a same-repo `workflow_run` can evaluate the publication artifact, confirm the PR is an `agent-canary`
  draft lane, and fail closed without re-running execution or checking out candidate PR code.
- The comment-gated template uses `LabVIEW-Community-CI-CD/comparevi-history@v1.3.13`. That is the right default when
  you want the public PR diagnostics surface frozen to a known immutable release. The release workflow updates that
  immutable pin as part of publish so the published example stays aligned to the latest reviewed immutable tag.
- The automatic changed-VI execution template keeps the checked-in PR policy and hosted NI Linux adapter on the pull
  request base checkout while executing against the candidate head checkout. That is the minimum safe split that keeps
  repo policy trusted without inventing repo-local orchestration code.
- Both automatic templates resolve the PR head repository and head SHA from the GitHub API, then check out that exact
  SHA with `fetch-depth: 0` so the backend can traverse commit history deterministically.
- Both automatic templates keep maintainer-only override inputs unset. That aligns with the trust guard and keeps
  consumers on the normal released bundle path.
- Both automatic templates pre-pull `nationalinstruments/labview:2026q1-linux` and route execution through
  `Tooling/Invoke-CompareVIHistoryHostedNILinux.ps1` so consumers use the hosted NI Linux contract instead of a
  repo-specific self-hosted Windows assumption.
- The legacy automatic PR discovery template and the comment-gated template expect the consumer repo to define target ids
  in `.github/comparevi-history-targets.json`.
- The automatic changed-VI execution template expects `.github/comparevi-history-pr-policy.json` using
  `comparevi-history/pr-policy@v2` when a repo wants dynamic-path discovery, `hosted-auto` fork execution, and the
  standard `artifact-index` reviewer surface under source control.
- The automatic changed-VI publication template expects the execution artifact to contain `pr-run.json` and
  `pr-comment.md`, plus `pr-preview-manifest.json` when preview images exist, then updates one sticky comment
  identified by the stable marker
  `<!-- comparevi-history:pull-request-diagnostics -->`.
- The sticky comment stays bounded. The full unsuppressed evidence still lives in the execution artifact, while the
  publisher can surface a small preview gallery by writing selected images to a repo-owned preview branch.
- The agent-canary evaluation template expects the publication artifact to contain `pr-comment-publication.json` plus
  the expanded execution artifact with `pr-run.json`, `changed-vi-discovery.json`, `index.md`, and `index.html`.
- The agent-canary evaluation template should not try to predict a publication artifact name from the publisher
  `workflow_run` id. The reusable evaluator resolves the publication artifact from the completed publisher run and treats
  `artifact_name` as an override only.
- The agent-canary lane is same-repo only, uses branch prefix `agent-canary/`, requires the `agent-canary` label, and
  expects one long-lived draft PR instead of a stream of throwaway proof branches.
- The action owns reviewer-facing rendering. Consumers should publish PR comments from `public-comment-path` and append
  `public-step-summary-path` instead of rebuilding markdown inline.
- The comment-gated template writes the action-owned step summary first, then attempts to publish the PR comment. If the
  repository token cannot create the comment, the workflow keeps the diagnostics job green and records the fallback in
  the step summary instead of masking a successful compare run as infrastructure failure.
- The published templates intentionally leave `keep_artifacts_on_no_diff` unset so they stay compatible with the
  currently pinned released backend bundle.
- `.github/workflows/published-consumer-validation.yml` in this repo validates the released `v1` tag and latest
  immutable tag against `ni/labview-icon-editor` by default and uploads evidence artifacts for both lanes.

## Recommended Adoption

1. Check in `.github/comparevi-history-pr-policy.json` first.
2. Start with the maintainer-dispatched template when your project is new to VI History diagnostics.
3. Add the automatic changed-VI execution template plus the `workflow_run` publication template when you want pull
   requests to run automatically for every changed `.vi`.
4. Add the agent-canary evaluation template plus `.github/comparevi-history-agent-canary.json` when you want one
   governed same-repo canary PR to keep proving the automatic review surface.
5. Keep the default explicit public mode bundle unless you have a documented reason to narrow it.
6. Add the legacy catalog-matched automatic PR template only if your repo still needs target-id allowlists for
   automatic PR execution.
7. Add the comment-gated template only after you are comfortable letting maintainers trigger diagnostics from PR
   comments on a trusted hosted runner.
8. If you need stricter reproducibility, replace `@v1` with the latest immutable tag after each reviewed release.


