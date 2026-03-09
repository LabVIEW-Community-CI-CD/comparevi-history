# Safe PR Diagnostics Templates

These templates show how to use `comparevi-history` safely in public repositories without violating the facade trust
guard, and they default to a broader mode bundle than a single `default` pass.

## Published Templates

- Maintainer-dispatched template:
  [comparevi-history-workflow-dispatch.yml](examples/comparevi-history-workflow-dispatch.yml)
- Comment-gated template:
  [comparevi-history-comment-gated.yml](examples/comparevi-history-comment-gated.yml)

## Recommended Mode Coverage

The published examples default to:

```text
default,attributes,front-panel,block-diagram
```

That bundle is intentional:

- `default` keeps the broad baseline compare lane.
- `attributes` surfaces VI attribute drift explicitly.
- `front-panel` isolates front-panel changes that often matter in UI-facing PRs.
- `block-diagram` adds functional and cosmetic block-diagram coverage that a narrow single-mode demo would miss.

If your consumer repository needs a narrower or broader set, adjust the `compare_modes` input or command override, but
keep the default bundle as the starting point for public PR diagnostics.

## Use These Patterns

- Use the maintainer-dispatched template when a maintainer wants to inspect a specific pull request on demand.
- Use the comment-gated template when you want a slash command such as
  `/comparevi-history Tooling/deployment/VIP_Post-Install Custom Action.vi --modes default,attributes,front-panel,block-diagram`
  to trigger diagnostics from a trusted maintainer comment.
- Run both patterns only on trusted Windows runners that already satisfy the backend LabVIEW and LVCompare
  prerequisites.

## Fork Adoption and Upstream Alignment

- Treat `ni/labview-icon-editor` as the canonical consumer surface when validating template behavior or comparing
  repository-relative VI paths.
- Downstream forks such as `svelderrainruiz/labview-icon-editor` should keep the workflow files aligned to upstream
  `develop` unless they intentionally diverge on diagnostics policy.
- The published templates are repo-local by design: they resolve the pull request head repository dynamically, so the
  same workflow file can live in upstream or in a fork and still inspect fork-authored PR heads safely from a trusted
  maintainer-controlled runner.

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
- The comment-gated template uses `LabVIEW-Community-CI-CD/comparevi-history@v1.0.2`. That is the right default when
  you want the public PR diagnostics surface frozen to a known immutable release.
- Both templates resolve the PR head repository and head SHA from the GitHub API, then check out that exact SHA with
  `fetch-depth: 0` so the facade can traverse commit history deterministically.
- Both templates keep maintainer-only override inputs unset. That aligns with the trust guard and keeps consumers on
  the normal released bundle path.
- Both templates surface the mode bundle in artifacts and summaries through the facade outputs
  `requested-mode-list`, `executed-mode-list`, `mode-manifests-json`, and `mode-summary-markdown`.
- The published templates intentionally leave `keep_artifacts_on_no_diff` unset so they stay compatible with the
  currently pinned released backend bundle.
- `.github/workflows/published-consumer-validation.yml` in this repo validates the published `v1` tag and latest
  immutable tag against `ni/labview-icon-editor` by default and uploads evidence artifacts for both lanes.

## Recommended Adoption

1. Start with the maintainer-dispatched template when your project is new to VI History diagnostics.
2. Keep the default multi-mode bundle unless you have a documented reason to narrow it.
3. Add the comment-gated template only after you are comfortable letting maintainers trigger diagnostics from PR
   comments on a trusted runner.
4. If you need stricter reproducibility, replace `@v1` with the latest immutable tag after each reviewed release.
