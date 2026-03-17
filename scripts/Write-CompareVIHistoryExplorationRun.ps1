param(
  [Parameter(Mandatory = $true)]
  [string]$RevisionCatalogPath,
  [Parameter(Mandatory = $true)]
  [string]$ChunkPlanPath,
  [string]$ResultsDir,
  [string]$Modes = 'attributes,front-panel,block-diagram',
  [ValidateSet('include', 'collapse', 'skip')]
  [string]$NoisePolicy = 'collapse',
  [switch]$IncludeMergeParents,
  [string]$TimelineMd,
  [string]$TimelineHtml,
  [string]$BundlePath,
  [string]$BundleStatus,
  [string]$BundleReason,
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

function Resolve-ExistingPath {
  param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$BasePath
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }

  $resolved = Resolve-AbsolutePath -Path $Path -BasePath $BasePath
  if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
    return $null
  }

  return $resolved
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

function Get-OptionalPropertyValue {
  param(
    [AllowNull()]
    $InputObject,
    [Parameter(Mandatory = $true)]
    [string]$PropertyName,
    [AllowNull()]
    $Default = $null
  )

  if ($null -eq $InputObject) {
    return $Default
  }

  if ($InputObject -is [System.Collections.IDictionary]) {
    if ($InputObject.Contains($PropertyName)) {
      return $InputObject[$PropertyName]
    }

    return $Default
  }

  $property = $InputObject.PSObject.Properties[$PropertyName]
  if ($null -eq $property) {
    return $Default
  }

  return $property.Value
}

function New-MarkdownTimeline {
  param(
    [Parameter(Mandatory = $true)]
    $Catalog,
    [Parameter(Mandatory = $true)]
    $ChunkPlan,
    [Parameter(Mandatory = $true)]
    $ChunkReceipts,
    [Parameter(Mandatory = $true)]
    [string]$FinalStatus,
    [Parameter(Mandatory = $true)]
    [string]$FinalReason
  )

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('# comparevi-history manual exploration timeline') | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add(('- Target path: `{0}`' -f [string]$Catalog.target.path)) | Out-Null
  $lines.Add(('- Selected ref: `{0}`' -f [string]$Catalog.target.selectedRef)) | Out-Null
  $lines.Add(('- Revision count: `{0}`' -f [int]$Catalog.summary.revisionCount)) | Out-Null
  $lines.Add(('- Pair count: `{0}`' -f [int]$ChunkPlan.summary.pairCount)) | Out-Null
  $lines.Add(('- Final status: `{0}`' -f $FinalStatus)) | Out-Null
  $lines.Add(('- Final reason: `{0}`' -f $FinalReason)) | Out-Null
  $lines.Add('') | Out-Null

  foreach ($segment in @($ChunkPlan.segments)) {
    $lines.Add(('## Segment {0}' -f [int]$segment.segmentOrdinal)) | Out-Null
    $lines.Add(('- Revision ordinals: `{0}` -> `{1}`' -f [int]$segment.startRevisionOrdinal, [int]$segment.endRevisionOrdinal)) | Out-Null
    $lines.Add(('- Pair count: `{0}`' -f [int]$segment.pairCount)) | Out-Null
    $lines.Add(('- Continuity start: `{0}`' -f [string]$segment.continuityStartReason)) | Out-Null
    if ($null -ne $segment.continuityBreakAfterRevisionOrdinal) {
      $lines.Add(('- Continuity break after revision: `{0}` ({1})' -f [int]$segment.continuityBreakAfterRevisionOrdinal, [string]$segment.continuityBreakReason)) | Out-Null
    }
    $lines.Add('') | Out-Null

    $segmentChunks = @($ChunkReceipts | Where-Object { [int]$_.segmentOrdinal -eq [int]$segment.segmentOrdinal })
    foreach ($chunk in $segmentChunks) {
      $chunkSummary = Get-OptionalPropertyValue -InputObject $chunk -PropertyName 'summary'
      $chunkOutputs = Get-OptionalPropertyValue -InputObject $chunk -PropertyName 'outputs'
      $chunkFailure = Get-OptionalPropertyValue -InputObject $chunk -PropertyName 'failure'
      $lines.Add(('### {0}' -f [string]$chunk.chunkId)) | Out-Null
      $lines.Add(('- Status: `{0}`' -f [string]$chunk.status)) | Out-Null
      $lines.Add(('- Pair ordinals: `{0}` -> `{1}`' -f [int]$chunk.pairOrdinalStart, [int]$chunk.pairOrdinalEnd)) | Out-Null
      $lines.Add(('- Revision ordinals: `{0}` -> `{1}`' -f [int]$chunk.revisionOrdinalStart, [int]$chunk.revisionOrdinalEnd)) | Out-Null
      $lines.Add(('- Start ref: `{0}`' -f [string]$chunk.execution.startRef)) | Out-Null
      $lines.Add(('- End ref: `{0}`' -f [string]$chunk.execution.endRef)) | Out-Null
      $lines.Add(('- Total processed: `{0}`' -f [int](Get-OptionalPropertyValue -InputObject $chunkSummary -PropertyName 'totalProcessed' -Default 0))) | Out-Null
      $lines.Add(('- Total diffs: `{0}`' -f [int](Get-OptionalPropertyValue -InputObject $chunkSummary -PropertyName 'totalDiffs' -Default 0))) | Out-Null
      $lines.Add(('- Final reason: `{0}`' -f [string](Get-OptionalPropertyValue -InputObject $chunkSummary -PropertyName 'finalReason' -Default 'planned'))) | Out-Null
      $historyReportMd = Get-OptionalPropertyValue -InputObject $chunkOutputs -PropertyName 'historyReportMd'
      $historyReportHtml = Get-OptionalPropertyValue -InputObject $chunkOutputs -PropertyName 'historyReportHtml'
      if ($historyReportMd) {
        $lines.Add(('- History report (md): `{0}`' -f [string]$historyReportMd)) | Out-Null
      }
      if ($historyReportHtml) {
        $lines.Add(('- History report (html): `{0}`' -f [string]$historyReportHtml)) | Out-Null
      }
      $failureMessage = Get-OptionalPropertyValue -InputObject $chunkFailure -PropertyName 'message'
      if ($failureMessage) {
        $lines.Add(('- Failure: `{0}`' -f [string]$failureMessage)) | Out-Null
      }
      $lines.Add('') | Out-Null
    }
  }

  return ($lines -join [Environment]::NewLine)
}

function New-HtmlTimeline {
  param(
    [Parameter(Mandatory = $true)]
    $Catalog,
    [Parameter(Mandatory = $true)]
    $ChunkReceipts,
    [Parameter(Mandatory = $true)]
    [string]$FinalStatus,
    [Parameter(Mandatory = $true)]
    [string]$FinalReason
  )

  $rows = New-Object System.Collections.Generic.List[string]
  foreach ($chunk in $ChunkReceipts) {
    $chunkSummary = Get-OptionalPropertyValue -InputObject $chunk -PropertyName 'summary'
    $rows.Add(@"
<tr>
  <td>$([int]$chunk.segmentOrdinal)</td>
  <td>$([string]$chunk.chunkId)</td>
  <td>$([string]$chunk.status)</td>
  <td>$([int]$chunk.revisionOrdinalStart)-$([int]$chunk.revisionOrdinalEnd)</td>
  <td>$([int]$chunk.pairCount)</td>
  <td>$([int](Get-OptionalPropertyValue -InputObject $chunkSummary -PropertyName 'totalDiffs' -Default 0))</td>
  <td>$([string](Get-OptionalPropertyValue -InputObject $chunkSummary -PropertyName 'finalReason' -Default 'planned'))</td>
</tr>
"@) | Out-Null
  }

  return @"
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8" />
  <title>comparevi-history manual exploration timeline</title>
  <style>
    body { font-family: Segoe UI, Arial, sans-serif; margin: 2rem; }
    table { border-collapse: collapse; width: 100%; }
    th, td { border: 1px solid #ccc; padding: 0.5rem; text-align: left; }
    th { background: #f3f3f3; }
  </style>
</head>
<body>
  <h1>comparevi-history manual exploration timeline</h1>
  <p><strong>Target path:</strong> $([string]$Catalog.target.path)</p>
  <p><strong>Selected ref:</strong> $([string]$Catalog.target.selectedRef)</p>
  <p><strong>Revision count:</strong> $([int]$Catalog.summary.revisionCount)</p>
  <p><strong>Final status:</strong> $FinalStatus</p>
  <p><strong>Final reason:</strong> $FinalReason</p>
  <table>
    <thead>
      <tr>
        <th>Segment</th>
        <th>Chunk</th>
        <th>Status</th>
        <th>Revision ordinals</th>
        <th>Pairs</th>
        <th>Diffs</th>
        <th>Reason</th>
      </tr>
    </thead>
    <tbody>
$($rows -join [Environment]::NewLine)
    </tbody>
  </table>
</body>
</html>
"@
}

$revisionCatalogPathResolved = Resolve-AbsolutePath -Path $RevisionCatalogPath -BasePath (Get-Location).Path
$chunkPlanPathResolved = Resolve-AbsolutePath -Path $ChunkPlanPath -BasePath (Get-Location).Path
if (-not (Test-Path -LiteralPath $revisionCatalogPathResolved -PathType Leaf)) {
  throw "Revision catalog not found: $revisionCatalogPathResolved"
}
if (-not (Test-Path -LiteralPath $chunkPlanPathResolved -PathType Leaf)) {
  throw "Chunk plan not found: $chunkPlanPathResolved"
}

$catalog = Get-Content -LiteralPath $revisionCatalogPathResolved -Raw | ConvertFrom-Json -Depth 64
$chunkPlan = Get-Content -LiteralPath $chunkPlanPathResolved -Raw | ConvertFrom-Json -Depth 64
if ([string]$catalog.schema -ne 'comparevi-history/revision-catalog@v1') {
  throw "Unsupported revision catalog schema in '$revisionCatalogPathResolved': $($catalog.schema)"
}
if ([string]$chunkPlan.schema -ne 'comparevi-history/chunk-plan@v1') {
  throw "Unsupported chunk plan schema in '$chunkPlanPathResolved': $($chunkPlan.schema)"
}

$resultsDirResolved = if ([string]::IsNullOrWhiteSpace($ResultsDir)) {
  Split-Path -Parent $revisionCatalogPathResolved
} else {
  Resolve-AbsolutePath -Path $ResultsDir -BasePath (Split-Path -Parent $revisionCatalogPathResolved)
}
New-Item -ItemType Directory -Path $resultsDirResolved -Force | Out-Null
$explorationRunPath = Join-Path $resultsDirResolved 'exploration-run.json'
$chunkReceiptsRoot = if ($chunkPlan.summary.chunkCount -eq 0) {
  Join-Path $resultsDirResolved 'chunk-receipts'
} else {
  Split-Path -Parent ([string]$chunkPlan.chunks[0].outputs.chunkRoot)
}

$requestedModes = @(ConvertTo-NormalizedModeList -Value $Modes)
if ($requestedModes.Count -eq 0) {
  throw 'Modes must contain at least one explicit compare mode.'
}

$timelineMdResolved = if ([string]::IsNullOrWhiteSpace($TimelineMd)) { Join-Path $resultsDirResolved 'timeline.md' } else { Resolve-AbsolutePath -Path $TimelineMd -BasePath $resultsDirResolved }
$timelineHtmlResolved = if ([string]::IsNullOrWhiteSpace($TimelineHtml)) { Join-Path $resultsDirResolved 'timeline.html' } else { Resolve-AbsolutePath -Path $TimelineHtml -BasePath $resultsDirResolved }
$bundlePathResolved = Resolve-ExistingPath -Path $BundlePath -BasePath $resultsDirResolved
$effectiveBundleStatus = if (-not [string]::IsNullOrWhiteSpace($BundleStatus)) {
  $BundleStatus
} elseif ($null -ne $bundlePathResolved) {
  'succeeded'
} else {
  'not-required'
}
$effectiveBundleReason = if (-not [string]::IsNullOrWhiteSpace($BundleReason)) {
  $BundleReason
} elseif ($effectiveBundleStatus -eq 'succeeded') {
  'bundle-created'
} else {
  'bundle-not-requested'
}

$chunkReceipts = New-Object System.Collections.Generic.List[object]
foreach ($plannedChunk in @($chunkPlan.chunks)) {
  $receiptPath = Resolve-AbsolutePath -Path ([string]$plannedChunk.outputs.receiptPath) -BasePath (Split-Path -Parent $chunkPlanPathResolved)
  if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
    $chunkReceipts.Add((Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -Depth 64)) | Out-Null
  } else {
    $chunkReceipts.Add([pscustomobject]$plannedChunk) | Out-Null
  }
}

$chunkCount = $chunkReceipts.Count
$pairCount = [int]$chunkPlan.summary.pairCount
$completedChunkCount = @($chunkReceipts | Where-Object { [string]$_.status -eq 'succeeded' }).Count
$failedChunkCount = @($chunkReceipts | Where-Object { [string]$_.status -eq 'failed' }).Count
$skippedChunkCount = @($chunkReceipts | Where-Object { [string]$_.status -eq 'skipped' }).Count
$plannedChunkCount = @($chunkReceipts | Where-Object { [string]$_.status -eq 'planned' }).Count

$planningStatus = if ($chunkCount -eq 0) {
  'not-required'
} elseif ($failedChunkCount -eq 0 -and $plannedChunkCount -eq 0) {
  'complete'
} elseif ($completedChunkCount -gt 0 -or $skippedChunkCount -gt 0) {
  'partial'
} elseif ($failedChunkCount -gt 0) {
  'failed'
} else {
  'planned'
}

$finalStatus = switch ($planningStatus) {
  'complete' { 'succeeded' }
  'partial' { 'partial' }
  'failed' { 'failed' }
  'not-required' { 'planned' }
  default { 'planned' }
}
$finalReason = switch ($planningStatus) {
  'complete' { 'all-chunks-succeeded' }
  'partial' { 'one-or-more-chunks-failed' }
  'failed' { 'all-chunks-failed' }
  'not-required' { 'no-revision-pairs' }
  default { 'chunk-plan-ready' }
}
$replayStatus = switch ($planningStatus) {
  'complete' { 'ready' }
  'partial' { 'degraded' }
  'failed' { 'degraded' }
  'not-required' { 'ready-for-summary' }
  default { 'ready-for-chunk-execution' }
}
$replayReason = switch ($planningStatus) {
  'complete' { 'all-chunks-executed' }
  'partial' { 'partial-chunk-execution' }
  'failed' { 'chunk-execution-failed' }
  'not-required' { 'catalog-has-no-adjacent-pairs' }
  default { 'chunk-plan-present' }
}

if ($planningStatus -eq 'complete' -and $effectiveBundleStatus -eq 'failed') {
  $finalStatus = 'partial'
  $finalReason = $effectiveBundleReason
  $replayStatus = 'degraded'
  $replayReason = 'bundle-packaging-failed'
}

$chunkReceiptArray = $chunkReceipts.ToArray()
$timelineMarkdown = New-MarkdownTimeline -Catalog $catalog -ChunkPlan $chunkPlan -ChunkReceipts $chunkReceiptArray -FinalStatus $finalStatus -FinalReason $finalReason
$timelineHtml = New-HtmlTimeline -Catalog $catalog -ChunkReceipts $chunkReceiptArray -FinalStatus $finalStatus -FinalReason $finalReason
$timelineMarkdown | Set-Content -LiteralPath $timelineMdResolved -Encoding utf8
$timelineHtml | Set-Content -LiteralPath $timelineHtmlResolved -Encoding utf8

$explorationRun = [ordered]@{
  schema = 'comparevi-history/exploration-run@v1'
  generatedAtUtc = [DateTime]::UtcNow.ToString('o')
  consumer = [ordered]@{
    repository = [string]$catalog.consumer.repository
    ref = [string]$catalog.consumer.ref
  }
  target = [ordered]@{
    path = [string]$catalog.target.path
    selectedRef = [string]$catalog.target.selectedRef
    extension = '.vi'
  }
  configuration = [ordered]@{
    requestedModes = @($requestedModes)
    noisePolicy = $NoisePolicy
    includeMergeParents = [bool]$IncludeMergeParents.IsPresent
  }
  discovery = [ordered]@{
    revisionCatalogPath = $revisionCatalogPathResolved
    revisionCount = [int]$catalog.summary.revisionCount
    catalogComplete = [bool]$catalog.discovery.complete
    catalogCompletenessReason = [string]$catalog.discovery.completenessReason
    continuityStatus = [string]$catalog.summary.continuityStatus
  }
  planning = [ordered]@{
    chunkPlanPath = $chunkPlanPathResolved
    chunkReceiptsRoot = $chunkReceiptsRoot
    chunkPairLimit = [int]$chunkPlan.summary.chunkPairLimit
    segmentCount = [int]$chunkPlan.summary.segmentCount
    pairCount = $pairCount
    chunkCount = $chunkCount
    plannedChunkCount = $chunkCount
    completedChunkCount = $completedChunkCount
    failedChunkCount = $failedChunkCount
    skippedChunkCount = $skippedChunkCount
    status = $planningStatus
    reason = $finalReason
  }
  publication = [ordered]@{
    bundleStatus = $effectiveBundleStatus
    bundleReason = $effectiveBundleReason
  }
  outputs = [ordered]@{
    resultsRoot = $resultsDirResolved
    revisionCatalogPath = $revisionCatalogPathResolved
    chunkPlanPath = $chunkPlanPathResolved
    chunkReceiptsRoot = $chunkReceiptsRoot
    explorationRunPath = $explorationRunPath
    timelineMd = $timelineMdResolved
    timelineHtml = $timelineHtmlResolved
    bundlePath = $bundlePathResolved
  }
  summary = [ordered]@{
    revisionCount = [int]$catalog.summary.revisionCount
    pairCount = $pairCount
    plannedChunkCount = $chunkCount
    completedChunkCount = $completedChunkCount
    failedChunkCount = $failedChunkCount
    skippedChunkCount = $skippedChunkCount
    finalStatus = $finalStatus
    finalReason = $finalReason
  }
  replay = [ordered]@{
    status = $replayStatus
    reason = $replayReason
  }
}
$explorationRun | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $explorationRunPath -Encoding utf8

Write-ActionOutput -Key 'exploration-run-path' -Value $explorationRunPath
Write-ActionOutput -Key 'exploration-status' -Value $finalStatus
Write-ActionOutput -Key 'exploration-reason' -Value $finalReason
Write-ActionOutput -Key 'timeline-md' -Value $timelineMdResolved
Write-ActionOutput -Key 'timeline-html' -Value $timelineHtmlResolved
Write-ActionOutput -Key 'bundle-path' -Value $(if ($null -eq $bundlePathResolved) { '' } else { $bundlePathResolved })

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  @(
    ''
    '## comparevi-history exploration run'
    ''
    ('- Exploration run: `{0}`' -f $explorationRunPath)
    ('- Revision count: `{0}`' -f [int]$catalog.summary.revisionCount)
    ('- Pair count: `{0}`' -f $pairCount)
    ('- Planned chunk count: `{0}`' -f $chunkCount)
    ('- Completed chunk count: `{0}`' -f $completedChunkCount)
    ('- Failed chunk count: `{0}`' -f $failedChunkCount)
    ('- Final status: `{0}`' -f $finalStatus)
    ('- Final reason: `{0}`' -f $finalReason)
    ('- Bundle status: `{0}`' -f $effectiveBundleStatus)
    ('- Bundle reason: `{0}`' -f $effectiveBundleReason)
    ('- Bundle path: `{0}`' -f $(if ($null -eq $bundlePathResolved) { '' } else { $bundlePathResolved }))
    ('- Timeline (md): `{0}`' -f $timelineMdResolved)
    ('- Timeline (html): `{0}`' -f $timelineHtmlResolved)
  ) | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
}

$explorationRun | ConvertTo-Json -Depth 64
