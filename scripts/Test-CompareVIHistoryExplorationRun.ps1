Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$catalogScriptPath = Join-Path $PSScriptRoot 'Write-CompareVIHistoryRevisionCatalog.ps1'
$chunkPlanScriptPath = Join-Path $PSScriptRoot 'Write-CompareVIHistoryChunkPlan.ps1'
$explorationRunScriptPath = Join-Path $PSScriptRoot 'Write-CompareVIHistoryExplorationRun.ps1'
$schemaPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'docs' 'schemas' 'comparevi-history-exploration-run-v1.schema.json'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("comparevi-history-exploration-run-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

function Invoke-Git {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryRoot,
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  $output = & git -C $RepositoryRoot @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw ([string]::Join([Environment]::NewLine, @($output)))
  }

  return [string]::Join([Environment]::NewLine, @($output))
}

try {
  $repoRoot = Join-Path $tempRoot 'consumer'
  New-Item -ItemType Directory -Path $repoRoot -Force | Out-Null

  Invoke-Git -RepositoryRoot $repoRoot -Arguments @('init', '--initial-branch=main') | Out-Null
  Invoke-Git -RepositoryRoot $repoRoot -Arguments @('config', 'user.name', 'comparevi-history-test') | Out-Null
  Invoke-Git -RepositoryRoot $repoRoot -Arguments @('config', 'user.email', 'comparevi-history-test@example.com') | Out-Null

  $targetDir = Join-Path $repoRoot 'Tooling' 'deployment'
  New-Item -ItemType Directory -Path $targetDir -Force | Out-Null

  foreach ($ordinal in 1..4) {
    "v$ordinal" | Set-Content -LiteralPath (Join-Path $targetDir 'Target.vi') -Encoding utf8
    Invoke-Git -RepositoryRoot $repoRoot -Arguments @('add', 'Tooling/deployment/Target.vi') | Out-Null
    Invoke-Git -RepositoryRoot $repoRoot -Arguments @('commit', '-m', "Revision $ordinal") | Out-Null
  }

  $resultsDir = Join-Path $tempRoot 'results'
  & $catalogScriptPath `
    -RepositoryRoot $repoRoot `
    -TargetPath 'Tooling/deployment/Target.vi' `
    -SelectedRef 'HEAD' `
    -ConsumerRepository 'LabVIEW-Community-CI-CD/labview-icon-editor-demo' `
    -ConsumerRef 'develop' `
    -ResultsDir $resultsDir | Out-Null

  & $chunkPlanScriptPath `
    -RevisionCatalogPath (Join-Path $resultsDir 'revision-catalog.json') `
    -ChunkPairLimit 2 `
    -ResultsDir $resultsDir | Out-Null

  $githubOutputPath = Join-Path $tempRoot 'exploration-run-output.txt'
  $summaryPath = Join-Path $tempRoot 'exploration-run-summary.md'
  $explorationRunJson = & $explorationRunScriptPath `
    -RevisionCatalogPath (Join-Path $resultsDir 'revision-catalog.json') `
    -ChunkPlanPath (Join-Path $resultsDir 'chunk-plan.json') `
    -Modes 'attributes,front-panel,block-diagram' `
    -NoisePolicy 'collapse' `
    -GitHubOutputPath $githubOutputPath `
    -StepSummaryPath $summaryPath

  $explorationRun = $explorationRunJson | ConvertFrom-Json -Depth 64
  if ($explorationRun.schema -ne 'comparevi-history/exploration-run@v1') {
    throw 'Exploration run schema mismatch.'
  }
  if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
    throw 'Exploration run schema file is missing.'
  }
  if ($explorationRun.discovery.revisionCount -ne 4) {
    throw 'Exploration run revision count mismatch.'
  }
  if ($explorationRun.planning.chunkCount -ne 2) {
    throw 'Exploration run chunk count mismatch.'
  }
  if ($explorationRun.summary.finalStatus -ne 'planned') {
    throw 'Exploration run final status mismatch.'
  }
  if ($explorationRun.summary.finalReason -ne 'chunk-plan-ready') {
    throw 'Exploration run final reason mismatch.'
  }
  if ($explorationRun.replay.status -ne 'ready-for-chunk-execution') {
    throw 'Exploration run replay status mismatch.'
  }
  if (-not (Test-Path -LiteralPath (Join-Path $resultsDir 'exploration-run.json') -PathType Leaf)) {
    throw 'Exploration run file was not written.'
  }

  $githubOutputs = Get-Content -LiteralPath $githubOutputPath -Raw
  foreach ($requiredKey in @(
      'exploration-run-path=',
      'exploration-status=planned',
      'exploration-reason=chunk-plan-ready'
    )) {
    if ($githubOutputs -notmatch [regex]::Escape($requiredKey)) {
      throw "Expected GitHub output '$requiredKey'."
    }
  }

  $summary = Get-Content -LiteralPath $summaryPath -Raw
  if ($summary -notmatch 'comparevi-history exploration run') {
    throw 'Exploration run summary was not written.'
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
