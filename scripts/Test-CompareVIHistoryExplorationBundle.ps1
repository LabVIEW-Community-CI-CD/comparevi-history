Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$catalogScriptPath = Join-Path $PSScriptRoot 'Write-CompareVIHistoryRevisionCatalog.ps1'
$chunkPlanScriptPath = Join-Path $PSScriptRoot 'Write-CompareVIHistoryChunkPlan.ps1'
$explorationRunScriptPath = Join-Path $PSScriptRoot 'Write-CompareVIHistoryExplorationRun.ps1'
$bundleScriptPath = Join-Path $PSScriptRoot 'Write-CompareVIHistoryExplorationBundle.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("comparevi-history-exploration-bundle-" + [guid]::NewGuid().ToString('N'))
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
  Add-Type -AssemblyName System.IO.Compression
  Add-Type -AssemblyName System.IO.Compression.FileSystem

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

  $chunkPlanJson = & $chunkPlanScriptPath `
    -RevisionCatalogPath (Join-Path $resultsDir 'revision-catalog.json') `
    -ChunkPairLimit 2 `
    -ResultsDir $resultsDir
  $chunkPlan = $chunkPlanJson | ConvertFrom-Json -Depth 64

  foreach ($chunk in @($chunkPlan.chunks)) {
    $chunkRoot = [string]$chunk.outputs.chunkRoot
    $historyDir = Join-Path $chunkRoot 'history'
    New-Item -ItemType Directory -Path $historyDir -Force | Out-Null
    '{}' | Set-Content -LiteralPath (Join-Path $historyDir 'history-summary.json') -Encoding utf8
    '# report' | Set-Content -LiteralPath (Join-Path $historyDir 'history-report.md') -Encoding utf8
    '<html><body>report</body></html>' | Set-Content -LiteralPath (Join-Path $historyDir 'history-report.html') -Encoding utf8
    '# mode summary' | Set-Content -LiteralPath (Join-Path $chunkRoot 'mode-summary.md') -Encoding utf8

    $receipt = Get-Content -LiteralPath ([string]$chunk.outputs.receiptPath) -Raw | ConvertFrom-Json -Depth 64
    $receipt.status = 'succeeded'
    $receipt | Add-Member -NotePropertyName summary -NotePropertyValue ([ordered]@{
        requestedModes = @('attributes', 'front-panel', 'block-diagram')
        executedModes = @('attributes', 'front-panel', 'block-diagram')
        modeCount = 3
        totalProcessed = [int]$chunk.pairCount
        totalDiffs = 1
        stopReason = 'completed'
        finalStatus = 'succeeded'
        finalReason = 'completed'
      }) -Force
    $receipt.outputs | Add-Member -NotePropertyName historyResultsDir -NotePropertyValue $historyDir -Force
    $receipt.outputs | Add-Member -NotePropertyName historySummaryJson -NotePropertyValue (Join-Path $historyDir 'history-summary.json') -Force
    $receipt.outputs | Add-Member -NotePropertyName historyReportMd -NotePropertyValue (Join-Path $historyDir 'history-report.md') -Force
    $receipt.outputs | Add-Member -NotePropertyName historyReportHtml -NotePropertyValue (Join-Path $historyDir 'history-report.html') -Force
    $receipt.outputs | Add-Member -NotePropertyName modeSummaryPath -NotePropertyValue (Join-Path $chunkRoot 'mode-summary.md') -Force
    $receipt | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath ([string]$chunk.outputs.receiptPath) -Encoding utf8
  }

  $explorationRunJson = & $explorationRunScriptPath `
    -RevisionCatalogPath (Join-Path $resultsDir 'revision-catalog.json') `
    -ChunkPlanPath (Join-Path $resultsDir 'chunk-plan.json') `
    -Modes 'attributes,front-panel,block-diagram' `
    -NoisePolicy 'collapse'
  $explorationRun = $explorationRunJson | ConvertFrom-Json -Depth 64

  $githubOutputPath = Join-Path $tempRoot 'bundle-output.txt'
  $summaryPath = Join-Path $tempRoot 'bundle-summary.md'
  $bundleJson = & $bundleScriptPath `
    -RevisionCatalogPath (Join-Path $resultsDir 'revision-catalog.json') `
    -ChunkPlanPath (Join-Path $resultsDir 'chunk-plan.json') `
    -ResultsDir $resultsDir `
    -ExplorationRunPath $explorationRun.outputs.explorationRunPath `
    -TimelineMd $explorationRun.outputs.timelineMd `
    -TimelineHtml $explorationRun.outputs.timelineHtml `
    -GitHubOutputPath $githubOutputPath `
    -StepSummaryPath $summaryPath

  $bundle = $bundleJson | ConvertFrom-Json -Depth 64
  if ($bundle.schema -ne 'comparevi-history/exploration-bundle@v1') {
    throw 'Exploration bundle schema mismatch.'
  }
  if ($bundle.bundle.status -ne 'succeeded') {
    throw 'Expected successful bundle publication.'
  }
  if (-not (Test-Path -LiteralPath $bundle.outputs.bundlePath -PathType Leaf)) {
    throw 'Bundle zip was not written.'
  }
  if (-not (Test-Path -LiteralPath (Join-Path $resultsDir 'bundle-manifest.json') -PathType Leaf)) {
    throw 'Bundle manifest was not written.'
  }

  $zip = [System.IO.Compression.ZipFile]::OpenRead([string]$bundle.outputs.bundlePath)
  try {
    $entryNames = @($zip.Entries | ForEach-Object { $_.FullName })
  } finally {
    $zip.Dispose()
  }

  foreach ($requiredEntry in @(
      'revision-catalog.json',
      'chunk-plan.json',
      'exploration-run.json',
      'timeline.md',
      'timeline.html',
      'chunk-receipts/chunk-001/chunk-receipt.json',
      'chunk-receipts/chunk-001/history/history-report.html'
    )) {
    if ($entryNames -notcontains $requiredEntry) {
      throw "Bundle entry '$requiredEntry' was not found."
    }
  }

  $githubOutputs = Get-Content -LiteralPath $githubOutputPath -Raw
  foreach ($requiredKey in @(
      'bundle-path=',
      'bundle-status=succeeded',
      'bundle-reason=bundle-created',
      'bundle-manifest-path='
    )) {
    if ($githubOutputs -notmatch [regex]::Escape($requiredKey)) {
      throw "Expected GitHub output '$requiredKey'."
    }
  }

  $summary = Get-Content -LiteralPath $summaryPath -Raw
  if ($summary -notmatch 'comparevi-history exploration bundle') {
    throw 'Bundle summary markdown was not written.'
  }

  $env:COMPAREVI_HISTORY_TEST_BUNDLE_FAIL = 'forced bundle failure'
  try {
    $failedBundleJson = & $bundleScriptPath `
      -RevisionCatalogPath (Join-Path $resultsDir 'revision-catalog.json') `
      -ChunkPlanPath (Join-Path $resultsDir 'chunk-plan.json') `
      -ResultsDir $resultsDir
  } finally {
    Remove-Item Env:COMPAREVI_HISTORY_TEST_BUNDLE_FAIL -ErrorAction SilentlyContinue
  }
  $failedBundle = $failedBundleJson | ConvertFrom-Json -Depth 64
  if ($failedBundle.bundle.status -ne 'failed') {
    throw 'Expected failed bundle status from the forced failure seam.'
  }
  if ($failedBundle.bundle.reason -ne 'bundle-packaging-failed') {
    throw 'Expected failed bundle reason mismatch.'
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
