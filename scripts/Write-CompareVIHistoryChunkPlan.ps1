param(
  [Parameter(Mandatory = $true)]
  [string]$RevisionCatalogPath,
  [string]$ResultsDir,
  [ValidateRange(1, 500)]
  [int]$ChunkPairLimit = 20,
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

function Resolve-ResultsRoot {
  param(
    [Parameter(Mandatory = $true)]
    [string]$CatalogPath,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$RequestedResultsDir
  )

  $catalogDirectory = Split-Path -Parent $CatalogPath
  if ([string]::IsNullOrWhiteSpace($RequestedResultsDir)) {
    return $catalogDirectory
  }

  return Resolve-AbsolutePath -Path $RequestedResultsDir -BasePath $catalogDirectory
}

function New-Segment {
  param(
    [Parameter(Mandatory = $true)]
    [int]$Ordinal,
    [Parameter(Mandatory = $true)]
    [int]$StartIndex,
    [Parameter(Mandatory = $true)]
    [string]$StartReason
  )

  return [ordered]@{
    segmentOrdinal = $Ordinal
    startIndex = $StartIndex
    endIndex = $null
    startRevisionOrdinal = $null
    endRevisionOrdinal = $null
    revisionCount = 0
    pairCount = 0
    continuityStartReason = $StartReason
    continuityBreakAfterRevisionOrdinal = $null
    continuityBreakReason = $null
  }
}

$revisionCatalogPathResolved = Resolve-AbsolutePath -Path $RevisionCatalogPath -BasePath (Get-Location).Path
if (-not (Test-Path -LiteralPath $revisionCatalogPathResolved -PathType Leaf)) {
  throw "Revision catalog not found: $revisionCatalogPathResolved"
}

$catalog = Get-Content -LiteralPath $revisionCatalogPathResolved -Raw | ConvertFrom-Json -Depth 64
if ([string]$catalog.schema -ne 'comparevi-history/revision-catalog@v1') {
  throw "Unsupported revision catalog schema in '$revisionCatalogPathResolved': $($catalog.schema)"
}

$resultsDirResolved = Resolve-ResultsRoot -CatalogPath $revisionCatalogPathResolved -RequestedResultsDir $ResultsDir
New-Item -ItemType Directory -Path $resultsDirResolved -Force | Out-Null
$chunkReceiptsRoot = Join-Path $resultsDirResolved 'chunk-receipts'
New-Item -ItemType Directory -Path $chunkReceiptsRoot -Force | Out-Null
$chunkPlanPath = Join-Path $resultsDirResolved 'chunk-plan.json'

$revisions = @($catalog.revisions)
$segments = [System.Collections.Generic.List[object]]::new()
$chunkReceipts = [System.Collections.Generic.List[object]]::new()
$pairOrdinalCursor = 1
$chunkOrdinal = 1

if ($revisions.Count -gt 0) {
  $segmentOrdinal = 1
  $currentSegment = New-Segment -Ordinal $segmentOrdinal -StartIndex 0 -StartReason 'selected-ref-lineage-start'

  for ($index = 0; $index -lt $revisions.Count; $index++) {
    $revision = $revisions[$index]
    if ($index -lt ($revisions.Count - 1) -and [string]$revision.changeKind -eq 'deleted') {
      $currentSegment.endIndex = $index
      $currentSegment.startRevisionOrdinal = [int]$revisions[$currentSegment.startIndex].ordinal
      $currentSegment.endRevisionOrdinal = [int]$revision.ordinal
      $currentSegment.revisionCount = $currentSegment.endIndex - $currentSegment.startIndex + 1
      $currentSegment.pairCount = [Math]::Max(0, $currentSegment.revisionCount - 1)
      $currentSegment.continuityBreakAfterRevisionOrdinal = [int]$revision.ordinal
      $currentSegment.continuityBreakReason = 'delete-observed'
      $segments.Add([pscustomobject]$currentSegment) | Out-Null

      $segmentOrdinal++
      $currentSegment = New-Segment -Ordinal $segmentOrdinal -StartIndex ($index + 1) -StartReason 'reintroduced-after-delete'
    }
  }

  $currentSegment.endIndex = $revisions.Count - 1
  $currentSegment.startRevisionOrdinal = [int]$revisions[$currentSegment.startIndex].ordinal
  $currentSegment.endRevisionOrdinal = [int]$revisions[$currentSegment.endIndex].ordinal
  $currentSegment.revisionCount = $currentSegment.endIndex - $currentSegment.startIndex + 1
  $currentSegment.pairCount = [Math]::Max(0, $currentSegment.revisionCount - 1)
  $segments.Add([pscustomobject]$currentSegment) | Out-Null
}

foreach ($segment in @($segments)) {
  if ([int]$segment.pairCount -le 0) {
    continue
  }

  $chunkStartIndex = [int]$segment.startIndex
  $segmentEndIndex = [int]$segment.endIndex

  while ($chunkStartIndex -lt $segmentEndIndex) {
    $remainingPairs = $segmentEndIndex - $chunkStartIndex
    $pairCount = [Math]::Min($ChunkPairLimit, $remainingPairs)
    $chunkEndIndex = $chunkStartIndex + $pairCount
    $chunkId = ('chunk-{0:d3}' -f $chunkOrdinal)
    $chunkRoot = Join-Path $chunkReceiptsRoot $chunkId
    New-Item -ItemType Directory -Path $chunkRoot -Force | Out-Null
    $chunkReceiptPath = Join-Path $chunkRoot 'chunk-receipt.json'
    $chunkManifestPath = Join-Path $chunkRoot 'chunk-manifest.json'

    $chunkRevisionSlice = @($revisions[$chunkStartIndex..$chunkEndIndex])
    $newestRevision = $chunkRevisionSlice[$chunkRevisionSlice.Count - 1]
    $oldestRevision = $chunkRevisionSlice[0]
    $chunkPairStart = $pairOrdinalCursor
    $chunkPairEnd = $pairOrdinalCursor + $pairCount - 1

    $chunkReceipt = [ordered]@{
      schema = 'comparevi-history/chunk-receipt@v1'
      generatedAtUtc = [DateTime]::UtcNow.ToString('o')
      chunkId = $chunkId
      chunkOrdinal = $chunkOrdinal
      segmentOrdinal = [int]$segment.segmentOrdinal
      status = 'planned'
      pairCount = $pairCount
      pairOrdinalStart = $chunkPairStart
      pairOrdinalEnd = $chunkPairEnd
      revisionOrdinalStart = [int]$oldestRevision.ordinal
      revisionOrdinalEnd = [int]$newestRevision.ordinal
      execution = [ordered]@{
        startRef = [string]$newestRevision.commit
        endRef = [string]$oldestRevision.commit
        maxPairs = $pairCount
      }
      outputs = [ordered]@{
        chunkRoot = $chunkRoot
        receiptPath = $chunkReceiptPath
        manifestPath = $chunkManifestPath
      }
      revisions = @(
        $chunkRevisionSlice | ForEach-Object {
          [ordered]@{
            ordinal = [int]$_.ordinal
            commit = [string]$_.commit
            path = [string]$_.path
            changeKind = [string]$_.changeKind
          }
        }
      )
    }
    $chunkReceipt | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $chunkReceiptPath -Encoding utf8
    $chunkReceipt | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $chunkManifestPath -Encoding utf8
    $chunkReceipts.Add([pscustomobject]$chunkReceipt) | Out-Null

    $pairOrdinalCursor += $pairCount
    $chunkOrdinal++
    $chunkStartIndex = $chunkEndIndex
  }
}

$chunkPlan = [ordered]@{
  schema = 'comparevi-history/chunk-plan@v1'
  generatedAtUtc = [DateTime]::UtcNow.ToString('o')
  revisionCatalogPath = $revisionCatalogPathResolved
  consumer = [ordered]@{
    repository = [string]$catalog.consumer.repository
    ref = [string]$catalog.consumer.ref
  }
  target = [ordered]@{
    path = [string]$catalog.target.path
    selectedRef = [string]$catalog.target.selectedRef
    extension = '.vi'
  }
  summary = [ordered]@{
    revisionCount = [int]$catalog.summary.revisionCount
    segmentCount = $segments.Count
    pairCount = [Math]::Max(0, $pairOrdinalCursor - 1)
    chunkCount = $chunkReceipts.Count
    chunkPairLimit = $ChunkPairLimit
    continuityStatus = [string]$catalog.summary.continuityStatus
  }
  segments = @(
    $segments | ForEach-Object {
      [ordered]@{
        segmentOrdinal = [int]$_.segmentOrdinal
        startRevisionOrdinal = [int]$_.startRevisionOrdinal
        endRevisionOrdinal = [int]$_.endRevisionOrdinal
        revisionCount = [int]$_.revisionCount
        pairCount = [int]$_.pairCount
        continuityStartReason = [string]$_.continuityStartReason
        continuityBreakAfterRevisionOrdinal = if ($null -eq $_.continuityBreakAfterRevisionOrdinal) { $null } else { [int]$_.continuityBreakAfterRevisionOrdinal }
        continuityBreakReason = if ([string]::IsNullOrWhiteSpace([string]$_.continuityBreakReason)) { $null } else { [string]$_.continuityBreakReason }
      }
    }
  )
  chunks = @($chunkReceipts)
}
$chunkPlan | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $chunkPlanPath -Encoding utf8

$plannerStatus = if ($chunkReceipts.Count -eq 0) { 'not-required' } else { 'planned' }
$plannerReason = if ($chunkReceipts.Count -eq 0) { 'no-revision-pairs' } else { 'chunk-plan-ready' }

Write-ActionOutput -Key 'chunk-plan-path' -Value $chunkPlanPath
Write-ActionOutput -Key 'chunk-receipts-root' -Value $chunkReceiptsRoot
Write-ActionOutput -Key 'chunk-count' -Value ([string]$chunkReceipts.Count)
Write-ActionOutput -Key 'executable-pair-count' -Value ([string][Math]::Max(0, $pairOrdinalCursor - 1))
Write-ActionOutput -Key 'chunk-pair-limit' -Value ([string]$ChunkPairLimit)
Write-ActionOutput -Key 'planning-status' -Value $plannerStatus
Write-ActionOutput -Key 'planning-reason' -Value $plannerReason

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  @(
    ''
    '## comparevi-history chunk plan'
    ''
    ('- Chunk pair limit: `{0}`' -f $ChunkPairLimit)
    ('- Segment count: `{0}`' -f $segments.Count)
    ('- Executable pair count: `{0}`' -f [Math]::Max(0, $pairOrdinalCursor - 1))
    ('- Chunk count: `{0}`' -f $chunkReceipts.Count)
    ('- Planning status: `{0}`' -f $plannerStatus)
    ('- Planning reason: `{0}`' -f $plannerReason)
    ('- Chunk plan: `{0}`' -f $chunkPlanPath)
    ('- Chunk receipts root: `{0}`' -f $chunkReceiptsRoot)
  ) | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
}

$chunkPlan | ConvertTo-Json -Depth 64
