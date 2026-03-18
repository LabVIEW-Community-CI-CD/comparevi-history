param(
  [Parameter(Mandatory = $true)]
  [string]$TargetRunsManifestPath,
  [Parameter(Mandatory = $true)]
  [string]$ResultsDir,
  [string]$OutputPath,
  [int]$CommentPreviewPairCap = 4,
  [int]$IndexPreviewPairCap = 12,
  [string]$GitHubOutputPath,
  [string]$StepSummaryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modeOrder = @{
  'front-panel' = 0
  'block-diagram' = 1
  'attributes' = 2
}

$sectionKindOrder = @{
  'overview' = 0
  'detail' = 1
}

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

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][string]$Path)

  $raw = Get-Content -LiteralPath $Path -Raw
  if ([string]::IsNullOrWhiteSpace($raw)) {
    throw "JSON file was empty: $Path"
  }

  return $raw | ConvertFrom-Json -Depth 100
}

function Get-OptionalString {
  param([AllowNull()]$Value)

  if ($null -eq $Value) {
    return $null
  }

  $stringValue = [string]$Value
  if ([string]::IsNullOrWhiteSpace($stringValue)) {
    return $null
  }

  return $stringValue.Trim()
}

function ConvertTo-ObjectArray {
  param([AllowNull()]$Value)

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

function Get-NestedValue {
  param(
    [AllowNull()]
    [object]$Object,
    [Parameter(Mandatory = $true)]
    [string[]]$Path,
    [AllowNull()]
    $Default = $null
  )

  $current = $Object
  foreach ($segment in $Path) {
    if ($null -eq $current) {
      return $Default
    }

    $property = $current.PSObject.Properties[$segment]
    if ($null -eq $property) {
      return $Default
    }

    $current = $property.Value
  }

  if ($null -eq $current) {
    return $Default
  }

  return $current
}

function Resolve-ExistingPath {
  param(
    [AllowNull()]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$BasePath,
    [Parameter(Mandatory = $true)]
    [string]$PathType
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }

  $resolved = Resolve-AbsolutePath -Path $Path -BasePath $BasePath
  if (-not (Test-Path -LiteralPath $resolved -PathType $PathType)) {
    return $null
  }

  return $resolved
}

function Resolve-RelativePath {
  param(
    [AllowNull()]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$ResultsRoot
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }

  $resolvedPath = Resolve-AbsolutePath -Path $Path -BasePath $ResultsRoot
  if (-not (Test-Path -LiteralPath $resolvedPath)) {
    return $null
  }

  return [System.IO.Path]::GetRelativePath($ResultsRoot, $resolvedPath).Replace('\', '/')
}

function ConvertFrom-HtmlText {
  param([AllowNull()][string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return ''
  }

  $decoded = [System.Net.WebUtility]::HtmlDecode($Value)
  $withoutTags = [regex]::Replace($decoded, '<[^>]+>', ' ')
  return [regex]::Replace($withoutTags, '\s+', ' ').Trim()
}

function ConvertTo-Slug {
  param(
    [AllowNull()]
    [string]$Value,
    [string]$Fallback = 'preview'
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $Fallback
  }

  $slug = $Value.ToLowerInvariant() -replace '[^a-z0-9]+', '-'
  $slug = $slug.Trim('-')
  if ([string]::IsNullOrWhiteSpace($slug)) {
    return $Fallback
  }

  return $slug
}

function Get-ModeSortOrder {
  param([AllowNull()][string]$Mode)

  if ([string]::IsNullOrWhiteSpace($Mode)) {
    return 99
  }

  if ($modeOrder.ContainsKey($Mode)) {
    return [int]$modeOrder[$Mode]
  }

  return 99
}

function Get-SectionKindSortOrder {
  param([AllowNull()][string]$SectionKind)

  if ([string]::IsNullOrWhiteSpace($SectionKind)) {
    return 99
  }

  if ($sectionKindOrder.ContainsKey($SectionKind)) {
    return [int]$sectionKindOrder[$SectionKind]
  }

  return 99
}

function ConvertTo-PreviewPairArray {
  param([AllowNull()]$Value)

  return @(
    ConvertTo-ObjectArray -Value $Value |
      Sort-Object {
        $sortKey = Get-OptionalString -Value $_.sortKey
        if ([string]::IsNullOrWhiteSpace($sortKey)) {
          [string]$_.label
        } else {
          $sortKey
        }
      }
  )
}

function Get-PreviewPairIdentityKey {
  param(
    [Parameter(Mandatory = $true)]
    [object]$PreviewPair
  )

  return '{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}' -f `
    [string]$PreviewPair.targetId, `
    [string]$PreviewPair.mode, `
    [int](Get-NestedValue -Object $PreviewPair -Path @('comparison', 'index') -Default 0), `
    [string]$PreviewPair.sectionKind, `
    [int](Get-NestedValue -Object $PreviewPair -Path @('sectionOrdinal') -Default 0), `
    $(if ([string]::IsNullOrWhiteSpace([string]$PreviewPair.reportHtmlRelativePath)) { '' } else { [string]$PreviewPair.reportHtmlRelativePath }), `
    [string]$PreviewPair.baseImageRelativePath, `
    [string]$PreviewPair.headImageRelativePath
}

function Add-PreviewPairSelection {
  param(
    [AllowNull()]
    [object]$PreviewPair,
    [AllowEmptyCollection()]
    [System.Collections.Generic.List[object]]$Selected,
    [AllowEmptyCollection()]
    [System.Collections.Generic.HashSet[string]]$Seen,
    [int]$Limit
  )

  if ($null -eq $PreviewPair -or $Selected.Count -ge $Limit) {
    return $false
  }

  $identityKey = Get-PreviewPairIdentityKey -PreviewPair $PreviewPair
  if (-not $Seen.Add($identityKey)) {
    return $false
  }

  $Selected.Add($PreviewPair) | Out-Null
  return $true
}

function Select-PreviewPairs {
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$PreviewPairs,
    [int]$Limit
  )

  if ($Limit -le 0 -or $PreviewPairs.Count -eq 0) {
    return @()
  }

  $orderedPairs = @(ConvertTo-PreviewPairArray -Value $PreviewPairs)
  $selected = New-Object System.Collections.Generic.List[object]
  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

  foreach ($mode in @('front-panel', 'block-diagram', 'attributes')) {
    if ($selected.Count -ge $Limit) {
      break
    }

    $overviewPair = @(
      $orderedPairs |
        Where-Object {
          [string]$_.mode -eq $mode -and
          [string]$_.sectionKind -eq 'overview'
        } |
        Select-Object -First 1
    )
    if ($overviewPair) {
      Add-PreviewPairSelection -PreviewPair $overviewPair[0] -Selected $selected -Seen $seen -Limit $Limit | Out-Null
    }
  }

  foreach ($pair in $orderedPairs) {
    if ($selected.Count -ge $Limit) {
      break
    }

    Add-PreviewPairSelection -PreviewPair $pair -Selected $selected -Seen $seen -Limit $Limit | Out-Null
  }

  return @($selected | ForEach-Object { $_ })
}

function Get-ReportPreviewPairs {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ReportHtmlPath,
    [Parameter(Mandatory = $true)]
    [string]$ResultsRoot,
    [Parameter(Mandatory = $true)]
    [string]$TargetId,
    [Parameter(Mandatory = $true)]
    [string]$TargetPath,
    [Parameter(Mandatory = $true)]
    [string]$Mode,
    [Parameter(Mandatory = $true)]
    [object]$Comparison
  )

  if (-not (Test-Path -LiteralPath $ReportHtmlPath -PathType Leaf)) {
    return @()
  }

  $reportHtml = Get-Content -LiteralPath $ReportHtmlPath -Raw
  if ([string]::IsNullOrWhiteSpace($reportHtml)) {
    return @()
  }

  $reportDirectory = Split-Path -Parent $ReportHtmlPath
  $reportHtmlRelativePath = Resolve-RelativePath -Path $ReportHtmlPath -ResultsRoot $ResultsRoot
  $pairs = New-Object System.Collections.Generic.List[object]
  $sectionOrdinal = 0
  $detailPattern = '(?is)<details(?<detailsAttrs>[^>]*)>\s*<summary(?<summaryAttrs>[^>]*)>(?<summary>.*?)</summary>\s*<table class="difference">(?<table>.*?)</table>\s*</details>'
  foreach ($match in [regex]::Matches($reportHtml, $detailPattern)) {
    $summaryAttrs = [string]$match.Groups['summaryAttrs'].Value
    $summaryText = ConvertFrom-HtmlText -Value ([string]$match.Groups['summary'].Value)
    $tableHtml = [string]$match.Groups['table'].Value
    $captionMatches = [regex]::Matches($tableHtml, '(?is)<td class="compared-vi-image-caption">(?<caption>.*?)</td>')
    $captions = @(
      $captionMatches |
        ForEach-Object { ConvertFrom-HtmlText -Value ([string]$_.Groups['caption'].Value) } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    $imageSources = @(
      [regex]::Matches($tableHtml, '(?is)<img[^>]+src="(?<src>[^"]+)"') |
        ForEach-Object { Get-OptionalString -Value ([string]$_.Groups['src'].Value) } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($imageSources.Count -lt 2) {
      continue
    }

    $baseImagePath = Resolve-ExistingPath -Path $imageSources[0] -BasePath $reportDirectory -PathType Leaf
    $headImagePath = Resolve-ExistingPath -Path $imageSources[1] -BasePath $reportDirectory -PathType Leaf
    if ($null -eq $baseImagePath -or $null -eq $headImagePath) {
      continue
    }

    $sectionKind = if ($summaryAttrs -match 'difference-heading') { 'overview' } else { 'detail' }
    $label = if ($sectionKind -eq 'overview' -and $captions.Count -gt 0) {
      $captions[0]
    } elseif (-not [string]::IsNullOrWhiteSpace($summaryText)) {
      $summaryText
    } elseif ($captions.Count -gt 0) {
      $captions[0]
    } else {
      'Preview'
    }

    $comparisonIndex = [int](Get-NestedValue -Object $Comparison -Path @('index') -Default 0)
    $sortKey = '{0}|{1:D2}|{2:D4}|{3:D2}|{4:D4}|{5}' -f `
      $TargetPath, `
      (Get-ModeSortOrder -Mode $Mode), `
      $comparisonIndex, `
      (Get-SectionKindSortOrder -SectionKind $sectionKind), `
      $sectionOrdinal, `
      (ConvertTo-Slug -Value $label)

    $pairs.Add([ordered]@{
        targetId = $TargetId
        targetPath = $TargetPath
        mode = $Mode
        comparison = [ordered]@{
          index = $comparisonIndex
          baseRef = Get-OptionalString -Value (Get-NestedValue -Object $Comparison -Path @('base', 'ref'))
          headRef = Get-OptionalString -Value (Get-NestedValue -Object $Comparison -Path @('head', 'ref'))
        }
        sectionKind = $sectionKind
        sectionOrdinal = $sectionOrdinal
        label = $label
        reportHtmlRelativePath = $reportHtmlRelativePath
        baseImageRelativePath = Resolve-RelativePath -Path $baseImagePath -ResultsRoot $ResultsRoot
        headImageRelativePath = Resolve-RelativePath -Path $headImagePath -ResultsRoot $ResultsRoot
        baseByteLength = [int64](Get-Item -LiteralPath $baseImagePath).Length
        headByteLength = [int64](Get-Item -LiteralPath $headImagePath).Length
        sortKey = $sortKey
      }) | Out-Null

    $sectionOrdinal += 1
  }

  return @($pairs | ForEach-Object { $_ })
}

$basePath = (Get-Location).Path
$manifestPathResolved = Resolve-AbsolutePath -Path $TargetRunsManifestPath -BasePath $basePath
$resultsDirResolved = Resolve-AbsolutePath -Path $ResultsDir -BasePath $basePath
$outputPathResolved = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
  Join-Path $resultsDirResolved 'pr-preview-manifest.json'
} else {
  Resolve-AbsolutePath -Path $OutputPath -BasePath $basePath
}

if (-not (Test-Path -LiteralPath $manifestPathResolved -PathType Leaf)) {
  throw "Target-runs manifest not found: $manifestPathResolved"
}
if (-not (Test-Path -LiteralPath $resultsDirResolved -PathType Container)) {
  throw "Results directory not found: $resultsDirResolved"
}

$targetRunsManifest = Read-JsonFile -Path $manifestPathResolved
if ([string]$targetRunsManifest.schema -ne 'comparevi-history/pr-target-runs-manifest@v2') {
  throw "Unsupported target-runs manifest schema in '$manifestPathResolved': $($targetRunsManifest.schema)"
}

$allPreviewPairs = New-Object System.Collections.Generic.List[object]
$targetReceipts = New-Object System.Collections.Generic.List[object]

foreach ($target in @(ConvertTo-ObjectArray -Value $targetRunsManifest.targets)) {
  $targetPreviewPairs = New-Object System.Collections.Generic.List[object]
  $suiteManifestPath = Resolve-ExistingPath -Path (Get-OptionalString -Value (Get-NestedValue -Object $target -Path @('manifestPath'))) -BasePath $basePath -PathType Leaf
  if ($null -ne $suiteManifestPath) {
    $suiteManifest = Read-JsonFile -Path $suiteManifestPath
    foreach ($modeEntry in @(ConvertTo-ObjectArray -Value $suiteManifest.modes)) {
      $modeName = Get-OptionalString -Value $modeEntry.name
      $modeManifestPath = Resolve-ExistingPath -Path (Get-OptionalString -Value $modeEntry.manifestPath) -BasePath $basePath -PathType Leaf
      if ($null -eq $modeManifestPath) {
        continue
      }

      $modeManifest = Read-JsonFile -Path $modeManifestPath
      foreach ($comparison in @(ConvertTo-ObjectArray -Value $modeManifest.comparisons)) {
        $reportHtmlPath = Resolve-ExistingPath -Path (Get-OptionalString -Value (Get-NestedValue -Object $comparison -Path @('result', 'reportHtml'))) -BasePath $basePath -PathType Leaf
        if ($null -eq $reportHtmlPath) {
          $reportHtmlPath = Resolve-ExistingPath -Path (Get-OptionalString -Value (Get-NestedValue -Object $comparison -Path @('result', 'reportPath'))) -BasePath $basePath -PathType Leaf
        }
        if ($null -eq $reportHtmlPath) {
          continue
        }

        foreach ($previewPair in @(Get-ReportPreviewPairs -ReportHtmlPath $reportHtmlPath -ResultsRoot $resultsDirResolved -TargetId ([string]$target.targetId) -TargetPath ([string]$target.targetPath) -Mode $modeName -Comparison $comparison)) {
          $targetPreviewPairs.Add($previewPair) | Out-Null
          $allPreviewPairs.Add($previewPair) | Out-Null
        }
      }
    }
  }

  $targetReceipts.Add([ordered]@{
      targetId = [string]$target.targetId
      targetPath = [string]$target.targetPath
      finalStatus = [string]$target.finalStatus
      finalReason = [string]$target.finalReason
      previewPairCount = $targetPreviewPairs.Count
      previewPairs = @(ConvertTo-PreviewPairArray -Value $targetPreviewPairs)
    }) | Out-Null
}

$orderedPreviewPairs = @(ConvertTo-PreviewPairArray -Value $allPreviewPairs)
$commentPreviewPairs = @(Select-PreviewPairs -PreviewPairs $orderedPreviewPairs -Limit $CommentPreviewPairCap)
$indexPreviewPairs = @(Select-PreviewPairs -PreviewPairs $orderedPreviewPairs -Limit $IndexPreviewPairCap)
$targetReceiptArray = @($targetReceipts | ForEach-Object { $_ })
$orderedPreviewPairArray = @($orderedPreviewPairs | ForEach-Object { $_ })
$commentPreviewPairArray = @($commentPreviewPairs | ForEach-Object { $_ })
$indexPreviewPairArray = @($indexPreviewPairs | ForEach-Object { $_ })

$receipt = [ordered]@{
  schema = 'comparevi-history/pr-preview-manifest@v1'
  generatedAtUtc = [DateTime]::UtcNow.ToString('o')
  targetRunsManifestPath = $manifestPathResolved
  resultsDir = $resultsDirResolved
  summary = [ordered]@{
    targetCount = $targetReceiptArray.Count
    previewPairCount = $orderedPreviewPairs.Count
    commentPreviewPairCap = [int]$CommentPreviewPairCap
    commentSelectionPolicy = 'mode-balanced@v1'
    commentPreviewPairCount = $commentPreviewPairs.Count
    commentPreviewPairOmittedCount = [Math]::Max($orderedPreviewPairs.Count - $commentPreviewPairs.Count, 0)
    indexPreviewPairCap = [int]$IndexPreviewPairCap
    indexSelectionPolicy = 'mode-balanced@v1'
    indexPreviewPairCount = $indexPreviewPairs.Count
    indexPreviewPairOmittedCount = [Math]::Max($orderedPreviewPairs.Count - $indexPreviewPairs.Count, 0)
  }
  targets = $targetReceiptArray
  previewPairs = $orderedPreviewPairArray
  commentPreviewPairs = $commentPreviewPairArray
  indexPreviewPairs = $indexPreviewPairArray
}

$receipt | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $outputPathResolved -Encoding utf8

Write-ActionOutput -Key 'preview-manifest-path' -Value $outputPathResolved
Write-ActionOutput -Key 'preview-pair-count' -Value ([string]$orderedPreviewPairs.Count)
Write-ActionOutput -Key 'comment-preview-pair-count' -Value ([string]$commentPreviewPairs.Count)
Write-ActionOutput -Key 'comment-preview-pair-omitted-count' -Value ([string][Math]::Max($orderedPreviewPairs.Count - $commentPreviewPairs.Count, 0))
Write-ActionOutput -Key 'index-preview-pair-count' -Value ([string]$indexPreviewPairs.Count)
Write-ActionOutput -Key 'index-preview-pair-omitted-count' -Value ([string][Math]::Max($orderedPreviewPairs.Count - $indexPreviewPairs.Count, 0))

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  @(
    '## comparevi-history PR preview manifest'
    ''
    ('- Preview manifest: `{0}`' -f $outputPathResolved)
    ('- Total preview pairs: `{0}`' -f $orderedPreviewPairs.Count)
    ('- Comment preview pairs: `{0}` shown, `{1}` omitted, cap `{2}`' -f $commentPreviewPairs.Count, [Math]::Max($orderedPreviewPairs.Count - $commentPreviewPairs.Count, 0), [int]$CommentPreviewPairCap)
    ('- Index preview pairs: `{0}` shown, `{1}` omitted, cap `{2}`' -f $indexPreviewPairs.Count, [Math]::Max($orderedPreviewPairs.Count - $indexPreviewPairs.Count, 0), [int]$IndexPreviewPairCap)
  ) | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
}

$receipt | ConvertTo-Json -Depth 64
