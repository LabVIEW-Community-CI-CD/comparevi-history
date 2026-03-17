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

$script:PreviewGalleryCap = 12
$script:StepSummaryPreviewCap = 2
$script:StepSummaryPreviewByteBudget = 196608

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

function ConvertTo-HtmlText {
  param(
    [AllowNull()]
    [string]$Value
  )

  if ($null -eq $Value) {
    return ''
  }

  return [System.Net.WebUtility]::HtmlEncode([string]$Value)
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
        ForEach-Object {
          $firstPath = [string](Get-OptionalPropertyValue -InputObject $_.Value -PropertyName 'firstPath' -Default '')
          $secondPath = [string](Get-OptionalPropertyValue -InputObject $_.Value -PropertyName 'secondPath' -Default '')
          if ([string]::IsNullOrWhiteSpace($firstPath) -or [string]::IsNullOrWhiteSpace($secondPath)) {
            return
          }
          [ordered]@{
            firstPath = $firstPath
            secondPath = $secondPath
            count = [int](Get-OptionalPropertyValue -InputObject $_.Value -PropertyName 'count' -Default 0)
          }
        } |
        Where-Object { $null -ne $_ } |
        Sort-Object { [string]$_.firstPath }, { [string]$_.secondPath }
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

function ConvertTo-PreviewComparisonPair {
  param(
    [AllowNull()]
    $Value
  )

  if ($null -eq $Value) {
    return $null
  }

  $firstPath = [string](Get-OptionalPropertyValue -InputObject $Value -PropertyName 'firstPath' -Default '')
  $secondPath = [string](Get-OptionalPropertyValue -InputObject $Value -PropertyName 'secondPath' -Default '')
  if ([string]::IsNullOrWhiteSpace($firstPath) -or [string]::IsNullOrWhiteSpace($secondPath)) {
    return $null
  }

  return [ordered]@{
    firstPath = $firstPath.Trim()
    secondPath = $secondPath.Trim()
  }
}

function Format-PreviewComparisonPairText {
  param(
    [AllowNull()]
    $Pair
  )

  $normalizedPair = ConvertTo-PreviewComparisonPair -Value $Pair
  if ($null -eq $normalizedPair) {
    return 'n/a'
  }

  return ('{0} -> {1}' -f [string]$normalizedPair.firstPath, [string]$normalizedPair.secondPath)
}

function ConvertTo-PreviewImageArray {
  param(
    [AllowNull()]
    $Value
  )

  $images = New-Object System.Collections.Generic.List[object]
  foreach ($preview in @(ConvertTo-ObjectArray -InputObject $Value)) {
    $relativePath = [string](Get-OptionalPropertyValue -InputObject $preview -PropertyName 'relativePath' -Default '')
    if ([string]::IsNullOrWhiteSpace($relativePath)) {
      continue
    }

    $chunkId = [string](Get-OptionalPropertyValue -InputObject $preview -PropertyName 'chunkId' -Default 'unknown')
    $mode = [string](Get-OptionalPropertyValue -InputObject $preview -PropertyName 'mode' -Default 'unknown')
    $category = Normalize-CategoryLabel -Value ([string](Get-OptionalPropertyValue -InputObject $preview -PropertyName 'category' -Default 'uncategorized'))
    if ([string]::IsNullOrWhiteSpace($category)) {
      $category = 'uncategorized'
    }

    $comparisonPair = ConvertTo-PreviewComparisonPair -Value (Get-OptionalPropertyValue -InputObject $preview -PropertyName 'comparisonPair')
    $sortKey = [string](Get-OptionalPropertyValue -InputObject $preview -PropertyName 'sortKey' -Default '')
    $normalizedRelativePath = $relativePath.Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($sortKey)) {
      $sortKey = ('{0}|{1}|{2}|{3}|{4}|{5}' -f $chunkId, $mode, $category, $(if ($null -eq $comparisonPair) { '' } else { [string]$comparisonPair.firstPath }), $(if ($null -eq $comparisonPair) { '' } else { [string]$comparisonPair.secondPath }), $normalizedRelativePath).ToLowerInvariant()
    }

    $images.Add([ordered]@{
        chunkId = $(if ([string]::IsNullOrWhiteSpace($chunkId)) { 'unknown' } else { $chunkId.Trim() })
        mode = $(if ([string]::IsNullOrWhiteSpace($mode)) { 'unknown' } else { $mode.Trim() })
        category = $category
        comparisonPair = $comparisonPair
        mimeType = [string](Get-OptionalPropertyValue -InputObject $preview -PropertyName 'mimeType' -Default '')
        byteLength = [int](Get-OptionalPropertyValue -InputObject $preview -PropertyName 'byteLength' -Default 0)
        relativePath = $normalizedRelativePath
        sortKey = $sortKey
      }) | Out-Null
  }

  return @(
    $images |
      Sort-Object { [string]$_.sortKey }, { [string]$_.relativePath } |
      ForEach-Object { $_ }
  )
}

function Add-PreviewImageAggregate {
  param(
    [Parameter(Mandatory = $true)]
    [hashtable]$Target,
    [Parameter(Mandatory = $true)]
    [string]$ChunkId,
    [AllowNull()]
    $PreviewImage,
    [Parameter(Mandatory = $true)]
    [string]$ResultsRoot
  )

  if ($null -eq $PreviewImage) {
    return
  }

  $relativePath = [string](Get-OptionalPropertyValue -InputObject $PreviewImage -PropertyName 'relativePath' -Default '')
  if ([string]::IsNullOrWhiteSpace($relativePath)) {
    $savedPath = [string](Get-OptionalPropertyValue -InputObject $PreviewImage -PropertyName 'savedPath' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($savedPath)) {
      $relativePath = ConvertTo-ArtifactReference -Path $savedPath -ResultsRoot $ResultsRoot -OnlyIfExists
    }
  }
  if ([string]::IsNullOrWhiteSpace($relativePath)) {
    return
  }

  $mode = [string](Get-OptionalPropertyValue -InputObject $PreviewImage -PropertyName 'mode' -Default 'unknown')
  $category = Normalize-CategoryLabel -Value ([string](Get-OptionalPropertyValue -InputObject $PreviewImage -PropertyName 'category' -Default 'uncategorized'))
  if ([string]::IsNullOrWhiteSpace($category)) {
    $category = 'uncategorized'
  }

  $comparisonPair = ConvertTo-PreviewComparisonPair -Value (Get-OptionalPropertyValue -InputObject $PreviewImage -PropertyName 'comparisonPair')
  $mimeType = [string](Get-OptionalPropertyValue -InputObject $PreviewImage -PropertyName 'mimeType' -Default '')
  $byteLength = [int](Get-OptionalPropertyValue -InputObject $PreviewImage -PropertyName 'byteLength' -Default 0)
  $sortKey = [string](Get-OptionalPropertyValue -InputObject $PreviewImage -PropertyName 'sortKey' -Default '')
  $normalizedRelativePath = $relativePath.Replace('\', '/')
  if ([string]::IsNullOrWhiteSpace($sortKey)) {
    $sortKey = ('{0}|{1}|{2}|{3}|{4}|{5}' -f $ChunkId, $mode, $category, $(if ($null -eq $comparisonPair) { '' } else { [string]$comparisonPair.firstPath }), $(if ($null -eq $comparisonPair) { '' } else { [string]$comparisonPair.secondPath }), $normalizedRelativePath).ToLowerInvariant()
  }

  $key = ('{0}|{1}|{2}|{3}|{4}|{5}' -f $ChunkId.Trim(), $mode.Trim(), $category, $(if ($null -eq $comparisonPair) { '' } else { [string]$comparisonPair.firstPath }), $(if ($null -eq $comparisonPair) { '' } else { [string]$comparisonPair.secondPath }), $normalizedRelativePath).ToLowerInvariant()
  if ($Target.Contains($key)) {
    return
  }

  $Target[$key] = [ordered]@{
    chunkId = $(if ([string]::IsNullOrWhiteSpace($ChunkId)) { 'unknown' } else { $ChunkId.Trim() })
    mode = $(if ([string]::IsNullOrWhiteSpace($mode)) { 'unknown' } else { $mode.Trim() })
    category = $category
    comparisonPair = $comparisonPair
    mimeType = $mimeType
    byteLength = $byteLength
    relativePath = $normalizedRelativePath
    sortKey = $sortKey
  }
}

function Select-PreviewGalleryImages {
  param(
    [AllowNull()]
    $PreviewImages,
    [Parameter(Mandatory = $true)]
    [int]$Limit
  )

  if ($Limit -le 0) {
    return @()
  }

  return @((ConvertTo-PreviewImageArray -Value $PreviewImages) | Select-Object -First $Limit)
}

function Select-StepSummaryPreviewImages {
  param(
    [AllowNull()]
    $PreviewImages,
    [Parameter(Mandatory = $true)]
    [string]$ResultsRoot,
    [Parameter(Mandatory = $true)]
    [int]$Limit,
    [Parameter(Mandatory = $true)]
    [int]$ByteBudget
  )

  $selected = New-Object System.Collections.Generic.List[object]
  $usedBytes = 0
  $previewArray = @(ConvertTo-PreviewImageArray -Value $PreviewImages)
  foreach ($preview in $previewArray) {
    if ($selected.Count -ge $Limit) {
      break
    }

    $mimeType = [string]$preview.mimeType
    if ([string]::IsNullOrWhiteSpace($mimeType) -or -not $mimeType.StartsWith('image/', [System.StringComparison]::OrdinalIgnoreCase)) {
      continue
    }

    $resolvedPath = Resolve-AbsolutePath -Path ([string]$preview.relativePath) -BasePath $ResultsRoot
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
      continue
    }

    $imageBytes = [System.IO.File]::ReadAllBytes($resolvedPath)
    $byteLength = if ([int]$preview.byteLength -gt 0) { [int]$preview.byteLength } else { $imageBytes.Length }
    if (($usedBytes + $byteLength) -gt $ByteBudget) {
      break
    }

    $selected.Add([ordered]@{
        chunkId = [string]$preview.chunkId
        mode = [string]$preview.mode
        category = [string]$preview.category
        comparisonPair = $preview.comparisonPair
        mimeType = $mimeType
        byteLength = $byteLength
        relativePath = [string]$preview.relativePath
        sortKey = [string]$preview.sortKey
        dataUri = ('data:{0};base64,{1}' -f $mimeType, [Convert]::ToBase64String($imageBytes))
      }) | Out-Null
    $usedBytes += $byteLength
  }

  return [pscustomobject]@{
    images = @($selected | ForEach-Object { $_ })
    byteCount = $usedBytes
  }
}

function New-MarkdownPreviewGallery {
  param(
    [AllowNull()]
    $PreviewImages,
    [AllowNull()]
    $EvidenceGraph,
    [Parameter(Mandatory = $true)]
    $RunStats
  )

  $previewArray = @(ConvertTo-PreviewImageArray -Value $PreviewImages)
  if ($previewArray.Count -eq 0) {
    return ''
  }

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('## Preview gallery') | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add(('- Preview images available: `{0}`' -f [int]$RunStats.previewImageCount)) | Out-Null
  $lines.Add(('- Gallery cap: `{0}`' -f [int]$RunStats.previewGalleryCap)) | Out-Null
  $lines.Add(('- Gallery shown: `{0}`' -f [int]$RunStats.previewGalleryCount)) | Out-Null
  $lines.Add(('- Gallery omitted: `{0}`' -f [int]$RunStats.previewGalleryOmittedCount)) | Out-Null
  $lines.Add('') | Out-Null

  $previewOrdinal = 1
  foreach ($preview in $previewArray) {
    $chunkNode = if ($null -eq $EvidenceGraph) { $null } else { Get-EvidenceGraphChunkById -EvidenceGraph $EvidenceGraph -ChunkId ([string]$preview.chunkId) }
    $chunkOutputs = Get-OptionalPropertyValue -InputObject $chunkNode -PropertyName 'outputs'
    $title = '{0} | {1}' -f [string]$preview.mode, [string]$preview.category
    $lines.Add(('### Preview `{0}`: {1}' -f $previewOrdinal, $title)) | Out-Null
    $lines.Add(('- Chunk: `{0}`' -f [string]$preview.chunkId)) | Out-Null
    $lines.Add(('- MIME type: `{0}`' -f [string]$preview.mimeType)) | Out-Null
    $lines.Add(('- Byte length: `{0}`' -f [int]$preview.byteLength)) | Out-Null
    if ($null -ne $preview.comparisonPair) {
      $lines.Add(('- Comparison pair: `{0}`' -f (Format-PreviewComparisonPairText -Pair $preview.comparisonPair))) | Out-Null
    }
    $lines.Add(('- Chunk details: {0}' -f (Format-MarkdownLink -Label ([string]$preview.chunkId) -Href ('#{0}' -f (Get-ChunkAnchorId -ChunkId ([string]$preview.chunkId)))))) | Out-Null
    $lines.Add(('- Image file: {0}' -f (Format-MarkdownLink -Label ([System.IO.Path]::GetFileName([string]$preview.relativePath)) -Href ([string]$preview.relativePath)))) | Out-Null
    $historyReportHtmlHref = [string](Get-OptionalPropertyValue -InputObject $chunkOutputs -PropertyName 'historyReportHtml' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($historyReportHtmlHref)) {
      $lines.Add(('- HTML report: {0}' -f (Format-MarkdownLink -Label 'history-report.html' -Href $historyReportHtmlHref))) | Out-Null
    }
    $modeSummaryHref = [string](Get-OptionalPropertyValue -InputObject $chunkOutputs -PropertyName 'modeSummaryPath' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($modeSummaryHref)) {
      $lines.Add(('- Mode summary: {0}' -f (Format-MarkdownLink -Label 'mode-summary.md' -Href $modeSummaryHref))) | Out-Null
    }
    $lines.Add(('![{0}]({1})' -f $title, [string]$preview.relativePath)) | Out-Null
    $lines.Add('') | Out-Null
    $previewOrdinal++
  }

  return ($lines -join [Environment]::NewLine)
}

function New-HtmlPreviewGallery {
  param(
    [AllowNull()]
    $PreviewImages,
    [AllowNull()]
    $EvidenceGraph,
    [Parameter(Mandatory = $true)]
    $RunStats
  )

  $previewArray = @(ConvertTo-PreviewImageArray -Value $PreviewImages)
  if ($previewArray.Count -eq 0) {
    return ''
  }

  $cards = New-Object System.Collections.Generic.List[string]
  foreach ($preview in $previewArray) {
    $chunkNode = if ($null -eq $EvidenceGraph) { $null } else { Get-EvidenceGraphChunkById -EvidenceGraph $EvidenceGraph -ChunkId ([string]$preview.chunkId) }
    $chunkOutputs = Get-OptionalPropertyValue -InputObject $chunkNode -PropertyName 'outputs'
    $chunkAnchorHref = '#' + (Get-ChunkAnchorId -ChunkId ([string]$preview.chunkId))
    $chunkLink = Format-HtmlLink -Label ([string]$preview.chunkId) -Href $chunkAnchorHref
    $rawImageLink = Format-HtmlLink -Label ([System.IO.Path]::GetFileName([string]$preview.relativePath)) -Href ([string]$preview.relativePath)
    $historyReportHtmlLink = Format-HtmlLink -Label 'history-report.html' -Href ([string](Get-OptionalPropertyValue -InputObject $chunkOutputs -PropertyName 'historyReportHtml'))
    $modeSummaryLink = Format-HtmlLink -Label 'mode-summary.md' -Href ([string](Get-OptionalPropertyValue -InputObject $chunkOutputs -PropertyName 'modeSummaryPath'))
    $comparisonPairMarkup = if ($null -eq $preview.comparisonPair) {
      ''
    } else {
      ('<div><strong>Comparison pair</strong><span>{0}</span></div>' -f (ConvertTo-HtmlText -Value (Format-PreviewComparisonPairText -Pair $preview.comparisonPair)))
    }
    $chunkDetailMarkup = if ([string]::IsNullOrWhiteSpace($chunkLink)) { '' } else { ('<div><strong>Chunk details</strong><span>{0}</span></div>' -f $chunkLink) }
    $rawImageMarkup = if ([string]::IsNullOrWhiteSpace($rawImageLink)) { '' } else { ('<div><strong>Image file</strong><span>{0}</span></div>' -f $rawImageLink) }
    $historyReportMarkup = if ([string]::IsNullOrWhiteSpace($historyReportHtmlLink)) { '' } else { ('<div><strong>HTML report</strong><span>{0}</span></div>' -f $historyReportHtmlLink) }
    $modeSummaryMarkup = if ([string]::IsNullOrWhiteSpace($modeSummaryLink)) { '' } else { ('<div><strong>Mode summary</strong><span>{0}</span></div>' -f $modeSummaryLink) }

    $cards.Add(@"
    <article class="preview-card">
      <div class="preview-card-title">$((ConvertTo-HtmlText -Value ([string]$preview.mode))) | $((ConvertTo-HtmlText -Value ([string]$preview.category)))</div>
      <div class="preview-card-meta">
        <div><strong>Chunk</strong><span>$((ConvertTo-HtmlText -Value ([string]$preview.chunkId)))</span></div>
        <div><strong>MIME type</strong><span>$((ConvertTo-HtmlText -Value ([string]$preview.mimeType)))</span></div>
        <div><strong>Byte length</strong><span>$([int]$preview.byteLength)</span></div>
$comparisonPairMarkup
$chunkDetailMarkup
$rawImageMarkup
$historyReportMarkup
$modeSummaryMarkup
      </div>
      <img src="$([string]$preview.relativePath)" alt="$((ConvertTo-HtmlText -Value ('{0} | {1}' -f [string]$preview.mode, [string]$preview.category)))" loading="lazy" />
    </article>
"@) | Out-Null
  }

  return @"
  <h2>Preview gallery</h2>
  <div class="preview-summary">
    <strong>Preview images available</strong><span>$([int]$RunStats.previewImageCount)</span>
    <strong>Gallery cap</strong><span>$([int]$RunStats.previewGalleryCap)</span>
    <strong>Gallery shown</strong><span>$([int]$RunStats.previewGalleryCount)</span>
    <strong>Gallery omitted</strong><span>$([int]$RunStats.previewGalleryOmittedCount)</span>
  </div>
  <div class="preview-grid">
$($cards -join [Environment]::NewLine)
  </div>
"@
}

function ConvertTo-AnchorSlug {
  param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$Value
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return 'item'
  }

  $slug = [regex]::Replace($Value.ToLowerInvariant(), '[^a-z0-9]+', '-').Trim('-')
  if ([string]::IsNullOrWhiteSpace($slug)) {
    return 'item'
  }

  return $slug
}

function Get-ChunkAnchorId {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ChunkId
  )

  return ('chunk-{0}' -f (ConvertTo-AnchorSlug -Value $ChunkId))
}

function Get-SegmentAnchorId {
  param(
    [Parameter(Mandatory = $true)]
    [int]$SegmentOrdinal
  )

  return ('segment-{0}' -f $SegmentOrdinal)
}

function ConvertTo-ComparisonPairKey {
  param(
    [AllowNull()]
    $Pair
  )

  if ($null -eq $Pair) {
    return ''
  }

  return ('{0}|{1}' -f [string](Get-OptionalPropertyValue -InputObject $Pair -PropertyName 'firstPath' -Default ''), [string](Get-OptionalPropertyValue -InputObject $Pair -PropertyName 'secondPath' -Default ''))
}

function Add-UniqueLinkEntry {
  param(
    [Parameter(Mandatory = $true)]
    [hashtable]$Target,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$Href,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$Label
  )

  if ([string]::IsNullOrWhiteSpace($Href)) {
    return
  }

  $resolvedLabel = if ([string]::IsNullOrWhiteSpace($Label)) { $Href } else { $Label }
  $key = ('{0}|{1}' -f $resolvedLabel, $Href).ToLowerInvariant()
  if ($Target.ContainsKey($key)) {
    return
  }

  $Target[$key] = [ordered]@{
    label = $resolvedLabel
    href = $Href
  }
}

function Format-MarkdownLinkList {
  param(
    [AllowNull()]
    $Links,
    [Parameter(Mandatory = $false)]
    [string]$EmptyText = 'none'
  )

  $linkTexts = @(
    ConvertTo-ObjectArray -InputObject $Links |
      ForEach-Object {
        $text = Format-MarkdownLink -Label ([string](Get-OptionalPropertyValue -InputObject $_ -PropertyName 'label' -Default '')) -Href ([string](Get-OptionalPropertyValue -InputObject $_ -PropertyName 'href' -Default ''))
        if (-not [string]::IsNullOrWhiteSpace($text)) { $text }
      }
  )
  if ($linkTexts.Count -eq 0) {
    return $EmptyText
  }

  return ($linkTexts -join ', ')
}

function Format-HtmlLinkList {
  param(
    [AllowNull()]
    $Links,
    [Parameter(Mandatory = $false)]
    [string]$EmptyText = 'none'
  )

  $linkTexts = @(
    ConvertTo-ObjectArray -InputObject $Links |
      ForEach-Object {
        $text = Format-HtmlLink -Label ([string](Get-OptionalPropertyValue -InputObject $_ -PropertyName 'label' -Default '')) -Href ([string](Get-OptionalPropertyValue -InputObject $_ -PropertyName 'href' -Default ''))
        if (-not [string]::IsNullOrWhiteSpace($text)) { $text }
      }
  )
  if ($linkTexts.Count -eq 0) {
    return $EmptyText
  }

  return ($linkTexts -join ', ')
}

function Get-EvidenceGraphChunkById {
  param(
    [Parameter(Mandatory = $true)]
    $EvidenceGraph,
    [Parameter(Mandatory = $true)]
    [string]$ChunkId
  )

  foreach ($chunk in @(ConvertTo-ObjectArray -InputObject (Get-OptionalPropertyValue -InputObject (Get-OptionalPropertyValue -InputObject $EvidenceGraph -PropertyName 'execution') -PropertyName 'chunks' -Default @()))) {
    if ([string]$chunk.chunkId -eq $ChunkId) {
      return $chunk
    }
  }

  return $null
}

function Get-EvidenceGraphSurfaceReference {
  param(
    [Parameter(Mandatory = $true)]
    $EvidenceGraph,
    [Parameter(Mandatory = $true)]
    [string]$Scope,
    [Parameter(Mandatory = $true)]
    [string]$Kind,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$ChunkId
  )

  $surfacesNode = Get-OptionalPropertyValue -InputObject $EvidenceGraph -PropertyName 'surfaces'
  $surfaceArrays = @(
    ConvertTo-ObjectArray -InputObject (Get-OptionalPropertyValue -InputObject $surfacesNode -PropertyName 'renderSurfaces' -Default @())
    ConvertTo-ObjectArray -InputObject (Get-OptionalPropertyValue -InputObject $surfacesNode -PropertyName 'artifactSurfaces' -Default @())
  )
  foreach ($surface in $surfaceArrays) {
    if ([string](Get-OptionalPropertyValue -InputObject $surface -PropertyName 'scope' -Default '') -ne $Scope) {
      continue
    }
    if ([string](Get-OptionalPropertyValue -InputObject $surface -PropertyName 'kind' -Default '') -ne $Kind) {
      continue
    }
    $surfaceChunkId = [string](Get-OptionalPropertyValue -InputObject $surface -PropertyName 'chunkId' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($ChunkId) -and $surfaceChunkId -ne $ChunkId) {
      continue
    }
    return $surface
  }

  return $null
}

function New-ModeNavigationArray {
  param(
    [Parameter(Mandatory = $true)]
    $EvidenceGraph
  )

  $modeMap = @{}
  foreach ($chunk in @(ConvertTo-ObjectArray -InputObject (Get-OptionalPropertyValue -InputObject (Get-OptionalPropertyValue -InputObject $EvidenceGraph -PropertyName 'execution') -PropertyName 'chunks' -Default @()) | Sort-Object { [int]$_.chunkOrdinal }, { [string]$_.chunkId })) {
    $summaryNode = Get-OptionalPropertyValue -InputObject $chunk -PropertyName 'summary'
    $chunkOutputs = Get-OptionalPropertyValue -InputObject $chunk -PropertyName 'outputs'
    $chunkSurfaces = Get-OptionalPropertyValue -InputObject $chunk -PropertyName 'surfaces'
    $modes = @(
      ConvertTo-ObjectArray -InputObject (Get-OptionalPropertyValue -InputObject $summaryNode -PropertyName 'executedModes' -Default @()) |
        ForEach-Object { [string]$_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($modes.Count -eq 0) {
      $modes = @(
        ConvertTo-ObjectArray -InputObject (Get-OptionalPropertyValue -InputObject $summaryNode -PropertyName 'requestedModes' -Default @()) |
          ForEach-Object { [string]$_ } |
          Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
      )
    }

    foreach ($mode in @($modes | Sort-Object -Unique)) {
      if (-not $modeMap.ContainsKey($mode)) {
        $modeMap[$mode] = [ordered]@{
          mode = $mode
          chunkIds = @{}
          previewCount = 0
          modeSummaryLinks = @{}
          historyReportHtmlLinks = @{}
        }
      }

      $entry = $modeMap[$mode]
      $entry.chunkIds[[string]$chunk.chunkId] = $true
      $entry.previewCount += @(
        ConvertTo-ObjectArray -InputObject (Get-OptionalPropertyValue -InputObject $chunkSurfaces -PropertyName 'previewImages' -Default @()) |
          Where-Object { [string](Get-OptionalPropertyValue -InputObject $_ -PropertyName 'mode' -Default '') -eq $mode }
      ).Count
      Add-UniqueLinkEntry -Target $entry.modeSummaryLinks -Href ([string](Get-OptionalPropertyValue -InputObject $chunkOutputs -PropertyName 'modeSummaryPath' -Default '')) -Label ('{0} mode-summary.md' -f [string]$chunk.chunkId)
      Add-UniqueLinkEntry -Target $entry.historyReportHtmlLinks -Href ([string](Get-OptionalPropertyValue -InputObject $chunkOutputs -PropertyName 'historyReportHtml' -Default '')) -Label ('{0} history-report.html' -f [string]$chunk.chunkId)
    }
  }

  return @(
    $modeMap.GetEnumerator() |
      Sort-Object Name |
      ForEach-Object {
        [ordered]@{
          mode = [string]$_.Value.mode
          chunkIds = @($_.Value.chunkIds.Keys | Sort-Object)
          previewCount = [int]$_.Value.previewCount
          modeSummaryLinks = @($_.Value.modeSummaryLinks.Values | Sort-Object { [string]$_.label }, { [string]$_.href })
          historyReportHtmlLinks = @($_.Value.historyReportHtmlLinks.Values | Sort-Object { [string]$_.label }, { [string]$_.href })
        }
      }
  )
}

function New-ComparisonPairNavigationArray {
  param(
    [Parameter(Mandatory = $true)]
    $EvidenceGraph
  )

  $pairMap = @{}
  foreach ($chunk in @(ConvertTo-ObjectArray -InputObject (Get-OptionalPropertyValue -InputObject (Get-OptionalPropertyValue -InputObject $EvidenceGraph -PropertyName 'execution') -PropertyName 'chunks' -Default @()) | Sort-Object { [int]$_.chunkOrdinal }, { [string]$_.chunkId })) {
    $chunkOutputs = Get-OptionalPropertyValue -InputObject $chunk -PropertyName 'outputs'
    $chunkSurfaces = Get-OptionalPropertyValue -InputObject $chunk -PropertyName 'surfaces'
    $previewImages = @(ConvertTo-ObjectArray -InputObject (Get-OptionalPropertyValue -InputObject $chunkSurfaces -PropertyName 'previewImages' -Default @()))
    foreach ($pair in @(ConvertTo-ObjectArray -InputObject (Get-OptionalPropertyValue -InputObject $chunkSurfaces -PropertyName 'comparisonPairs' -Default @()))) {
      $key = ConvertTo-ComparisonPairKey -Pair $pair
      if ([string]::IsNullOrWhiteSpace($key)) {
        continue
      }

      if (-not $pairMap.ContainsKey($key)) {
        $pairMap[$key] = [ordered]@{
          pair = [ordered]@{
            firstPath = [string](Get-OptionalPropertyValue -InputObject $pair -PropertyName 'firstPath' -Default '')
            secondPath = [string](Get-OptionalPropertyValue -InputObject $pair -PropertyName 'secondPath' -Default '')
          }
          count = 0
          previewCount = 0
          chunkIds = @{}
          historyReportHtmlLinks = @{}
        }
      }

      $entry = $pairMap[$key]
      $entry.count += [int](Get-OptionalPropertyValue -InputObject $pair -PropertyName 'count' -Default 0)
      $entry.chunkIds[[string]$chunk.chunkId] = $true
      $entry.previewCount += @(
        $previewImages |
          Where-Object { (ConvertTo-ComparisonPairKey -Pair (Get-OptionalPropertyValue -InputObject $_ -PropertyName 'comparisonPair')) -eq $key }
      ).Count
      Add-UniqueLinkEntry -Target $entry.historyReportHtmlLinks -Href ([string](Get-OptionalPropertyValue -InputObject $chunkOutputs -PropertyName 'historyReportHtml' -Default '')) -Label ('{0} history-report.html' -f [string]$chunk.chunkId)
    }
  }

  return @(
    $pairMap.GetEnumerator() |
      Sort-Object Name |
      ForEach-Object {
        [ordered]@{
          pair = $_.Value.pair
          count = [int]$_.Value.count
          previewCount = [int]$_.Value.previewCount
          chunkIds = @($_.Value.chunkIds.Keys | Sort-Object)
          historyReportHtmlLinks = @($_.Value.historyReportHtmlLinks.Values | Sort-Object { [string]$_.label }, { [string]$_.href })
        }
      }
  )
}

function New-MarkdownPrimaryReviewSurfaces {
  param(
    [Parameter(Mandatory = $true)]
    $EvidenceGraph,
    [Parameter(Mandatory = $true)]
    [string]$ExplorationRunPath,
    [Parameter(Mandatory = $true)]
    [string]$EvidenceGraphPath,
    [Parameter(Mandatory = $true)]
    [string]$ResultsRoot
  )

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('## Primary review surfaces') | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add(('- Exploration run: {0}' -f (Format-MarkdownLink -Label 'exploration-run.json' -Href (ConvertTo-ArtifactReference -Path $ExplorationRunPath -ResultsRoot $ResultsRoot)))) | Out-Null
  $lines.Add(('- Canonical evidence graph: {0}' -f (Format-MarkdownLink -Label 'evidence-graph.json' -Href (ConvertTo-ArtifactReference -Path $EvidenceGraphPath -ResultsRoot $ResultsRoot)))) | Out-Null
  foreach ($surfaceSpec in @(
      @{ Scope = 'run'; Kind = 'revision-catalog-json'; Label = 'revision-catalog.json' },
      @{ Scope = 'run'; Kind = 'chunk-plan-json'; Label = 'chunk-plan.json' },
      @{ Scope = 'run'; Kind = 'timeline-markdown'; Label = 'timeline.md' },
      @{ Scope = 'run'; Kind = 'timeline-html'; Label = 'timeline.html' },
      @{ Scope = 'run'; Kind = 'bundle-zip'; Label = 'manual-vi-exploration-bundle.zip' }
    )) {
    $surface = Get-EvidenceGraphSurfaceReference -EvidenceGraph $EvidenceGraph -Scope ([string]$surfaceSpec.Scope) -Kind ([string]$surfaceSpec.Kind)
    $href = [string](Get-OptionalPropertyValue -InputObject $surface -PropertyName 'relativePath' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($href)) {
      $lines.Add(('- {0}: {1}' -f [string]$surfaceSpec.Label, (Format-MarkdownLink -Label ([string]$surfaceSpec.Label) -Href $href))) | Out-Null
    }
  }
  $lines.Add('') | Out-Null

  return ($lines -join [Environment]::NewLine)
}

function New-MarkdownReviewNavigation {
  param(
    [Parameter(Mandatory = $true)]
    $EvidenceGraph
  )

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('## Review navigation') | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add('### Segment navigation') | Out-Null
  $lines.Add('') | Out-Null
  foreach ($segment in @(ConvertTo-ObjectArray -InputObject (Get-OptionalPropertyValue -InputObject (Get-OptionalPropertyValue -InputObject $EvidenceGraph -PropertyName 'continuity') -PropertyName 'segments' -Default @()) | Sort-Object { [int]$_.segmentOrdinal })) {
    $chunkLinks = @(
      ConvertTo-ObjectArray -InputObject (Get-OptionalPropertyValue -InputObject $segment -PropertyName 'chunkIds' -Default @()) |
        ForEach-Object {
          $chunkId = [string]$_
          if (-not [string]::IsNullOrWhiteSpace($chunkId)) {
            [ordered]@{
              label = $chunkId
              href = ('#{0}' -f (Get-ChunkAnchorId -ChunkId $chunkId))
            }
          }
        }
    )
    $continuityNote = if ($null -ne (Get-OptionalPropertyValue -InputObject $segment -PropertyName 'continuityBreakAfterRevisionOrdinal')) {
      ('; break after revision `{0}` ({1})' -f [int]$segment.continuityBreakAfterRevisionOrdinal, [string]$segment.continuityBreakReason)
    } else {
      ''
    }
    $detailLink = Format-MarkdownLink -Label 'details' -Href ('#{0}' -f (Get-SegmentAnchorId -SegmentOrdinal ([int]$segment.segmentOrdinal)))
    $lines.Add(('- Segment `{0}`: {1}; revisions `{2}` -> `{3}`; chunks {4}{5}' -f [int]$segment.segmentOrdinal, $detailLink, [int]$segment.startRevisionOrdinal, [int]$segment.endRevisionOrdinal, (Format-MarkdownLinkList -Links $chunkLinks), $continuityNote)) | Out-Null
  }
  $lines.Add('') | Out-Null
  $lines.Add('### Mode navigation') | Out-Null
  $lines.Add('') | Out-Null
  foreach ($entry in @(New-ModeNavigationArray -EvidenceGraph $EvidenceGraph)) {
    $chunkLinks = @(
      @($entry.chunkIds) |
        ForEach-Object {
          [ordered]@{
            label = [string]$_
            href = ('#{0}' -f (Get-ChunkAnchorId -ChunkId ([string]$_)))
          }
        }
    )
    $lines.Add(('- Mode `{0}`: chunks {1}; preview images `{2}`; mode summaries {3}; HTML reports {4}' -f [string]$entry.mode, (Format-MarkdownLinkList -Links $chunkLinks), [int]$entry.previewCount, (Format-MarkdownLinkList -Links $entry.modeSummaryLinks), (Format-MarkdownLinkList -Links $entry.historyReportHtmlLinks))) | Out-Null
  }
  $lines.Add('') | Out-Null
  $lines.Add('### Comparison pair navigation') | Out-Null
  $lines.Add('') | Out-Null
  foreach ($entry in @(New-ComparisonPairNavigationArray -EvidenceGraph $EvidenceGraph)) {
    $chunkLinks = @(
      @($entry.chunkIds) |
        ForEach-Object {
          [ordered]@{
            label = [string]$_
            href = ('#{0}' -f (Get-ChunkAnchorId -ChunkId ([string]$_)))
          }
        }
    )
    $lines.Add(('- Pair `{0}`: count `{1}`; chunks {2}; preview images `{3}`; HTML reports {4}' -f (Format-PreviewComparisonPairText -Pair $entry.pair), [int]$entry.count, (Format-MarkdownLinkList -Links $chunkLinks), [int]$entry.previewCount, (Format-MarkdownLinkList -Links $entry.historyReportHtmlLinks))) | Out-Null
  }
  $lines.Add('') | Out-Null

  return ($lines -join [Environment]::NewLine)
}

function New-HtmlPrimaryReviewSurfaces {
  param(
    [Parameter(Mandatory = $true)]
    $EvidenceGraph,
    [Parameter(Mandatory = $true)]
    [string]$ExplorationRunPath,
    [Parameter(Mandatory = $true)]
    [string]$EvidenceGraphPath,
    [Parameter(Mandatory = $true)]
    [string]$ResultsRoot
  )

  $items = New-Object System.Collections.Generic.List[string]
  $items.Add(('<li>{0}</li>' -f (Format-HtmlLink -Label 'exploration-run.json' -Href (ConvertTo-ArtifactReference -Path $ExplorationRunPath -ResultsRoot $ResultsRoot)))) | Out-Null
  $items.Add(('<li>{0}</li>' -f (Format-HtmlLink -Label 'evidence-graph.json' -Href (ConvertTo-ArtifactReference -Path $EvidenceGraphPath -ResultsRoot $ResultsRoot)))) | Out-Null
  foreach ($surfaceSpec in @(
      @{ Scope = 'run'; Kind = 'revision-catalog-json'; Label = 'revision-catalog.json' },
      @{ Scope = 'run'; Kind = 'chunk-plan-json'; Label = 'chunk-plan.json' },
      @{ Scope = 'run'; Kind = 'timeline-markdown'; Label = 'timeline.md' },
      @{ Scope = 'run'; Kind = 'timeline-html'; Label = 'timeline.html' },
      @{ Scope = 'run'; Kind = 'bundle-zip'; Label = 'manual-vi-exploration-bundle.zip' }
    )) {
    $surface = Get-EvidenceGraphSurfaceReference -EvidenceGraph $EvidenceGraph -Scope ([string]$surfaceSpec.Scope) -Kind ([string]$surfaceSpec.Kind)
    $href = [string](Get-OptionalPropertyValue -InputObject $surface -PropertyName 'relativePath' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($href)) {
      $items.Add(('<li>{0}</li>' -f (Format-HtmlLink -Label ([string]$surfaceSpec.Label) -Href $href))) | Out-Null
    }
  }

  return @"
  <h2>Primary review surfaces</h2>
  <ul>
$($items -join [Environment]::NewLine)
  </ul>
"@
}

function New-HtmlReviewNavigation {
  param(
    [Parameter(Mandatory = $true)]
    $EvidenceGraph
  )

  $segmentRows = New-Object System.Collections.Generic.List[string]
  foreach ($segment in @(ConvertTo-ObjectArray -InputObject (Get-OptionalPropertyValue -InputObject (Get-OptionalPropertyValue -InputObject $EvidenceGraph -PropertyName 'continuity') -PropertyName 'segments' -Default @()) | Sort-Object { [int]$_.segmentOrdinal })) {
    $chunkLinks = @(
      ConvertTo-ObjectArray -InputObject (Get-OptionalPropertyValue -InputObject $segment -PropertyName 'chunkIds' -Default @()) |
        ForEach-Object {
          $chunkId = [string]$_
          if (-not [string]::IsNullOrWhiteSpace($chunkId)) {
            [ordered]@{
              label = $chunkId
              href = ('#{0}' -f (Get-ChunkAnchorId -ChunkId $chunkId))
            }
          }
        }
    )
    $breakCell = if ($null -ne (Get-OptionalPropertyValue -InputObject $segment -PropertyName 'continuityBreakAfterRevisionOrdinal')) {
      ('{0} ({1})' -f [int]$segment.continuityBreakAfterRevisionOrdinal, [string]$segment.continuityBreakReason)
    } else {
      'none'
    }
    $segmentRows.Add(@"
    <tr id="$((Get-SegmentAnchorId -SegmentOrdinal ([int]$segment.segmentOrdinal)))">
      <td>$([int]$segment.segmentOrdinal)</td>
      <td>$([int]$segment.startRevisionOrdinal)-$([int]$segment.endRevisionOrdinal)</td>
      <td>$([int]$segment.pairCount)</td>
      <td>$(Format-HtmlLink -Label 'details' -Href ('#' + (Get-SegmentAnchorId -SegmentOrdinal ([int]$segment.segmentOrdinal))))</td>
      <td>$(Format-HtmlLinkList -Links $chunkLinks)</td>
      <td>$((ConvertTo-HtmlText -Value ([string]$segment.continuityStartReason)))</td>
      <td>$((ConvertTo-HtmlText -Value $breakCell))</td>
    </tr>
"@) | Out-Null
  }

  $modeRows = New-Object System.Collections.Generic.List[string]
  foreach ($entry in @(New-ModeNavigationArray -EvidenceGraph $EvidenceGraph)) {
    $chunkLinks = @(
      @($entry.chunkIds) |
        ForEach-Object {
          [ordered]@{
            label = [string]$_
            href = ('#{0}' -f (Get-ChunkAnchorId -ChunkId ([string]$_)))
          }
        }
    )
    $modeRows.Add(@"
    <tr>
      <td>$((ConvertTo-HtmlText -Value ([string]$entry.mode)))</td>
      <td>$(Format-HtmlLinkList -Links $chunkLinks)</td>
      <td>$([int]$entry.previewCount)</td>
      <td>$(Format-HtmlLinkList -Links $entry.modeSummaryLinks)</td>
      <td>$(Format-HtmlLinkList -Links $entry.historyReportHtmlLinks)</td>
    </tr>
"@) | Out-Null
  }

  $pairRows = New-Object System.Collections.Generic.List[string]
  foreach ($entry in @(New-ComparisonPairNavigationArray -EvidenceGraph $EvidenceGraph)) {
    $chunkLinks = @(
      @($entry.chunkIds) |
        ForEach-Object {
          [ordered]@{
            label = [string]$_
            href = ('#{0}' -f (Get-ChunkAnchorId -ChunkId ([string]$_)))
          }
        }
    )
    $pairRows.Add(@"
    <tr>
      <td>$((ConvertTo-HtmlText -Value (Format-PreviewComparisonPairText -Pair $entry.pair)))</td>
      <td>$([int]$entry.count)</td>
      <td>$(Format-HtmlLinkList -Links $chunkLinks)</td>
      <td>$([int]$entry.previewCount)</td>
      <td>$(Format-HtmlLinkList -Links $entry.historyReportHtmlLinks)</td>
    </tr>
"@) | Out-Null
  }

  return @"
  <h2>Review navigation</h2>
  <h3>Segment navigation</h3>
  <table>
    <thead>
      <tr>
        <th>Segment</th>
        <th>Revision ordinals</th>
        <th>Pairs</th>
        <th>Details</th>
        <th>Chunks</th>
        <th>Start reason</th>
        <th>Break</th>
      </tr>
    </thead>
    <tbody>
$($segmentRows -join [Environment]::NewLine)
    </tbody>
  </table>
  <h3>Mode navigation</h3>
  <table>
    <thead>
      <tr>
        <th>Mode</th>
        <th>Chunks</th>
        <th>Preview images</th>
        <th>Mode summaries</th>
        <th>HTML reports</th>
      </tr>
    </thead>
    <tbody>
$($modeRows -join [Environment]::NewLine)
    </tbody>
  </table>
  <h3>Comparison pair navigation</h3>
  <table>
    <thead>
      <tr>
        <th>Comparison pair</th>
        <th>Count</th>
        <th>Chunks</th>
        <th>Preview images</th>
        <th>HTML reports</th>
      </tr>
    </thead>
    <tbody>
$($pairRows -join [Environment]::NewLine)
    </tbody>
  </table>
"@
}

function New-StepSummaryPreviewSection {
  param(
    [Parameter(Mandatory = $true)]
    $RunStats,
    [Parameter(Mandatory = $true)]
    $PreviewSelection
  )

  $lines = New-Object System.Collections.Generic.List[string]
  if ([int]$RunStats.previewImageCount -le 0) {
    return @()
  }

  $selectedImages = @(ConvertTo-ObjectArray -InputObject $PreviewSelection.images)
  $lines.Add(('- Preview images: `{0}`' -f [int]$RunStats.previewImageCount)) | Out-Null
  $lines.Add(('- Preview gallery: `{0}` shown, `{1}` omitted, cap `{2}`' -f [int]$RunStats.previewGalleryCount, [int]$RunStats.previewGalleryOmittedCount, [int]$RunStats.previewGalleryCap)) | Out-Null
  $lines.Add(('- Step summary previews: `{0}` shown, `{1}` omitted, cap `{2}`, byte-budget `{3}`' -f [int]$RunStats.stepSummaryPreviewCount, [int]$RunStats.stepSummaryPreviewOmittedCount, [int]$RunStats.stepSummaryPreviewCap, [int]$RunStats.stepSummaryPreviewByteBudget)) | Out-Null

  if ($selectedImages.Count -gt 0) {
    $lines.Add('') | Out-Null
    $lines.Add('### Preview gallery') | Out-Null
    foreach ($preview in $selectedImages) {
      $comparisonPairLine = if ($null -eq $preview.comparisonPair) {
        ''
      } else {
        ('<br/><strong>Comparison pair:</strong> <code>{0}</code>' -f (ConvertTo-HtmlText -Value (Format-PreviewComparisonPairText -Pair $preview.comparisonPair)))
      }
      $lines.Add((
          '<p><strong>{0} | {1}</strong><br/><strong>Chunk:</strong> <code>{2}</code><br/><strong>MIME type:</strong> <code>{3}</code><br/><strong>Byte length:</strong> <code>{4}</code>{5}<br/><img src="{6}" alt="{7}" style="max-width: 420px; height: auto; border: 1px solid #d0d7de; background: #ffffff;" /></p>' -f
          (ConvertTo-HtmlText -Value ([string]$preview.mode)),
          (ConvertTo-HtmlText -Value ([string]$preview.category)),
          (ConvertTo-HtmlText -Value ([string]$preview.chunkId)),
          (ConvertTo-HtmlText -Value ([string]$preview.mimeType)),
          [int]$preview.byteLength,
          $comparisonPairLine,
          [string]$preview.dataUri,
          (ConvertTo-HtmlText -Value ('{0} | {1}' -f [string]$preview.mode, [string]$preview.category))
        )) | Out-Null
    }
  }

  return @($lines | ForEach-Object { $_ })
}

function New-ExplorationSurfaceAggregate {
  param(
    [Parameter(Mandatory = $true)]
    $ChunkReceipts,
    [Parameter(Mandatory = $true)]
    [string]$ResultsRoot
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
  $aggregatePreviewImages = @{}

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

    foreach ($previewImage in @(ConvertTo-ObjectArray -InputObject (Get-OptionalPropertyValue -InputObject $surfaceNode -PropertyName 'previewImages' -Default @()))) {
      Add-PreviewImageAggregate -Target $aggregatePreviewImages -ChunkId ([string]$chunk.chunkId) -PreviewImage $previewImage -ResultsRoot $ResultsRoot
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
    previewImages = @(ConvertTo-PreviewImageArray -Value $aggregatePreviewImages.Values)
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
    [string]$NoisePolicy,
    [Parameter(Mandatory = $true)]
    [int]$PreviewGalleryCount,
    [Parameter(Mandatory = $true)]
    [int]$StepSummaryPreviewCount
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
  $previewImageCount = @(ConvertTo-PreviewImageArray -Value $SurfaceAggregate.previewImages).Count

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
    previewImageCount         = $previewImageCount
    previewGalleryCap         = $script:PreviewGalleryCap
    previewGalleryCount       = $PreviewGalleryCount
    previewGalleryOmittedCount = [Math]::Max($previewImageCount - $PreviewGalleryCount, 0)
    stepSummaryPreviewCap     = $script:StepSummaryPreviewCap
    stepSummaryPreviewCount   = $StepSummaryPreviewCount
    stepSummaryPreviewOmittedCount = [Math]::Max($previewImageCount - $StepSummaryPreviewCount, 0)
    stepSummaryPreviewByteBudget = $script:StepSummaryPreviewByteBudget
  }
}

function New-ContinuitySegmentArray {
  param(
    [Parameter(Mandatory = $true)]
    $Catalog,
    [Parameter(Mandatory = $true)]
    $ChunkPlan,
    [Parameter(Mandatory = $true)]
    $ChunkReceipts
  )

  $revisionByOrdinal = @{}
  foreach ($revision in @(ConvertTo-ObjectArray -InputObject $Catalog.revisions)) {
    $revisionByOrdinal[[int]$revision.ordinal] = $revision
  }

  $chunkReceiptArray = @(
    ConvertTo-ObjectArray -InputObject $ChunkReceipts |
      Sort-Object { [int]$_.chunkOrdinal }, { [string]$_.chunkId }
  )

  return @(
    ConvertTo-ObjectArray -InputObject $ChunkPlan.segments |
      Sort-Object { [int]$_.segmentOrdinal } |
      ForEach-Object {
        $segment = $_
        $segmentOrdinal = [int]$segment.segmentOrdinal
        $startRevisionOrdinal = [int]$segment.startRevisionOrdinal
        $endRevisionOrdinal = [int]$segment.endRevisionOrdinal
        $segmentRevisions = New-Object System.Collections.Generic.List[object]
        if ($startRevisionOrdinal -le $endRevisionOrdinal) {
          foreach ($ordinal in $startRevisionOrdinal..$endRevisionOrdinal) {
            if (-not $revisionByOrdinal.ContainsKey([int]$ordinal)) {
              continue
            }

            $revision = $revisionByOrdinal[[int]$ordinal]
            $segmentRevisions.Add([ordered]@{
                ordinal = [int]$revision.ordinal
                commit = [string]$revision.commit
                committedAtUtc = [string]$revision.committedAtUtc
                subject = [string]$revision.subject
                changeKind = [string]$revision.changeKind
                statusToken = [string]$revision.statusToken
                path = [string]$revision.path
                previousPath = Get-OptionalPropertyValue -InputObject $revision -PropertyName 'previousPath'
              }) | Out-Null
          }
        }

        $chunkIds = @(
          $chunkReceiptArray |
            Where-Object { [int]$_.segmentOrdinal -eq $segmentOrdinal } |
            ForEach-Object { [string]$_.chunkId }
        )

        [ordered]@{
          segmentOrdinal = $segmentOrdinal
          startRevisionOrdinal = $startRevisionOrdinal
          endRevisionOrdinal = $endRevisionOrdinal
          revisionCount = [int]$segment.revisionCount
          pairCount = [int]$segment.pairCount
          continuityStartReason = [string]$segment.continuityStartReason
          continuityBreakAfterRevisionOrdinal = if ($null -eq $segment.continuityBreakAfterRevisionOrdinal) { $null } else { [int]$segment.continuityBreakAfterRevisionOrdinal }
          continuityBreakReason = if ([string]::IsNullOrWhiteSpace([string]$segment.continuityBreakReason)) { $null } else { [string]$segment.continuityBreakReason }
          chunkIds = @($chunkIds)
          revisions = @($segmentRevisions | ForEach-Object { $_ })
        }
      }
  )
}

function New-ContinuityBreakArray {
  param(
    [Parameter(Mandatory = $true)]
    $Segments
  )

  $segmentArray = @(ConvertTo-ObjectArray -InputObject $Segments)
  $breaks = New-Object System.Collections.Generic.List[object]
  for ($index = 0; $index -lt $segmentArray.Count; $index++) {
    $segment = $segmentArray[$index]
    $afterRevisionOrdinal = Get-OptionalPropertyValue -InputObject $segment -PropertyName 'continuityBreakAfterRevisionOrdinal'
    if ($null -eq $afterRevisionOrdinal) {
      continue
    }

    $resumeSegment = if (($index + 1) -lt $segmentArray.Count) { $segmentArray[$index + 1] } else { $null }
    $afterRevision = $null
    foreach ($revision in @(ConvertTo-ObjectArray -InputObject (Get-OptionalPropertyValue -InputObject $segment -PropertyName 'revisions' -Default @()))) {
      if ([int](Get-OptionalPropertyValue -InputObject $revision -PropertyName 'ordinal' -Default -1) -eq [int]$afterRevisionOrdinal) {
        $afterRevision = $revision
        break
      }
    }

    $breaks.Add([ordered]@{
        segmentOrdinal = [int]$segment.segmentOrdinal
        afterRevisionOrdinal = [int]$afterRevisionOrdinal
        afterCommit = if ($null -eq $afterRevision) { $null } else { [string]$afterRevision.commit }
        afterPath = if ($null -eq $afterRevision) { $null } else { [string]$afterRevision.path }
        reason = [string](Get-OptionalPropertyValue -InputObject $segment -PropertyName 'continuityBreakReason' -Default '')
        nextSegmentOrdinal = if ($null -eq $resumeSegment) { $null } else { [int]$resumeSegment.segmentOrdinal }
        nextStartReason = if ($null -eq $resumeSegment) { $null } else { [string]$resumeSegment.continuityStartReason }
      }) | Out-Null
  }

  return @($breaks | ForEach-Object { $_ })
}

function New-ChunkEvidenceArray {
  param(
    [Parameter(Mandatory = $true)]
    $ChunkReceipts,
    [Parameter(Mandatory = $true)]
    [string]$ResultsRoot
  )

  return @(
    ConvertTo-ObjectArray -InputObject $ChunkReceipts |
      Sort-Object { [int]$_.chunkOrdinal }, { [string]$_.chunkId } |
      ForEach-Object {
        $chunk = $_
        $outputsNode = Get-OptionalPropertyValue -InputObject $chunk -PropertyName 'outputs'
        $summaryNode = Get-OptionalPropertyValue -InputObject $chunk -PropertyName 'summary'
        $executionNode = Get-OptionalPropertyValue -InputObject $chunk -PropertyName 'execution'
        $replayNode = Get-OptionalPropertyValue -InputObject $chunk -PropertyName 'replay'
        $failureNode = Get-OptionalPropertyValue -InputObject $chunk -PropertyName 'failure'
        $surfaceNode = Get-OptionalPropertyValue -InputObject $chunk -PropertyName 'surfaces'
        $metadataNode = Get-SurfaceMetadataNode -SurfaceNode $surfaceNode
        $normalizedSurface = ConvertTo-NormalizedCategorySurface `
          -CategoryCounts (Get-OptionalPropertyValue -InputObject $surfaceNode -PropertyName 'categoryCounts') `
          -ComparisonPairs (Get-OptionalPropertyValue -InputObject $surfaceNode -PropertyName 'comparisonPairs')
        $chunkPreviewImageMap = @{}
        foreach ($previewImage in @(ConvertTo-ObjectArray -InputObject (Get-OptionalPropertyValue -InputObject $surfaceNode -PropertyName 'previewImages' -Default @()))) {
          Add-PreviewImageAggregate `
            -Target $chunkPreviewImageMap `
            -PreviewImage $previewImage `
            -ResultsRoot $ResultsRoot `
            -ChunkId ([string]$chunk.chunkId)
        }

        [ordered]@{
          chunkId = [string]$chunk.chunkId
          chunkOrdinal = [int]$chunk.chunkOrdinal
          segmentOrdinal = [int]$chunk.segmentOrdinal
          status = [string]$chunk.status
          pairCount = [int]$chunk.pairCount
          pairOrdinalStart = [int]$chunk.pairOrdinalStart
          pairOrdinalEnd = [int]$chunk.pairOrdinalEnd
          revisionOrdinalStart = [int]$chunk.revisionOrdinalStart
          revisionOrdinalEnd = [int]$chunk.revisionOrdinalEnd
          execution = [ordered]@{
            startRef = [string](Get-OptionalPropertyValue -InputObject $executionNode -PropertyName 'startRef' -Default '')
            endRef = [string](Get-OptionalPropertyValue -InputObject $executionNode -PropertyName 'endRef' -Default '')
            maxPairs = [int](Get-OptionalPropertyValue -InputObject $executionNode -PropertyName 'maxPairs' -Default 0)
            toolingSource = Get-OptionalPropertyValue -InputObject $executionNode -PropertyName 'toolingSource'
            compareviRepository = Get-OptionalPropertyValue -InputObject $executionNode -PropertyName 'compareviRepository'
            compareviRef = Get-OptionalPropertyValue -InputObject $executionNode -PropertyName 'compareviRef'
            invokeScriptPath = Get-OptionalPropertyValue -InputObject $executionNode -PropertyName 'invokeScriptPath'
          }
          outputs = [ordered]@{
            chunkRoot = ConvertTo-ArtifactReference -Path (Get-OptionalPropertyValue -InputObject $outputsNode -PropertyName 'chunkRoot') -ResultsRoot $ResultsRoot
            receiptPath = ConvertTo-ArtifactReference -Path (Get-OptionalPropertyValue -InputObject $outputsNode -PropertyName 'receiptPath') -ResultsRoot $ResultsRoot
            manifestPath = ConvertTo-ArtifactReference -Path (Get-OptionalPropertyValue -InputObject $outputsNode -PropertyName 'manifestPath') -ResultsRoot $ResultsRoot
            runOutputPath = ConvertTo-ArtifactReference -Path (Get-OptionalPropertyValue -InputObject $outputsNode -PropertyName 'runOutputPath') -ResultsRoot $ResultsRoot -OnlyIfExists
            historyResultsDir = ConvertTo-ArtifactReference -Path (Get-OptionalPropertyValue -InputObject $outputsNode -PropertyName 'historyResultsDir') -ResultsRoot $ResultsRoot
            historyManifestPath = ConvertTo-ArtifactReference -Path (Get-OptionalPropertyValue -InputObject $outputsNode -PropertyName 'historyManifestPath') -ResultsRoot $ResultsRoot -OnlyIfExists
            historySummaryJson = ConvertTo-ArtifactReference -Path (Get-OptionalPropertyValue -InputObject $outputsNode -PropertyName 'historySummaryJson') -ResultsRoot $ResultsRoot -OnlyIfExists
            historyReportMd = ConvertTo-ArtifactReference -Path (Get-OptionalPropertyValue -InputObject $outputsNode -PropertyName 'historyReportMd') -ResultsRoot $ResultsRoot -OnlyIfExists
            historyReportHtml = ConvertTo-ArtifactReference -Path (Get-OptionalPropertyValue -InputObject $outputsNode -PropertyName 'historyReportHtml') -ResultsRoot $ResultsRoot -OnlyIfExists
            modeSummaryPath = ConvertTo-ArtifactReference -Path (Get-OptionalPropertyValue -InputObject $outputsNode -PropertyName 'modeSummaryPath') -ResultsRoot $ResultsRoot -OnlyIfExists
            modeSummaryJsonPath = ConvertTo-ArtifactReference -Path (Get-OptionalPropertyValue -InputObject $outputsNode -PropertyName 'modeSummaryJsonPath') -ResultsRoot $ResultsRoot -OnlyIfExists
          }
          summary = [ordered]@{
            requestedModes = @(ConvertTo-ObjectArray -InputObject (Get-OptionalPropertyValue -InputObject $summaryNode -PropertyName 'requestedModes' -Default @()) | ForEach-Object { [string]$_ })
            executedModes = @(ConvertTo-ObjectArray -InputObject (Get-OptionalPropertyValue -InputObject $summaryNode -PropertyName 'executedModes' -Default @()) | ForEach-Object { [string]$_ })
            modeCount = [int](Get-OptionalPropertyValue -InputObject $summaryNode -PropertyName 'modeCount' -Default 0)
            totalProcessed = [int](Get-OptionalPropertyValue -InputObject $summaryNode -PropertyName 'totalProcessed' -Default 0)
            totalDiffs = [int](Get-OptionalPropertyValue -InputObject $summaryNode -PropertyName 'totalDiffs' -Default 0)
            stopReason = Get-OptionalPropertyValue -InputObject $summaryNode -PropertyName 'stopReason'
            finalStatus = Get-OptionalPropertyValue -InputObject $summaryNode -PropertyName 'finalStatus'
            finalReason = Get-OptionalPropertyValue -InputObject $summaryNode -PropertyName 'finalReason'
          }
          failure = if ($null -eq $failureNode) {
            $null
          } else {
            [ordered]@{
              message = [string](Get-OptionalPropertyValue -InputObject $failureNode -PropertyName 'message' -Default '')
            }
          }
          replay = if ($null -eq $replayNode) {
            $null
          } else {
            [ordered]@{
              status = [string](Get-OptionalPropertyValue -InputObject $replayNode -PropertyName 'status' -Default '')
              reason = [string](Get-OptionalPropertyValue -InputObject $replayNode -PropertyName 'reason' -Default '')
            }
          }
          surfaces = [ordered]@{
            suppressionProfile = [string](Get-OptionalPropertyValue -InputObject $surfaceNode -PropertyName 'suppressionProfile' -Default 'unknown')
            comparisonArtifactCount = [int](Get-OptionalPropertyValue -InputObject $metadataNode -PropertyName 'comparisonArtifactCount' -Default 0)
            captureCount = [int](Get-OptionalPropertyValue -InputObject $metadataNode -PropertyName 'captureCount' -Default 0)
            imageArtifactCount = [int](Get-OptionalPropertyValue -InputObject $metadataNode -PropertyName 'imageArtifactCount' -Default 0)
            imageMimeTypes = @(
              ConvertTo-ObjectArray -InputObject (Get-OptionalPropertyValue -InputObject $metadataNode -PropertyName 'imageMimeTypes' -Default @()) |
                ForEach-Object { [string]$_ } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique
            )
            categoryCounts = $normalizedSurface.categoryCounts
            comparisonPairs = @($normalizedSurface.comparisonPairs)
            bucketCounts = ConvertTo-OrderedCountMap -Value (Get-OptionalPropertyValue -InputObject $surfaceNode -PropertyName 'bucketCounts')
            previewImages = @(ConvertTo-PreviewImageArray -Value $chunkPreviewImageMap.Values)
          }
        }
      }
  )
}

function Add-SurfaceReference {
  param(
    [Parameter(Mandatory = $true)]
    [System.Collections.IList]$Target,
    [Parameter(Mandatory = $true)]
    [string]$Scope,
    [Parameter(Mandatory = $true)]
    [string]$Kind,
    [Parameter(Mandatory = $true)]
    [string]$ResultsRoot,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$Path,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$ChunkId,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$ContentType = '',
    [AllowNull()]
    [AllowEmptyString()]
    [string]$PathType = ''
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return
  }

  $resolved = Resolve-AbsolutePath -Path $Path -BasePath $ResultsRoot
  if (-not (Test-Path -LiteralPath $resolved)) {
    return
  }

  $detectedPathType = if ([string]::IsNullOrWhiteSpace($PathType)) {
    if (Test-Path -LiteralPath $resolved -PathType Container) { 'directory' } else { 'file' }
  } else {
    $PathType
  }

  $Target.Add([ordered]@{
      scope = $Scope
      kind = $Kind
      chunkId = $(if ([string]::IsNullOrWhiteSpace($ChunkId)) { $null } else { $ChunkId })
      relativePath = ConvertTo-ArtifactReference -Path $resolved -ResultsRoot $ResultsRoot
      pathType = $detectedPathType
      contentType = $(if ([string]::IsNullOrWhiteSpace($ContentType)) { $null } else { $ContentType })
    }) | Out-Null
}

function New-SurfaceReferenceCollection {
  param(
    [Parameter(Mandatory = $true)]
    $ChunkReceipts,
    [Parameter(Mandatory = $true)]
    [string]$ResultsRoot,
    [Parameter(Mandatory = $true)]
    [string]$RevisionCatalogPath,
    [Parameter(Mandatory = $true)]
    [string]$ChunkPlanPath,
    [Parameter(Mandatory = $true)]
    [string]$ExplorationRunPath,
    [Parameter(Mandatory = $true)]
    [string]$IndexMdPath,
    [Parameter(Mandatory = $true)]
    [string]$IndexHtmlPath,
    [Parameter(Mandatory = $true)]
    [string]$TimelineMdPath,
    [Parameter(Mandatory = $true)]
    [string]$TimelineHtmlPath,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$BundlePath
  )

  $renderSurfaces = New-Object System.Collections.Generic.List[object]
  $artifactSurfaces = New-Object System.Collections.Generic.List[object]

  Add-SurfaceReference -Target $artifactSurfaces -Scope 'run' -Kind 'revision-catalog-json' -ResultsRoot $ResultsRoot -Path $RevisionCatalogPath -ContentType 'application/json'
  Add-SurfaceReference -Target $artifactSurfaces -Scope 'run' -Kind 'chunk-plan-json' -ResultsRoot $ResultsRoot -Path $ChunkPlanPath -ContentType 'application/json'
  Add-SurfaceReference -Target $artifactSurfaces -Scope 'run' -Kind 'exploration-run-json' -ResultsRoot $ResultsRoot -Path $ExplorationRunPath -ContentType 'application/json'
  Add-SurfaceReference -Target $renderSurfaces -Scope 'run' -Kind 'index-markdown' -ResultsRoot $ResultsRoot -Path $IndexMdPath -ContentType 'text/markdown'
  Add-SurfaceReference -Target $renderSurfaces -Scope 'run' -Kind 'index-html' -ResultsRoot $ResultsRoot -Path $IndexHtmlPath -ContentType 'text/html'
  Add-SurfaceReference -Target $renderSurfaces -Scope 'run' -Kind 'timeline-markdown' -ResultsRoot $ResultsRoot -Path $TimelineMdPath -ContentType 'text/markdown'
  Add-SurfaceReference -Target $renderSurfaces -Scope 'run' -Kind 'timeline-html' -ResultsRoot $ResultsRoot -Path $TimelineHtmlPath -ContentType 'text/html'
  Add-SurfaceReference -Target $artifactSurfaces -Scope 'run' -Kind 'bundle-zip' -ResultsRoot $ResultsRoot -Path $BundlePath -ContentType 'application/zip'

  foreach ($chunk in @(ConvertTo-ObjectArray -InputObject $ChunkReceipts | Sort-Object { [int]$_.chunkOrdinal }, { [string]$_.chunkId })) {
    $outputsNode = Get-OptionalPropertyValue -InputObject $chunk -PropertyName 'outputs'
    $chunkId = [string]$chunk.chunkId
    Add-SurfaceReference -Target $artifactSurfaces -Scope 'chunk' -Kind 'chunk-root' -ResultsRoot $ResultsRoot -Path (Get-OptionalPropertyValue -InputObject $outputsNode -PropertyName 'chunkRoot') -ChunkId $chunkId
    Add-SurfaceReference -Target $artifactSurfaces -Scope 'chunk' -Kind 'chunk-receipt-json' -ResultsRoot $ResultsRoot -Path (Get-OptionalPropertyValue -InputObject $outputsNode -PropertyName 'receiptPath') -ChunkId $chunkId -ContentType 'application/json'
    Add-SurfaceReference -Target $artifactSurfaces -Scope 'chunk' -Kind 'chunk-manifest-json' -ResultsRoot $ResultsRoot -Path (Get-OptionalPropertyValue -InputObject $outputsNode -PropertyName 'manifestPath') -ChunkId $chunkId -ContentType 'application/json'
    Add-SurfaceReference -Target $artifactSurfaces -Scope 'chunk' -Kind 'chunk-run-output' -ResultsRoot $ResultsRoot -Path (Get-OptionalPropertyValue -InputObject $outputsNode -PropertyName 'runOutputPath') -ChunkId $chunkId -ContentType 'text/plain'
    Add-SurfaceReference -Target $artifactSurfaces -Scope 'chunk' -Kind 'history-results-dir' -ResultsRoot $ResultsRoot -Path (Get-OptionalPropertyValue -InputObject $outputsNode -PropertyName 'historyResultsDir') -ChunkId $chunkId
    Add-SurfaceReference -Target $artifactSurfaces -Scope 'chunk' -Kind 'history-manifest-json' -ResultsRoot $ResultsRoot -Path (Get-OptionalPropertyValue -InputObject $outputsNode -PropertyName 'historyManifestPath') -ChunkId $chunkId -ContentType 'application/json'
    Add-SurfaceReference -Target $artifactSurfaces -Scope 'chunk' -Kind 'history-summary-json' -ResultsRoot $ResultsRoot -Path (Get-OptionalPropertyValue -InputObject $outputsNode -PropertyName 'historySummaryJson') -ChunkId $chunkId -ContentType 'application/json'
    Add-SurfaceReference -Target $renderSurfaces -Scope 'chunk' -Kind 'history-report-markdown' -ResultsRoot $ResultsRoot -Path (Get-OptionalPropertyValue -InputObject $outputsNode -PropertyName 'historyReportMd') -ChunkId $chunkId -ContentType 'text/markdown'
    Add-SurfaceReference -Target $renderSurfaces -Scope 'chunk' -Kind 'history-report-html' -ResultsRoot $ResultsRoot -Path (Get-OptionalPropertyValue -InputObject $outputsNode -PropertyName 'historyReportHtml') -ChunkId $chunkId -ContentType 'text/html'
    Add-SurfaceReference -Target $renderSurfaces -Scope 'chunk' -Kind 'mode-summary-markdown' -ResultsRoot $ResultsRoot -Path (Get-OptionalPropertyValue -InputObject $outputsNode -PropertyName 'modeSummaryPath') -ChunkId $chunkId -ContentType 'text/markdown'
    Add-SurfaceReference -Target $artifactSurfaces -Scope 'chunk' -Kind 'mode-summary-json' -ResultsRoot $ResultsRoot -Path (Get-OptionalPropertyValue -InputObject $outputsNode -PropertyName 'modeSummaryJsonPath') -ChunkId $chunkId -ContentType 'application/json'
  }

  return [pscustomobject]@{
    renderSurfaces = @(
      $renderSurfaces |
        Sort-Object { [string]$_.scope }, { [string]$_.kind }, { [string]$_.chunkId }, { [string]$_.relativePath } |
        ForEach-Object { $_ }
    )
    artifactSurfaces = @(
      $artifactSurfaces |
        Sort-Object { [string]$_.scope }, { [string]$_.kind }, { [string]$_.chunkId }, { [string]$_.relativePath } |
        ForEach-Object { $_ }
    )
  }
}

function New-EvidenceGraph {
  param(
    [Parameter(Mandatory = $true)]
    $Catalog,
    [Parameter(Mandatory = $true)]
    $ChunkPlan,
    [Parameter(Mandatory = $true)]
    $ChunkReceipts,
    [Parameter(Mandatory = $true)]
    [string]$ResultsRoot,
    [Parameter(Mandatory = $true)]
    [string[]]$RequestedModes,
    [Parameter(Mandatory = $true)]
    [string]$NoisePolicy,
    [Parameter(Mandatory = $true)]
    $SurfaceAggregate,
    [Parameter(Mandatory = $true)]
    $RunStats,
    [Parameter(Mandatory = $true)]
    [string]$RevisionCatalogPath,
    [Parameter(Mandatory = $true)]
    [string]$ChunkPlanPath,
    [Parameter(Mandatory = $true)]
    [string]$ChunkReceiptsRoot,
    [Parameter(Mandatory = $true)]
    [string]$ExplorationRunPath,
    [Parameter(Mandatory = $true)]
    [string]$IndexMdPath,
    [Parameter(Mandatory = $true)]
    [string]$IndexHtmlPath,
    [Parameter(Mandatory = $true)]
    [string]$TimelineMdPath,
    [Parameter(Mandatory = $true)]
    [string]$TimelineHtmlPath,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$BundlePath
  )

  $continuitySegments = @(New-ContinuitySegmentArray -Catalog $Catalog -ChunkPlan $ChunkPlan -ChunkReceipts $ChunkReceipts)
  $continuityBreaks = @(New-ContinuityBreakArray -Segments $continuitySegments)
  $chunkEvidence = @(New-ChunkEvidenceArray -ChunkReceipts $ChunkReceipts -ResultsRoot $ResultsRoot)
  $surfaceReferences = New-SurfaceReferenceCollection `
    -ChunkReceipts $ChunkReceipts `
    -ResultsRoot $ResultsRoot `
    -RevisionCatalogPath $RevisionCatalogPath `
    -ChunkPlanPath $ChunkPlanPath `
    -ExplorationRunPath $ExplorationRunPath `
    -IndexMdPath $IndexMdPath `
    -IndexHtmlPath $IndexHtmlPath `
    -TimelineMdPath $TimelineMdPath `
    -TimelineHtmlPath $TimelineHtmlPath `
    -BundlePath $BundlePath

  return [ordered]@{
    schema = 'comparevi-history/evidence-graph@v1'
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    consumer = [ordered]@{
      repository = [string]$Catalog.consumer.repository
      ref = [string]$Catalog.consumer.ref
    }
    target = [ordered]@{
      path = [string]$Catalog.target.path
      selectedRef = [string]$Catalog.target.selectedRef
      extension = '.vi'
    }
    configuration = [ordered]@{
      requestedModes = @($RequestedModes)
      noisePolicy = $NoisePolicy
      includeMergeParents = [bool]$Catalog.discovery.includeMergeParents
    }
    discovery = [ordered]@{
      revisionCatalogPath = ConvertTo-ArtifactReference -Path $RevisionCatalogPath -ResultsRoot $ResultsRoot
      revisionCount = [int]$Catalog.summary.revisionCount
      historyMode = [string]$Catalog.discovery.historyMode
      followRenames = [bool]$Catalog.discovery.followRenames
      catalogComplete = [bool]$Catalog.discovery.complete
      catalogCompletenessReason = [string]$Catalog.discovery.completenessReason
    }
    continuity = [ordered]@{
      status = [string]$Catalog.summary.continuityStatus
      breakCount = @($continuityBreaks).Count
      segmentCount = @($continuitySegments).Count
      segments = @($continuitySegments)
      breaks = @($continuityBreaks)
    }
    execution = [ordered]@{
      chunkPlanPath = ConvertTo-ArtifactReference -Path $ChunkPlanPath -ResultsRoot $ResultsRoot
      chunkReceiptsRoot = ConvertTo-ArtifactReference -Path $ChunkReceiptsRoot -ResultsRoot $ResultsRoot
      chunkPairLimit = [int]$ChunkPlan.summary.chunkPairLimit
      pairCount = [int]$ChunkPlan.summary.pairCount
      chunkCount = @($chunkEvidence).Count
      plannedChunkCount = [int]$RunStats.totalChunkCount
      completedChunkCount = [int]$RunStats.completedChunkCount
      failedChunkCount = [int]$RunStats.failedChunkCount
      skippedChunkCount = [int]$RunStats.skippedChunkCount
      status = [string]$RunStats.finalStatus
      reason = [string]$RunStats.finalReason
      chunks = @($chunkEvidence)
    }
    surfaces = [ordered]@{
      suppressionProfile = [string]$SurfaceAggregate.suppressionProfile
      comparisonArtifactCount = [int]$SurfaceAggregate.comparisonArtifactCount
      captureCount = [int]$SurfaceAggregate.captureCount
      imageArtifactCount = [int]$SurfaceAggregate.imageArtifactCount
      imageMimeTypes = @($SurfaceAggregate.imageMimeTypes)
      chunkCountWithMetadata = [int]$SurfaceAggregate.chunkCountWithMetadata
      categoryCounts = $SurfaceAggregate.categoryCounts
      comparisonPairs = @($SurfaceAggregate.comparisonPairs)
      bucketCounts = $SurfaceAggregate.bucketCounts
      previewImages = @(ConvertTo-PreviewImageArray -Value $SurfaceAggregate.previewImages)
      renderSurfaces = @($surfaceReferences.renderSurfaces)
      artifactSurfaces = @($surfaceReferences.artifactSurfaces)
    }
    completeness = [ordered]@{
      catalogComplete = [bool]$RunStats.catalogComplete
      catalogCompletenessReason = [string]$RunStats.catalogCompletenessReason
      finalStatus = [string]$RunStats.finalStatus
      finalReason = [string]$RunStats.finalReason
      replayStatus = [string]$RunStats.replayStatus
      replayReason = [string]$RunStats.replayReason
      bundleStatus = [string]$RunStats.bundleStatus
      bundleReason = [string]$RunStats.bundleReason
      previewImageCount = [int]$RunStats.previewImageCount
      previewGalleryCap = [int]$RunStats.previewGalleryCap
      previewGalleryCount = [int]$RunStats.previewGalleryCount
      previewGalleryOmittedCount = [int]$RunStats.previewGalleryOmittedCount
      stepSummaryPreviewCap = [int]$RunStats.stepSummaryPreviewCap
      stepSummaryPreviewCount = [int]$RunStats.stepSummaryPreviewCount
      stepSummaryPreviewOmittedCount = [int]$RunStats.stepSummaryPreviewOmittedCount
      stepSummaryPreviewByteBudget = [int]$RunStats.stepSummaryPreviewByteBudget
    }
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
    $EvidenceGraph,
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
    $PreviewImages,
    [AllowNull()]
    [string]$TimelineMdPath,
    [AllowNull()]
    [string]$TimelineHtmlPath,
    [Parameter(Mandatory = $true)]
    [string]$ExplorationRunPath,
    [Parameter(Mandatory = $true)]
    [string]$EvidenceGraphPath,
    [AllowNull()]
    [string]$BundlePath
  )

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('# comparevi-history manual exploration index') | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add(('- Target path: `{0}`' -f [string]$Catalog.target.path)) | Out-Null
  $lines.Add(('- Selected ref: `{0}`' -f [string]$Catalog.target.selectedRef)) | Out-Null
  $lines.Add(('- Final status: `{0}`' -f $FinalStatus)) | Out-Null
  $lines.Add(('- Final reason: `{0}`' -f $FinalReason)) | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add((New-MarkdownPrimaryReviewSurfaces -EvidenceGraph $EvidenceGraph -ExplorationRunPath $ExplorationRunPath -EvidenceGraphPath $EvidenceGraphPath -ResultsRoot $ResultsRoot)) | Out-Null
  $lines.Add((New-MarkdownReviewNavigation -EvidenceGraph $EvidenceGraph)) | Out-Null
  $previewGalleryMarkdown = New-MarkdownPreviewGallery -PreviewImages $PreviewImages -EvidenceGraph $EvidenceGraph -RunStats $RunStats
  if (-not [string]::IsNullOrWhiteSpace($previewGalleryMarkdown)) {
    $lines.Add($previewGalleryMarkdown) | Out-Null
    $lines.Add('') | Out-Null
  }
  $lines.Add('## Run summary') | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add(('- Revision count: `{0}`' -f [int]$RunStats.revisionCount)) | Out-Null
  $lines.Add(('- Pair count: `{0}`' -f [int]$RunStats.pairCount)) | Out-Null
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
  if ([int]$RunStats.previewImageCount -gt 0) {
    $lines.Add(('- Preview images: `{0}`' -f [int]$RunStats.previewImageCount)) | Out-Null
    $lines.Add(('- Preview gallery: `{0}` shown, `{1}` omitted, cap `{2}`' -f [int]$RunStats.previewGalleryCount, [int]$RunStats.previewGalleryOmittedCount, [int]$RunStats.previewGalleryCap)) | Out-Null
    $lines.Add(('- Step summary previews: `{0}` shown, `{1}` omitted, cap `{2}`, byte-budget `{3}`' -f [int]$RunStats.stepSummaryPreviewCount, [int]$RunStats.stepSummaryPreviewOmittedCount, [int]$RunStats.stepSummaryPreviewCap, [int]$RunStats.stepSummaryPreviewByteBudget)) | Out-Null
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
  foreach ($segment in @(ConvertTo-ObjectArray -InputObject (Get-OptionalPropertyValue -InputObject (Get-OptionalPropertyValue -InputObject $EvidenceGraph -PropertyName 'continuity') -PropertyName 'segments' -Default @()) | Sort-Object { [int]$_.segmentOrdinal })) {
    $lines.Add(('<a id="{0}"></a>' -f (Get-SegmentAnchorId -SegmentOrdinal ([int]$segment.segmentOrdinal)))) | Out-Null
    $continuityNote = if ($null -ne (Get-OptionalPropertyValue -InputObject $segment -PropertyName 'continuityBreakAfterRevisionOrdinal')) {
      ('; break after revision `{0}` ({1})' -f [int]$segment.continuityBreakAfterRevisionOrdinal, [string]$segment.continuityBreakReason)
    } else {
      ''
    }
    $chunkLinks = @(
      ConvertTo-ObjectArray -InputObject (Get-OptionalPropertyValue -InputObject $segment -PropertyName 'chunkIds' -Default @()) |
        ForEach-Object {
          $chunkId = [string]$_
          if (-not [string]::IsNullOrWhiteSpace($chunkId)) {
            [ordered]@{
              label = $chunkId
              href = ('#{0}' -f (Get-ChunkAnchorId -ChunkId $chunkId))
            }
          }
        }
    )
    $lines.Add(('- Segment `{0}`: revisions `{1}` -> `{2}`, pairs `{3}`, chunks {4}, start `{5}`{6}' -f [int]$segment.segmentOrdinal, [int]$segment.startRevisionOrdinal, [int]$segment.endRevisionOrdinal, [int]$segment.pairCount, (Format-MarkdownLinkList -Links $chunkLinks), [string]$segment.continuityStartReason, $continuityNote)) | Out-Null
  }
  $lines.Add('') | Out-Null
  $lines.Add('## Chunk navigation') | Out-Null
  $lines.Add('') | Out-Null

  foreach ($chunk in @(ConvertTo-ObjectArray -InputObject (Get-OptionalPropertyValue -InputObject (Get-OptionalPropertyValue -InputObject $EvidenceGraph -PropertyName 'execution') -PropertyName 'chunks' -Default @()) | Sort-Object { [int]$_.chunkOrdinal }, { [string]$_.chunkId })) {
    $chunkOutputs = Get-OptionalPropertyValue -InputObject $chunk -PropertyName 'outputs'
    $chunkSummary = Get-OptionalPropertyValue -InputObject $chunk -PropertyName 'summary'
    $chunkSurfaces = Get-OptionalPropertyValue -InputObject $chunk -PropertyName 'surfaces'
    $lines.Add(('### {0}' -f [string]$chunk.chunkId)) | Out-Null
    $lines.Add(('<a id="{0}"></a>' -f (Get-ChunkAnchorId -ChunkId ([string]$chunk.chunkId)))) | Out-Null
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
      $mimeTypeText = if (@(ConvertTo-ObjectArray -InputObject (Get-OptionalPropertyValue -InputObject $chunkSurfaces -PropertyName 'imageMimeTypes' -Default @())).Count -gt 0) {
        @(ConvertTo-ObjectArray -InputObject (Get-OptionalPropertyValue -InputObject $chunkSurfaces -PropertyName 'imageMimeTypes' -Default @())) -join ', '
      } else {
        'none'
      }
      $lines.Add(('- Metadata surfaces: `captures={0}, images={1}, artifact-dirs={2}, mime-types={3}`' -f [int](Get-OptionalPropertyValue -InputObject $chunkSurfaces -PropertyName 'captureCount' -Default 0), [int](Get-OptionalPropertyValue -InputObject $chunkSurfaces -PropertyName 'imageArtifactCount' -Default 0), [int](Get-OptionalPropertyValue -InputObject $chunkSurfaces -PropertyName 'comparisonArtifactCount' -Default 0), $mimeTypeText)) | Out-Null
      if ($chunkNormalizedSurface.categoryCounts.Count -gt 0) {
        $lines.Add(('- Category counts: `{0}`' -f (Format-CountMapText -Map $chunkNormalizedSurface.categoryCounts))) | Out-Null
      }
      if (@($chunkNormalizedSurface.comparisonPairs).Count -gt 0) {
        $lines.Add(('- Comparison pairs: `{0}`' -f (Format-ComparisonPairText -Pairs $chunkNormalizedSurface.comparisonPairs))) | Out-Null
      }
    }
    $receiptReference = [string](Get-OptionalPropertyValue -InputObject $chunkOutputs -PropertyName 'receiptPath' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($receiptReference)) {
      $lines.Add(('- Receipt: {0}' -f (Format-MarkdownLink -Label 'chunk-receipt.json' -Href $receiptReference))) | Out-Null
    }
    $historyReportMdReference = [string](Get-OptionalPropertyValue -InputObject $chunkOutputs -PropertyName 'historyReportMd' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($historyReportMdReference)) {
      $lines.Add(('- History report (md): {0}' -f (Format-MarkdownLink -Label 'history-report.md' -Href $historyReportMdReference))) | Out-Null
    }
    $historyReportHtmlReference = [string](Get-OptionalPropertyValue -InputObject $chunkOutputs -PropertyName 'historyReportHtml' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($historyReportHtmlReference)) {
      $lines.Add(('- History report (html): {0}' -f (Format-MarkdownLink -Label 'history-report.html' -Href $historyReportHtmlReference))) | Out-Null
    }
    $modeSummaryReference = [string](Get-OptionalPropertyValue -InputObject $chunkOutputs -PropertyName 'modeSummaryPath' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($modeSummaryReference)) {
      $lines.Add(('- Mode summary: {0}' -f (Format-MarkdownLink -Label 'mode-summary.md' -Href $modeSummaryReference))) | Out-Null
    }
    $modeSummaryJsonReference = [string](Get-OptionalPropertyValue -InputObject $chunkOutputs -PropertyName 'modeSummaryJsonPath' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($modeSummaryJsonReference)) {
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
    $EvidenceGraph,
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
    $PreviewImages,
    [AllowNull()]
    [string]$TimelineMdPath,
    [AllowNull()]
    [string]$TimelineHtmlPath,
    [Parameter(Mandatory = $true)]
    [string]$ExplorationRunPath,
    [Parameter(Mandatory = $true)]
    [string]$EvidenceGraphPath,
    [AllowNull()]
    [string]$BundlePath
  )

  $summaryClass = Get-HtmlStatusClass -Status $FinalStatus
  $rows = New-Object System.Collections.Generic.List[string]
  foreach ($chunk in @(ConvertTo-ObjectArray -InputObject (Get-OptionalPropertyValue -InputObject (Get-OptionalPropertyValue -InputObject $EvidenceGraph -PropertyName 'execution') -PropertyName 'chunks' -Default @()) | Sort-Object { [int]$_.chunkOrdinal }, { [string]$_.chunkId })) {
    $chunkOutputs = Get-OptionalPropertyValue -InputObject $chunk -PropertyName 'outputs'
    $chunkSummary = Get-OptionalPropertyValue -InputObject $chunk -PropertyName 'summary'
    $chunkSurfaces = Get-OptionalPropertyValue -InputObject $chunk -PropertyName 'surfaces'
    $chunkClass = Get-HtmlStatusClass -Status ([string]$chunk.status)
    $receiptReference = [string](Get-OptionalPropertyValue -InputObject $chunkOutputs -PropertyName 'receiptPath' -Default '')
    $historyReportMdReference = [string](Get-OptionalPropertyValue -InputObject $chunkOutputs -PropertyName 'historyReportMd' -Default '')
    $historyReportHtmlReference = [string](Get-OptionalPropertyValue -InputObject $chunkOutputs -PropertyName 'historyReportHtml' -Default '')
    $modeSummaryReference = [string](Get-OptionalPropertyValue -InputObject $chunkOutputs -PropertyName 'modeSummaryPath' -Default '')
    $modeSummaryJsonReference = [string](Get-OptionalPropertyValue -InputObject $chunkOutputs -PropertyName 'modeSummaryJsonPath' -Default '')
    $receiptLink = Format-HtmlLink -Label 'chunk-receipt.json' -Href $receiptReference
    $historyReportMdLink = Format-HtmlLink -Label 'history-report.md' -Href $historyReportMdReference
    $historyReportHtmlLink = Format-HtmlLink -Label 'history-report.html' -Href $historyReportHtmlReference
    $modeSummaryLink = Format-HtmlLink -Label 'mode-summary.md' -Href $modeSummaryReference
    $modeSummaryJsonLink = Format-HtmlLink -Label 'mode-summary.json' -Href $modeSummaryJsonReference
    $chunkProfile = [string](Get-OptionalPropertyValue -InputObject $chunkSurfaces -PropertyName 'suppressionProfile' -Default 'unknown')
    $chunkMetadataText = 'captures={0}, images={1}, artifact-dirs={2}' -f [int](Get-OptionalPropertyValue -InputObject $chunkSurfaces -PropertyName 'captureCount' -Default 0), [int](Get-OptionalPropertyValue -InputObject $chunkSurfaces -PropertyName 'imageArtifactCount' -Default 0), [int](Get-OptionalPropertyValue -InputObject $chunkSurfaces -PropertyName 'comparisonArtifactCount' -Default 0)
    $rows.Add(@"
<tr id="$((Get-ChunkAnchorId -ChunkId ([string]$chunk.chunkId)))" class="$chunkClass">
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
  foreach ($segment in @(ConvertTo-ObjectArray -InputObject (Get-OptionalPropertyValue -InputObject (Get-OptionalPropertyValue -InputObject $EvidenceGraph -PropertyName 'continuity') -PropertyName 'segments' -Default @()) | Sort-Object { [int]$_.segmentOrdinal })) {
    $chunkLinks = @(
      ConvertTo-ObjectArray -InputObject (Get-OptionalPropertyValue -InputObject $segment -PropertyName 'chunkIds' -Default @()) |
        ForEach-Object {
          $chunkId = [string]$_
          if (-not [string]::IsNullOrWhiteSpace($chunkId)) {
            [ordered]@{
              label = $chunkId
              href = ('#{0}' -f (Get-ChunkAnchorId -ChunkId $chunkId))
            }
          }
        }
    )
    $breakCell = if ($null -ne $segment.continuityBreakAfterRevisionOrdinal) {
      ('{0} ({1})' -f [int]$segment.continuityBreakAfterRevisionOrdinal, [string]$segment.continuityBreakReason)
    } else {
      'none'
    }
    $continuityRows.Add(@"
<tr id="$((Get-SegmentAnchorId -SegmentOrdinal ([int]$segment.segmentOrdinal)))">
  <td>$([int]$segment.segmentOrdinal)</td>
  <td>$([int]$segment.startRevisionOrdinal)-$([int]$segment.endRevisionOrdinal)</td>
  <td>$([int]$segment.pairCount)</td>
  <td>$(Format-HtmlLinkList -Links $chunkLinks)</td>
  <td>$([string]$segment.continuityStartReason)</td>
  <td>$breakCell</td>
</tr>
"@) | Out-Null
  }
  $primaryReviewHtml = New-HtmlPrimaryReviewSurfaces -EvidenceGraph $EvidenceGraph -ExplorationRunPath $ExplorationRunPath -EvidenceGraphPath $EvidenceGraphPath -ResultsRoot $ResultsRoot
  $reviewNavigationHtml = New-HtmlReviewNavigation -EvidenceGraph $EvidenceGraph
  $previewGalleryHtml = New-HtmlPreviewGallery -PreviewImages $PreviewImages -EvidenceGraph $EvidenceGraph -RunStats $RunStats

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
    .preview-summary { display: grid; grid-template-columns: max-content 1fr; gap: 0.5rem 1rem; margin: 1rem 0; }
    .preview-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(18rem, 1fr)); gap: 1rem; margin-bottom: 1.5rem; }
    .preview-card { border: 1px solid #ccc; padding: 0.75rem; background: #fff; }
    .preview-card-title { font-weight: 600; margin-bottom: 0.5rem; }
    .preview-card-meta { display: grid; grid-template-columns: max-content 1fr; gap: 0.25rem 0.75rem; margin-bottom: 0.75rem; }
    .preview-card img { max-width: 100%; height: auto; border: 1px solid #ddd; background: #fafafa; }
  </style>
</head>
<body>
  <h1>comparevi-history manual exploration index</h1>
  <div class="banner $summaryClass">
    <strong>Final status:</strong> $FinalStatus
    <span> | <strong>Final reason:</strong> $FinalReason</span>
    <span> | <strong>Continuity:</strong> $([string]$RunStats.continuityStatus)</span>
  </div>
  <p><strong>Target path:</strong> $([string]$Catalog.target.path)<br/><strong>Selected ref:</strong> $([string]$Catalog.target.selectedRef)</p>
$primaryReviewHtml
$reviewNavigationHtml
$previewGalleryHtml
  <h2>Run summary</h2>
  <div class="meta">
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
    <strong>Preview images</strong><span>$([int]$RunStats.previewImageCount)</span>
    <strong>Preview gallery</strong><span>$([int]$RunStats.previewGalleryCount) shown, $([int]$RunStats.previewGalleryOmittedCount) omitted, cap $([int]$RunStats.previewGalleryCap)</span>
    <strong>Step summary previews</strong><span>$([int]$RunStats.stepSummaryPreviewCount) shown, $([int]$RunStats.stepSummaryPreviewOmittedCount) omitted, cap $([int]$RunStats.stepSummaryPreviewCap), byte-budget $([int]$RunStats.stepSummaryPreviewByteBudget)</span>
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
        <th>Chunks</th>
        <th>Start reason</th>
        <th>Break</th>
      </tr>
    </thead>
    <tbody>
$($continuityRows -join [Environment]::NewLine)
    </tbody>
  </table>
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
$evidenceGraphPath = Join-Path $resultsDirResolved 'evidence-graph.json'
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

$surfaceAggregate = New-ExplorationSurfaceAggregate -ChunkReceipts $chunkReceipts -ResultsRoot $resultsDirResolved
$previewGalleryImages = @(Select-PreviewGalleryImages -PreviewImages $surfaceAggregate.previewImages -Limit $script:PreviewGalleryCap)
$stepSummaryPreviewSelection = Select-StepSummaryPreviewImages `
  -PreviewImages $surfaceAggregate.previewImages `
  -ResultsRoot $resultsDirResolved `
  -Limit $script:StepSummaryPreviewCap `
  -ByteBudget $script:StepSummaryPreviewByteBudget
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
  -NoisePolicy $NoisePolicy `
  -PreviewGalleryCount $previewGalleryImages.Count `
  -StepSummaryPreviewCount (@(ConvertTo-ObjectArray -InputObject $stepSummaryPreviewSelection.images).Count)

$chunkReceiptArray = @(ConvertTo-ObjectArray -InputObject $chunkReceipts)
$timelineMarkdown = New-MarkdownTimeline -Catalog $catalog -ChunkPlan $chunkPlan -ChunkReceipts $chunkReceiptArray -RunStats $runStats -FinalStatus $finalStatus -FinalReason $finalReason
$timelineHtml = New-HtmlTimeline -Catalog $catalog -ChunkPlan $chunkPlan -ChunkReceipts $chunkReceiptArray -RunStats $runStats -FinalStatus $finalStatus -FinalReason $finalReason
$timelineMarkdown | Set-Content -LiteralPath $timelineMdResolved -Encoding utf8
$timelineHtml | Set-Content -LiteralPath $timelineHtmlResolved -Encoding utf8

'' | Set-Content -LiteralPath $indexMdResolved -Encoding utf8
'' | Set-Content -LiteralPath $indexHtmlResolved -Encoding utf8

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
    previewImages = @(ConvertTo-PreviewImageArray -Value $surfaceAggregate.previewImages)
  }
  discovery = [ordered]@{
    revisionCatalogPath = $revisionCatalogPathResolved
    revisionCount = [int]$catalog.summary.revisionCount
    catalogComplete = [bool]$catalog.discovery.complete
    catalogCompletenessReason = [string]$catalog.discovery.completenessReason
    continuityStatus = [string]$catalog.summary.continuityStatus
  }
  evidence = [ordered]@{
    schema = 'comparevi-history/evidence-graph@v1'
    graphPath = $evidenceGraphPath
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
    evidenceGraphPath = $evidenceGraphPath
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
    previewImageCount = [int]$runStats.previewImageCount
    previewGalleryCap = [int]$runStats.previewGalleryCap
    previewGalleryCount = [int]$runStats.previewGalleryCount
    previewGalleryOmittedCount = [int]$runStats.previewGalleryOmittedCount
    stepSummaryPreviewCap = [int]$runStats.stepSummaryPreviewCap
    stepSummaryPreviewCount = [int]$runStats.stepSummaryPreviewCount
    stepSummaryPreviewOmittedCount = [int]$runStats.stepSummaryPreviewOmittedCount
    stepSummaryPreviewByteBudget = [int]$runStats.stepSummaryPreviewByteBudget
  }
  replay = [ordered]@{
    status = $replayStatus
    reason = $replayReason
  }
}
$explorationRun | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $explorationRunPath -Encoding utf8

$evidenceGraph = New-EvidenceGraph `
  -Catalog $catalog `
  -ChunkPlan $chunkPlan `
  -ChunkReceipts $chunkReceipts `
  -ResultsRoot $resultsDirResolved `
  -RequestedModes $requestedModes `
  -NoisePolicy $NoisePolicy `
  -SurfaceAggregate $surfaceAggregate `
  -RunStats $runStats `
  -RevisionCatalogPath $revisionCatalogPathResolved `
  -ChunkPlanPath $chunkPlanPathResolved `
  -ChunkReceiptsRoot $chunkReceiptsRoot `
  -ExplorationRunPath $explorationRunPath `
  -IndexMdPath $indexMdResolved `
  -IndexHtmlPath $indexHtmlResolved `
  -TimelineMdPath $timelineMdResolved `
  -TimelineHtmlPath $timelineHtmlResolved `
  -BundlePath $bundlePathResolved

$indexMarkdown = New-MarkdownIndex `
  -Catalog $catalog `
  -ChunkPlan $chunkPlan `
  -ChunkReceipts $chunkReceiptArray `
  -RunStats $runStats `
  -EvidenceGraph $evidenceGraph `
  -FinalStatus $finalStatus `
  -FinalReason $finalReason `
  -BundleStatus $effectiveBundleStatus `
  -BundleReason $effectiveBundleReason `
  -ResultsRoot $resultsDirResolved `
  -PreviewImages $previewGalleryImages `
  -TimelineMdPath $timelineMdResolved `
  -TimelineHtmlPath $timelineHtmlResolved `
  -ExplorationRunPath $explorationRunPath `
  -EvidenceGraphPath $evidenceGraphPath `
  -BundlePath $bundlePathResolved
$indexHtml = New-HtmlIndex `
  -Catalog $catalog `
  -ChunkPlan $chunkPlan `
  -ChunkReceipts $chunkReceiptArray `
  -RunStats $runStats `
  -EvidenceGraph $evidenceGraph `
  -FinalStatus $finalStatus `
  -FinalReason $finalReason `
  -BundleStatus $effectiveBundleStatus `
  -BundleReason $effectiveBundleReason `
  -ResultsRoot $resultsDirResolved `
  -PreviewImages $previewGalleryImages `
  -TimelineMdPath $timelineMdResolved `
  -TimelineHtmlPath $timelineHtmlResolved `
  -ExplorationRunPath $explorationRunPath `
  -EvidenceGraphPath $evidenceGraphPath `
  -BundlePath $bundlePathResolved
$indexMarkdown | Set-Content -LiteralPath $indexMdResolved -Encoding utf8
$indexHtml | Set-Content -LiteralPath $indexHtmlResolved -Encoding utf8
$evidenceGraph | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $evidenceGraphPath -Encoding utf8

Write-ActionOutput -Key 'exploration-run-path' -Value $explorationRunPath
Write-ActionOutput -Key 'evidence-graph-path' -Value $evidenceGraphPath
Write-ActionOutput -Key 'exploration-status' -Value $finalStatus
Write-ActionOutput -Key 'exploration-reason' -Value $finalReason
Write-ActionOutput -Key 'index-md' -Value $indexMdResolved
Write-ActionOutput -Key 'index-html' -Value $indexHtmlResolved
Write-ActionOutput -Key 'timeline-md' -Value $timelineMdResolved
Write-ActionOutput -Key 'timeline-html' -Value $timelineHtmlResolved
Write-ActionOutput -Key 'bundle-path' -Value $(if ($null -eq $bundlePathResolved) { '' } else { $bundlePathResolved })

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  $stepSummaryLines = New-Object System.Collections.Generic.List[string]
  @(
    ''
    '## comparevi-history exploration run'
    ''
    ('- Exploration run: `{0}`' -f $explorationRunPath)
    ('- Evidence graph: `{0}`' -f $evidenceGraphPath)
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
  ) | ForEach-Object { $stepSummaryLines.Add($_) | Out-Null }
  foreach ($line in @(New-StepSummaryPreviewSection -RunStats $runStats -PreviewSelection $stepSummaryPreviewSelection)) {
    $stepSummaryLines.Add($line) | Out-Null
  }
  $stepSummaryLines | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
}

$explorationRun | ConvertTo-Json -Depth 64
