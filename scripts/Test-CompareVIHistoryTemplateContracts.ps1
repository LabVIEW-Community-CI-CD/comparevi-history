Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$manualTemplatePath = Join-Path $repoRoot 'docs/examples/comparevi-history-workflow-dispatch.yml'
$commentTemplatePath = Join-Path $repoRoot 'docs/examples/comparevi-history-comment-gated.yml'
$manualExplorationTemplatePath = Join-Path $repoRoot 'docs/examples/comparevi-history-manual-vi-exploration.yml'
$safeTemplatesPath = Join-Path $repoRoot 'docs/SAFE_PR_DIAGNOSTICS_TEMPLATES.md'
$publishedValidationWorkflowPath = Join-Path $repoRoot '.github/workflows/published-consumer-validation.yml'
$manualExplorationWorkflowPath = Join-Path $repoRoot '.github/workflows/manual-vi-exploration.yml'
$smokeWorkflowPath = Join-Path $repoRoot '.github/workflows/smoke.yml'
$releaseWorkflowPath = Join-Path $repoRoot '.github/workflows/release.yml'
$releaseReadinessScriptPath = Join-Path $repoRoot 'scripts/Resolve-CompareVIHistoryReleasePublishReadiness.ps1'
$readmePath = Join-Path $repoRoot 'README.md'
$exampleTargetsPath = Join-Path $repoRoot 'docs/examples/comparevi-history-consumer-targets.json'
$actionPath = Join-Path $repoRoot 'action.yml'

function Assert-Match {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Content,
    [Parameter(Mandatory = $true)]
    [string]$Pattern,
    [Parameter(Mandatory = $true)]
    [string]$Message
  )

  if ($Content -notmatch $Pattern) {
    throw $Message
  }
}

function Assert-NotMatch {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Content,
    [Parameter(Mandatory = $true)]
    [string]$Pattern,
    [Parameter(Mandatory = $true)]
    [string]$Message
  )

  if ($Content -match $Pattern) {
    throw $Message
  }
}

function Assert-Equal {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Actual,
    [Parameter(Mandatory = $true)]
    [string]$Expected,
    [Parameter(Mandatory = $true)]
    [string]$Message
  )

  if ($Actual -ne $Expected) {
    throw "$Message Expected '$Expected', actual '$Actual'."
  }
}

$manualTemplate = Get-Content -LiteralPath $manualTemplatePath -Raw
$commentTemplate = Get-Content -LiteralPath $commentTemplatePath -Raw
$manualExplorationTemplate = Get-Content -LiteralPath $manualExplorationTemplatePath -Raw
$safeTemplates = Get-Content -LiteralPath $safeTemplatesPath -Raw
$publishedValidationWorkflow = Get-Content -LiteralPath $publishedValidationWorkflowPath -Raw
$manualExplorationWorkflow = Get-Content -LiteralPath $manualExplorationWorkflowPath -Raw
$smokeWorkflow = Get-Content -LiteralPath $smokeWorkflowPath -Raw
$releaseWorkflow = Get-Content -LiteralPath $releaseWorkflowPath -Raw
$releaseReadinessScript = Get-Content -LiteralPath $releaseReadinessScriptPath -Raw
$readme = Get-Content -LiteralPath $readmePath -Raw
$exampleTargets = Get-Content -LiteralPath $exampleTargetsPath -Raw
$actionYaml = Get-Content -LiteralPath $actionPath -Raw

Assert-Match -Content $manualTemplate -Pattern '(?m)^\s*runs-on:\s+ubuntu-latest\s*$' -Message 'Manual template must use ubuntu-latest.'
Assert-Match -Content $manualTemplate -Pattern '(?m)^\s*COMPAREVI_NI_LINUX_IMAGE:\s+nationalinstruments/labview:2026q1-linux\s*$' -Message 'Manual template must pin the NI Linux image.'
Assert-Match -Content $manualTemplate -Pattern 'docker pull "\$COMPAREVI_NI_LINUX_IMAGE"' -Message 'Manual template must pre-pull the NI Linux image.'
Assert-Match -Content $manualTemplate -Pattern 'invoke_script_path:\s+Tooling/Invoke-CompareVIHistoryHostedNILinux\.ps1' -Message 'Manual template must use the hosted NI Linux invoke adapter.'
Assert-Match -Content $manualTemplate -Pattern 'target_spec_path:\s+\.github/comparevi-history-targets\.json' -Message 'Manual template must consume the checked-in target catalog.'
Assert-Match -Content $manualTemplate -Pattern 'target_id:\s+\$\{\{ inputs\.target_id \}\}' -Message 'Manual template must route a target id into the action.'
Assert-Match -Content $manualTemplate -Pattern 'reviewer_surface:\s+manual' -Message 'Manual template must declare the manual reviewer surface.'
Assert-Match -Content $manualTemplate -Pattern 'public-step-summary-path' -Message 'Manual template must consume the action-owned public step summary output.'
Assert-NotMatch -Content $manualTemplate -Pattern '## comparevi-history manual PR diagnostics' -Message 'Manual template must not rebuild the diagnostics summary inline.'

Assert-Match -Content $manualExplorationTemplate -Pattern '(?m)^\s*vi_path:\s*$' -Message 'Manual exploration template must accept vi_path.'
Assert-Match -Content $manualExplorationTemplate -Pattern '(?m)^\s*default:\s+develop\s*$' -Message 'Manual exploration template must default the consumer ref to develop.'
Assert-Match -Content $manualExplorationTemplate -Pattern '(?m)^\s*default:\s+attributes,front-panel,block-diagram\s*$' -Message 'Manual exploration template must default to explicit public modes only.'
Assert-Match -Content $manualExplorationTemplate -Pattern 'LabVIEW-Community-CI-CD/comparevi-history/\.github/workflows/manual-vi-exploration\.yml@v1' -Message 'Manual exploration template must call the reusable workflow surface.'
Assert-Match -Content $manualExplorationTemplate -Pattern 'platform_ref:\s+v1' -Message 'Manual exploration template must keep platform_ref aligned with the workflow pin.'
Assert-NotMatch -Content $manualExplorationTemplate -Pattern 'target_id:' -Message 'Manual exploration template must not require a curated target id.'
Assert-NotMatch -Content $manualExplorationTemplate -Pattern 'target_spec_path:' -Message 'Manual exploration template must not require a curated target spec.'

Assert-Match -Content $manualExplorationWorkflow -Pattern '(?m)^\s*workflow_call:\s*$' -Message 'Manual exploration workflow must be reusable.'
Assert-Match -Content $manualExplorationWorkflow -Pattern '(?m)^\s*workflow_dispatch:\s*$' -Message 'Manual exploration workflow must remain manually dispatchable.'
Assert-Match -Content $manualExplorationWorkflow -Pattern '(?m)^\s*vi_path:\s*$' -Message 'Manual exploration workflow must accept vi_path.'
Assert-Match -Content $manualExplorationWorkflow -Pattern 'Write-CompareVIHistoryRevisionCatalog\.ps1' -Message 'Manual exploration workflow must write the revision catalog.'
Assert-Match -Content $manualExplorationWorkflow -Pattern 'Write-CompareVIHistoryChunkPlan\.ps1' -Message 'Manual exploration workflow must write the chunk plan.'
Assert-Match -Content $manualExplorationWorkflow -Pattern 'Invoke-CompareVIHistoryChunkExecution\.ps1' -Message 'Manual exploration workflow must execute planned chunks.'
Assert-Match -Content $manualExplorationWorkflow -Pattern 'Write-CompareVIHistoryExplorationRun\.ps1' -Message 'Manual exploration workflow must write the exploration run receipt.'
Assert-Match -Content $manualExplorationWorkflow -Pattern 'revision-catalog-path' -Message 'Manual exploration workflow must expose the revision catalog output.'
Assert-Match -Content $manualExplorationWorkflow -Pattern 'chunk-plan-path' -Message 'Manual exploration workflow must expose the chunk plan output.'
Assert-Match -Content $manualExplorationWorkflow -Pattern 'execution-status' -Message 'Manual exploration workflow must expose the chunk execution status.'
Assert-Match -Content $manualExplorationWorkflow -Pattern 'exploration-run-path' -Message 'Manual exploration workflow must expose the exploration run output.'
Assert-Match -Content $manualExplorationWorkflow -Pattern 'timeline-md' -Message 'Manual exploration workflow must expose the timeline markdown output.'
Assert-Match -Content $manualExplorationWorkflow -Pattern 'timeline-html' -Message 'Manual exploration workflow must expose the timeline HTML output.'
Assert-Match -Content $manualExplorationWorkflow -Pattern 'platform_ref' -Message 'Manual exploration workflow must expose the platform_ref seam explicitly.'

Assert-Match -Content $commentTemplate -Pattern '(?m)^\s*runs-on:\s+ubuntu-latest\s*$' -Message 'Comment-gated template must use ubuntu-latest.'
Assert-Match -Content $commentTemplate -Pattern '(?m)^\s*pull-requests:\s+write\s*$' -Message 'Comment-gated template must request pull-requests: write.'
Assert-Match -Content $commentTemplate -Pattern '(?m)^\s*DEFAULT_COMPARE_MODES:\s+attributes,front-panel,block-diagram\s*$' -Message 'Comment-gated template must default to explicit public modes only.'
Assert-Match -Content $commentTemplate -Pattern '(?m)^\s*COMPAREVI_NI_LINUX_IMAGE:\s+nationalinstruments/labview:2026q1-linux\s*$' -Message 'Comment-gated template must pin the NI Linux image.'
Assert-Match -Content $commentTemplate -Pattern 'docker pull "\$COMPAREVI_NI_LINUX_IMAGE"' -Message 'Comment-gated template must pre-pull the NI Linux image.'
Assert-Match -Content $commentTemplate -Pattern 'invoke_script_path:\s+Tooling/Invoke-CompareVIHistoryHostedNILinux\.ps1' -Message 'Comment-gated template must use the hosted NI Linux invoke adapter.'
Assert-Match -Content $commentTemplate -Pattern 'target-id=' -Message 'Comment-gated template must parse a target id from the slash command.'
Assert-Match -Content $commentTemplate -Pattern 'target_spec_path:\s+\.github/comparevi-history-targets\.json' -Message 'Comment-gated template must consume the checked-in target catalog.'
Assert-Match -Content $commentTemplate -Pattern 'reviewer_surface:\s+comment-gated' -Message 'Comment-gated template must declare the comment-gated reviewer surface.'
Assert-Match -Content $commentTemplate -Pattern 'public-comment-path' -Message 'Comment-gated template must publish the action-owned comment body.'
Assert-Match -Content $commentTemplate -Pattern 'public-step-summary-path' -Message 'Comment-gated template must publish the action-owned step summary.'
Assert-Match -Content $commentTemplate -Pattern 'Resource not accessible by integration' -Message 'Comment-gated template must recognize permission-denied PR comment failures.'
Assert-Match -Content $commentTemplate -Pattern 'PR comment publication was denied by the repository token' -Message 'Comment-gated template must warn on denied PR comment publication.'
Assert-Match -Content $commentTemplate -Pattern 'PR comment publication: `skipped`' -Message 'Comment-gated template must record skipped PR comment publication in the step summary.'
Assert-NotMatch -Content $commentTemplate -Pattern 'comparevi-history diagnostics finished for PR' -Message 'Comment-gated template must not rebuild the PR comment inline.'
Assert-NotMatch -Content $commentTemplate -Pattern '(?m)^\s*DEFAULT_COMPARE_MODES:\s+default,' -Message 'Comment-gated template must not default to aggregate public modes.'

Assert-Match -Content $exampleTargets -Pattern 'comparevi-history/consumer-targets@v1' -Message 'Example targets file must declare the consumer-targets schema.'
Assert-Match -Content $exampleTargets -Pattern '"publicModes"' -Message 'Example targets file must declare public modes.'
Assert-Match -Content $safeTemplates -Pattern 'attributes,front-panel,block-diagram' -Message 'Safe template docs must document the explicit public mode contract.'
Assert-Match -Content $safeTemplates -Pattern '\.github/comparevi-history-targets\.json' -Message 'Safe template docs must document the checked-in target catalog path.'
Assert-Match -Content $safeTemplates -Pattern 'public-comment-path' -Message 'Safe template docs must point consumers at the action-owned comment output.'
Assert-Match -Content $safeTemplates -Pattern 'public-step-summary-path' -Message 'Safe template docs must point consumers at the action-owned step summary output.'
Assert-Match -Content $publishedValidationWorkflow -Pattern '\.github/comparevi-history-targets\.json' -Message 'Published validation must synthesize a checked-in-style target catalog path.'
Assert-Match -Content $publishedValidationWorkflow -Pattern 'target_spec_path:\s+\.github/comparevi-history-targets\.json' -Message 'Published validation must route target_spec_path into the action.'
Assert-Match -Content $publishedValidationWorkflow -Pattern 'target_id:\s+published-consumer-target' -Message 'Published validation must route a stable target id into the action.'
Assert-Match -Content $publishedValidationWorkflow -Pattern 'history-summary-json' -Message 'Published validation must consume the action-owned history summary output.'
Assert-Match -Content $publishedValidationWorkflow -Pattern 'public-comment-path' -Message 'Published validation must consume the action-owned public comment output.'
Assert-Match -Content $publishedValidationWorkflow -Pattern 'public-step-summary-path' -Message 'Published validation must consume the action-owned public step summary output.'
Assert-Match -Content $publishedValidationWorkflow -Pattern '(?m)^\s*default:\s+attributes,front-panel,block-diagram\s*$' -Message 'Published validation must default to explicit public modes only.'
Assert-NotMatch -Content $publishedValidationWorkflow -Pattern '(?m)^\s*default:\s+default,attributes,front-panel,block-diagram\s*$' -Message 'Published validation must not default to aggregate aliases for public modes.'
Assert-Match -Content $smokeWorkflow -Pattern 'comparevi-backend-ref\.txt' -Message 'Smoke workflow must resolve the repo-pinned backend release tag.'
Assert-Match -Content $releaseWorkflow -Pattern 'comparevi-backend-ref\.txt' -Message 'Release workflow must read comparevi-backend-ref.txt.'
Assert-Match -Content $releaseWorkflow -Pattern "tooling-source'\] -ne 'bundle'" -Message 'Release workflow must fail closed when the resolved backend is not a bundle release.'
Assert-Match -Content $releaseWorkflow -Pattern 'scripts/Resolve-CompareVIHistoryReleasePublishReadiness\.ps1' -Message 'Release workflow must check publish readiness against already-reviewed main content.'
Assert-Match -Content $releaseWorkflow -Pattern 'if \[ "\$current_head_sha" != "\$current_main_sha" \]; then' -Message 'Release workflow must verify publish still targets the current origin/main tip before tagging.'
Assert-Match -Content $releaseWorkflow -Pattern 'Published comment-gated template already points at' -Message 'Release notes must mention the published comment-gated template pin.'
Assert-Match -Content $releaseWorkflow -Pattern 'git push origin "refs/tags/\$IMMUTABLE_TAG"' -Message 'Release workflow must push only the immutable tag during publish.'
Assert-Match -Content $releaseWorkflow -Pattern '(?s)uses:\s+\./\.github/workflows/published-consumer-validation\.yml.*?compare_modes:\s+attributes,front-panel,block-diagram' -Message 'Release workflow must invoke published-consumer validation with explicit public modes only.'
Assert-NotMatch -Content $releaseWorkflow -Pattern '(?s)uses:\s+\./\.github/workflows/published-consumer-validation\.yml.*?compare_modes:\s+default,attributes,front-panel,block-diagram' -Message 'Release workflow must not invoke published-consumer validation with aggregate aliases.'
Assert-NotMatch -Content $releaseWorkflow -Pattern 'git push --atomic origin HEAD:main' -Message 'Release workflow must not push a fresh commit directly to protected main during publish.'
Assert-Match -Content $releaseReadinessScript -Pattern 'Sync-CompareVIHistoryPublishedTemplates\.ps1' -Message 'Release readiness helper must derive desired publish content through the published template sync script.'
Assert-Match -Content $actionYaml -Pattern '(?s)id:\s+public_run.*if:\s+\$\{\{\s*always\(\)\s*&&\s*steps\.request\.outcome == ''success''\s*&&\s*steps\.request\.outputs\[''request-path''\]\s*!=\s*''''\s*\}\}' -Message 'Action public-run writer must only run when the request receipt exists.'
Assert-Match -Content $readme -Pattern 'comparevi-history/consumer-targets@v1' -Message 'README must document the target catalog contract.'
Assert-Match -Content $readme -Pattern 'comparevi-history/public-run@v1' -Message 'README must document the public run contract.'
Assert-Match -Content $readme -Pattern 'comparevi-history/revision-catalog@v1' -Message 'README must document the revision catalog contract.'
Assert-Match -Content $readme -Pattern 'comparevi-history/exploration-run@v1' -Message 'README must document the exploration run contract.'
Assert-Match -Content $readme -Pattern 'timeline\.md' -Message 'README must document the timeline markdown output.'
Assert-Match -Content $readme -Pattern 'timeline\.html' -Message 'README must document the timeline HTML output.'
Assert-Match -Content $readme -Pattern 'docs/examples/comparevi-history-manual-vi-exploration\.yml' -Message 'README must point to the manual exploration wrapper example.'
Assert-Match -Content $readme -Pattern 'hosted NI Linux container path wired by a repo-local adapter' -Message 'README must document the hosted NI Linux adapter path.'
Assert-Match -Content $readme -Pattern 'public-comment-path' -Message 'README must document the action-owned public comment output.'
Assert-Match -Content $readme -Pattern 'attributes`, `front-panel`, and `block-diagram' -Message 'README must document explicit public modes only.'
Assert-Match -Content $readme -Pattern 'comparevi-history/issues/24' -Message 'README must point at the comparevi-history platform-boundary epic.'
Assert-Match -Content $readme -Pattern 'merge a\s+prep PR first' -Message 'README must explain the protected-main release prep requirement.'
Assert-NotMatch -Content $readme -Pattern 'compare-vi-cli-action/issues/841' -Message 'README must not point at the legacy compare-vi-cli-action tracking epic.'

$facadeRefMatch = [regex]::Match($commentTemplate, '(?m)^\s*FACADE_REF:\s*(v[0-9]+\.[0-9]+\.[0-9]+)\s*$')
$usesRefMatch = [regex]::Match($commentTemplate, '(?m)^\s*uses:\s+LabVIEW-Community-CI-CD/comparevi-history@(v[0-9]+\.[0-9]+\.[0-9]+)\s*$')
$actionRefMatch = [regex]::Match($commentTemplate, '(?m)^\s*ACTION_REF:\s+LabVIEW-Community-CI-CD/comparevi-history@(v[0-9]+\.[0-9]+\.[0-9]+)\s*$')
$docsRefMatch = [regex]::Match($safeTemplates, 'LabVIEW-Community-CI-CD/comparevi-history@(v[0-9]+\.[0-9]+\.[0-9]+)')

foreach ($match in @($facadeRefMatch, $usesRefMatch, $actionRefMatch, $docsRefMatch)) {
  if (-not $match.Success) {
    throw 'Failed to resolve the published immutable tag across the comment-gated template contract.'
  }
}

$immutableTag = $facadeRefMatch.Groups[1].Value
Assert-Equal -Actual $usesRefMatch.Groups[1].Value -Expected $immutableTag -Message 'Comment-gated template uses: pin mismatch.'
Assert-Equal -Actual $actionRefMatch.Groups[1].Value -Expected $immutableTag -Message 'Comment-gated template ACTION_REF mismatch.'
Assert-Equal -Actual $docsRefMatch.Groups[1].Value -Expected $immutableTag -Message 'Safe template docs immutable tag mismatch.'
