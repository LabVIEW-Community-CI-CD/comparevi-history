# RFC: CompareVI History PR Integration Surface

## 1. Title

RFC: Standard Pull Request Integration Surface for CompareVI History

## 2. Summary

This RFC evaluates whether CompareVI History should be packaged as a GitHub Marketplace action and adopted by consumer
repositories as their standard pull request integration surface.

The recommendation is no.

`comparevi-history` should keep the reusable workflow as the canonical public pull request orchestration layer, keep
the composite action as the lower-level single-run primitive, and keep `compare-vi-cli-action` as the pinned backend
tooling provider. Consumer repositories should stay thin and policy-driven.

GitHub Marketplace packaging may still be useful later as a secondary discovery surface, but it is not the right
boundary for the standard PR integration product. The core reason is that the PR product surface needs workflow-level
control over trust, permissions, changed-file discovery, aggregation, and reviewer publication.

## 3. Current State

`comparevi-history` already has two proven public surfaces:

- curated PR diagnostics through checked-in consumer target catalogs and trusted PR wrappers
- manual VI exploration through a reusable workflow plus thin consumer wrapper

The current platform boundary is already coherent:

- consumer repositories define what to inspect and what policy applies
- `comparevi-history` defines the public orchestration, receipts, rendering, and trust guard
- `compare-vi-cli-action` defines the backend execution bundle and stable backend facade

What is missing is a standard automatic PR surface that detects changed VIs from PR context and runs CompareVI History
for the affected files without pushing orchestration logic back into consumers.

## 4. Decision

The standard PR integration surface for CompareVI History should be:

- a reusable workflow in `comparevi-history` for automatic changed-VI pull request diagnostics

The lower-level execution primitive should remain:

- the existing `comparevi-history` action

The backend execution/tooling layer should remain:

- `compare-vi-cli-action`

Consumer repositories should adopt:

- a thin wrapper workflow
- a checked-in target catalog for curated targets
- a checked-in PR policy file for automatic changed-VI behavior
- repo-owned trigger and permission policy only

The standard product should not be:

- a GitHub Marketplace action as the main integration boundary

## 5. Why Marketplace Is Not the Canonical Surface

GitHub Marketplace packaging works well for single-step actions. It is the wrong abstraction for the CompareVI History
PR product because the full PR experience depends on workflow concerns, not only action concerns.

The standard PR product has to own:

- event triggers
- PR base/head discovery
- changed-VI inventory
- fan-out across multiple changed targets
- trust gating for same-repo and fork PRs
- permissions strategy for comments and artifacts
- aggregation across multiple VI runs
- PR-scope receipts, summaries, and reviewer comments

Those concerns belong in a reusable workflow. A composite action can help execute one normalized run, but it cannot be
the whole public PR product without pushing unsafe or duplicative orchestration back into consumer repositories.

Marketplace may still be useful later as:

- a discovery/onboarding surface
- a thin launcher action in a separate repository

That would be secondary. It should not replace the reusable workflow as the standard public PR surface.

## 6. Goals

- Automatically detect changed `.vi` files in pull requests.
- Run CompareVI History for the affected VIs when policy allows it.
- Keep consumer repositories thin and policy-driven.
- Publish stable reviewer-facing outputs and machine-readable receipts.
- Fail closed in unsafe PR contexts, especially fork and untrusted scenarios.
- Keep release management and version pinning deterministic.

## 7. Non-Goals

This RFC does not propose:

- replacing the current manual exploration surface
- replacing current curated target-id diagnostics
- executing untrusted fork content automatically through `pull_request_target`
- making consumer repositories own compare orchestration or renderer logic
- building a hosted web service
- making GitHub step summaries the primary review product

## 8. Recommended Platform Boundary

### 8.1 `comparevi-history` reusable workflow

This should become the standard PR integration product surface.

Responsibilities:

- discover changed VIs from PR context
- load repo-owned PR policy
- resolve curated target policy where needed
- enforce trust and permission guards
- orchestrate one or more `comparevi-history` action invocations
- aggregate per-target evidence into PR-scope receipts and reports
- publish artifacts, summaries, and optional PR comments

### 8.2 `comparevi-history` action

This remains the lower-level public execution primitive.

Responsibilities:

- normalize one request
- invoke the pinned backend bundle
- write `comparevi-history/request@v1`
- write `comparevi-history/public-run@v1`
- write `comparevi-history/shared-evidence@v1`
- render action-owned reviewer artifacts for one target

### 8.3 `compare-vi-cli-action`

This remains the backend layer.

Responsibilities:

- bundle/tooling distribution
- low-level compare/history execution
- stable backend facade artifacts such as `history-summary.json`
- bundled helper/render dependencies

### 8.4 Consumer repositories

Consumer repositories should contain only:

- checked-in policy/config files
- thin wrapper workflows
- repo-owned trigger and permission choices
- small adoption docs

Consumer repositories should not contain:

- changed-VI discovery logic
- repo-local history orchestration logic
- copied renderer scripts
- direct pins to the backend bundle as the normal public integration path

## 9. Changed-VI Discovery Model

Changed-VI discovery should be workflow-owned and PR-context driven.

Recommended flow:

1. Resolve the exact PR base and head repository plus SHA from the GitHub event payload and GitHub API.
2. Query the PR file list through the GitHub API.
3. Filter to `.vi` paths.
4. Include `added`, `modified`, and `renamed` file states.
5. For renames, record both previous and current paths so policy and receipts can represent continuity explicitly.
6. Produce a machine-readable discovery receipt before execution.

Discovery should not rely on:

- `paths:` trigger filters as the authoritative target inventory
- local `git diff` guesses without exact PR base/head resolution

The workflow must fail closed when discovery is incomplete. Examples:

- GitHub API pagination or file-count ceilings prevent complete inventory
- PR metadata cannot prove the exact head repository or head SHA
- the changed-file list cannot be normalized into deterministic `.vi` targets

## 10. Consumer Policy Contract

Automatic PR diagnostics should use a new additive consumer-owned contract:

- `comparevi-history/pr-policy@v1`

This is separate from the existing curated target catalog:

- `comparevi-history/consumer-targets@v1`

Rationale:

- curated target catalogs answer "what named targets exist and how can maintainers inspect them?"
- PR policy answers "when changed VIs appear in a PR, what automatic behavior is allowed?"

`pr-policy@v1` should own:

- include globs
- exclude globs
- optional allowlists or denylist behavior
- maximum changed-VI count per run
- branch-budget limits
- allowed public modes
- no-diff artifact policy
- reviewer comment policy
- default fork behavior
- fail-closed behavior when limits are exceeded

Default public modes should remain:

- `attributes`
- `front-panel`
- `block-diagram`

Aggregate aliases such as `default`, `full`, and `all` should remain outside the standard public PR contract.

## 11. Trust, Permissions, and Fork Behavior

The trust guard remains a platform-owned concern.

### 11.1 Same-repo PRs

Default behavior:

- auto-run is allowed
- artifacts and receipts are published
- PR comments may be published when token permissions allow it

### 11.2 Fork PRs

Default behavior:

- automatic execution against fork content is not allowed through unsafe trusted-token paths
- `pull_request_target` must not be used to execute fork content automatically with write-scoped permissions or secrets

Recommended fork behavior:

- fail closed with an explicit machine-readable receipt
- optionally instruct maintainers to use a trusted fallback surface

Trusted fallback surfaces:

- maintainer-dispatched reusable workflow
- comment-gated maintainer workflow

Those fallback paths must reuse the same aggregate PR receipt shape so downstream tooling does not depend on how the run
was initiated.

### 11.3 Permission-restricted environments

When PR comment publication is denied but diagnostics succeed:

- keep the diagnostics result successful
- record the comment publication failure in the aggregate receipt
- preserve the reviewer summary and uploaded artifacts

## 12. Output and Receipt Model

The automatic PR surface should publish both per-target and PR-scope artifacts.

### 12.1 Per-target outputs

Reuse the existing action-level outputs and receipts:

- `request.json`
- `public-run.json`
- `shared-evidence.json`
- `history-summary.json`
- `history-report.md`
- `history-report.html`

### 12.2 PR-scope outputs

Add new PR orchestration outputs:

- `changed-vi-discovery.json`
- `pr-run.json`
- `index.md`
- `index.html`
- `pr-comment.md`
- `step-summary.md`
- bundle zip of all PR-scope receipts and per-target artifacts

Recommended new schemas:

- `comparevi-history/changed-vi-discovery@v1`
- `comparevi-history/pr-run@v1`

`pr-run@v1` should include:

- consumer repository and ref
- PR number
- base/head repository and SHA
- discovered VI list
- skipped/excluded targets with reasons
- per-target receipt references
- reviewer publication status
- aggregate final status and reason

## 13. Reviewer-Facing Surface

The reviewer-facing product should be additive and layered:

- PR comment: short digest plus links
- step summary: bounded digest plus key counts and receipts
- static `index.md` / `index.html`: primary human navigation surface
- uploaded artifact bundle: complete evidence package

The platform should not force consumers to rebuild reviewer markdown inline. The action and reusable workflow should own
that rendering and publish stable file outputs.

## 14. Version Pinning and Release Management

Versioning should keep the current reviewed-release model.

Recommended policy:

- consumer repositories pin the reusable workflow by immutable release ref for strict reproducibility
- `@v1` can remain the moving compatible major after publish validation
- `comparevi-history` pins `compare-vi-cli-action` by reviewed immutable release
- published examples stay aligned to the latest reviewed immutable tag through the normal release workflow

If Marketplace packaging is added later, it should be:

- a separate repository
- a thin launcher/discovery surface
- explicitly secondary to the reusable workflow contract

## 15. Alternatives Considered

### 15.1 Marketplace action as the canonical public surface

Pros:

- strong discoverability
- familiar `uses:` syntax

Cons:

- wrong abstraction for multi-job PR orchestration
- weak fit for fork and permission policy
- encourages consumer repos to own discovery and aggregation logic
- does not match the current reusable-workflow trust model

Decision:

- reject as the canonical public surface

### 15.2 Consumer-local PR workflows that call the action directly

Pros:

- flexible for one repo

Cons:

- duplicated orchestration
- trust drift
- schema drift
- renderer drift

Decision:

- reject as the standard model

### 15.3 Central hosted service or GitHub App

Pros:

- strongest central control

Cons:

- much larger operational footprint
- new deployment and trust burden

Decision:

- defer

## 16. Recommended Rollout Plan

### Phase 1: RFC and decision lock

- land this RFC
- document the reusable-workflow recommendation
- define the new PR-specific contracts to add

### Phase 2: Automatic changed-VI reusable workflow

- add the reusable workflow in `comparevi-history`
- implement changed-VI discovery from PR context
- orchestrate per-target action calls
- emit `changed-vi-discovery.json` and initial `pr-run.json`

### Phase 3: Consumer PR policy contract

- add `comparevi-history/pr-policy@v1`
- publish examples
- prove thin consumer adoption in `labview-icon-editor-demo`

### Phase 4: Fork/trust/manual fallback alignment

- define same-repo vs fork behavior precisely
- add maintainer-triggered fallback using the same aggregate receipt shape
- validate comment failure and permission-restricted paths

### Phase 5: Release and adoption guidance

- document immutable pinning guidance
- update published examples
- validate `@v1` plus immutable tag behavior through published-consumer validation

## 17. Acceptance Criteria

This initiative is complete when:

- the reusable workflow is the documented standard PR integration surface
- a consumer repository can adopt automatic changed-VI PR diagnostics with only thin wrapper files and checked-in policy
- same-repo PRs produce deterministic PR-scope receipts and reviewer outputs
- unsafe fork PR paths fail closed
- maintainer-triggered fallback paths reuse the same aggregate evidence model
- consumer repositories do not need repo-local orchestration or inline renderers

## 18. Open Questions

- Should `pr-policy@v1` support only path globs at first, or also target-id mapping for curated overrides?
- Should the first PR aggregate receipt include sticky-comment coordination metadata, or should that stay outside the
  schema initially?
- Should `merge_group` support be part of the first automatic PR slice or follow after `pull_request` proves stable?

## 19. Recommendation

Do not make GitHub Marketplace action packaging the standard CompareVI History PR integration surface.

Make the reusable workflow in `comparevi-history` the standard public PR product, keep the action as the lower-level
execution primitive, keep `compare-vi-cli-action` as the backend layer, and keep consumer repositories thin and
policy-driven.
