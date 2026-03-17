param(
  [Parameter(Mandatory = $true)]
  [string]$RevisionCatalogPath,
  [Parameter(Mandatory = $true)]
  [string]$ChunkPlanPath,
  [string]$ResultsDir,
  [string]$Modes = 'full',
  [ValidateSet('include', 'collapse', 'skip')]
  [string]$NoisePolicy = 'include',
  [switch]$IncludeMergeParents,
  [string]$TimelineMd,
  [string]$TimelineHtml,
  [string]$IndexMd,
  [string]$IndexHtml,
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

  return @($modes | ForEach-Object { $_ })
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

function Get-SurfaceMetadataNode {
  param(
    [AllowNull()]
    $SurfaceNode
  )

  if ($null -eq $SurfaceNode) {
    return $null
  }

  $metadataNode = Get-OptionalPropertyValue -InputObject $SurfaceNode -PropertyName 'metadata'
  if ($null -ne $metadataNode) {
    return $metadataNode
  }

  return $SurfaceNode
}

function ConvertTo-ArtifactReference {
  param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$ResultsRoot,
    [switch]$OnlyIfExists
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }

  $resolved = Resolve-AbsolutePath -Path $Path -BasePath $ResultsRoot
  if ($OnlyIfExists.IsPresent -and -not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
    return $null
  }

  $resultsRootResolved = [System.IO.Path]::GetFullPath($ResultsRoot)
  $resultsRootWithSeparator = $resultsRootResolved
  if (-not $resultsRootWithSeparator.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
    $resultsRootWithSeparator += [System.IO.Path]::DirectorySeparatorChar
  }

  if ($resolved.StartsWith($resultsRootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $resolved.Substring($resultsRootWithSeparator.Length).Replace('\', '/')
  }

  return $resolved.Replace('\', '/')
}

function Format-MarkdownLink {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Label,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$Href
  )

  if ([string]::IsNullOrWhiteSpace($Href)) {
    return ''
  }

  return ('[{0}]({1})' -f $Label, $Href)
}

function Format-HtmlLink {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Label,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$Href
  )

  if ([string]::IsNullOrWhiteSpace($Href)) {
    return ''
  }

  return ('<a href="{0}">{1}</a>' -f $Href, $Label)
}

function ConvertTo-OrderedCountMap {
  param(
    [AllowNull()]
    $Value
  )

  $map = [ordered]@{}
  if ($null -eq $Value) {
    return $map
  }

  if ($Value -is [System.Collections.IDictionary]) {
    foreach ($key in @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object)) {
      $map[$key] = [int]$Value[$key]
    }
    return $map
  }

  foreach ($property in @($Value.PSObject.Properties | Sort-Object Name)) {
    $map[[string]$property.Name] = [int]$property.Value
  }

  return $map
}

function Merge-CountMap {
  param(
    [Parameter(Mandatory = $true)]
    [hashtable]$Target,
    [AllowNull()]
    $Source
  )

  $normalizedSource = ConvertTo-OrderedCountMap -Value $Source
  foreach ($key in $normalizedSource.Keys) {
    if (-not $Target.Contains($key)) {
      $Target[$key] = 0
    }
    $Target[$key] = [int]$Target[$key] + [int]$normalizedSource[$key]
  }
}

function Format-CountMapText {
  param(
    [AllowNull()]
    $Map
  )

  $normalized = ConvertTo-OrderedCountMap -Value $Map
  if ($normalized.Count -eq 0) {
    return 'none'
  }

  return (($normalized.Keys | ForEach-Object { '{0} ({1})' -f $_, [int]$normalized[$_] }) -join ', ')
}

function Normalize-CategoryLabel {
  param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$Value
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return ''
  }

  $decoded = [System.Net.WebUtility]::HtmlDecode($Value)
  $withoutTags = [regex]::Replace($decoded, '<[^>]+>', ' ')
  return ([regex]::Replace($withoutTags, '\s+', ' ')).Trim()
}

function Try-ParseComparisonPairLabel {
  param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$Label
  )

  $normalizedLabel = Normalize-CategoryLabel -Value $Label
  if ([string]::IsNullOrWhiteSpace($normalizedLabel)) {
    return $null
  }

  $pattern = '^\s*First\s+VI:\s*(?<first>.+?)\s+Second\s+VI:\s*(?<second>.+?)\s*$'
  if ($normalizedLabel -notmatch $pattern) {
    return $null
  }

  return [ordered]@{
    firstPath = $Matches['first'].Trim()
    secondPath = $Matches['second'].Trim()
  }
}

function Add-ComparisonPairAggregate {
  param(
    [Parameter(Mandatory = $true)]
    [hashtable]$Target,
    [Parameter(Mandatory = $true)]
    [string]$FirstPath,
    [Parameter(Mandatory = $true)]
    [string]$SecondPath,
    [int]$Count = 1
  )

  $key = '{0}`n{1}' -f $FirstPath, $SecondPath
  if (-not $Target.Contains($key)) {
    $Target[$key] = [ordered]@{
      firstPath = $FirstPath
      secondPath = $SecondPath
      count = 0
    }
  }

  $Target[$key].count = [int]$Target[$key].count + [int]$Count
}

function ConvertTo-ComparisonPairArray {
  param(
    [AllowNull()]
    $Value
  )

  if ($null -eq $Value) {
    return @()
  }

  if ($Value -is [System.Collections.IDictionary]) {
    return @(
      $Value.GetEnumerator() |
        Sort-Object { [string]$_.Value.firstPath }, { [string]$_.Value.secondPath } |
        ForEach-Object {
          [ordered]@{
            firstPath = [string]$_.Value.firstPath
            secondPath = [string]$_.Value.secondPath
            count = [int]$_.Value.count
          }
        }
    )
  }

  $pairs = New-Object System.Collections.Generic.List[object]
  foreach ($pair in @(ConvertTo-ObjectArray -InputObject $Value)) {
    $firstPath = [string](Get-OptionalPropertyValue -InputObject $pair -PropertyName 'firstPath' -Default '')
    $secondPath = [string](Get-OptionalPropertyValue -InputObject $pair -PropertyName 'secondPath' -Default '')
    if ([string]::IsNullOrWhiteSpace($firstPath) -or [string]::IsNullOrWhiteSpace($secondPath)) {
      continue
    }

    $pairs.Add([ordered]@{
        firstPath = $firstPath.Trim()
        secondPath = $secondPath.Trim()
        count = [int](Get-OptionalPropertyValue -InputObject $pair -PropertyName 'count' -Default 0)
      }) | Out-Null
  }

  return @(
    $pairs |
      Sort-Object { [string]$_.firstPath }, { [string]$_.secondPath } |
      ForEach-Object { $_ }
  )
}

function Merge-ComparisonPairCollection {
  param(
    [Parameter(Mandatory = $true)]
    [hashtable]$Target,
    [AllowNull()]
    $Source
  )

  foreach ($pair in @(ConvertTo-ComparisonPairArray -Value $Source)) {
    Add-ComparisonPairAggregate -Target $Target -FirstPath ([string]$pair.firstPath) -SecondPath ([string]$pair.secondPath) -Count ([int]$pair.count)
  }
}

function ConvertTo-NormalizedCategorySurface {
  param(
    [AllowNull()]
    $CategoryCounts,
    [AllowNull()]
    $ComparisonPairs
  )

  $normalizedCategoryCounts = @{}
  $comparisonPairAggregate = @{}

  foreach ($rawKey in @((ConvertTo-OrderedCountMap -Value $CategoryCounts).Keys | Sort-Object)) {
    $count = [int](ConvertTo-OrderedCountMap -Value $CategoryCounts)[$rawKey]
    $comparisonPair = Try-ParseComparisonPairLabel -Label ([string]$rawKey)
    if ($null -ne $comparisonPair) {
      Add-ComparisonPairAggregate -Target $comparisonPairAggregate -FirstPath ([string]$comparisonPair.firstPath) -SecondPath ([string]$comparisonPair.secondPath) -Count $count
      continue
    }

    $normalizedLabel = Normalize-CategoryLabel -Value ([string]$rawKey)
    if ([string]::IsNullOrWhiteSpace($normalizedLabel)) {
      continue
    }

    if (-not $normalizedCategoryCounts.Contains($normalizedLabel)) {
      $normalizedCategoryCounts[$normalizedLabel] = 0
    }
    $normalizedCategoryCounts[$normalizedLabel] = [int]$normalizedCategoryCounts[$normalizedLabel] + $count
  }

  Merge-ComparisonPairCollection -Target $comparisonPairAggregate -Source $ComparisonPairs

  return [pscustomobject]@{
    categoryCounts = ConvertTo-OrderedCountMap -Value $normalizedCategoryCounts
    comparisonPairs = @(ConvertTo-ComparisonPairArray -Value $comparisonPairAggregate)
  }
}

function Format-ComparisonPairText {
  param(
    [AllowNull()]
    $Pairs
  )

  $pairArray = @(ConvertTo-ComparisonPairArray -Value $Pairs)
  if ($pairArray.Count -eq 0) {
    return 'none'
  }

  return (($pairArray | ForEach-Object { '{0} -> {1} ({2})' -f [string]$_.firstPath, [string]$_.secondPath, [int]$_.count }) -join ', ')
}

function New-ExplorationSurfaceAggregate {
  param(
    [Parameter(Mandatory = $true)]
    $ChunkReceipts
  )

  $chunkReceiptArray = ConvertTo-ObjectArray -InputObject $ChunkReceipts
  $suppressionProfiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $hasUnknownProfile = $false
  $aggregateCategoryCounts = @{}
  $aggregateBucketCounts = @{}
  $aggregateComparisonPairs = @{}
  $captureCount = 0
  $imageArtifactCount = 0
  $comparisonArtifactCount = 0
  $chunkCountWithMetadata = 0
  $imageMimeTypes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

  foreach ($chunk in $chunkReceiptArray) {
    $surfaceNode = Get-OptionalPropertyValue -InputObject $chunk -PropertyName 'surfaces'
    if ($null -eq $surfaceNode) {
      continue
    }

    $chunkHasMetadata = $false
    $profile = [string](Get-OptionalPropertyValue -InputObject $surfaceNode -PropertyName 'suppressionProfile' -Default '')
    if ([string]::IsNullOrWhiteSpace($profile) -or $profile -eq 'unknown') {
      $hasUnknownProfile = $true
    } else {
      [void]$suppressionProfiles.Add($profile)
    }

    $normalizedSurface = ConvertTo-NormalizedCategorySurface `
      -CategoryCounts (Get-OptionalPropertyValue -InputObject $surfaceNode -PropertyName 'categoryCounts') `
      -ComparisonPairs (Get-OptionalPropertyValue -InputObject $surfaceNode -PropertyName 'comparisonPairs')
    Merge-CountMap -Target $aggregateCategoryCounts -Source $normalizedSurface.categoryCounts
    Merge-ComparisonPairCollection -Target $aggregateComparisonPairs -Source $normalizedSurface.comparisonPairs
    Merge-CountMap -Target $aggregateBucketCounts -Source (Get-OptionalPropertyValue -InputObject $surfaceNode -PropertyName 'bucketCounts')

    $metadataNode = Get-SurfaceMetadataNode -SurfaceNode $surfaceNode
    $currentCaptureCount = [int](Get-OptionalPropertyValue -InputObject $metadataNode -PropertyName 'captureCount' -Default 0)
    $currentImageArtifactCount = [int](Get-OptionalPropertyValue -InputObject $metadataNode -PropertyName 'imageArtifactCount' -Default 0)
    $currentComparisonArtifactCount = [int](Get-OptionalPropertyValue -InputObject $metadataNode -PropertyName 'comparisonArtifactCount' -Default 0)

    $captureCount += $currentCaptureCount
    $imageArtifactCount += $currentImageArtifactCount
    $comparisonArtifactCount += $currentComparisonArtifactCount
    if ($currentCaptureCount -gt 0 -or $currentImageArtifactCount -gt 0 -or $currentComparisonArtifactCount -gt 0) {
      $chunkHasMetadata = $true
    }

    foreach ($mimeType in @(ConvertTo-ObjectArray -InputObject (Get-OptionalPropertyValue -InputObject $metadataNode -PropertyName 'imageMimeTypes' -Default @()))) {
      $mimeTypeValue = [string]$mimeType
      if (-not [string]::IsNullOrWhiteSpace($mimeTypeValue)) {
        [void]$imageMimeTypes.Add($mimeTypeValue.Trim())
      }
    }

    if ($chunkHasMetadata) {
      $chunkCountWithMetadata++
    }
  }

  $suppressionProfile = if ($suppressionProfiles.Count -eq 0) {
    'unknown'
  } elseif ($suppressionProfiles.Count -eq 1) {
    @($suppressionProfiles | ForEach-Object { $_ })[0]
  } else {
    'mixed'
  }

  return [pscustomobject]@{
    suppressionProfile = $suppressionProfile
    comparisonArtifactCount = $comparisonArtifactCount
    captureCount = $captureCount
    imageArtifactCount = $imageArtifactCount
    imageMimeTypes = @($imageMimeTypes | Sort-Object)
    chunkCountWithMetadata = $chunkCountWithMetadata
    categoryCounts = ConvertTo-OrderedCountMap -Value $aggregateCategoryCounts
    comparisonPairs = @(ConvertTo-ComparisonPairArray -Value $aggregateComparisonPairs)
    bucketCounts = ConvertTo-OrderedCountMap -Value $aggregateBucketCounts
  }
}

function New-ExplorationSurfaceStats {
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
    [string]$FinalReason,
    [Parameter(Mandatory = $true)]
    [string]$ReplayStatus,
    [Parameter(Mandatory = $true)]
    [string]$ReplayReason,
    [Parameter(Mandatory = $true)]
    [string]$BundleStatus,
    [Parameter(Mandatory = $true)]
    [string]$BundleReason,
    [Parameter(Mandatory = $true)]
    $SurfaceAggregate,
    [Parameter(Mandatory = $true)]
    [string[]]$RequestedModes,
    [Parameter(Mandatory = $true)]
    [string]$NoisePolicy
  )

  $segmentArray = ConvertTo-ObjectArray -InputObject $ChunkPlan.segments
  $segmentCount = $segmentArray.Count
  $continuityBreakCount = @(
    $segmentArray |
      Where-Object { $null -ne $_.continuityBreakAfterRevisionOrdinal }
  ).Count
  $chunkReceiptArray = ConvertTo-ObjectArray -InputObject $ChunkReceipts
  $completedChunkCount = @($chunkReceiptArray | Where-Object { [string]$_.status -eq 'succeeded' }).Count
  $failedChunkCount = @($chunkReceiptArray | Where-Object { [string]$_.status -eq 'failed' }).Count
  $skippedChunkCount = @($chunkReceiptArray | Where-Object { [string]$_.status -eq 'skipped' }).Count
  $remainingPlannedChunkCount = @($chunkReceiptArray | Where-Object { [string]$_.status -eq 'planned' }).Count

  return [pscustomobject]@{
    revisionCount             = [int]$Catalog.summary.revisionCount
    pairCount                 = [int]$ChunkPlan.summary.pairCount
    segmentCount              = $segmentCount
    continuityStatus          = [string]$Catalog.summary.continuityStatus
    continuityBreakCount      = $continuityBreakCount
    catalogComplete           = [bool]$Catalog.discovery.complete
    catalogCompletenessReason = [string]$Catalog.discovery.completenessReason
    totalChunkCount           = $chunkReceiptArray.Count
    completedChunkCount       = $completedChunkCount
    failedChunkCount          = $failedChunkCount
    skippedChunkCount         = $skippedChunkCount
    remainingPlannedChunkCount = $remainingPlannedChunkCount
    finalStatus               = $FinalStatus
    finalReason               = $FinalReason
    replayStatus              = $ReplayStatus
    replayReason              = $ReplayReason
    bundleStatus              = $BundleStatus
    bundleReason              = $BundleReason
    requestedModes            = @($RequestedModes)
    noisePolicy               = $NoisePolicy
    suppressionProfile        = [string]$SurfaceAggregate.suppressionProfile
    comparisonArtifactCount   = [int]$SurfaceAggregate.comparisonArtifactCount
    captureCount              = [int]$SurfaceAggregate.captureCount
    imageArtifactCount        = [int]$SurfaceAggregate.imageArtifactCount
    imageMimeTypes            = @($SurfaceAggregate.imageMimeTypes)
    chunkCountWithMetadata    = [int]$SurfaceAggregate.chunkCountWithMetadata
    categoryCounts            = $SurfaceAggregate.categoryCounts
    comparisonPairs           = @($SurfaceAggregate.comparisonPairs)
    bucketCounts              = $SurfaceAggregate.bucketCounts
  }
}

function Get-HtmlStatusClass {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Status
  )

  switch ($Status) {
    { $_ -in @('succeeded', 'ready', 'complete') } { return 'status-good' }
    { $_ -in @('partial', 'degraded', 'planned', 'not-required') } { return 'status-warn' }
    { $_ -eq 'failed' } { return 'status-bad' }
    default { return 'status-neutral' }
  }
}

function ConvertTo-ObjectArray {
  param(
    [AllowNull()]
    $InputObject
  )

  if ($null -eq $InputObject) {
    return @()
  }

  if ($InputObject -is [string] -or $InputObject -isnot [System.Collections.IEnumerable]) {
    return @($InputObject)
  }

  $items = New-Object System.Collections.Generic.List[object]
  foreach ($item in ([System.Collections.IEnumerable]$InputObject)) {
    $items.Add($item) | Out-Null
  }

  return @($items | ForEach-Object { $_ })
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
    $RunStats,
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
  $lines.Add('## Run summary') | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add(('- Catalog completeness: `{0}` ({1})' -f $RunStats.catalogComplete.ToString().ToLowerInvariant(), [string]$RunStats.catalogCompletenessReason)) | Out-Null
  $lines.Add(('- Continuity status: `{0}`' -f [string]$RunStats.continuityStatus)) | Out-Null
  $lines.Add(('- Continuity break count: `{0}`' -f [int]$RunStats.continuityBreakCount)) | Out-Null
  $lines.Add(('- Segment count: `{0}`' -f [int]$RunStats.segmentCount)) | Out-Null
  $lines.Add(('- Total chunk count: `{0}`' -f [int]$RunStats.totalChunkCount)) | Out-Null
  $lines.Add(('- Completed chunk count: `{0}`' -f [int]$RunStats.completedChunkCount)) | Out-Null
  $lines.Add(('- Failed chunk count: `{0}`' -f [int]$RunStats.failedChunkCount)) | Out-Null
  $lines.Add(('- Skipped chunk count: `{0}`' -f [int]$RunStats.skippedChunkCount)) | Out-Null
  $lines.Add(('- Remaining planned chunk count: `{0}`' -f [int]$RunStats.remainingPlannedChunkCount)) | Out-Null
  $lines.Add(('- Replay status: `{0}` ({1})' -f [string]$RunStats.replayStatus, [string]$RunStats.replayReason)) | Out-Null
  $lines.Add(('- Requested modes: `{0}`' -f $(if ($RunStats.requestedModes.Count -gt 0) { $RunStats.requestedModes -join ', ' } else { 'n/a' }))) | Out-Null
  $lines.Add(('- Noise policy: `{0}`' -f [string]$RunStats.noisePolicy)) | Out-Null
  $lines.Add(('- Suppression profile: `{0}`' -f [string]$RunStats.suppressionProfile)) | Out-Null
  if ([int]$RunStats.captureCount -gt 0 -or [int]$RunStats.imageArtifactCount -gt 0 -or [int]$RunStats.comparisonArtifactCount -gt 0) {
    $mimeTypeText = if ($RunStats.imageMimeTypes.Count -gt 0) { $RunStats.imageMimeTypes -join ', ' } else { 'none' }
    $lines.Add(('- Metadata surfaces: `captures={0}, images={1}, artifact-dirs={2}, mime-types={3}`' -f [int]$RunStats.captureCount, [int]$RunStats.imageArtifactCount, [int]$RunStats.comparisonArtifactCount, $mimeTypeText)) | Out-Null
    $lines.Add(('- Chunks with metadata: `{0}`' -f [int]$RunStats.chunkCountWithMetadata)) | Out-Null
  }
  if ($RunStats.categoryCounts.Count -gt 0) {
    $lines.Add(('- Category counts: `{0}`' -f (Format-CountMapText -Map $RunStats.categoryCounts))) | Out-Null
  }
  if (@($RunStats.comparisonPairs).Count -gt 0) {
    $lines.Add(('- Comparison pairs: `{0}`' -f (Format-ComparisonPairText -Pairs $RunStats.comparisonPairs))) | Out-Null
  }
  if ($RunStats.bucketCounts.Count -gt 0) {
    $lines.Add(('- Bucket counts: `{0}`' -f (Format-CountMapText -Map $RunStats.bucketCounts))) | Out-Null
  }
  $lines.Add('') | Out-Null
  $lines.Add('## Continuity overview') | Out-Null
  $lines.Add('') | Out-Null

  foreach ($segment in @($ChunkPlan.segments)) {
    $continuityNote = if ($null -ne $segment.continuityBreakAfterRevisionOrdinal) {
      ('; break after revision `{0}` ({1})' -f [int]$segment.continuityBreakAfterRevisionOrdinal, [string]$segment.continuityBreakReason)
    } else {
      ''
    }
    $lines.Add(('- Segment `{0}`: revisions `{1}` -> `{2}`, pairs `{3}`, start `{4}`{5}' -f [int]$segment.segmentOrdinal, [int]$segment.startRevisionOrdinal, [int]$segment.endRevisionOrdinal, [int]$segment.pairCount, [string]$segment.continuityStartReason, $continuityNote)) | Out-Null
  }
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
      $chunkSurfaces = Get-OptionalPropertyValue -InputObject $chunk -PropertyName 'surfaces'
      $chunkMetadata = Get-SurfaceMetadataNode -SurfaceNode $chunkSurfaces
      $lines.Add(('### {0}' -f [string]$chunk.chunkId)) | Out-Null
      $lines.Add(('- Status: `{0}`' -f [string]$chunk.status)) | Out-Null
      $lines.Add(('- Pair ordinals: `{0}` -> `{1}`' -f [int]$chunk.pairOrdinalStart, [int]$chunk.pairOrdinalEnd)) | Out-Null
      $lines.Add(('- Revision ordinals: `{0}` -> `{1}`' -f [int]$chunk.revisionOrdinalStart, [int]$chunk.revisionOrdinalEnd)) | Out-Null
      $lines.Add(('- Start ref: `{0}`' -f [string]$chunk.execution.startRef)) | Out-Null
      $lines.Add(('- End ref: `{0}`' -f [string]$chunk.execution.endRef)) | Out-Null
      $lines.Add(('- Total processed: `{0}`' -f [int](Get-OptionalPropertyValue -InputObject $chunkSummary -PropertyName 'totalProcessed' -Default 0))) | Out-Null
      $lines.Add(('- Total diffs: `{0}`' -f [int](Get-OptionalPropertyValue -InputObject $chunkSummary -PropertyName 'totalDiffs' -Default 0))) | Out-Null
      $lines.Add(('- Final reason: `{0}`' -f [string](Get-OptionalPropertyValue -InputObject $chunkSummary -PropertyName 'finalReason' -Default 'planned'))) | Out-Null
      if ($chunkSurfaces) {
        $chunkNormalizedSurface = ConvertTo-NormalizedCategorySurface `
          -CategoryCounts (Get-OptionalPropertyValue -InputObject $chunkSurfaces -PropertyName 'categoryCounts') `
          -ComparisonPairs (Get-OptionalPropertyValue -InputObject $chunkSurfaces -PropertyName 'comparisonPairs')
        $lines.Add(('- Suppression profile: `{0}`' -f [string](Get-OptionalPropertyValue -InputObject $chunkSurfaces -PropertyName 'suppressionProfile' -Default 'unknown'))) | Out-Null
        $mimeTypeText = if (@(ConvertTo-ObjectArray -InputObject (Get-OptionalPropertyValue -InputObject $chunkMetadata -PropertyName 'imageMimeTypes' -Default @())).Count -gt 0) {
          @(ConvertTo-ObjectArray -InputObject (Get-OptionalPropertyValue -InputObject $chunkMetadata -PropertyName 'imageMimeTypes' -Default @())) -join ', '
        } else {
          'none'
        }
        $lines.Add(('- Metadata surfaces: `captures={0}, images={1}, artifact-dirs={2}, mime-types={3}`' -f [int](Get-OptionalPropertyValue -InputObject $chunkMetadata -PropertyName 'captureCount' -Default 0), [int](Get-OptionalPropertyValue -InputObject $chunkMetadata -PropertyName 'imageArtifactCount' -Default 0), [int](Get-OptionalPropertyValue -InputObject $chunkMetadata -PropertyName 'comparisonArtifactCount' -Default 0), $mimeTypeText)) | Out-Null
        if ($chunkNormalizedSurface.categoryCounts.Count -gt 0) {
          $lines.Add(('- Category counts: `{0}`' -f (Format-CountMapText -Map $chunkNormalizedSurface.categoryCounts))) | Out-Null
        }
        if (@($chunkNormalizedSurface.comparisonPairs).Count -gt 0) {
          $lines.Add(('- Comparison pairs: `{0}`' -f (Format-ComparisonPairText -Pairs $chunkNormalizedSurface.comparisonPairs))) | Out-Null
        }
        $chunkBucketCounts = Get-OptionalPropertyValue -InputObject $chunkSurfaces -PropertyName 'bucketCounts'
        if ((ConvertTo-OrderedCountMap -Value $chunkBucketCounts).Count -gt 0) {
          $lines.Add(('- Bucket counts: `{0}`' -f (Format-CountMapText -Map $chunkBucketCounts))) | Out-Null
        }
      }
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

function New-MarkdownIndex {
  param(
    [Parameter(Mandatory = $true)]
    $Catalog,
    [Parameter(Mandatory = $true)]
    $ChunkPlan,
    [Parameter(Mandatory = $true)]
    $ChunkReceipts,
    [Parameter(Mandatory = $true)]
    $RunStats,
    [Parameter(Mandatory = $true)]
    [string]$FinalStatus,
    [Parameter(Mandatory = $true)]
    [string]$FinalReason,
    [Parameter(Mandatory = $true)]
    [string]$BundleStatus,
    [Parameter(Mandatory = $true)]
    [string]$BundleReason,
    [Parameter(Mandatory = $true)]
    [string]$ResultsRoot,
    [AllowNull()]
    [string]$TimelineMdPath,
    [AllowNull()]
    [string]$TimelineHtmlPath,
    [AllowNull()]
    [string]$BundlePath
  )

  $timelineMdReference = ConvertTo-ArtifactReference -Path $TimelineMdPath -ResultsRoot $ResultsRoot
  $timelineHtmlReference = ConvertTo-ArtifactReference -Path $TimelineHtmlPath -ResultsRoot $ResultsRoot
  $bundleReference = ConvertTo-ArtifactReference -Path $BundlePath -ResultsRoot $ResultsRoot -OnlyIfExists

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('# comparevi-history manual exploration index') | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add('## Run summary') | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add(('- Target path: `{0}`' -f [string]$Catalog.target.path)) | Out-Null
  $lines.Add(('- Selected ref: `{0}`' -f [string]$Catalog.target.selectedRef)) | Out-Null
  $lines.Add(('- Revision count: `{0}`' -f [int]$RunStats.revisionCount)) | Out-Null
  $lines.Add(('- Pair count: `{0}`' -f [int]$RunStats.pairCount)) | Out-Null
  $lines.Add(('- Final status: `{0}`' -f $FinalStatus)) | Out-Null
  $lines.Add(('- Final reason: `{0}`' -f $FinalReason)) | Out-Null
  $lines.Add(('- Catalog complete: `{0}` ({1})' -f $RunStats.catalogComplete.ToString().ToLowerInvariant(), [string]$RunStats.catalogCompletenessReason)) | Out-Null
  $lines.Add(('- Continuity status: `{0}`' -f [string]$RunStats.continuityStatus)) | Out-Null
  $lines.Add(('- Continuity break count: `{0}`' -f [int]$RunStats.continuityBreakCount)) | Out-Null
  $lines.Add(('- Segment count: `{0}`' -f [int]$RunStats.segmentCount)) | Out-Null
  $lines.Add(('- Total chunk count: `{0}`' -f [int]$RunStats.totalChunkCount)) | Out-Null
  $lines.Add(('- Completed chunk count: `{0}`' -f [int]$RunStats.completedChunkCount)) | Out-Null
  $lines.Add(('- Failed chunk count: `{0}`' -f [int]$RunStats.failedChunkCount)) | Out-Null
  $lines.Add(('- Skipped chunk count: `{0}`' -f [int]$RunStats.skippedChunkCount)) | Out-Null
  $lines.Add(('- Remaining planned chunk count: `{0}`' -f [int]$RunStats.remainingPlannedChunkCount)) | Out-Null
  $lines.Add(('- Replay status: `{0}` ({1})' -f [string]$RunStats.replayStatus, [string]$RunStats.replayReason)) | Out-Null
  $lines.Add(('- Requested modes: `{0}`' -f $(if ($RunStats.requestedModes.Count -gt 0) { $RunStats.requestedModes -join ', ' } else { 'n/a' }))) | Out-Null
  $lines.Add(('- Noise policy: `{0}`' -f [string]$RunStats.noisePolicy)) | Out-Null
  $lines.Add(('- Suppression profile: `{0}`' -f [string]$RunStats.suppressionProfile)) | Out-Null
  if ([int]$RunStats.captureCount -gt 0 -or [int]$RunStats.imageArtifactCount -gt 0 -or [int]$RunStats.comparisonArtifactCount -gt 0) {
    $mimeTypeText = if ($RunStats.imageMimeTypes.Count -gt 0) { $RunStats.imageMimeTypes -join ', ' } else { 'none' }
    $lines.Add(('- Metadata surfaces: `captures={0}, images={1}, artifact-dirs={2}, mime-types={3}`' -f [int]$RunStats.captureCount, [int]$RunStats.imageArtifactCount, [int]$RunStats.comparisonArtifactCount, $mimeTypeText)) | Out-Null
    $lines.Add(('- Chunks with metadata: `{0}`' -f [int]$RunStats.chunkCountWithMetadata)) | Out-Null
  }
  if ($RunStats.categoryCounts.Count -gt 0) {
    $lines.Add(('- Category counts: `{0}`' -f (Format-CountMapText -Map $RunStats.categoryCounts))) | Out-Null
  }
  if (@($RunStats.comparisonPairs).Count -gt 0) {
    $lines.Add(('- Comparison pairs: `{0}`' -f (Format-ComparisonPairText -Pairs $RunStats.comparisonPairs))) | Out-Null
  }
  if ($RunStats.bucketCounts.Count -gt 0) {
    $lines.Add(('- Bucket counts: `{0}`' -f (Format-CountMapText -Map $RunStats.bucketCounts))) | Out-Null
  }
  $lines.Add(('- Bundle status: `{0}`' -f $BundleStatus)) | Out-Null
  $lines.Add(('- Bundle reason: `{0}`' -f $BundleReason)) | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add('## Continuity overview') | Out-Null
  $lines.Add('') | Out-Null
  foreach ($segment in @($ChunkPlan.segments)) {
    $continuityNote = if ($null -ne $segment.continuityBreakAfterRevisionOrdinal) {
      ('; break after revision `{0}` ({1})' -f [int]$segment.continuityBreakAfterRevisionOrdinal, [string]$segment.continuityBreakReason)
    } else {
      ''
    }
    $lines.Add(('- Segment `{0}`: revisions `{1}` -> `{2}`, pairs `{3}`, start `{4}`{5}' -f [int]$segment.segmentOrdinal, [int]$segment.startRevisionOrdinal, [int]$segment.endRevisionOrdinal, [int]$segment.pairCount, [string]$segment.continuityStartReason, $continuityNote)) | Out-Null
  }
  $lines.Add('') | Out-Null
  $lines.Add('## Top-level surfaces') | Out-Null
  $lines.Add('') | Out-Null
  if ($timelineMdReference) {
    $lines.Add(('- Timeline markdown: {0}' -f (Format-MarkdownLink -Label 'timeline.md' -Href $timelineMdReference))) | Out-Null
  }
  if ($timelineHtmlReference) {
    $lines.Add(('- Timeline HTML: {0}' -f (Format-MarkdownLink -Label 'timeline.html' -Href $timelineHtmlReference))) | Out-Null
  }
  if ($bundleReference) {
    $lines.Add(('- Bundle zip: {0}' -f (Format-MarkdownLink -Label 'manual-vi-exploration-bundle.zip' -Href $bundleReference))) | Out-Null
  }
  $lines.Add('') | Out-Null
  $lines.Add('## Chunk navigation') | Out-Null
  $lines.Add('') | Out-Null

  foreach ($chunk in $ChunkReceipts) {
    $chunkOutputs = Get-OptionalPropertyValue -InputObject $chunk -PropertyName 'outputs'
    $chunkSummary = Get-OptionalPropertyValue -InputObject $chunk -PropertyName 'summary'
    $chunkSurfaces = Get-OptionalPropertyValue -InputObject $chunk -PropertyName 'surfaces'
    $chunkMetadata = Get-SurfaceMetadataNode -SurfaceNode $chunkSurfaces
    $receiptReference = ConvertTo-ArtifactReference -Path (Get-OptionalPropertyValue -InputObject $chunkOutputs -PropertyName 'receiptPath') -ResultsRoot $ResultsRoot -OnlyIfExists
    $historyReportMdReference = ConvertTo-ArtifactReference -Path (Get-OptionalPropertyValue -InputObject $chunkOutputs -PropertyName 'historyReportMd') -ResultsRoot $ResultsRoot -OnlyIfExists
    $historyReportHtmlReference = ConvertTo-ArtifactReference -Path (Get-OptionalPropertyValue -InputObject $chunkOutputs -PropertyName 'historyReportHtml') -ResultsRoot $ResultsRoot -OnlyIfExists
    $modeSummaryReference = ConvertTo-ArtifactReference -Path (Get-OptionalPropertyValue -InputObject $chunkOutputs -PropertyName 'modeSummaryPath') -ResultsRoot $ResultsRoot -OnlyIfExists
    $modeSummaryJsonReference = ConvertTo-ArtifactReference -Path (Get-OptionalPropertyValue -InputObject $chunkOutputs -PropertyName 'modeSummaryJsonPath') -ResultsRoot $ResultsRoot -OnlyIfExists

    $lines.Add(('### {0}' -f [string]$chunk.chunkId)) | Out-Null
    $lines.Add(('- Status: `{0}`' -f [string]$chunk.status)) | Out-Null
    $lines.Add(('- Segment: `{0}`' -f [int]$chunk.segmentOrdinal)) | Out-Null
    $lines.Add(('- Revision ordinals: `{0}` -> `{1}`' -f [int]$chunk.revisionOrdinalStart, [int]$chunk.revisionOrdinalEnd)) | Out-Null
    $lines.Add(('- Pair ordinals: `{0}` -> `{1}`' -f [int]$chunk.pairOrdinalStart, [int]$chunk.pairOrdinalEnd)) | Out-Null
    $lines.Add(('- Total diffs: `{0}`' -f [int](Get-OptionalPropertyValue -InputObject $chunkSummary -PropertyName 'totalDiffs' -Default 0))) | Out-Null
    if ($chunkSurfaces) {
      $chunkNormalizedSurface = ConvertTo-NormalizedCategorySurface `
        -CategoryCounts (Get-OptionalPropertyValue -InputObject $chunkSurfaces -PropertyName 'categoryCounts') `
        -ComparisonPairs (Get-OptionalPropertyValue -InputObject $chunkSurfaces -PropertyName 'comparisonPairs')
      $lines.Add(('- Suppression profile: `{0}`' -f [string](Get-OptionalPropertyValue -InputObject $chunkSurfaces -PropertyName 'suppressionProfile' -Default 'unknown'))) | Out-Null
      $mimeTypeText = if (@(ConvertTo-ObjectArray -InputObject (Get-OptionalPropertyValue -InputObject $chunkMetadata -PropertyName 'imageMimeTypes' -Default @())).Count -gt 0) {
        @(ConvertTo-ObjectArray -InputObject (Get-OptionalPropertyValue -InputObject $chunkMetadata -PropertyName 'imageMimeTypes' -Default @())) -join ', '
      } else {
        'none'
      }
      $lines.Add(('- Metadata surfaces: `captures={0}, images={1}, artifact-dirs={2}, mime-types={3}`' -f [int](Get-OptionalPropertyValue -InputObject $chunkMetadata -PropertyName 'captureCount' -Default 0), [int](Get-OptionalPropertyValue -InputObject $chunkMetadata -PropertyName 'imageArtifactCount' -Default 0), [int](Get-OptionalPropertyValue -InputObject $chunkMetadata -PropertyName 'comparisonArtifactCount' -Default 0), $mimeTypeText)) | Out-Null
      if ($chunkNormalizedSurface.categoryCounts.Count -gt 0) {
        $lines.Add(('- Category counts: `{0}`' -f (Format-CountMapText -Map $chunkNormalizedSurface.categoryCounts))) | Out-Null
      }
      if (@($chunkNormalizedSurface.comparisonPairs).Count -gt 0) {
        $lines.Add(('- Comparison pairs: `{0}`' -f (Format-ComparisonPairText -Pairs $chunkNormalizedSurface.comparisonPairs))) | Out-Null
      }
    }
    if ($receiptReference) {
      $lines.Add(('- Receipt: {0}' -f (Format-MarkdownLink -Label 'chunk-receipt.json' -Href $receiptReference))) | Out-Null
    }
    if ($historyReportMdReference) {
      $lines.Add(('- History report (md): {0}' -f (Format-MarkdownLink -Label 'history-report.md' -Href $historyReportMdReference))) | Out-Null
    }
    if ($historyReportHtmlReference) {
      $lines.Add(('- History report (html): {0}' -f (Format-MarkdownLink -Label 'history-report.html' -Href $historyReportHtmlReference))) | Out-Null
    }
    if ($modeSummaryReference) {
      $lines.Add(('- Mode summary: {0}' -f (Format-MarkdownLink -Label 'mode-summary.md' -Href $modeSummaryReference))) | Out-Null
    }
    if ($modeSummaryJsonReference) {
      $lines.Add(('- Mode summary (json): {0}' -f (Format-MarkdownLink -Label 'mode-summary.json' -Href $modeSummaryJsonReference))) | Out-Null
    }
    $lines.Add('') | Out-Null
  }

  return ($lines -join [Environment]::NewLine)
}

function New-HtmlTimeline {
  param(
    [Parameter(Mandatory = $true)]
    $Catalog,
    [Parameter(Mandatory = $true)]
    $ChunkPlan,
    [Parameter(Mandatory = $true)]
    $ChunkReceipts,
    [Parameter(Mandatory = $true)]
    $RunStats,
    [Parameter(Mandatory = $true)]
    [string]$FinalStatus,
    [Parameter(Mandatory = $true)]
    [string]$FinalReason
  )

  $summaryClass = Get-HtmlStatusClass -Status $FinalStatus
  $rows = New-Object System.Collections.Generic.List[string]
  foreach ($chunk in $ChunkReceipts) {
    $chunkSummary = Get-OptionalPropertyValue -InputObject $chunk -PropertyName 'summary'
    $chunkClass = Get-HtmlStatusClass -Status ([string]$chunk.status)
    $rows.Add(@"
<tr class="$chunkClass">
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

  $continuityRows = New-Object System.Collections.Generic.List[string]
  foreach ($segment in @($ChunkPlan.segments)) {
    $breakCell = if ($null -ne $segment.continuityBreakAfterRevisionOrdinal) {
      ('{0} ({1})' -f [int]$segment.continuityBreakAfterRevisionOrdinal, [string]$segment.continuityBreakReason)
    } else {
      'none'
    }
    $continuityRows.Add(@"
<tr>
  <td>$([int]$segment.segmentOrdinal)</td>
  <td>$([int]$segment.startRevisionOrdinal)-$([int]$segment.endRevisionOrdinal)</td>
  <td>$([int]$segment.pairCount)</td>
  <td>$([string]$segment.continuityStartReason)</td>
  <td>$breakCell</td>
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
    .summary { display: grid; grid-template-columns: max-content 1fr; gap: 0.5rem 1rem; margin-bottom: 1.5rem; }
    .banner { padding: 0.75rem 1rem; margin-bottom: 1rem; border-left: 0.4rem solid #666; background: #f3f3f3; }
    .status-good { background: #eef8ef; border-left-color: #2e7d32; }
    .status-warn { background: #fff7e8; border-left-color: #b26a00; }
    .status-bad { background: #fdecea; border-left-color: #b42318; }
    .status-neutral { background: #f3f3f3; border-left-color: #666; }
    table { border-collapse: collapse; width: 100%; }
    th, td { border: 1px solid #ccc; padding: 0.5rem; text-align: left; }
    th { background: #f3f3f3; }
  </style>
</head>
<body>
  <h1>comparevi-history manual exploration timeline</h1>
  <div class="banner $summaryClass">
    <strong>Final status:</strong> $FinalStatus
    <span> | <strong>Final reason:</strong> $FinalReason</span>
    <span> | <strong>Continuity:</strong> $([string]$RunStats.continuityStatus)</span>
  </div>
  <div class="summary">
    <strong>Target path</strong><span>$([string]$Catalog.target.path)</span>
    <strong>Selected ref</strong><span>$([string]$Catalog.target.selectedRef)</span>
    <strong>Revision count</strong><span>$([int]$RunStats.revisionCount)</span>
    <strong>Pair count</strong><span>$([int]$RunStats.pairCount)</span>
    <strong>Requested modes</strong><span>$(if ($RunStats.requestedModes.Count -gt 0) { $RunStats.requestedModes -join ', ' } else { 'n/a' })</span>
    <strong>Noise policy</strong><span>$([string]$RunStats.noisePolicy)</span>
    <strong>Suppression profile</strong><span>$([string]$RunStats.suppressionProfile)</span>
    <strong>Catalog completeness</strong><span>$($RunStats.catalogComplete.ToString().ToLowerInvariant()) ($([string]$RunStats.catalogCompletenessReason))</span>
    <strong>Segment count</strong><span>$([int]$RunStats.segmentCount)</span>
    <strong>Continuity break count</strong><span>$([int]$RunStats.continuityBreakCount)</span>
    <strong>Total chunk count</strong><span>$([int]$RunStats.totalChunkCount)</span>
    <strong>Metadata surfaces</strong><span>captures=$([int]$RunStats.captureCount), images=$([int]$RunStats.imageArtifactCount), artifact-dirs=$([int]$RunStats.comparisonArtifactCount)</span>
    <strong>Image MIME types</strong><span>$(if ($RunStats.imageMimeTypes.Count -gt 0) { $RunStats.imageMimeTypes -join ', ' } else { 'none' })</span>
    <strong>Category counts</strong><span>$(Format-CountMapText -Map $RunStats.categoryCounts)</span>
    <strong>Comparison pairs</strong><span>$(Format-ComparisonPairText -Pairs $RunStats.comparisonPairs)</span>
    <strong>Bucket counts</strong><span>$(Format-CountMapText -Map $RunStats.bucketCounts)</span>
    <strong>Completed chunks</strong><span>$([int]$RunStats.completedChunkCount)</span>
    <strong>Failed chunks</strong><span>$([int]$RunStats.failedChunkCount)</span>
    <strong>Skipped chunks</strong><span>$([int]$RunStats.skippedChunkCount)</span>
    <strong>Remaining planned chunks</strong><span>$([int]$RunStats.remainingPlannedChunkCount)</span>
    <strong>Replay status</strong><span>$([string]$RunStats.replayStatus) ($([string]$RunStats.replayReason))</span>
  </div>
  <h2>Continuity overview</h2>
  <table>
    <thead>
      <tr>
        <th>Segment</th>
        <th>Revision ordinals</th>
        <th>Pairs</th>
        <th>Start reason</th>
        <th>Break</th>
      </tr>
    </thead>
    <tbody>
$($continuityRows -join [Environment]::NewLine)
    </tbody>
  </table>
  <h2>Chunk timeline</h2>
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

function New-HtmlIndex {
  param(
    [Parameter(Mandatory = $true)]
    $Catalog,
    [Parameter(Mandatory = $true)]
    $ChunkPlan,
    [Parameter(Mandatory = $true)]
    $ChunkReceipts,
    [Parameter(Mandatory = $true)]
    $RunStats,
    [Parameter(Mandatory = $true)]
    [string]$FinalStatus,
    [Parameter(Mandatory = $true)]
    [string]$FinalReason,
    [Parameter(Mandatory = $true)]
    [string]$BundleStatus,
    [Parameter(Mandatory = $true)]
    [string]$BundleReason,
    [Parameter(Mandatory = $true)]
    [string]$ResultsRoot,
    [AllowNull()]
    [string]$TimelineMdPath,
    [AllowNull()]
    [string]$TimelineHtmlPath,
    [AllowNull()]
    [string]$BundlePath
  )

  $timelineMdReference = ConvertTo-ArtifactReference -Path $TimelineMdPath -ResultsRoot $ResultsRoot
  $timelineHtmlReference = ConvertTo-ArtifactReference -Path $TimelineHtmlPath -ResultsRoot $ResultsRoot
  $bundleReference = ConvertTo-ArtifactReference -Path $BundlePath -ResultsRoot $ResultsRoot -OnlyIfExists
  $summaryClass = Get-HtmlStatusClass -Status $FinalStatus
  $rows = New-Object System.Collections.Generic.List[string]
  foreach ($chunk in $ChunkReceipts) {
    $chunkOutputs = Get-OptionalPropertyValue -InputObject $chunk -PropertyName 'outputs'
    $chunkSummary = Get-OptionalPropertyValue -InputObject $chunk -PropertyName 'summary'
    $chunkSurfaces = Get-OptionalPropertyValue -InputObject $chunk -PropertyName 'surfaces'
    $chunkMetadata = Get-SurfaceMetadataNode -SurfaceNode $chunkSurfaces
    $receiptReference = ConvertTo-ArtifactReference -Path (Get-OptionalPropertyValue -InputObject $chunkOutputs -PropertyName 'receiptPath') -ResultsRoot $ResultsRoot -OnlyIfExists
    $historyReportMdReference = ConvertTo-ArtifactReference -Path (Get-OptionalPropertyValue -InputObject $chunkOutputs -PropertyName 'historyReportMd') -ResultsRoot $ResultsRoot -OnlyIfExists
    $historyReportHtmlReference = ConvertTo-ArtifactReference -Path (Get-OptionalPropertyValue -InputObject $chunkOutputs -PropertyName 'historyReportHtml') -ResultsRoot $ResultsRoot -OnlyIfExists
    $modeSummaryReference = ConvertTo-ArtifactReference -Path (Get-OptionalPropertyValue -InputObject $chunkOutputs -PropertyName 'modeSummaryPath') -ResultsRoot $ResultsRoot -OnlyIfExists
    $modeSummaryJsonReference = ConvertTo-ArtifactReference -Path (Get-OptionalPropertyValue -InputObject $chunkOutputs -PropertyName 'modeSummaryJsonPath') -ResultsRoot $ResultsRoot -OnlyIfExists
    $receiptLink = Format-HtmlLink -Label 'chunk-receipt.json' -Href $receiptReference
    $historyReportMdLink = Format-HtmlLink -Label 'history-report.md' -Href $historyReportMdReference
    $historyReportHtmlLink = Format-HtmlLink -Label 'history-report.html' -Href $historyReportHtmlReference
    $modeSummaryLink = Format-HtmlLink -Label 'mode-summary.md' -Href $modeSummaryReference
    $modeSummaryJsonLink = Format-HtmlLink -Label 'mode-summary.json' -Href $modeSummaryJsonReference
    $chunkClass = Get-HtmlStatusClass -Status ([string]$chunk.status)
    $chunkProfile = [string](Get-OptionalPropertyValue -InputObject $chunkSurfaces -PropertyName 'suppressionProfile' -Default 'unknown')
    $chunkMetadataText = 'captures={0}, images={1}, artifact-dirs={2}' -f [int](Get-OptionalPropertyValue -InputObject $chunkMetadata -PropertyName 'captureCount' -Default 0), [int](Get-OptionalPropertyValue -InputObject $chunkMetadata -PropertyName 'imageArtifactCount' -Default 0), [int](Get-OptionalPropertyValue -InputObject $chunkMetadata -PropertyName 'comparisonArtifactCount' -Default 0)
    $rows.Add(@"
<tr class="$chunkClass">
  <td>$([string]$chunk.chunkId)</td>
  <td>$([string]$chunk.status)</td>
  <td>$chunkProfile</td>
  <td>$([int]$chunk.segmentOrdinal)</td>
  <td>$([int]$chunk.revisionOrdinalStart)-$([int]$chunk.revisionOrdinalEnd)</td>
  <td>$([int]$chunk.pairOrdinalStart)-$([int]$chunk.pairOrdinalEnd)</td>
  <td>$([int](Get-OptionalPropertyValue -InputObject $chunkSummary -PropertyName 'totalDiffs' -Default 0))</td>
  <td>$chunkMetadataText</td>
  <td>$receiptLink</td>
  <td>$historyReportMdLink</td>
  <td>$historyReportHtmlLink</td>
  <td>$modeSummaryLink</td>
  <td>$modeSummaryJsonLink</td>
</tr>
"@) | Out-Null
  }

  $continuityRows = New-Object System.Collections.Generic.List[string]
  foreach ($segment in @($ChunkPlan.segments)) {
    $breakCell = if ($null -ne $segment.continuityBreakAfterRevisionOrdinal) {
      ('{0} ({1})' -f [int]$segment.continuityBreakAfterRevisionOrdinal, [string]$segment.continuityBreakReason)
    } else {
      'none'
    }
    $continuityRows.Add(@"
<tr>
  <td>$([int]$segment.segmentOrdinal)</td>
  <td>$([int]$segment.startRevisionOrdinal)-$([int]$segment.endRevisionOrdinal)</td>
  <td>$([int]$segment.pairCount)</td>
  <td>$([string]$segment.continuityStartReason)</td>
  <td>$breakCell</td>
</tr>
"@) | Out-Null
  }

  $topLevelLinks = New-Object System.Collections.Generic.List[string]
  if ($timelineMdReference) {
    $topLevelLinks.Add(('<li><a href="{0}">timeline.md</a></li>' -f $timelineMdReference)) | Out-Null
  }
  if ($timelineHtmlReference) {
    $topLevelLinks.Add(('<li><a href="{0}">timeline.html</a></li>' -f $timelineHtmlReference)) | Out-Null
  }
  if ($bundleReference) {
    $topLevelLinks.Add(('<li><a href="{0}">manual-vi-exploration-bundle.zip</a></li>' -f $bundleReference)) | Out-Null
  }

  return @"
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8" />
  <title>comparevi-history manual exploration index</title>
  <style>
    body { font-family: Segoe UI, Arial, sans-serif; margin: 2rem; }
    table { border-collapse: collapse; width: 100%; }
    th, td { border: 1px solid #ccc; padding: 0.5rem; text-align: left; vertical-align: top; }
    th { background: #f3f3f3; }
    .meta { display: grid; grid-template-columns: max-content 1fr; gap: 0.5rem 1rem; margin-bottom: 1.5rem; }
    .banner { padding: 0.75rem 1rem; margin-bottom: 1rem; border-left: 0.4rem solid #666; background: #f3f3f3; }
    .status-good { background: #eef8ef; border-left-color: #2e7d32; }
    .status-warn { background: #fff7e8; border-left-color: #b26a00; }
    .status-bad { background: #fdecea; border-left-color: #b42318; }
    .status-neutral { background: #f3f3f3; border-left-color: #666; }
  </style>
</head>
<body>
  <h1>comparevi-history manual exploration index</h1>
  <div class="banner $summaryClass">
    <strong>Final status:</strong> $FinalStatus
    <span> | <strong>Final reason:</strong> $FinalReason</span>
    <span> | <strong>Continuity:</strong> $([string]$RunStats.continuityStatus)</span>
  </div>
  <div class="meta">
    <strong>Target path</strong><span>$([string]$Catalog.target.path)</span>
    <strong>Selected ref</strong><span>$([string]$Catalog.target.selectedRef)</span>
    <strong>Revision count</strong><span>$([int]$RunStats.revisionCount)</span>
    <strong>Pair count</strong><span>$([int]$RunStats.pairCount)</span>
    <strong>Requested modes</strong><span>$(if ($RunStats.requestedModes.Count -gt 0) { $RunStats.requestedModes -join ', ' } else { 'n/a' })</span>
    <strong>Noise policy</strong><span>$([string]$RunStats.noisePolicy)</span>
    <strong>Suppression profile</strong><span>$([string]$RunStats.suppressionProfile)</span>
    <strong>Final status</strong><span>$FinalStatus</span>
    <strong>Final reason</strong><span>$FinalReason</span>
    <strong>Catalog completeness</strong><span>$($RunStats.catalogComplete.ToString().ToLowerInvariant()) ($([string]$RunStats.catalogCompletenessReason))</span>
    <strong>Continuity status</strong><span>$([string]$RunStats.continuityStatus)</span>
    <strong>Continuity break count</strong><span>$([int]$RunStats.continuityBreakCount)</span>
    <strong>Segment count</strong><span>$([int]$RunStats.segmentCount)</span>
    <strong>Total chunk count</strong><span>$([int]$RunStats.totalChunkCount)</span>
    <strong>Metadata surfaces</strong><span>captures=$([int]$RunStats.captureCount), images=$([int]$RunStats.imageArtifactCount), artifact-dirs=$([int]$RunStats.comparisonArtifactCount)</span>
    <strong>Image MIME types</strong><span>$(if ($RunStats.imageMimeTypes.Count -gt 0) { $RunStats.imageMimeTypes -join ', ' } else { 'none' })</span>
    <strong>Category counts</strong><span>$(Format-CountMapText -Map $RunStats.categoryCounts)</span>
    <strong>Comparison pairs</strong><span>$(Format-ComparisonPairText -Pairs $RunStats.comparisonPairs)</span>
    <strong>Bucket counts</strong><span>$(Format-CountMapText -Map $RunStats.bucketCounts)</span>
    <strong>Completed chunks</strong><span>$([int]$RunStats.completedChunkCount)</span>
    <strong>Failed chunks</strong><span>$([int]$RunStats.failedChunkCount)</span>
    <strong>Skipped chunks</strong><span>$([int]$RunStats.skippedChunkCount)</span>
    <strong>Remaining planned chunks</strong><span>$([int]$RunStats.remainingPlannedChunkCount)</span>
    <strong>Replay status</strong><span>$([string]$RunStats.replayStatus) ($([string]$RunStats.replayReason))</span>
    <strong>Bundle status</strong><span>$BundleStatus</span>
    <strong>Bundle reason</strong><span>$BundleReason</span>
  </div>
  <h2>Continuity overview</h2>
  <table>
    <thead>
      <tr>
        <th>Segment</th>
        <th>Revision ordinals</th>
        <th>Pairs</th>
        <th>Start reason</th>
        <th>Break</th>
      </tr>
    </thead>
    <tbody>
$($continuityRows -join [Environment]::NewLine)
    </tbody>
  </table>
  <h2>Top-level surfaces</h2>
  <ul>
$($topLevelLinks -join [Environment]::NewLine)
  </ul>
  <h2>Chunk navigation</h2>
  <table>
    <thead>
      <tr>
        <th>Chunk</th>
        <th>Status</th>
        <th>Profile</th>
        <th>Segment</th>
        <th>Revision ordinals</th>
        <th>Pair ordinals</th>
        <th>Diffs</th>
        <th>Metadata</th>
        <th>Receipt</th>
        <th>Markdown</th>
        <th>HTML</th>
        <th>Mode summary</th>
        <th>Mode summary JSON</th>
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
$indexMdResolved = if ([string]::IsNullOrWhiteSpace($IndexMd)) { Join-Path $resultsDirResolved 'index.md' } else { Resolve-AbsolutePath -Path $IndexMd -BasePath $resultsDirResolved }
$indexHtmlResolved = if ([string]::IsNullOrWhiteSpace($IndexHtml)) { Join-Path $resultsDirResolved 'index.html' } else { Resolve-AbsolutePath -Path $IndexHtml -BasePath $resultsDirResolved }
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

$surfaceAggregate = New-ExplorationSurfaceAggregate -ChunkReceipts $chunkReceipts
$runStats = New-ExplorationSurfaceStats `
  -Catalog $catalog `
  -ChunkPlan $chunkPlan `
  -ChunkReceipts $chunkReceipts `
  -FinalStatus $finalStatus `
  -FinalReason $finalReason `
  -ReplayStatus $replayStatus `
  -ReplayReason $replayReason `
  -BundleStatus $effectiveBundleStatus `
  -BundleReason $effectiveBundleReason `
  -SurfaceAggregate $surfaceAggregate `
  -RequestedModes $requestedModes `
  -NoisePolicy $NoisePolicy

$chunkReceiptArray = @(ConvertTo-ObjectArray -InputObject $chunkReceipts)
$timelineMarkdown = New-MarkdownTimeline -Catalog $catalog -ChunkPlan $chunkPlan -ChunkReceipts $chunkReceiptArray -RunStats $runStats -FinalStatus $finalStatus -FinalReason $finalReason
$timelineHtml = New-HtmlTimeline -Catalog $catalog -ChunkPlan $chunkPlan -ChunkReceipts $chunkReceiptArray -RunStats $runStats -FinalStatus $finalStatus -FinalReason $finalReason
$indexMarkdown = New-MarkdownIndex `
  -Catalog $catalog `
  -ChunkPlan $chunkPlan `
  -ChunkReceipts $chunkReceiptArray `
  -RunStats $runStats `
  -FinalStatus $finalStatus `
  -FinalReason $finalReason `
  -BundleStatus $effectiveBundleStatus `
  -BundleReason $effectiveBundleReason `
  -ResultsRoot $resultsDirResolved `
  -TimelineMdPath $timelineMdResolved `
  -TimelineHtmlPath $timelineHtmlResolved `
  -BundlePath $bundlePathResolved
$indexHtml = New-HtmlIndex `
  -Catalog $catalog `
  -ChunkPlan $chunkPlan `
  -ChunkReceipts $chunkReceiptArray `
  -RunStats $runStats `
  -FinalStatus $finalStatus `
  -FinalReason $finalReason `
  -BundleStatus $effectiveBundleStatus `
  -BundleReason $effectiveBundleReason `
  -ResultsRoot $resultsDirResolved `
  -TimelineMdPath $timelineMdResolved `
  -TimelineHtmlPath $timelineHtmlResolved `
  -BundlePath $bundlePathResolved
$timelineMarkdown | Set-Content -LiteralPath $timelineMdResolved -Encoding utf8
$timelineHtml | Set-Content -LiteralPath $timelineHtmlResolved -Encoding utf8
$indexMarkdown | Set-Content -LiteralPath $indexMdResolved -Encoding utf8
$indexHtml | Set-Content -LiteralPath $indexHtmlResolved -Encoding utf8

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
  surfaces = [ordered]@{
    suppressionProfile = [string]$surfaceAggregate.suppressionProfile
    comparisonArtifactCount = [int]$surfaceAggregate.comparisonArtifactCount
    captureCount = [int]$surfaceAggregate.captureCount
    imageArtifactCount = [int]$surfaceAggregate.imageArtifactCount
    imageMimeTypes = @($surfaceAggregate.imageMimeTypes)
    chunkCountWithMetadata = [int]$surfaceAggregate.chunkCountWithMetadata
    categoryCounts = $surfaceAggregate.categoryCounts
    comparisonPairs = @($surfaceAggregate.comparisonPairs)
    bucketCounts = $surfaceAggregate.bucketCounts
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
    indexMd = $indexMdResolved
    indexHtml = $indexHtmlResolved
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
    suppressionProfile = [string]$surfaceAggregate.suppressionProfile
    captureCount = [int]$surfaceAggregate.captureCount
    imageArtifactCount = [int]$surfaceAggregate.imageArtifactCount
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
Write-ActionOutput -Key 'index-md' -Value $indexMdResolved
Write-ActionOutput -Key 'index-html' -Value $indexHtmlResolved
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
    ('- Total chunk count: `{0}`' -f $runStats.totalChunkCount)
    ('- Completed chunk count: `{0}`' -f $completedChunkCount)
    ('- Failed chunk count: `{0}`' -f $failedChunkCount)
    ('- Skipped chunk count: `{0}`' -f $skippedChunkCount)
    ('- Remaining planned chunk count: `{0}`' -f $runStats.remainingPlannedChunkCount)
    ('- Catalog completeness: `{0}` ({1})' -f $runStats.catalogComplete.ToString().ToLowerInvariant(), [string]$runStats.catalogCompletenessReason)
    ('- Continuity status: `{0}`' -f [string]$runStats.continuityStatus)
    ('- Continuity break count: `{0}`' -f [int]$runStats.continuityBreakCount)
    ('- Segment count: `{0}`' -f [int]$runStats.segmentCount)
    ('- Final status: `{0}`' -f $finalStatus)
    ('- Final reason: `{0}`' -f $finalReason)
    ('- Replay status: `{0}` ({1})' -f [string]$runStats.replayStatus, [string]$runStats.replayReason)
    ('- Requested modes: `{0}`' -f $(if ($requestedModes.Count -gt 0) { $requestedModes -join ', ' } else { 'n/a' }))
    ('- Noise policy: `{0}`' -f $NoisePolicy)
    ('- Suppression profile: `{0}`' -f [string]$surfaceAggregate.suppressionProfile)
    ('- Metadata surfaces: `captures={0}, images={1}, artifact-dirs={2}`' -f [int]$surfaceAggregate.captureCount, [int]$surfaceAggregate.imageArtifactCount, [int]$surfaceAggregate.comparisonArtifactCount)
    ('- Category counts: `{0}`' -f (Format-CountMapText -Map $surfaceAggregate.categoryCounts))
    ('- Comparison pairs: `{0}`' -f (Format-ComparisonPairText -Pairs $surfaceAggregate.comparisonPairs))
    ('- Bucket counts: `{0}`' -f (Format-CountMapText -Map $surfaceAggregate.bucketCounts))
    ('- Index (md): `{0}`' -f $indexMdResolved)
    ('- Index (html): `{0}`' -f $indexHtmlResolved)
    ('- Bundle status: `{0}`' -f $effectiveBundleStatus)
    ('- Bundle reason: `{0}`' -f $effectiveBundleReason)
    ('- Bundle path: `{0}`' -f $(if ($null -eq $bundlePathResolved) { '' } else { $bundlePathResolved }))
    ('- Timeline (md): `{0}`' -f $timelineMdResolved)
    ('- Timeline (html): `{0}`' -f $timelineHtmlResolved)
  ) | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
}

$explorationRun | ConvertTo-Json -Depth 64
