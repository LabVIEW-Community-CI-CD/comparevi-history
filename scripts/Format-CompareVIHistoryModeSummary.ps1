param(
  [string]$RequestedModeList,
  [string]$ExecutedModeList,
  [string]$ModeManifestsJson,
  [string]$TotalProcessed,
  [string]$TotalDiffs,
  [string]$StopReason,
  [ValidateSet('include', 'collapse', 'skip')]
  [string]$NoisePolicy,
  [string]$GitHubOutputPath,
  [string]$OutputPath,
  [string]$JsonOutputPath,
  [string]$StepSummaryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$suppressionFlags = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($flag in @('-nobd', '-noattr', '-nofp', '-nofppos', '-nobdcosm')) {
  [void]$suppressionFlags.Add($flag)
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

  return @($modes | Sort-Object -Unique)
}

function ConvertTo-ObjectArray {
  param(
    [AllowNull()]
    $Value
  )

  if ($null -eq $Value) {
    return @()
  }

  if ($Value -is [string] -or $Value -isnot [System.Collections.IEnumerable]) {
    return @($Value)
  }

  $items = New-Object System.Collections.Generic.List[object]
  foreach ($item in ([System.Collections.IEnumerable]$Value)) {
    $items.Add($item) | Out-Null
  }

  return @($items | ForEach-Object { $_ })
}

function Resolve-ExistingPath {
  param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$Path
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }

  $resolved = if ([System.IO.Path]::IsPathRooted($Path)) {
    [System.IO.Path]::GetFullPath($Path)
  } else {
    [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
  }

  if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
    return $null
  }

  return $resolved
}

function Write-MultilineGitHubOutput {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Key,
    [Parameter(Mandatory = $true)]
    [string]$Value,
    [string]$Path
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return
  }

  $delimiter = "EOF_{0}" -f ([guid]::NewGuid().ToString('N'))
  @(
    "$Key<<$delimiter"
    $Value
    $delimiter
  ) | Out-File -FilePath $Path -Encoding utf8 -Append
}

function Get-EntryValue {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Entry,
    [Parameter(Mandatory = $true)]
    [string]$Name,
    $DefaultValue = $null
  )

  if ($Entry -is [System.Collections.IDictionary]) {
    if ($Entry.Contains($Name)) {
      return $Entry[$Name]
    }

    return $DefaultValue
  }

  $property = $Entry.PSObject.Properties[$Name]
  if ($null -eq $property) {
    return $DefaultValue
  }

  return $property.Value
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
    $keys = @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object)
    foreach ($key in $keys) {
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

function Format-CountMap {
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
  foreach ($pair in @(ConvertTo-ObjectArray -Value $Value)) {
    $firstPath = [string](Get-EntryValue -Entry $pair -Name 'firstPath' -DefaultValue '')
    $secondPath = [string](Get-EntryValue -Entry $pair -Name 'secondPath' -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace($firstPath) -or [string]::IsNullOrWhiteSpace($secondPath)) {
      continue
    }

    $pairs.Add([ordered]@{
        firstPath = $firstPath.Trim()
        secondPath = $secondPath.Trim()
        count = [int](Get-EntryValue -Entry $pair -Name 'count' -DefaultValue 0)
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
    $Value
  )

  $normalizedSource = ConvertTo-OrderedCountMap -Value $Value
  $categoryCounts = @{}
  $comparisonPairs = @{}

  foreach ($rawKey in @($normalizedSource.Keys | Sort-Object)) {
    $count = [int]$normalizedSource[$rawKey]
    $comparisonPair = Try-ParseComparisonPairLabel -Label ([string]$rawKey)
    if ($null -ne $comparisonPair) {
      Add-ComparisonPairAggregate -Target $comparisonPairs -FirstPath ([string]$comparisonPair.firstPath) -SecondPath ([string]$comparisonPair.secondPath) -Count $count
      continue
    }

    $normalizedKey = Normalize-CategoryLabel -Value ([string]$rawKey)
    if ([string]::IsNullOrWhiteSpace($normalizedKey)) {
      continue
    }

    if (-not $categoryCounts.Contains($normalizedKey)) {
      $categoryCounts[$normalizedKey] = 0
    }
    $categoryCounts[$normalizedKey] = [int]$categoryCounts[$normalizedKey] + $count
  }

  return [pscustomobject]@{
    categoryCounts = ConvertTo-OrderedCountMap -Value $categoryCounts
    comparisonPairs = @(ConvertTo-ComparisonPairArray -Value $comparisonPairs)
  }
}

function Format-ComparisonPairList {
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

function Get-ModeSummaryTotal {
  param(
    [AllowNull()]
    $ModeSummaries,
    [Parameter(Mandatory = $true)]
    [string]$PropertyName
  )

  $total = 0
  foreach ($modeSummary in @(ConvertTo-ObjectArray -Value $ModeSummaries)) {
    $value = Get-EntryValue -Entry $modeSummary -Name $PropertyName -DefaultValue 0
    if ($null -eq $value) {
      continue
    }

    $renderedValue = [string]$value
    if ([string]::IsNullOrWhiteSpace($renderedValue)) {
      continue
    }

    $total += [int]$value
  }

  return $total
}

function Get-SuppressionProfile {
  param(
    [AllowNull()]
    [object[]]$Flags
  )

  $flagList = @()
  if ($Flags) {
    $flagList = @(
      $Flags |
        ForEach-Object { [string]$_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim() }
    )
  }

  foreach ($flag in $flagList) {
    if ($suppressionFlags.Contains($flag)) {
      return 'suppressed'
    }
  }

  if ($flagList.Count -eq 0) {
    return 'unsuppressed'
  }

  return 'unsuppressed'
}

function Read-CaptureMetadata {
  param(
    [AllowNull()]
    [string]$ArtifactDir
  )

  $summary = [ordered]@{
    comparisonArtifactCount = 0
    captureCount = 0
    imageArtifactCount = 0
    imageMimeTypes = @()
  }

  if ([string]::IsNullOrWhiteSpace($ArtifactDir)) {
    return $summary
  }

  if (-not (Test-Path -LiteralPath $ArtifactDir -PathType Container)) {
    return $summary
  }

  $summary.comparisonArtifactCount = 1
  $capturePath = Join-Path $ArtifactDir 'lvcompare-capture.json'
  if (-not (Test-Path -LiteralPath $capturePath -PathType Leaf)) {
    return $summary
  }

  try {
    $capture = Get-Content -LiteralPath $capturePath -Raw | ConvertFrom-Json -Depth 32
  } catch {
    return $summary
  }

  $summary.captureCount = 1
  $mimeTypes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $images = ConvertTo-ObjectArray -Value $capture.environment.cli.artifacts.images
  foreach ($image in $images) {
    $summary.imageArtifactCount++
    $mimeType = [string](Get-EntryValue -Entry $image -Name 'mimeType' -DefaultValue '')
    if (-not [string]::IsNullOrWhiteSpace($mimeType)) {
      [void]$mimeTypes.Add($mimeType.Trim())
    }
  }
  $summary.imageMimeTypes = @($mimeTypes | Sort-Object)
  return $summary
}

function Get-ModeSurfaceSummary {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Entry
  )

  $manifestPath = Resolve-ExistingPath -Path ([string](Get-EntryValue -Entry $Entry -Name 'manifest' -DefaultValue ''))
  $manifest = $null
  if ($manifestPath) {
    try {
      $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 64
    } catch {
      $manifest = $null
    }
  }

  $flags = @(
    (Get-EntryValue -Entry $Entry -Name 'flags' -DefaultValue @()) |
      ForEach-Object { [string]$_ } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      ForEach-Object { $_.Trim() }
  )
  if ($flags.Count -eq 0 -and $manifest) {
    $flags = @(
      (Get-EntryValue -Entry $manifest -Name 'flags' -DefaultValue @()) |
        ForEach-Object { [string]$_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim() }
    )
  }

  $stats = if ($manifest) { Get-EntryValue -Entry $manifest -Name 'stats' -DefaultValue $null } else { $null }
  $categorySurface = ConvertTo-NormalizedCategorySurface -Value $(if ($stats) { Get-EntryValue -Entry $stats -Name 'categoryCounts' -DefaultValue $null } else { Get-EntryValue -Entry $Entry -Name 'categoryCounts' -DefaultValue $null })
  $categoryCounts = $categorySurface.categoryCounts
  $comparisonPairs = @($categorySurface.comparisonPairs)
  $bucketCounts = ConvertTo-OrderedCountMap -Value $(if ($stats) { Get-EntryValue -Entry $stats -Name 'bucketCounts' -DefaultValue $null } else { Get-EntryValue -Entry $Entry -Name 'bucketCounts' -DefaultValue $null })

  $artifactDirSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $captureCount = 0
  $imageArtifactCount = 0
  $comparisonArtifactCount = 0
  $imageMimeTypes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($comparison in @(ConvertTo-ObjectArray -Value $(if ($manifest) { Get-EntryValue -Entry $manifest -Name 'comparisons' -DefaultValue @() } else { @() }))) {
    $resultNode = Get-EntryValue -Entry $comparison -Name 'result' -DefaultValue $null
    $artifactDir = [string](Get-EntryValue -Entry $resultNode -Name 'artifactDir' -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace($artifactDir)) {
      continue
    }
    $resolvedArtifactDir = if ([System.IO.Path]::IsPathRooted($artifactDir)) {
      [System.IO.Path]::GetFullPath($artifactDir)
    } else {
      [System.IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $manifestPath) $artifactDir))
    }
    if (-not $artifactDirSet.Add($resolvedArtifactDir)) {
      continue
    }

    $captureSummary = Read-CaptureMetadata -ArtifactDir $resolvedArtifactDir
    $comparisonArtifactCount += [int]$captureSummary.comparisonArtifactCount
    $captureCount += [int]$captureSummary.captureCount
    $imageArtifactCount += [int]$captureSummary.imageArtifactCount
    foreach ($mimeType in @($captureSummary.imageMimeTypes)) {
      [void]$imageMimeTypes.Add([string]$mimeType)
    }
  }

  return [pscustomobject]@{
    mode = [string](Get-EntryValue -Entry $Entry -Name 'mode' -DefaultValue 'unknown')
    processed = [int](Get-EntryValue -Entry $Entry -Name 'processed' -DefaultValue 0)
    diffs = [int](Get-EntryValue -Entry $Entry -Name 'diffs' -DefaultValue 0)
    signalDiffs = [int](Get-EntryValue -Entry $Entry -Name 'signalDiffs' -DefaultValue 0)
    noiseCollapsed = [int](Get-EntryValue -Entry $Entry -Name 'noiseCollapsed' -DefaultValue 0)
    errors = [int](Get-EntryValue -Entry $Entry -Name 'errors' -DefaultValue 0)
    status = [string](Get-EntryValue -Entry $Entry -Name 'status' -DefaultValue 'unknown')
    flags = @($flags | Sort-Object -Unique)
    suppressionProfile = Get-SuppressionProfile -Flags $flags
    categoryCounts = $categoryCounts
    comparisonPairs = $comparisonPairs
    bucketCounts = $bucketCounts
    metadata = [ordered]@{
      comparisonArtifactCount = $comparisonArtifactCount
      captureCount = $captureCount
      imageArtifactCount = $imageArtifactCount
      imageMimeTypes = @($imageMimeTypes | Sort-Object)
    }
  }
}

$requestedModes = @(ConvertTo-NormalizedModeList -Value $RequestedModeList)
$executedModes = @(ConvertTo-NormalizedModeList -Value $ExecutedModeList)

$modeEntries = @()
if (-not [string]::IsNullOrWhiteSpace($ModeManifestsJson)) {
  $modeEntries = @(ConvertTo-ObjectArray -Value ($ModeManifestsJson | ConvertFrom-Json -Depth 64))
}

if ($requestedModes.Count -eq 0 -and $modeEntries.Count -gt 0) {
  $requestedModes = @(
    $modeEntries |
      ForEach-Object { [string](Get-EntryValue -Entry $_ -Name 'mode' -DefaultValue '') } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      Sort-Object -Unique
  )
}

if ($executedModes.Count -eq 0 -and $modeEntries.Count -gt 0) {
  $executedModes = @(
    $modeEntries |
      ForEach-Object { [string](Get-EntryValue -Entry $_ -Name 'mode' -DefaultValue '') } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      Sort-Object -Unique
  )
}

$modeSummaries = @($modeEntries | ForEach-Object { Get-ModeSurfaceSummary -Entry $_ })
$aggregateCategoryCounts = @{}
$aggregateBucketCounts = @{}
$aggregateComparisonPairs = @{}
$aggregateCaptureCount = 0
$aggregateImageArtifactCount = 0
$aggregateComparisonArtifactCount = 0
$aggregateMimeTypes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$aggregateProfiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$hasUnknownProfile = $false

foreach ($modeSummary in $modeSummaries) {
  $profile = [string]$modeSummary.suppressionProfile
  if ([string]::IsNullOrWhiteSpace($profile) -or $profile -eq 'unknown') {
    $hasUnknownProfile = $true
  } else {
    [void]$aggregateProfiles.Add($profile)
  }
  Merge-CountMap -Target $aggregateCategoryCounts -Source $modeSummary.categoryCounts
  Merge-ComparisonPairCollection -Target $aggregateComparisonPairs -Source $modeSummary.comparisonPairs
  Merge-CountMap -Target $aggregateBucketCounts -Source $modeSummary.bucketCounts
  $aggregateCaptureCount += [int]$modeSummary.metadata.captureCount
  $aggregateImageArtifactCount += [int]$modeSummary.metadata.imageArtifactCount
  $aggregateComparisonArtifactCount += [int]$modeSummary.metadata.comparisonArtifactCount
  foreach ($mimeType in @($modeSummary.metadata.imageMimeTypes)) {
    [void]$aggregateMimeTypes.Add([string]$mimeType)
  }
}

$suppressionProfile = if ($aggregateProfiles.Count -eq 0) {
  'unknown'
} elseif ($aggregateProfiles.Count -eq 1) {
  @($aggregateProfiles | ForEach-Object { $_ })[0]
} else {
  'mixed'
}

$effectiveTotalProcessed = if ([string]::IsNullOrWhiteSpace($TotalProcessed)) {
  [string](Get-ModeSummaryTotal -ModeSummaries $modeSummaries -PropertyName 'processed')
} else {
  $TotalProcessed
}
$effectiveTotalDiffs = if ([string]::IsNullOrWhiteSpace($TotalDiffs)) {
  [string](Get-ModeSummaryTotal -ModeSummaries $modeSummaries -PropertyName 'diffs')
} else {
  $TotalDiffs
}

$modeSummaryObject = [ordered]@{
  schema = 'comparevi-history/mode-summary@v1'
  requestedModes = @($requestedModes)
  executedModes = @($executedModes)
  totalProcessed = if ([string]::IsNullOrWhiteSpace($effectiveTotalProcessed)) { $null } else { [int]$effectiveTotalProcessed }
  totalDiffs = if ([string]::IsNullOrWhiteSpace($effectiveTotalDiffs)) { $null } else { [int]$effectiveTotalDiffs }
  stopReason = if ([string]::IsNullOrWhiteSpace($StopReason)) { $null } else { $StopReason }
  noisePolicy = if ([string]::IsNullOrWhiteSpace($NoisePolicy)) { $null } else { $NoisePolicy }
  suppressionProfile = $suppressionProfile
  categoryCounts = [ordered]@{}
  comparisonPairs = @()
  bucketCounts = [ordered]@{}
  metadata = [ordered]@{
    comparisonArtifactCount = $aggregateComparisonArtifactCount
    captureCount = $aggregateCaptureCount
    imageArtifactCount = $aggregateImageArtifactCount
    imageMimeTypes = @($aggregateMimeTypes | Sort-Object)
  }
  modes = @($modeSummaries)
}

foreach ($key in @($aggregateCategoryCounts.Keys | Sort-Object)) {
  $modeSummaryObject.categoryCounts[$key] = [int]$aggregateCategoryCounts[$key]
}
$modeSummaryObject.comparisonPairs = @(ConvertTo-ComparisonPairArray -Value $aggregateComparisonPairs)
foreach ($key in @($aggregateBucketCounts.Keys | Sort-Object)) {
  $modeSummaryObject.bucketCounts[$key] = [int]$aggregateBucketCounts[$key]
}

$summaryLines = New-Object System.Collections.Generic.List[string]
$summaryLines.Add(('Requested modes: `{0}`' -f $(if ($requestedModes.Count -gt 0) { $requestedModes -join ', ' } else { 'n/a' })))
$summaryLines.Add(('Executed modes: `{0}`' -f $(if ($executedModes.Count -gt 0) { $executedModes -join ', ' } else { 'n/a' })))
if (-not [string]::IsNullOrWhiteSpace($NoisePolicy)) {
  $summaryLines.Add(('Noise policy: `{0}`' -f $NoisePolicy))
}
$summaryLines.Add(('Suppression profile: `{0}`' -f $suppressionProfile))
$summaryLines.Add(('Total processed: `{0}`' -f $(if ([string]::IsNullOrWhiteSpace($effectiveTotalProcessed)) { 'n/a' } else { $effectiveTotalProcessed })))
$summaryLines.Add(('Total diffs: `{0}`' -f $(if ([string]::IsNullOrWhiteSpace($effectiveTotalDiffs)) { 'n/a' } else { $effectiveTotalDiffs })))
if (-not [string]::IsNullOrWhiteSpace($StopReason)) {
  $summaryLines.Add(('Stop reason: `{0}`' -f $StopReason))
}
if ($aggregateCaptureCount -gt 0 -or $aggregateImageArtifactCount -gt 0 -or $aggregateComparisonArtifactCount -gt 0) {
  $mimeTypeText = if ($aggregateMimeTypes.Count -gt 0) { @($aggregateMimeTypes | Sort-Object) -join ', ' } else { 'none' }
  $summaryLines.Add(('Metadata surfaces: `captures={0}, images={1}, artifact-dirs={2}, mime-types={3}`' -f $aggregateCaptureCount, $aggregateImageArtifactCount, $aggregateComparisonArtifactCount, $mimeTypeText))
}
if ($modeSummaryObject.categoryCounts.Count -gt 0) {
  $summaryLines.Add(('Category counts: `{0}`' -f (Format-CountMap -Map $modeSummaryObject.categoryCounts)))
}
if ($modeSummaryObject.comparisonPairs.Count -gt 0) {
  $summaryLines.Add(('Comparison pairs: `{0}`' -f (Format-ComparisonPairList -Pairs $modeSummaryObject.comparisonPairs)))
}
if ($modeSummaryObject.bucketCounts.Count -gt 0) {
  $summaryLines.Add(('Bucket counts: `{0}`' -f (Format-CountMap -Map $modeSummaryObject.bucketCounts)))
}

if ($modeSummaries.Count -gt 0) {
  $summaryLines.Add('')
  $summaryLines.Add('| Mode | Profile | Flags | Processed | Diffs | Signal | Noise | Metadata | Status |')
  $summaryLines.Add('| --- | --- | --- | ---: | ---: | ---: | --- | --- | --- |')
  foreach ($entry in @($modeSummaries | Sort-Object -Property @{ Expression = { $_.mode } })) {
    $flagsText = if ($entry.flags.Count -gt 0) { $entry.flags -join ', ' } else { 'none' }
    $noiseText = if (-not [string]::IsNullOrWhiteSpace($NoisePolicy) -and $NoisePolicy -eq 'include') {
      'in-band'
    } elseif ($entry.noiseCollapsed -gt 0) {
      'collapsed:{0}' -f [int]$entry.noiseCollapsed
    } else {
      '0'
    }
    $metadataText = 'captures={0}; images={1}' -f [int]$entry.metadata.captureCount, [int]$entry.metadata.imageArtifactCount
    $summaryLines.Add((
      '| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} |' -f `
      $entry.mode, `
      $entry.suppressionProfile, `
      $flagsText, `
      [int]$entry.processed, `
      [int]$entry.diffs, `
      [int]$entry.signalDiffs, `
      $noiseText, `
      $metadataText, `
      $entry.status
    ))
  }

  foreach ($entry in @($modeSummaries | Sort-Object -Property @{ Expression = { $_.mode } })) {
    if ($entry.categoryCounts.Count -eq 0 -and $entry.bucketCounts.Count -eq 0 -and [int]$entry.metadata.captureCount -eq 0 -and [int]$entry.metadata.imageArtifactCount -eq 0) {
      continue
    }

    $detailParts = New-Object System.Collections.Generic.List[string]
    if ($entry.categoryCounts.Count -gt 0) {
      $detailParts.Add(('categories={0}' -f (Format-CountMap -Map $entry.categoryCounts))) | Out-Null
    }
    if (@($entry.comparisonPairs).Count -gt 0) {
      $detailParts.Add(('comparison-pairs={0}' -f (Format-ComparisonPairList -Pairs $entry.comparisonPairs))) | Out-Null
    }
    if ($entry.bucketCounts.Count -gt 0) {
      $detailParts.Add(('buckets={0}' -f (Format-CountMap -Map $entry.bucketCounts))) | Out-Null
    }
    if ([int]$entry.metadata.captureCount -gt 0 -or [int]$entry.metadata.imageArtifactCount -gt 0) {
      $mimeTypeText = if ($entry.metadata.imageMimeTypes.Count -gt 0) { $entry.metadata.imageMimeTypes -join ', ' } else { 'none' }
      $detailParts.Add(('metadata=captures:{0}, images:{1}, artifact-dirs:{2}, mime-types:{3}' -f [int]$entry.metadata.captureCount, [int]$entry.metadata.imageArtifactCount, [int]$entry.metadata.comparisonArtifactCount, $mimeTypeText)) | Out-Null
    }
    if ($detailParts.Count -gt 0) {
      $summaryLines.Add(('- {0}: `{1}`' -f $entry.mode, ($detailParts -join '; ')))
    }
  }
}

$summary = $summaryLines -join [Environment]::NewLine

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
  $outputDirectory = Split-Path -Parent $OutputPath
  if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
  }
  $summary | Set-Content -LiteralPath $OutputPath -Encoding utf8
}

if (-not [string]::IsNullOrWhiteSpace($JsonOutputPath)) {
  $jsonDirectory = Split-Path -Parent $JsonOutputPath
  if (-not [string]::IsNullOrWhiteSpace($jsonDirectory)) {
    New-Item -ItemType Directory -Path $jsonDirectory -Force | Out-Null
  }
  $modeSummaryObject | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $JsonOutputPath -Encoding utf8
}

Write-MultilineGitHubOutput -Key 'mode-summary-markdown' -Value $summary -Path $GitHubOutputPath
if (-not [string]::IsNullOrWhiteSpace($JsonOutputPath) -and -not [string]::IsNullOrWhiteSpace($GitHubOutputPath)) {
  "$('mode-summary-json-path')=$JsonOutputPath" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
}

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  @(
    '### comparevi-history mode summary'
    ''
    $summary
  ) | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
}

$summary
