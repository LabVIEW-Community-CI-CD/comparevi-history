# Safe PR Diagnostics Templates

These templates show how to use `comparevi-history` safely in public repositories without violating the facade trust
guard. They default to an explicit scoped mode bundle, and they assume a GitHub-hosted Linux
runner that pre-pulls the NI container image before invoking a repo-local hosted-runner adapter.

## Published Templates

- Maintainer-dispatched template:
  [comparevi-history-workflow-dispatch.yml](examples/comparevi-history-workflow-dispatch.yml)
- Comment-gated template:
  [comparevi-history-comment-gated.yml](examples/comparevi-history-comment-gated.yml)

## Recommended Mode Coverage

The published examples default to:

```text
attributes,front-panel,block-diagram
```

That bundle is intentional:

- `attributes` surfaces VI attribute drift explicitly.
- `front-panel` isolates front-panel changes that often matter in UI-facing PRs.
- `block-diagram` adds functional and cosmetic block-diagram coverage that a narrow single-mode demo would miss.
- Aggregate aliases such as `default`, `full`, and `all` are intentionally excluded because they disguise which
  scoped lane produced the evidence.

If your consumer repository needs a narrower set, adjust the `compare_modes` input or command override, but keep the
published explicit bundle as the starting point for public PR diagnostics.

## Use These Patterns

- Use the maintainer-dispatched template when a maintainer wants to inspect a specific pull request on demand.
- Use the comment-gated template when you want a slash command such as
  `/comparevi-history Tooling/deployment/VIP_Post-Install Custom Action.vi --modes attributes,front-panel,block-diagram`
  to trigger diagnostics from a trusted maintainer comment.
- Run both patterns on trusted maintainer-controlled workflows that pre-pull the hosted NI Linux image serially and use
  a repo-local adapter such as `Tooling/Invoke-CompareVIHistoryHostedNILinux.ps1`.

## Fork Adoption and Upstream Alignment

- Treat `ni/labview-icon-editor` as the canonical consumer surface when validating template behavior or comparing
  repository-relative VI paths.
- Downstream forks such as `svelderrainruiz/labview-icon-editor` should keep the workflow files aligned to upstream
  `develop` unless they intentionally diverge on diagnostics policy.
- The published templates are repo-local by design: they resolve the pull request head repository dynamically, so the
  same workflow file can live in upstream or in a fork and still inspect fork-authored PR heads safely from a trusted
  maintainer-controlled hosted runner.

## Do Not Use These Patterns

- Do not run `comparevi-history` directly from `pull_request` on public fork PRs. The facade intentionally fails closed
  there because the event does not prove a trusted runner or trusted refs.
- Do not use `pull_request_target` to run the facade automatically against fork content with write-scoped tokens or
  secrets. That pattern crosses the trust boundary the guard is designed to enforce.
- Do not pin consumer workflows to branch refs such as `@main`, `@develop`, or unpublished SHAs. Use released facade
  refs only.
- Do not hide the mode list inside local wrapper scripts. Public PR diagnostics should make the executed mode bundle
  obvious in the workflow file, summary, and PR comment so reviewers know what coverage they received.

## Template Notes

- The maintainer-dispatched template uses `LabVIEW-Community-CI-CD/comparevi-history@v1`. That is the right default
  when you want compatible updates after each reviewed facade release.
- The comment-gated template uses `LabVIEW-Community-CI-CD/comparevi-history@v1.0.4`. That is the right default when
  you want the public PR diagnostics surface frozen to a known immutable release. The release workflow updates that
  immutable pin as part of publish so the published example stays aligned to the latest reviewed immutable tag.
- Both templates resolve the PR head repository and head SHA from the GitHub API, then check out that exact SHA with
  `fetch-depth: 0` so the facade can traverse commit history deterministically.
- Both templates keep maintainer-only override inputs unset. That aligns with the trust guard and keeps consumers on
  the normal released bundle path.
- Both templates pre-pull `nationalinstruments/labview:2026q1-linux` and route execution through
  `Tooling/Invoke-CompareVIHistoryHostedNILinux.ps1` so consumers use the hosted NI Linux contract instead of a
  repo-specific self-hosted Windows assumption.
- Both templates surface the mode bundle in artifacts and summaries through the facade outputs
  `requested-mode-list`, `executed-mode-list`, `mode-manifests-json`, `mode-summary-markdown`, and
  `history-summary-json`.
- The comment and step-summary body are rendered through the bundle helper
  `tools/New-CompareVIHistoryDiagnosticsBody.ps1` resolved from `steps.history.outputs['tooling-path']`, so consumers
  do not need to copy additional PowerShell helpers into their repositories.
- The comment-gated template writes the diagnostics summary to the step summary first, then attempts to publish the PR
  comment. If the repository token cannot create the comment, the workflow keeps the diagnostics job green and records
  the fallback in the step summary instead of masking a successful compare run as infrastructure failure.
- The published templates intentionally leave `keep_artifacts_on_no_diff` unset so they stay compatible with the
  currently pinned released backend bundle.
- `.github/workflows/published-consumer-validation.yml` in this repo validates the published `v1` tag and latest
  immutable tag against `ni/labview-icon-editor` by default and uploads evidence artifacts for both lanes.

## Recommended Adoption

1. Start with the maintainer-dispatched template when your project is new to VI History diagnostics.
2. Keep the published explicit multi-mode bundle unless you have a documented reason to narrow it.
3. Add the comment-gated template only after you are comfortable letting maintainers trigger diagnostics from PR
   comments on a trusted hosted runner.
4. If you need stricter reproducibility, replace `@v1` with the latest immutable tag after each reviewed release.

