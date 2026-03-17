Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$catalogScriptPath = Join-Path $PSScriptRoot 'Write-CompareVIHistoryRevisionCatalog.ps1'
$chunkPlanScriptPath = Join-Path $PSScriptRoot 'Write-CompareVIHistoryChunkPlan.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("comparevi-history-chunk-plan-" + [guid]::NewGuid().ToString('N'))
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

  foreach ($ordinal in 1..6) {
    "v$ordinal" | Set-Content -LiteralPath (Join-Path $targetDir 'Target.vi') -Encoding utf8
    Invoke-Git -RepositoryRoot $repoRoot -Arguments @('add', 'Tooling/deployment/Target.vi') | Out-Null
    Invoke-Git -RepositoryRoot $repoRoot -Arguments @('commit', '-m', "Revision $ordinal") | Out-Null
  }

  $resultsDir = Join-Path $tempRoot 'results'
  $catalogJson = & $catalogScriptPath `
    -RepositoryRoot $repoRoot `
    -TargetPath 'Tooling/deployment/Target.vi' `
    -SelectedRef 'HEAD' `
    -ConsumerRepository 'LabVIEW-Community-CI-CD/labview-icon-editor-demo' `
    -ConsumerRef 'develop' `
    -ResultsDir $resultsDir
  $catalog = $catalogJson | ConvertFrom-Json -Depth 64

  $githubOutputPath = Join-Path $tempRoot 'chunk-plan-output.txt'
  $summaryPath = Join-Path $tempRoot 'chunk-plan-summary.md'
  $chunkPlanJson = & $chunkPlanScriptPath `
    -RevisionCatalogPath (Join-Path $resultsDir 'revision-catalog.json') `
    -ChunkPairLimit 2 `
    -GitHubOutputPath $githubOutputPath `
    -StepSummaryPath $summaryPath

  $chunkPlan = $chunkPlanJson | ConvertFrom-Json -Depth 64
  if ($chunkPlan.schema -ne 'comparevi-history/chunk-plan@v1') {
    throw 'Chunk plan schema mismatch.'
  }
  if ($chunkPlan.summary.revisionCount -ne 6) {
    throw 'Chunk plan revision count mismatch.'
  }
  if ($chunkPlan.summary.pairCount -ne 5) {
    throw 'Chunk plan pair count mismatch.'
  }
  if ($chunkPlan.summary.chunkCount -ne 3) {
    throw 'Chunk count mismatch.'
  }
  if ($chunkPlan.summary.chunkPairLimit -ne 2) {
    throw 'Chunk pair limit mismatch.'
  }
  if ($chunkPlan.chunks[0].pairOrdinalStart -ne 1 -or $chunkPlan.chunks[0].pairOrdinalEnd -ne 2) {
    throw 'First chunk pair range mismatch.'
  }
  if ($chunkPlan.chunks[0].revisionOrdinalStart -ne 1 -or $chunkPlan.chunks[0].revisionOrdinalEnd -ne 3) {
    throw 'First chunk revision range mismatch.'
  }
  if ($chunkPlan.chunks[2].pairCount -ne 1) {
    throw 'Tail chunk pair count mismatch.'
  }
  if (-not (Test-Path -LiteralPath $chunkPlan.chunks[0].outputs.receiptPath -PathType Leaf)) {
    throw 'Chunk receipt was not written.'
  }
  if (-not (Test-Path -LiteralPath (Join-Path $resultsDir 'chunk-plan.json') -PathType Leaf)) {
    throw 'Chunk plan file was not written.'
  }

  $githubOutputs = Get-Content -LiteralPath $githubOutputPath -Raw
  foreach ($requiredKey in @(
      'chunk-plan-path=',
      'chunk-receipts-root=',
      'chunk-count=3',
      'executable-pair-count=5',
      'chunk-pair-limit=2',
      'planning-status=planned',
      'planning-reason=chunk-plan-ready'
    )) {
    if ($githubOutputs -notmatch [regex]::Escape($requiredKey)) {
      throw "Expected GitHub output '$requiredKey'."
    }
  }

  $summary = Get-Content -LiteralPath $summaryPath -Raw
  if ($summary -notmatch 'comparevi-history chunk plan') {
    throw 'Chunk plan summary was not written.'
  }

  if ($catalog.summary.revisionCount -ne 6) {
    throw 'Catalog precondition mismatch.'
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
