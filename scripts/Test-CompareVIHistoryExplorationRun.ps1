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

  $chunkPlanJson = & $chunkPlanScriptPath `
    -RevisionCatalogPath (Join-Path $resultsDir 'revision-catalog.json') `
    -ChunkPairLimit 2 `
    -ResultsDir $resultsDir
  $chunkPlan = $chunkPlanJson | ConvertFrom-Json -Depth 64

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
  if ($explorationRun.publication.bundleStatus -ne 'not-required') {
    throw 'Exploration run bundle status mismatch for the planning-only path.'
  }
  if ($explorationRun.replay.status -ne 'ready-for-chunk-execution') {
    throw 'Exploration run replay status mismatch.'
  }
  if (-not (Test-Path -LiteralPath $explorationRun.outputs.timelineMd -PathType Leaf)) {
    throw 'Timeline markdown was not written for the planned exploration run.'
  }
  if (-not (Test-Path -LiteralPath $explorationRun.outputs.timelineHtml -PathType Leaf)) {
    throw 'Timeline HTML was not written for the planned exploration run.'
  }
  if (-not (Test-Path -LiteralPath (Join-Path $resultsDir 'exploration-run.json') -PathType Leaf)) {
    throw 'Exploration run file was not written.'
  }

  $githubOutputs = Get-Content -LiteralPath $githubOutputPath -Raw
  foreach ($requiredKey in @(
      'exploration-run-path=',
      'exploration-status=planned',
      'exploration-reason=chunk-plan-ready',
      'timeline-md=',
      'timeline-html=',
      'bundle-path='
    )) {
    if ($githubOutputs -notmatch [regex]::Escape($requiredKey)) {
      throw "Expected GitHub output '$requiredKey'."
    }
  }

  $summary = Get-Content -LiteralPath $summaryPath -Raw
  if ($summary -notmatch 'comparevi-history exploration run') {
    throw 'Exploration run summary was not written.'
  }

  $firstReceiptPath = [string]$chunkPlan.chunks[0].outputs.receiptPath
  $secondReceiptPath = [string]$chunkPlan.chunks[1].outputs.receiptPath
  $firstHistoryDir = Join-Path $tempRoot 'chunk-1-history'
  $secondHistoryDir = Join-Path $tempRoot 'chunk-2-history'
  New-Item -ItemType Directory -Path $firstHistoryDir -Force | Out-Null
  New-Item -ItemType Directory -Path $secondHistoryDir -Force | Out-Null
  $firstReportMd = Join-Path $firstHistoryDir 'history-report.md'
  $firstReportHtml = Join-Path $firstHistoryDir 'history-report.html'
  '# chunk 1 report' | Set-Content -LiteralPath $firstReportMd -Encoding utf8
  '<html><body>chunk 1 report</body></html>' | Set-Content -LiteralPath $firstReportHtml -Encoding utf8

  $firstReceipt = [ordered]@{
    schema = 'comparevi-history/chunk-receipt@v1'
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    chunkId = [string]$chunkPlan.chunks[0].chunkId
    chunkOrdinal = [int]$chunkPlan.chunks[0].chunkOrdinal
    segmentOrdinal = [int]$chunkPlan.chunks[0].segmentOrdinal
    status = 'succeeded'
    pairCount = [int]$chunkPlan.chunks[0].pairCount
    pairOrdinalStart = [int]$chunkPlan.chunks[0].pairOrdinalStart
    pairOrdinalEnd = [int]$chunkPlan.chunks[0].pairOrdinalEnd
    revisionOrdinalStart = [int]$chunkPlan.chunks[0].revisionOrdinalStart
    revisionOrdinalEnd = [int]$chunkPlan.chunks[0].revisionOrdinalEnd
    execution = [ordered]@{
      startRef = [string]$chunkPlan.chunks[0].execution.startRef
      endRef = [string]$chunkPlan.chunks[0].execution.endRef
      maxPairs = [int]$chunkPlan.chunks[0].execution.maxPairs
    }
    outputs = [ordered]@{
      chunkRoot = [string]$chunkPlan.chunks[0].outputs.chunkRoot
      receiptPath = $firstReceiptPath
      manifestPath = [string]$chunkPlan.chunks[0].outputs.manifestPath
      historyResultsDir = $firstHistoryDir
      historyReportMd = $firstReportMd
      historyReportHtml = $firstReportHtml
      modeSummaryPath = $null
    }
    summary = [ordered]@{
      requestedModes = @('attributes', 'front-panel', 'block-diagram')
      executedModes = @('attributes', 'front-panel', 'block-diagram')
      modeCount = 3
      totalProcessed = 2
      totalDiffs = 1
      stopReason = 'completed'
      finalStatus = 'succeeded'
      finalReason = 'completed'
    }
    failure = $null
  }
  $firstReceipt | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $firstReceiptPath -Encoding utf8

  $secondReceipt = [ordered]@{
    schema = 'comparevi-history/chunk-receipt@v1'
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    chunkId = [string]$chunkPlan.chunks[1].chunkId
    chunkOrdinal = [int]$chunkPlan.chunks[1].chunkOrdinal
    segmentOrdinal = [int]$chunkPlan.chunks[1].segmentOrdinal
    status = 'failed'
    pairCount = [int]$chunkPlan.chunks[1].pairCount
    pairOrdinalStart = [int]$chunkPlan.chunks[1].pairOrdinalStart
    pairOrdinalEnd = [int]$chunkPlan.chunks[1].pairOrdinalEnd
    revisionOrdinalStart = [int]$chunkPlan.chunks[1].revisionOrdinalStart
    revisionOrdinalEnd = [int]$chunkPlan.chunks[1].revisionOrdinalEnd
    execution = [ordered]@{
      startRef = [string]$chunkPlan.chunks[1].execution.startRef
      endRef = [string]$chunkPlan.chunks[1].execution.endRef
      maxPairs = [int]$chunkPlan.chunks[1].execution.maxPairs
    }
    outputs = [ordered]@{
      chunkRoot = [string]$chunkPlan.chunks[1].outputs.chunkRoot
      receiptPath = $secondReceiptPath
      manifestPath = [string]$chunkPlan.chunks[1].outputs.manifestPath
      historyResultsDir = $secondHistoryDir
      historyReportMd = $null
      historyReportHtml = $null
      modeSummaryPath = $null
    }
    summary = [ordered]@{
      requestedModes = @('attributes', 'front-panel', 'block-diagram')
      executedModes = @()
      modeCount = 0
      totalProcessed = 0
      totalDiffs = 0
      stopReason = 'facade-step-failed'
      finalStatus = 'failed'
      finalReason = 'facade-step-failed'
    }
    failure = [ordered]@{
      message = 'Forced compare failure.'
    }
  }
  $secondReceipt | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $secondReceiptPath -Encoding utf8

  $executedOutputPath = Join-Path $tempRoot 'exploration-run-executed-output.txt'
  $executedSummaryPath = Join-Path $tempRoot 'exploration-run-executed-summary.md'
  $executedRunJson = & $explorationRunScriptPath `
    -RevisionCatalogPath (Join-Path $resultsDir 'revision-catalog.json') `
    -ChunkPlanPath (Join-Path $resultsDir 'chunk-plan.json') `
    -Modes 'attributes,front-panel,block-diagram' `
    -NoisePolicy 'collapse' `
    -GitHubOutputPath $executedOutputPath `
    -StepSummaryPath $executedSummaryPath

  $executedRun = $executedRunJson | ConvertFrom-Json -Depth 64
  if ($executedRun.planning.status -ne 'partial') {
    throw 'Executed exploration run planning status mismatch.'
  }
  if ($executedRun.summary.finalStatus -ne 'partial') {
    throw 'Executed exploration run final status mismatch.'
  }
  if ($executedRun.summary.finalReason -ne 'one-or-more-chunks-failed') {
    throw 'Executed exploration run final reason mismatch.'
  }
  if ($executedRun.replay.status -ne 'degraded') {
    throw 'Executed exploration run replay status mismatch.'
  }

  $timelineMarkdown = Get-Content -LiteralPath $executedRun.outputs.timelineMd -Raw
  if ($timelineMarkdown -notmatch [regex]::Escape([string]$chunkPlan.chunks[0].chunkId)) {
    throw 'Timeline markdown must include the executed chunk id.'
  }
  if ($timelineMarkdown -notmatch 'Failure: `Forced compare failure\.?`') {
    throw 'Timeline markdown must include the failed chunk message.'
  }

  $secondReceipt.status = 'succeeded'
  $secondReceipt.summary.executedModes = @('attributes', 'front-panel', 'block-diagram')
  $secondReceipt.summary.modeCount = 3
  $secondReceipt.summary.totalProcessed = [int]$chunkPlan.chunks[1].pairCount
  $secondReceipt.summary.totalDiffs = 1
  $secondReceipt.summary.stopReason = 'completed'
  $secondReceipt.summary.finalStatus = 'succeeded'
  $secondReceipt.summary.finalReason = 'completed'
  $secondReceipt.failure = $null
  $secondReceipt | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $secondReceiptPath -Encoding utf8

  $bundleDir = Join-Path $tempRoot 'bundle'
  New-Item -ItemType Directory -Path $bundleDir -Force | Out-Null
  $bundlePath = Join-Path $bundleDir 'manual-vi-exploration-bundle.zip'
  [System.IO.File]::WriteAllBytes($bundlePath, @(0x50,0x4B,0x03,0x04))

  $bundleOutputPath = Join-Path $tempRoot 'exploration-run-bundle-output.txt'
  $bundleSummaryPath = Join-Path $tempRoot 'exploration-run-bundle-summary.md'
  $bundledRunJson = & $explorationRunScriptPath `
    -RevisionCatalogPath (Join-Path $resultsDir 'revision-catalog.json') `
    -ChunkPlanPath (Join-Path $resultsDir 'chunk-plan.json') `
    -Modes 'attributes,front-panel,block-diagram' `
    -NoisePolicy 'collapse' `
    -BundlePath $bundlePath `
    -BundleStatus 'succeeded' `
    -BundleReason 'bundle-created' `
    -GitHubOutputPath $bundleOutputPath `
    -StepSummaryPath $bundleSummaryPath
  $bundledRun = $bundledRunJson | ConvertFrom-Json -Depth 64
  if ($bundledRun.outputs.bundlePath -ne $bundlePath) {
    throw 'Bundled exploration run must record bundlePath.'
  }
  if ($bundledRun.publication.bundleStatus -ne 'succeeded') {
    throw 'Bundled exploration run publication status mismatch.'
  }

  $bundleFailureOutputPath = Join-Path $tempRoot 'exploration-run-bundle-failure-output.txt'
  $bundleFailureSummaryPath = Join-Path $tempRoot 'exploration-run-bundle-failure-summary.md'
  $bundleFailureRunJson = & $explorationRunScriptPath `
    -RevisionCatalogPath (Join-Path $resultsDir 'revision-catalog.json') `
    -ChunkPlanPath (Join-Path $resultsDir 'chunk-plan.json') `
    -Modes 'attributes,front-panel,block-diagram' `
    -NoisePolicy 'collapse' `
    -BundleStatus 'failed' `
    -BundleReason 'bundle-packaging-failed' `
    -GitHubOutputPath $bundleFailureOutputPath `
    -StepSummaryPath $bundleFailureSummaryPath
  $bundleFailureRun = $bundleFailureRunJson | ConvertFrom-Json -Depth 64
  if ($bundleFailureRun.summary.finalStatus -ne 'partial') {
    throw 'Bundle failure must degrade the final exploration run status.'
  }
  if ($bundleFailureRun.summary.finalReason -ne 'bundle-packaging-failed') {
    throw 'Bundle failure final reason mismatch.'
  }
  if ($bundleFailureRun.publication.bundleStatus -ne 'failed') {
    throw 'Bundle failure publication status mismatch.'
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
