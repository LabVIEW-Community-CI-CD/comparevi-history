# Safe PR Diagnostics Templates

These templates show how to use `comparevi-history` safely in public repositories without violating the trust guard.
They now assume a checked-in consumer target catalog, explicit public modes, and action-owned reviewer artifacts instead
of repo-local inline comment renderers.

## Published Templates

- Maintainer-dispatched template:
  [comparevi-history-workflow-dispatch.yml](examples/comparevi-history-workflow-dispatch.yml)
- Comment-gated template:
  [comparevi-history-comment-gated.yml](examples/comparevi-history-comment-gated.yml)
- Example consumer target catalog source:
  [comparevi-history-consumer-targets.json](examples/comparevi-history-consumer-targets.json)

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
- workflow trigger wiring and permissions policy
- small repo-local docs explaining what target ids exist and when the history surface should run

Consumer repositories should not contain:

- copied inline PowerShell renderers
- repo-local history execution logic
- direct pins to `compare-vi-cli-action`
- repo-specific forks of the public run/comment/summary schemas

## Use These Patterns

- Use the maintainer-dispatched template when a maintainer wants to inspect a specific pull request on demand.
- Use the comment-gated template when you want a slash command such as
  `/comparevi-history vip-post-install-custom-action --modes attributes,front-panel,block-diagram`
  to trigger diagnostics from a trusted maintainer comment.
- Run both patterns on trusted maintainer-controlled workflows that pre-pull the hosted NI Linux image serially and use
  a repo-local adapter such as `Tooling/Invoke-CompareVIHistoryHostedNILinux.ps1`.
- Keep the target catalog checked in under `.github/comparevi-history-targets.json` so the consumer repo owns target
  policy without owning execution logic.

## Fork Adoption and Upstream Alignment

- Treat `ni/labview-icon-editor` as the canonical consumer surface when validating template behavior or comparing
  repository-relative VI paths.
- Downstream forks such as `svelderrainruiz/labview-icon-editor` should keep the workflow files aligned to upstream
  `develop` unless they intentionally diverge on diagnostics policy.
- The published templates are fork-safe by design: they resolve the pull request head repository and head SHA from the
  GitHub API, then run `comparevi-history` against that exact checkout while keeping the public reviewer logic in the
  pinned action.

## Do Not Use These Patterns

- Do not run `comparevi-history` directly from `pull_request` on public fork PRs. The action intentionally fails closed
  there because the event does not prove a trusted runner or trusted refs.
- Do not use `pull_request_target` to run the action automatically against fork content with write-scoped tokens or
  secrets. That crosses the trust boundary the guard is designed to enforce.
- Do not pin consumer workflows to branch refs such as `@main`, `@develop`, or unpublished SHAs. Use released facade
  refs only.
- Do not hide the mode list or reviewer renderer inside local wrapper scripts. Public PR diagnostics should resolve the
  bundle-backed renderer via `tooling-path` and consume the action outputs `public-comment-path`,
  `public-step-summary-path`, `public-run-path`, and `history-summary-json`.

## Template Notes

- The maintainer-dispatched template uses `LabVIEW-Community-CI-CD/comparevi-history@v1`. That is the right default
  when you want compatible updates after each reviewed facade release.
- The comment-gated template uses `LabVIEW-Community-CI-CD/comparevi-history@v1.0.4`. That is the right default when
  you want the public PR diagnostics surface frozen to a known immutable release. The release workflow updates that
  immutable pin as part of publish so the published example stays aligned to the latest reviewed immutable tag.
- Both templates resolve the PR head repository and head SHA from the GitHub API, then check out that exact SHA with
  `fetch-depth: 0` so the backend can traverse commit history deterministically.
- Both templates keep maintainer-only override inputs unset. That aligns with the trust guard and keeps consumers on the
  normal released bundle path.
- Both templates pre-pull `nationalinstruments/labview:2026q1-linux` and route execution through
  `Tooling/Invoke-CompareVIHistoryHostedNILinux.ps1` so consumers use the hosted NI Linux contract instead of a
  repo-specific self-hosted Windows assumption.
- Both templates expect the consumer repo to define target ids in `.github/comparevi-history-targets.json`.
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

1. Check in `.github/comparevi-history-targets.json` first.
2. Start with the maintainer-dispatched template when your project is new to VI History diagnostics.
3. Keep the default explicit public mode bundle unless you have a documented reason to narrow it.
4. Add the comment-gated template only after you are comfortable letting maintainers trigger diagnostics from PR
   comments on a trusted hosted runner.
5. If you need stricter reproducibility, replace `@v1` with the latest immutable tag after each reviewed release.
