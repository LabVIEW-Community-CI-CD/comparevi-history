# RFC: First-Class VI History Exploration Platform

## 1. Title

RFC: First-Class VI History Exploration Platform for LabVIEW Repositories

## 2. Summary

This RFC proposes a durable developer capability for exploring the full history of a single VI from a trusted manual
workflow, starting with `LabVIEW-Community-CI-CD/labview-icon-editor-demo` as the first consumer.

The platform will let a developer select a repo-relative `.vi` path, resolve that VI safely at a chosen repository
ref, discover the full available history for that VI on the selected ref lineage, run the VI History Suite across the
discovered revisions, and publish reviewer-usable outputs such as a timeline, rendered reports, and downloadable
artifacts.

This is not a replacement for existing curated target diagnostics. It is a second platform surface:

- curated target-id diagnostics remain the standard PR and comment-gated diagnostic path
- manual VI exploration becomes the standard trusted maintainer path for arbitrary VI history investigation

## 3. Motivation

Current cross-repo VI history support already exists, but it is optimized for curated, policy-approved targets and PR
diagnostics:

- `labview-icon-editor-demo` already publishes `.github/comparevi-history-targets.json`
- it already uses `comparevi-history@v1.1.0`
- it already exposes:
  - `comparevi-history-comment-gated.yml`
  - `comparevi-history-manual-pr-diagnostics.yml`

That current surface solves a narrow problem well: review a known VI target in a PR-oriented flow with bounded
execution. It does not solve the exploratory problem:

- a maintainer needs to inspect any VI in the repo
- they want the VI's history since its inception on the chosen lineage
- they need to understand evolution, not just receive a bounded diagnostic bundle

Ad hoc scripts and repo-local workflows are the wrong answer because they fragment behavior, create new trust surfaces,
and duplicate orchestration that `comparevi-history` already owns. A first-class platform capability is justified
because:

- VI history exploration is recurring repository maintenance work, not an exceptional debugging trick
- the operator needs a stable contract and stable outputs
- consumer repositories should stay thin and policy-driven
- the history execution and rendering surfaces already exist in shared infrastructure and should be extended there

`labview-icon-editor-demo` is the right first consumer because it already proves the existing cross-repo history model,
already has trusted runner wiring, and already uses the consumer target catalog contract that this RFC will extend with
an exploration surface rather than replace.

## 4. Goals

Operator-facing goals:

- Allow a maintainer to manually run VI history exploration for one repo-relative `.vi` path.
- Show the VI's historical evolution in a way that is useful for investigation and review.
- Keep the workflow understandable even when a VI has a large history.

Platform-facing goals:

- Make VI history exploration a first-class `comparevi-history` capability rather than a consumer-local script.
- Preserve existing backend artifacts and contracts from `compare-vi-cli-action`.
- Add new exploration-layer receipts and indexes without breaking current `comparevi-history` consumers.

Repository-facing goals:

- Keep `labview-icon-editor-demo` thin.
- Avoid repo-local history discovery logic, renderer copies, or schema forks.
- Make the pattern portable to future LabVIEW repositories.

## 5. Non-Goals

The initial rollout does not attempt to:

- replace existing curated target-id diagnostics
- replace PR comment-gated diagnostics
- build a standalone web application
- expose arbitrary LabVIEW artifact types beyond `.vi`
- union history across every branch in the repository
- infer continuity across unrelated branch families without explicit evidence
- make untrusted fork PRs a supported entrypoint for exploration

## 6. User Personas

Primary operator: trusted maintainer

- Needs to investigate how one VI evolved over time.
- Needs to choose the VI directly by path.
- Needs a run output that can be read without reconstructing history manually from raw artifacts.

Secondary operator: reviewer or release maintainer

- Needs to validate whether a behavioral change is new, recurring, or historical.
- Needs a durable artifact bundle they can inspect after the run completes.

Consumer repository maintainer:

- Needs a thin workflow wrapper and stable configuration surface.
- Does not want to own history discovery orchestration or renderer logic.

Platform maintainer:

- Needs stable contracts, release-pinned dependencies, and clear ownership boundaries between `comparevi-history` and
  `compare-vi-cli-action`.

## 7. User Experience

Discovery:

- The consumer repo documents a manual workflow named `CompareVI History Manual Exploration`.
- The operator finds it under the GitHub Actions tab.

Inputs:

- Required:
  - `vi_path`: repository-relative `.vi` path
- Optional:
  - `ref`: defaults to the consumer default branch; for `labview-icon-editor-demo` this is `develop`
  - `modes`: defaults to `full` for the trusted raw exploration surface
  - `include_merge_parents`: defaults to `false`
  - `noise_policy`: defaults to `include` so metadata-rich output stays in-band

Run behavior:

- The workflow validates the path and chosen ref before starting expensive work.
- The workflow writes a request receipt and a discovery summary early in the run.
- The workflow then discovers the full available revision catalog for the VI on the selected lineage.
- If the VI has a small history, the run can execute as a single bounded lane.
- If the VI has a large history, the run plans chunks and executes them serially or in bounded parallel slices.

Completion experience:

- The step summary presents:
  - the selected VI
  - selected ref
  - continuity summary
  - number of discovered revisions
  - chunk completeness state
  - links to the main timeline and final bundle
- Uploaded artifacts include:
  - timeline markdown and HTML
  - revision catalog JSON
  - aggregate exploration receipt
  - chunk manifests and reports
  - the final downloadable bundle

Large-history usability:

- The operator sees a master timeline first, not a flat wall of per-compare output.
- Detailed change renders are chunked and linked from the timeline.
- The platform never silently hides revisions; it must show completeness or incompleteness explicitly.

## 8. Functional Requirements

The platform must:

- accept a repo-relative `.vi` path from a `workflow_dispatch` surface
- validate that the path is safe and exists at the selected ref
- discover the VI's full historical footprint on the selected lineage
- follow renames and moves where history evidence supports continuity
- detect and represent continuity breaks instead of flattening them silently
- generate the VI History Suite across the discovered revisions
- preserve stable backend artifacts:
  - `suite-manifest.json`
  - `history-summary.json`
  - `history-report.md`
  - `history-report.html`
- add exploration-layer artifacts:
  - `revision-catalog.json`
  - `timeline.md`
  - `timeline.html`
  - `exploration-run.json`
  - `mode-summary.json`
  - chunk receipts and manifests
  - downloadable bundle
- emit human-readable and machine-readable outputs
- keep existing curated target-id workflows unchanged

## 9. History Model

Identity:

- The platform treats a VI as a repository path plus git-backed continuity evidence over time.
- Continuity is inferred along the selected ref lineage, not across all branches in the repository.

Since inception:

- For v1, "since inception" means the full discoverable history of the selected VI on the selected ref lineage.
- The default selected ref is the consumer default branch.
- The platform must not claim complete cross-branch global ancestry unless it actually computes and proves it.

Renames and moves:

- Rename and move following is required when git history can support continuity.
- When rename continuity is ambiguous, the platform records ambiguity rather than choosing silently.

Deletes and reintroductions:

- If a VI disappears and later reappears, the platform records separate continuity segments or re-entry points.
- Reintroduced files are not automatically treated as a single uninterrupted identity.

Branch topology assumptions:

- Safe assumptions:
  - the selected ref lineage is the authoritative exploration boundary for the run
  - first-parent default is acceptable unless `include_merge_parents=true`
- Unsafe assumptions:
  - every appearance of the same repo-relative path is the same logical VI
  - all relevant history lives on the default branch
  - squash or cherry-pick history implies full continuity without explicit evidence

## 10. Output and Artifact Model

Required backend artifacts preserved from `compare-vi-cli-action`:

- `suite-manifest.json` (`vi-compare/history-suite@v1`)
- `history-summary.json` (`comparevi-tools/history-facade@v1`)
- `history-report.md`
- `history-report.html`

Required exploration-layer artifacts:

- `revision-catalog.json`
  - machine-readable catalog of discovered revisions, continuity segments, and chunk allocation
- `timeline.md`
  - operator-facing navigable markdown index
- `timeline.html`
  - richer navigable HTML view
- `exploration-run.json`
  - top-level orchestration receipt for the manual exploration run
- `chunk-<n>/...`
  - chunk-level manifests, reports, and receipts
- `vi-history-exploration-bundle.zip`
  - downloadable consolidated artifact bundle

Required exploration-layer schemas:

- `comparevi-history/revision-catalog@v1`
- `comparevi-history/exploration-run@v1`

Step summary requirements:

- must identify the selected VI and ref
- must report discovered revision count
- must report continuity shape
- must report chunk completeness
- must link the timeline and final bundle

## 11. Architecture

`labview-icon-editor-demo` owns:

- the thin `workflow_dispatch` wrapper
- trusted runner and image wiring
- repo-specific permission and policy choices
- optional documentation pointing operators at the workflow

`comparevi-history` owns:

- path validation and request normalization for exploration
- revision discovery and continuity modeling
- chunk planning
- orchestration receipt generation
- timeline/index rendering
- reusable workflow entrypoint for manual exploration
- stable exploration-layer schemas and outputs

`compare-vi-cli-action` owns:

- the history execution engine
- stable backend suite/report/facade artifacts
- compare execution, rendering, and per-run backend contracts

Configuration only:

- curated target catalogs remain consumer-owned
- manual exploration input is operator-supplied and does not require curated target registration

Boundary rule:

- consumers define when to run
- `comparevi-history` defines how manual exploration is orchestrated
- `compare-vi-cli-action` defines how history comparisons execute

## 12. Workflow and Contract Design

Manual exploration workflow in the consumer repo:

- new consumer wrapper workflow:
  - `comparevi-history-manual-vi-exploration.yml`
- trigger:
  - `workflow_dispatch`

Input contract:

- `vi_path` required
- `ref` optional, default `develop` for `labview-icon-editor-demo`
- `modes` optional, default `full`
- `include_merge_parents` optional, default `false`
- `noise_policy` optional, default `include`

Validation contract:

- path must be relative to repo root
- path must not be absolute
- path must not contain traversal escapes
- resolved path must remain inside repo root
- file must exist at selected ref
- file must end in `.vi`

New orchestration shape in `comparevi-history`:

- reusable workflow:
  - manual exploration entrypoint
- composite action:
  - remains the single-run history execution primitive
- new phases:
  - validate request
  - discover revision catalog
  - plan chunks
  - run chunked history suites
  - aggregate and render outputs

Existing contracts preserved:

- `comparevi-history/request@v1`
- `comparevi-history/public-run@v1`

New exploration contracts:

- `comparevi-history/revision-catalog@v1`
- `comparevi-history/exploration-run@v1`

Deterministic output requirements:

- every run writes a top-level exploration receipt
- every chunk writes a deterministic receipt
- completeness state is machine-readable
- continuation evidence is machine-readable when the run is incomplete

## 13. Safety, Governance, and Trust Model

The workflow must fail closed when:

- the selected path is invalid
- the selected path is outside repo root
- the selected path is not a `.vi`
- the selected ref cannot be resolved
- the VI does not exist at the selected ref
- the trusted execution plane is unavailable

Trust model:

- v1 is maintainer-dispatched and trusted-runner only
- it is not a fork PR surface
- consumer repos pin `comparevi-history`
- `comparevi-history` pins `compare-vi-cli-action`
- unreleased backend overrides remain maintainer-only and are not part of the v1 operator surface

Runtime and storage controls:

- complete discovery is mandatory before execution
- execution may chunk, but must not silently truncate
- hard limits must yield explicit `incomplete` results, not partial success disguised as complete success

Partial success rule:

- if discovery succeeds but some chunk execution or rendering fails, the platform publishes receipts and discovery
  evidence and marks the run degraded or incomplete explicitly

## 14. Scalability Model

Shallow history:

- one revision catalog
- one or a few chunks
- single timeline with linked reports

Deep history:

- full catalog still generated first
- execution split into bounded chunks
- timeline groups revisions into continuity segments and chunks
- detailed per-chunk reports linked from the master timeline

Very large history handling:

- chunking is internal platform behavior, not a user-facing hidden limit
- the main timeline remains the primary navigation surface
- the run explicitly records:
  - discovered revision count
  - executed chunk count
  - completed chunk count
  - skipped or failed chunk count
  - completeness status

## 15. Failure Model

Invalid path:

- fail closed before discovery

Non-VI target:

- fail closed before discovery

VI never existed at selected ref:

- fail closed with explicit reason

Incomplete history discovery:

- fail or degrade with explicit continuity reason; never pretend completeness

Rendering failure:

- keep discovery and execution receipts, mark final run degraded

Backend/tooling failure:

- preserve completed chunk evidence and final incomplete state

Artifact publication failure:

- preserve local receipts and mark publication degradation explicitly

Diagnostic success with degraded human-facing output:

- allowed only if machine-readable receipts and core backend artifacts exist
- final status must reflect degraded or incomplete state

## 16. Alternatives Considered

Repo-local one-off manual workflow:

- rejected because it would duplicate orchestration and validation logic in every consumer repo

Direct backend-only integration from consumer repos:

- rejected because it bypasses the public platform boundary and pushes too much logic into consumers

Central hosted service:

- deferred because the current trusted-runner and release-pinned model already exists and is sufficient for v1

Limited-history-only workflow:

- rejected because the product goal is exploration since inception on the selected lineage, not another bounded PR
  diagnostic surface

Reusing the current curated target-id manual PR workflow:

- rejected because it is PR-focused, target-catalog-driven, and intentionally bounded

## 17. Rollout Plan

Phase 1: manual exploration request and full discovery

- add the manual exploration reusable workflow in `comparevi-history`
- add fail-closed arbitrary path validation
- add full revision discovery and `revision-catalog.json`
- add thin consumer wrapper in `labview-icon-editor-demo`

Phase 2: chunked execution and aggregation

- add chunk planner and chunk receipts
- run the full VI History Suite across discovered revisions
- generate `timeline.md`, `timeline.html`, `exploration-run.json`, and bundle output

Phase 3: portability and documentation hardening

- document the pattern as the standard manual exploration capability
- prove that the consumer wrapper remains thin
- prepare a second consumer adoption path without changing the platform boundary

## 18. Acceptance Criteria

Phase 1:

- operator can run the workflow with `vi_path`
- path validation is fail-closed
- the complete revision catalog is produced for the selected VI on the selected lineage
- existing curated target-id workflows remain unchanged

Phase 2:

- discovered revisions are executed through chunked history suites
- a master timeline and final bundle are published
- large histories are chunked without silent truncation
- incomplete runs emit explicit machine-readable completeness state

Phase 3:

- the manual exploration capability is documented as a reusable platform pattern
- `labview-icon-editor-demo` remains a thin wrapper consumer
- no renderer or discovery logic is copied into the consumer repo

## 19. Risks and Mitigations

Technical risk: ambiguous continuity across rename or delete/reintroduce boundaries

- Mitigation: represent continuity breaks explicitly instead of guessing

Technical risk: long-running or storage-heavy histories

- Mitigation: full discovery plus chunked execution plus explicit completeness state

Operational risk: trusted-runner dependency

- Mitigation: make trusted execution an explicit requirement and keep hosted PR diagnostics separate

UX risk: overwhelming output for deep-history VIs

- Mitigation: timeline-first output model with chunked detail pages

Governance risk: consumer repos reimplement orchestration locally

- Mitigation: define the reusable workflow and schemas in `comparevi-history` and document the thin-consumer rule

## 20. Success Metrics

- maintainers can explore an arbitrary `.vi` by repo-relative path without repo-local scripting
- manual exploration runs produce stable receipts, timeline outputs, and bundle artifacts
- deep-history runs complete with explicit completeness accounting
- curated target-id diagnostics remain unaffected
- future consumer adoption does not require copying orchestration or rendering logic

## 21. Open Questions

- Should v1 support selecting a non-default ref only by exact ref name, or also by pull request number as a convenience
  wrapper?
- Should chunk execution be strictly serial in v1, or allow bounded parallelism when trusted runner capacity exists?
- Should continuity ambiguity be modeled only in JSON receipts in v1, or also visually highlighted in the HTML timeline?
- Should deleted-then-reintroduced files be shown as separate top-level exploration segments or a single timeline with
  explicit break markers?

## 22. Recommended Next Actions

1. Add this RFC to `comparevi-history` and review it as the platform decision record.
2. Open a `comparevi-history` implementation issue for Phase 1:
   - manual exploration reusable workflow
   - arbitrary `vi_path` validation
   - `revision-catalog@v1`
3. Open a `labview-icon-editor-demo` consumer issue for the thin manual wrapper workflow.
4. Keep existing curated PR workflows unchanged while the manual exploration surface is introduced in parallel.
5. Implement Phase 1 before designing any richer UI beyond timeline markdown and HTML.
