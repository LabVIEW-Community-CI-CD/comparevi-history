param(
  [Parameter(Mandatory = $true)]
  [string]$ConsumerRepositoryRoot,
  [Parameter(Mandatory = $true)]
  [string]$ChunkPlanPath,
  [string]$ResultsDir,
  [string]$Mode = 'full',
  [ValidateSet('include', 'collapse', 'skip')]
  [string]$NoisePolicy = 'include',
  [switch]$IncludeMergeParents,
  [Nullable[int]]$MaxSignalPairs,
  [Nullable[int]]$CompareTimeoutSeconds,
  [string]$InvokeScriptPath,
  [string]$ToolingRoot,
  [string]$CompareviRepository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
  [string]$CompareviRef,
  [string]$GitHubToken,
  [string]$GitHubOutputPath,
  [string]$StepSummaryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-ActionOutput {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Key,
    [AllowNull()]
    [string]$Value
  )

  if ([string]::IsNullOrWhiteSpace($GitHubOutputPath)) {
    return
  }

  $safeValue = if ($null -eq $Value) { '' } else { [string]$Value }
  "$Key=$safeValue" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
}

function Resolve-AbsolutePath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$BasePath
  )

  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }

  return [System.IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function Resolve-GitHubToken {
  if (-not [string]::IsNullOrWhiteSpace($GitHubToken)) {
    return $GitHubToken.Trim()
  }

  foreach ($candidate in @($env:GITHUB_TOKEN, $env:GH_TOKEN)) {
    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
      return $candidate.Trim()
    }
  }

  return $null
}

function Read-KeyValueFile {
  param([Parameter(Mandatory = $true)][string]$Path)

  $values = @{}
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $values
  }

  foreach ($line in Get-Content -LiteralPath $Path) {
    if ($line -match '^(?<key>[^=]+)=(?<value>.*)$') {
      $values[$Matches['key']] = $Matches['value']
    }
  }

  return $values
}

function Resolve-DefaultInvokeScriptPath {
  param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

  $candidate = Join-Path $RepositoryRoot 'Tooling' 'Invoke-CompareVIHistoryHostedNILinux.ps1'
  if (Test-Path -LiteralPath $candidate -PathType Leaf) {
    return $candidate
  }

  return $null
}

function ConvertTo-NormalizedModeList {
  param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$Value
  )

  $modes = New-Object System.Collections.Generic.List[string]
  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($segment in @($Value -split '[,;]')) {
    $trimmed = $segment.Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
      continue
    }
    if ($seen.Add($trimmed)) {
      $modes.Add($trimmed) | Out-Null
    }
  }

  return @($modes.ToArray())
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$consumerRootResolved = Resolve-AbsolutePath -Path $ConsumerRepositoryRoot -BasePath (Get-Location).Path
if (-not (Test-Path -LiteralPath $consumerRootResolved -PathType Container)) {
  throw "Consumer repository root not found: $consumerRootResolved"
}

$chunkPlanPathResolved = Resolve-AbsolutePath -Path $ChunkPlanPath -BasePath (Get-Location).Path
if (-not (Test-Path -LiteralPath $chunkPlanPathResolved -PathType Leaf)) {
  throw "Chunk plan not found: $chunkPlanPathResolved"
}

$chunkPlan = Get-Content -LiteralPath $chunkPlanPathResolved -Raw | ConvertFrom-Json -Depth 64
if ([string]$chunkPlan.schema -ne 'comparevi-history/chunk-plan@v1') {
  throw "Unsupported chunk plan schema in '$chunkPlanPathResolved': $($chunkPlan.schema)"
}

$resultsDirResolved = if ([string]::IsNullOrWhiteSpace($ResultsDir)) {
  Split-Path -Parent $chunkPlanPathResolved
} else {
  Resolve-AbsolutePath -Path $ResultsDir -BasePath $consumerRootResolved
}
New-Item -ItemType Directory -Path $resultsDirResolved -Force | Out-Null

$effectiveInvokeScriptPath = if (-not [string]::IsNullOrWhiteSpace($InvokeScriptPath)) {
  Resolve-AbsolutePath -Path $InvokeScriptPath -BasePath $consumerRootResolved
} else {
  Resolve-DefaultInvokeScriptPath -RepositoryRoot $consumerRootResolved
}
if ([string]::IsNullOrWhiteSpace($effectiveInvokeScriptPath) -or -not (Test-Path -LiteralPath $effectiveInvokeScriptPath -PathType Leaf)) {
  throw 'Manual VI exploration execution requires invoke_script_path or a consumer-local Tooling/Invoke-CompareVIHistoryHostedNILinux.ps1 adapter.'
}

$resolvedGitHubToken = Resolve-GitHubToken
$toolingRootResolved = $null
$toolingSource = $null
$effectiveCompareviRef = $null

if (-not [string]::IsNullOrWhiteSpace($ToolingRoot)) {
  $toolingRootResolved = Resolve-AbsolutePath -Path $ToolingRoot -BasePath (Get-Location).Path
  if (-not (Test-Path -LiteralPath $toolingRootResolved -PathType Container)) {
    throw "Tooling root not found: $toolingRootResolved"
  }
  $toolingSource = 'provided-tooling-root'
  $effectiveCompareviRef = if ([string]::IsNullOrWhiteSpace($CompareviRef)) { 'provided-tooling-root' } else { $CompareviRef.Trim() }
} else {
  $resolveOutputPath = Join-Path $resultsDirResolved 'resolve-backend.out'
  & (Join-Path $repoRoot 'scripts' 'Resolve-CompareVIHistoryBackend.ps1') `
    -Repository $CompareviRepository `
    -RequestedRef $CompareviRef `
    -DefaultRefPath (Join-Path $repoRoot 'comparevi-backend-ref.txt') `
    -ActionRef 'manual-vi-exploration' `
    -ToolingPath (Join-Path $resultsDirResolved '.comparevi-history-tools') `
    -AllowSourceFallback `
    -GitHubToken $resolvedGitHubToken `
    -GitHubOutputPath $resolveOutputPath | Out-Null

  $backendValues = Read-KeyValueFile -Path $resolveOutputPath
  $toolingSource = [string]$backendValues['tooling-source']
  $effectiveCompareviRef = [string]$backendValues['comparevi-ref']
  if ([string]::IsNullOrWhiteSpace($toolingSource)) {
    throw 'Failed to resolve comparevi-history backend tooling source for manual exploration execution.'
  }

  if ($toolingSource -eq 'bundle') {
    $acquireOutputPath = Join-Path $resultsDirResolved 'acquire-backend.out'
    & (Join-Path $repoRoot 'scripts' 'Acquire-CompareVIToolsBundle.ps1') `
      -Repository $CompareviRepository `
      -ReleaseTag ([string]$backendValues['release-tag']) `
      -BundleAssetName ([string]$backendValues['bundle-asset-name']) `
      -BundleAssetUrl ([string]$backendValues['bundle-asset-url']) `
      -BundleAssetDigest ([string]$backendValues['bundle-asset-digest']) `
      -DestinationPath ([string]$backendValues['tooling-path']) `
      -GitHubToken $resolvedGitHubToken `
      -GitHubOutputPath $acquireOutputPath | Out-Null

    $acquireValues = Read-KeyValueFile -Path $acquireOutputPath
    $toolingRootResolved = Resolve-AbsolutePath -Path ([string]$acquireValues['tooling-path']) -BasePath (Get-Location).Path
  } else {
    throw 'Manual VI exploration execution supports released backend bundles only. For unreleased backend work, supply -ToolingRoot explicitly.'
  }
}

if (-not (Test-Path -LiteralPath $toolingRootResolved -PathType Container)) {
  throw "Resolved tooling root not found: $toolingRootResolved"
}

$requestedModes = @(ConvertTo-NormalizedModeList -Value $Mode)
if ($requestedModes.Count -eq 0) {
  throw 'Mode must contain at least one explicit compare mode.'
}

$completedChunkCount = 0
$failedChunkCount = 0
$skippedChunkCount = 0
$chunks = @($chunkPlan.chunks)

foreach ($plannedChunk in $chunks) {
  $chunkRoot = Resolve-AbsolutePath -Path ([string]$plannedChunk.outputs.chunkRoot) -BasePath (Split-Path -Parent $chunkPlanPathResolved)
  $chunkReceiptPath = Resolve-AbsolutePath -Path ([string]$plannedChunk.outputs.receiptPath) -BasePath (Split-Path -Parent $chunkPlanPathResolved)
  $chunkManifestPath = Resolve-AbsolutePath -Path ([string]$plannedChunk.outputs.manifestPath) -BasePath (Split-Path -Parent $chunkPlanPathResolved)
  New-Item -ItemType Directory -Path $chunkRoot -Force | Out-Null

  $chunkResultsDir = Join-Path $chunkRoot 'history'
  $chunkRunOutputPath = Join-Path $chunkRoot 'run.out'
  $chunkModeSummaryPath = Join-Path $chunkRoot 'mode-summary.md'
  $chunkModeSummaryJsonPath = Join-Path $chunkRoot 'mode-summary.json'
  $chunkStatus = 'succeeded'
  $chunkFailureMessage = $null
  $runValues = @{}

  try {
    $invokeArgs = @{
      RepositoryRoot = $consumerRootResolved
      ToolingRoot = $toolingRootResolved
      TargetPath = [string]$chunkPlan.target.path
      StartRef = [string]$plannedChunk.execution.startRef
      EndRef = [string]$plannedChunk.execution.endRef
      MaxPairs = [int]$plannedChunk.execution.maxPairs
      NoisePolicy = $NoisePolicy
      Mode = ($requestedModes -join ',')
      ResultsDir = $chunkResultsDir
      ReportFormat = 'html'
      RenderReport = $true
      Detailed = $true
      InvokeScriptPath = $effectiveInvokeScriptPath
      GitHubOutputPath = $chunkRunOutputPath
    }
    if ($IncludeMergeParents.IsPresent) {
      $invokeArgs.IncludeMergeParents = $true
    }
    if ($null -ne $MaxSignalPairs) {
      $invokeArgs.MaxSignalPairs = [int]$MaxSignalPairs
    }
    if ($null -ne $CompareTimeoutSeconds) {
      $invokeArgs.CompareTimeoutSeconds = [int]$CompareTimeoutSeconds
    }

    & (Join-Path $repoRoot 'scripts' 'Invoke-CompareVIHistoryFacade.ps1') @invokeArgs | Out-Null
  } catch {
    $chunkStatus = 'failed'
    $chunkFailureMessage = $_.Exception.Message
  }

  $runValues = Read-KeyValueFile -Path $chunkRunOutputPath
  & (Join-Path $repoRoot 'scripts' 'Format-CompareVIHistoryModeSummary.ps1') `
    -RequestedModeList $(if ($runValues.ContainsKey('requested-mode-list')) { [string]$runValues['requested-mode-list'] } else { ($requestedModes -join ',') }) `
    -ExecutedModeList $(if ($runValues.ContainsKey('executed-mode-list')) { [string]$runValues['executed-mode-list'] } else { '' }) `
    -ModeManifestsJson $(if ($runValues.ContainsKey('mode-manifests-json')) { [string]$runValues['mode-manifests-json'] } else { '' }) `
    -TotalProcessed $(if ($runValues.ContainsKey('total-processed')) { [string]$runValues['total-processed'] } else { '' }) `
    -TotalDiffs $(if ($runValues.ContainsKey('total-diffs')) { [string]$runValues['total-diffs'] } else { '' }) `
    -StopReason $(if ($runValues.ContainsKey('stop-reason')) { [string]$runValues['stop-reason'] } else { '' }) `
    -NoisePolicy $NoisePolicy `
    -JsonOutputPath $chunkModeSummaryJsonPath `
    -OutputPath $chunkModeSummaryPath | Out-Null

  $modeSummary = $null
  if (Test-Path -LiteralPath $chunkModeSummaryJsonPath -PathType Leaf) {
    $modeSummary = Get-Content -LiteralPath $chunkModeSummaryJsonPath -Raw | ConvertFrom-Json -Depth 64
  }

  $chunkFinalReason = if ($chunkStatus -eq 'failed') {
    if ($runValues.ContainsKey('stop-reason') -and -not [string]::IsNullOrWhiteSpace([string]$runValues['stop-reason'])) {
      [string]$runValues['stop-reason']
    } else {
      'facade-step-failed'
    }
  } else {
    if ($runValues.ContainsKey('stop-reason') -and -not [string]::IsNullOrWhiteSpace([string]$runValues['stop-reason'])) {
      [string]$runValues['stop-reason']
    } else {
      'completed'
    }
  }

  $chunkReceipt = [ordered]@{
    schema = 'comparevi-history/chunk-receipt@v1'
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    chunkId = [string]$plannedChunk.chunkId
    chunkOrdinal = [int]$plannedChunk.chunkOrdinal
    segmentOrdinal = [int]$plannedChunk.segmentOrdinal
    status = $chunkStatus
    pairCount = [int]$plannedChunk.pairCount
    pairOrdinalStart = [int]$plannedChunk.pairOrdinalStart
    pairOrdinalEnd = [int]$plannedChunk.pairOrdinalEnd
    revisionOrdinalStart = [int]$plannedChunk.revisionOrdinalStart
    revisionOrdinalEnd = [int]$plannedChunk.revisionOrdinalEnd
    execution = [ordered]@{
      startRef = [string]$plannedChunk.execution.startRef
      endRef = [string]$plannedChunk.execution.endRef
      maxPairs = [int]$plannedChunk.execution.maxPairs
      toolingSource = $toolingSource
      compareviRepository = $CompareviRepository
      compareviRef = $effectiveCompareviRef
      invokeScriptPath = $effectiveInvokeScriptPath
    }
    outputs = [ordered]@{
      chunkRoot = $chunkRoot
      receiptPath = $chunkReceiptPath
      manifestPath = $chunkManifestPath
      runOutputPath = $(if (Test-Path -LiteralPath $chunkRunOutputPath -PathType Leaf) { $chunkRunOutputPath } else { $null })
      historyResultsDir = $(if (Test-Path -LiteralPath $chunkResultsDir -PathType Container) { $chunkResultsDir } else { $null })
      historyManifestPath = $(if ($runValues.ContainsKey('manifest-path')) { [string]$runValues['manifest-path'] } else { $null })
      historySummaryJson = $(if ($runValues.ContainsKey('history-summary-json')) { [string]$runValues['history-summary-json'] } else { $null })
      historyReportMd = $(if ($runValues.ContainsKey('history-report-md')) { [string]$runValues['history-report-md'] } else { $null })
      historyReportHtml = $(if ($runValues.ContainsKey('history-report-html')) { [string]$runValues['history-report-html'] } else { $null })
      modeSummaryPath = $(if (Test-Path -LiteralPath $chunkModeSummaryPath -PathType Leaf) { $chunkModeSummaryPath } else { $null })
      modeSummaryJsonPath = $(if (Test-Path -LiteralPath $chunkModeSummaryJsonPath -PathType Leaf) { $chunkModeSummaryJsonPath } else { $null })
    }
    summary = [ordered]@{
      requestedModes = @($requestedModes)
      executedModes = @(ConvertTo-NormalizedModeList -Value $(if ($runValues.ContainsKey('executed-mode-list')) { [string]$runValues['executed-mode-list'] } else { '' }))
      modeCount = $(if ($runValues.ContainsKey('mode-count') -and -not [string]::IsNullOrWhiteSpace([string]$runValues['mode-count'])) { [int][string]$runValues['mode-count'] } else { 0 })
      totalProcessed = $(if ($runValues.ContainsKey('total-processed') -and -not [string]::IsNullOrWhiteSpace([string]$runValues['total-processed'])) { [int][string]$runValues['total-processed'] } else { 0 })
      totalDiffs = $(if ($runValues.ContainsKey('total-diffs') -and -not [string]::IsNullOrWhiteSpace([string]$runValues['total-diffs'])) { [int][string]$runValues['total-diffs'] } else { 0 })
      stopReason = $(if ($runValues.ContainsKey('stop-reason')) { [string]$runValues['stop-reason'] } else { $null })
      finalStatus = $(if ($chunkStatus -eq 'failed') { 'failed' } else { 'succeeded' })
      finalReason = $chunkFinalReason
    }
    surfaces = $modeSummary
    failure = $(if ([string]::IsNullOrWhiteSpace($chunkFailureMessage)) { $null } else { [ordered]@{ message = $chunkFailureMessage } })
    replay = [ordered]@{
      status = $(if ($chunkStatus -eq 'failed') { 'degraded' } else { 'ready' })
      reason = $(if ($chunkStatus -eq 'failed') { 'chunk-failed' } else { 'chunk-executed' })
    }
    revisions = @($plannedChunk.revisions)
  }
  $chunkReceipt | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $chunkReceiptPath -Encoding utf8
  $chunkReceipt | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $chunkManifestPath -Encoding utf8

  if ($chunkStatus -eq 'failed') {
    $failedChunkCount++
  } else {
    $completedChunkCount++
  }
}

$executionStatus = if ($chunks.Count -eq 0) {
  'not-required'
} elseif ($failedChunkCount -eq 0) {
  'succeeded'
} elseif ($completedChunkCount -gt 0) {
  'partial'
} else {
  'failed'
}
$executionReason = switch ($executionStatus) {
  'not-required' { 'no-revision-pairs' }
  'succeeded' { 'all-chunks-succeeded' }
  'partial' { 'one-or-more-chunks-failed' }
  default { 'all-chunks-failed' }
}

Write-ActionOutput -Key 'tooling-path' -Value $toolingRootResolved
Write-ActionOutput -Key 'tooling-source' -Value $toolingSource
Write-ActionOutput -Key 'comparevi-ref' -Value $effectiveCompareviRef
Write-ActionOutput -Key 'executed-chunk-count' -Value ([string]$completedChunkCount)
Write-ActionOutput -Key 'failed-chunk-count' -Value ([string]$failedChunkCount)
Write-ActionOutput -Key 'skipped-chunk-count' -Value ([string]$skippedChunkCount)
Write-ActionOutput -Key 'execution-status' -Value $executionStatus
Write-ActionOutput -Key 'execution-reason' -Value $executionReason

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  @(
    ''
    '## comparevi-history chunk execution'
    ''
    ('- Tooling source: `{0}`' -f $toolingSource)
    ('- Tooling ref: `{0}`' -f $effectiveCompareviRef)
    ('- Executed chunk count: `{0}`' -f $completedChunkCount)
    ('- Failed chunk count: `{0}`' -f $failedChunkCount)
    ('- Skipped chunk count: `{0}`' -f $skippedChunkCount)
    ('- Execution status: `{0}`' -f $executionStatus)
    ('- Execution reason: `{0}`' -f $executionReason)
  ) | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
}

[ordered]@{
  schema = 'comparevi-history/chunk-execution-summary@v1'
  generatedAtUtc = [DateTime]::UtcNow.ToString('o')
  toolingPath = $toolingRootResolved
  toolingSource = $toolingSource
  compareviRef = $effectiveCompareviRef
  completedChunkCount = $completedChunkCount
  failedChunkCount = $failedChunkCount
  skippedChunkCount = $skippedChunkCount
  executionStatus = $executionStatus
  executionReason = $executionReason
} | ConvertTo-Json -Depth 32
