Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$catalogScriptPath = Join-Path $PSScriptRoot 'Write-CompareVIHistoryRevisionCatalog.ps1'
$chunkPlanScriptPath = Join-Path $PSScriptRoot 'Write-CompareVIHistoryChunkPlan.ps1'
$executionScriptPath = Join-Path $PSScriptRoot 'Invoke-CompareVIHistoryChunkExecution.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("comparevi-history-chunk-execution-" + [guid]::NewGuid().ToString('N'))
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
  $consumerRoot = Join-Path $tempRoot 'consumer'
  New-Item -ItemType Directory -Path $consumerRoot -Force | Out-Null

  Invoke-Git -RepositoryRoot $consumerRoot -Arguments @('init', '--initial-branch=main') | Out-Null
  Invoke-Git -RepositoryRoot $consumerRoot -Arguments @('config', 'user.name', 'comparevi-history-test') | Out-Null
  Invoke-Git -RepositoryRoot $consumerRoot -Arguments @('config', 'user.email', 'comparevi-history-test@example.com') | Out-Null

  $deploymentDir = Join-Path $consumerRoot 'Tooling' 'deployment'
  $toolingDir = Join-Path $consumerRoot 'Tooling'
  New-Item -ItemType Directory -Path $deploymentDir -Force | Out-Null

  foreach ($ordinal in 1..4) {
    "v$ordinal" | Set-Content -LiteralPath (Join-Path $deploymentDir 'Target.vi') -Encoding utf8
    Invoke-Git -RepositoryRoot $consumerRoot -Arguments @('add', 'Tooling/deployment/Target.vi') | Out-Null
    Invoke-Git -RepositoryRoot $consumerRoot -Arguments @('commit', '-m', "Revision $ordinal") | Out-Null
  }

  $consumerAdapterPath = Join-Path $toolingDir 'Invoke-CompareVIHistoryHostedNILinux.ps1'
  'param()' | Set-Content -LiteralPath $consumerAdapterPath -Encoding utf8

  $toolingRoot = Join-Path $tempRoot 'tooling'
  $toolingToolsDir = Join-Path $toolingRoot 'tools'
  New-Item -ItemType Directory -Path $toolingToolsDir -Force | Out-Null
  @'
param(
  [string]$TargetPath,
  [string]$StartRef,
  [string]$EndRef,
  [Nullable[int]]$MaxPairs,
  [object]$Mode,
  [string]$InvokeScriptPath,
  [string]$ResultsDir,
  [string]$GitHubOutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($InvokeScriptPath) -or -not (Test-Path -LiteralPath $InvokeScriptPath -PathType Leaf)) {
  throw 'InvokeScriptPath must point to an existing adapter script.'
}

if ($env:COMPAREVI_HISTORY_TEST_FAIL_START_REF -and $env:COMPAREVI_HISTORY_TEST_FAIL_START_REF -eq $StartRef) {
  throw "Forced compare failure for start ref $StartRef."
}

New-Item -ItemType Directory -Path $ResultsDir -Force | Out-Null
$manifestPath = Join-Path $ResultsDir 'manifest.json'
$historySummaryPath = Join-Path $ResultsDir 'history-summary.json'
$historyReportMd = Join-Path $ResultsDir 'history-report.md'
$historyReportHtml = Join-Path $ResultsDir 'history-report.html'

$modeValues = @()
if ($Mode -is [System.Array]) {
  $modeValues = @($Mode | ForEach-Object { [string]$_ })
} elseif (-not [string]::IsNullOrWhiteSpace([string]$Mode)) {
  $modeValues = @(([string]$Mode -split '[,;]') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}
if ($modeValues.Count -eq 0) {
  $modeValues = @('attributes')
}

$modeEntries = New-Object System.Collections.Generic.List[object]
foreach ($entry in $modeValues) {
  $slug = $entry.ToLowerInvariant()
  $modeDir = Join-Path $ResultsDir $slug
  New-Item -ItemType Directory -Path $modeDir -Force | Out-Null
  $modeManifestPath = Join-Path $modeDir 'manifest.json'
  $artifactDir = Join-Path $modeDir 'pair-001-artifacts'
  $imagesDir = Join-Path $artifactDir 'cli-images'
  New-Item -ItemType Directory -Path $imagesDir -Force | Out-Null
  [System.IO.File]::WriteAllBytes((Join-Path $imagesDir 'cli-image-00.png'), @(0xCA,0xFE,0xBA,0xBE))
  @(
    '{'
    '  "schema": "lvcompare-capture-v1",'
    '  "environment": {'
    '    "cli": {'
    '      "artifacts": {'
    '        "images": ['
    '          {'
    '            "index": 0,'
    '            "mimeType": "image/png",'
    '            "byteLength": 4,'
    ('            "savedPath": "{0}"' -f ((Join-Path $imagesDir 'cli-image-00.png') -replace '\\','\\\\'))
    '          }'
    '        ]'
    '      }'
    '    }'
    '  }'
    '}'
  ) | Set-Content -LiteralPath (Join-Path $artifactDir 'lvcompare-capture.json') -Encoding utf8
  @(
    '{'
    '  "schema": "vi-compare/history@v1",'
    '  "comparisons": ['
    '    {'
    '      "result": {'
    ('        "artifactDir": "{0}"' -f ($artifactDir -replace '\\','\\\\'))
    '      }'
    '    }'
    '  ],'
    '  "stats": {'
    '    "categoryCounts": { "attributes": 1 },'
    '    "bucketCounts": { "metadata-rich": 1 }'
    '  }'
    '}'
  ) | Set-Content -LiteralPath $modeManifestPath -Encoding utf8
  [void]$modeEntries.Add([ordered]@{
      mode = $entry
      slug = $slug
      manifest = $modeManifestPath
      resultsDir = $modeDir
      processed = if ($null -eq $MaxPairs) { 1 } else { [int]$MaxPairs }
      diffs = 1
      signalDiffs = 1
      noiseCollapsed = 0
      errors = 0
      status = 'ok'
      stopReason = 'completed'
      flags = @()
      categoryCounts = [ordered]@{ attributes = 1 }
      bucketCounts = [ordered]@{ 'metadata-rich' = 1 }
    })
}

'{}' | Set-Content -LiteralPath $manifestPath -Encoding utf8
@{
  schema = 'comparevi-tools/history-facade@v1'
  targetPath = $TargetPath
  startRef = $StartRef
  endRef = $EndRef
  invokeScriptPath = $InvokeScriptPath
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $historySummaryPath -Encoding utf8
"# report for $StartRef" | Set-Content -LiteralPath $historyReportMd -Encoding utf8
"<html><body>report for $StartRef</body></html>" | Set-Content -LiteralPath $historyReportHtml -Encoding utf8

$processedCount = if ($null -eq $MaxPairs) { 1 } else { [int]$MaxPairs }
@(
  "target-path=$TargetPath"
  "manifest-path=$manifestPath"
  "results-dir=$ResultsDir"
  "history-summary-json=$historySummaryPath"
  "history-report-md=$historyReportMd"
  "history-report-html=$historyReportHtml"
  "mode-count=$($modeValues.Count)"
  "total-processed=$processedCount"
  'total-diffs=1'
  'stop-reason=completed'
  'category-counts-json={}'
  'bucket-counts-json={}'
  ("mode-manifests-json={0}" -f (($modeEntries.ToArray() | ConvertTo-Json -Depth 8 -Compress)))
  ("requested-mode-list={0}" -f ($modeValues -join ','))
  ("executed-mode-list={0}" -f ($modeValues -join ','))
  ("mode-list={0}" -f ($modeValues -join ','))
  'flag-list='
) | Set-Content -LiteralPath $GitHubOutputPath -Encoding utf8
'@ | Set-Content -LiteralPath (Join-Path $toolingToolsDir 'Compare-VIHistory.ps1') -Encoding utf8

  $resultsDir = Join-Path $tempRoot 'results'
  & $catalogScriptPath `
    -RepositoryRoot $consumerRoot `
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
  if ($chunkPlan.summary.chunkCount -ne 2) {
    throw 'Chunk-plan precondition mismatch.'
  }

  $githubOutputPath = Join-Path $tempRoot 'chunk-execution-output.txt'
  $summaryPath = Join-Path $tempRoot 'chunk-execution-summary.md'
  $executionJson = & $executionScriptPath `
    -ConsumerRepositoryRoot $consumerRoot `
    -ChunkPlanPath (Join-Path $resultsDir 'chunk-plan.json') `
    -ResultsDir $resultsDir `
    -Mode 'attributes' `
    -ToolingRoot $toolingRoot `
    -GitHubOutputPath $githubOutputPath `
    -StepSummaryPath $summaryPath

  $execution = $executionJson | ConvertFrom-Json -Depth 32
  if ($execution.schema -ne 'comparevi-history/chunk-execution-summary@v1') {
    throw 'Chunk execution summary schema mismatch.'
  }
  if ($execution.completedChunkCount -ne 2) {
    throw 'Completed chunk count mismatch.'
  }
  if ($execution.failedChunkCount -ne 0) {
    throw 'Failed chunk count mismatch.'
  }
  if ($execution.executionStatus -ne 'succeeded') {
    throw 'Execution status mismatch.'
  }
  if ($execution.executionReason -ne 'all-chunks-succeeded') {
    throw 'Execution reason mismatch.'
  }

  foreach ($chunk in @($chunkPlan.chunks)) {
    $receipt = Get-Content -LiteralPath $chunk.outputs.receiptPath -Raw | ConvertFrom-Json -Depth 64
    if ($receipt.status -ne 'succeeded') {
      throw "Expected succeeded chunk receipt for $($chunk.chunkId)."
    }
    if ($receipt.summary.finalReason -ne 'completed') {
      throw "Expected completed final reason for $($chunk.chunkId)."
    }
    foreach ($path in @(
        $receipt.outputs.historySummaryJson,
        $receipt.outputs.historyReportMd,
        $receipt.outputs.historyReportHtml,
        $receipt.outputs.modeSummaryPath,
        $receipt.outputs.modeSummaryJsonPath
      )) {
      if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Expected chunk output path '$path'."
      }
    }
    if (-not $receipt.surfaces) {
      throw "Expected chunk surfaces summary for $($chunk.chunkId)."
    }
    if ($receipt.surfaces.metadata.captureCount -ne 1 -or $receipt.surfaces.metadata.imageArtifactCount -ne 1) {
      throw "Expected capture/image metadata counts for $($chunk.chunkId)."
    }
    if ($receipt.surfaces.suppressionProfile -ne 'unsuppressed') {
      throw "Expected unsuppressed mode profile for $($chunk.chunkId)."
    }
  }

  $githubOutputs = Get-Content -LiteralPath $githubOutputPath -Raw
  foreach ($requiredKey in @(
      'tooling-path=',
      'tooling-source=provided-tooling-root',
      'comparevi-ref=provided-tooling-root',
      'executed-chunk-count=2',
      'failed-chunk-count=0',
      'execution-status=succeeded',
      'execution-reason=all-chunks-succeeded'
    )) {
    if ($githubOutputs -notmatch [regex]::Escape($requiredKey)) {
      throw "Expected GitHub output '$requiredKey'."
    }
  }

  $summary = Get-Content -LiteralPath $summaryPath -Raw
  if ($summary -notmatch 'comparevi-history chunk execution') {
    throw 'Chunk execution summary markdown was not written.'
  }

  $partialResultsDir = Join-Path $tempRoot 'results-partial'
  Copy-Item -LiteralPath $resultsDir -Destination $partialResultsDir -Recurse
  $partialPlanPath = Join-Path $partialResultsDir 'chunk-plan.json'
  $partialPlan = Get-Content -LiteralPath $partialPlanPath -Raw | ConvertFrom-Json -Depth 64
  $env:COMPAREVI_HISTORY_TEST_FAIL_START_REF = [string]$partialPlan.chunks[0].execution.startRef
  try {
    $partialJson = & $executionScriptPath `
      -ConsumerRepositoryRoot $consumerRoot `
      -ChunkPlanPath $partialPlanPath `
      -ResultsDir $partialResultsDir `
      -Mode 'attributes' `
      -ToolingRoot $toolingRoot
  } finally {
    Remove-Item Env:COMPAREVI_HISTORY_TEST_FAIL_START_REF -ErrorAction SilentlyContinue
  }

  $partial = $partialJson | ConvertFrom-Json -Depth 32
  if ($partial.executionStatus -ne 'partial') {
    throw 'Expected partial execution status when one chunk fails.'
  }
  if ($partial.failedChunkCount -ne 1 -or $partial.completedChunkCount -ne 1) {
    throw 'Partial execution counts mismatch.'
  }
  $failedReceiptPath = [string]$partialPlan.chunks[0].outputs.receiptPath
  $failedReceipt = Get-Content -LiteralPath $failedReceiptPath -Raw | ConvertFrom-Json -Depth 64
  if ($failedReceipt.status -ne 'failed') {
    throw 'Expected failed chunk receipt for forced failure.'
  }
  if (-not $failedReceipt.failure -or [string]::IsNullOrWhiteSpace([string]$failedReceipt.failure.message)) {
    throw 'Expected failure details for forced chunk failure.'
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
