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

$timelineMdResolved = Resolve-ExistingPath -Path $TimelineMd -BasePath $resultsDirResolved
$timelineHtmlResolved = Resolve-ExistingPath -Path $TimelineHtml -BasePath $resultsDirResolved
$bundlePathResolved = Resolve-ExistingPath -Path $BundlePath -BasePath $resultsDirResolved

$chunkCount = [int]$chunkPlan.summary.chunkCount
$pairCount = [int]$chunkPlan.summary.pairCount
$finalStatus = 'planned'
$finalReason = if ($chunkCount -eq 0) { 'no-revision-pairs' } else { 'chunk-plan-ready' }
$replayStatus = if ($chunkCount -eq 0) { 'ready-for-summary' } else { 'ready-for-chunk-execution' }
$replayReason = if ($chunkCount -eq 0) { 'catalog-has-no-adjacent-pairs' } else { 'chunk-plan-present' }

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
    completedChunkCount = 0
    failedChunkCount = 0
    skippedChunkCount = 0
    status = if ($chunkCount -eq 0) { 'not-required' } else { 'planned' }
    reason = $finalReason
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
    completedChunkCount = 0
    failedChunkCount = 0
    skippedChunkCount = 0
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

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  @(
    ''
    '## comparevi-history exploration run'
    ''
    ('- Exploration run: `{0}`' -f $explorationRunPath)
    ('- Revision count: `{0}`' -f [int]$catalog.summary.revisionCount)
    ('- Pair count: `{0}`' -f $pairCount)
    ('- Planned chunk count: `{0}`' -f $chunkCount)
    ('- Final status: `{0}`' -f $finalStatus)
    ('- Final reason: `{0}`' -f $finalReason)
  ) | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
}

$explorationRun | ConvertTo-Json -Depth 64
