param(
  [Parameter(Mandatory = $true)]
  [string]$DiscoveryPath,
  [Parameter(Mandatory = $true)]
  [string]$ResultsDir,
  [string]$TargetRunsManifestPath,
  [string]$RunUrl,
  [string]$ArtifactName,
  [string]$GitHubOutputPath,
  [string]$StepSummaryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$stickyMarker = '<!-- comparevi-history:pull-request-diagnostics -->'

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
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $raw = Get-Content -LiteralPath $Path -Raw
  if ([string]::IsNullOrWhiteSpace($raw)) {
    throw "JSON file was empty: $Path"
  }

  return $raw | ConvertFrom-Json -Depth 100
}

function Get-OptionalString {
  param(
    [AllowNull()]
    $Value
  )

  if ($null -eq $Value) {
    return $null
  }

  $stringValue = [string]$Value
  if ([string]::IsNullOrWhiteSpace($stringValue)) {
    return $null
  }

  return $stringValue.Trim()
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

    if ($current -is [System.Collections.IDictionary]) {
      if (-not $current.Contains($segment)) {
        return $Default
      }

      $current = $current[$segment]
      continue
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

  return [System.IO.Path]::GetRelativePath($ResultsRoot, $resolvedPath).Replace('\\', '/')
}

function Escape-Html {
  param([AllowNull()][string]$Value)

  if ($null -eq $Value) {
    return ''
  }

  return [System.Net.WebUtility]::HtmlEncode($Value)
}

function ConvertTo-ShortRef {
  param([AllowNull()][string]$Ref)

  $refValue = Get-OptionalString -Value $Ref
  if ([string]::IsNullOrWhiteSpace($refValue)) {
    return $null
  }

  if ($refValue.Length -le 12) {
    return $refValue
  }

  return $refValue.Substring(0, 12)
}

function Get-ReviewerPreviewComparisonIndex {
  param(
    [Parameter(Mandatory = $true)]
    [object]$PreviewPair
  )

  return [int](Get-NestedValue -Object $PreviewPair -Path @('comparison', 'index') -Default 0)
}

function Get-ReviewerPreviewRevisionContext {
  param(
    [Parameter(Mandatory = $true)]
    [object]$PreviewPair
  )

  $baseShortRef = Get-OptionalString -Value (Get-NestedValue -Object $PreviewPair -Path @('comparison', 'baseShortRef'))
  if ([string]::IsNullOrWhiteSpace($baseShortRef)) {
    $baseShortRef = ConvertTo-ShortRef -Ref (Get-OptionalString -Value (Get-NestedValue -Object $PreviewPair -Path @('comparison', 'baseRef')))
  }

  $headShortRef = Get-OptionalString -Value (Get-NestedValue -Object $PreviewPair -Path @('comparison', 'headShortRef'))
  if ([string]::IsNullOrWhiteSpace($headShortRef)) {
    $headShortRef = ConvertTo-ShortRef -Ref (Get-OptionalString -Value (Get-NestedValue -Object $PreviewPair -Path @('comparison', 'headRef')))
  }

  if ([string]::IsNullOrWhiteSpace($baseShortRef) -and [string]::IsNullOrWhiteSpace($headShortRef)) {
    return $null
  }

  if ([string]::IsNullOrWhiteSpace($baseShortRef)) {
    return $headShortRef
  }

  if ([string]::IsNullOrWhiteSpace($headShortRef)) {
    return $baseShortRef
  }

  return '{0} -> {1}' -f $baseShortRef, $headShortRef
}

function Get-ReviewerPreviewDetailLines {
  param(
    [Parameter(Mandatory = $true)]
    [object]$PreviewPair
  )

  $lines = New-Object System.Collections.Generic.List[string]
  $baseSubject = Get-OptionalString -Value (Get-NestedValue -Object $PreviewPair -Path @('comparison', 'baseSubject'))
  if (-not [string]::IsNullOrWhiteSpace($baseSubject)) {
    $lines.Add('Base: {0}' -f $baseSubject) | Out-Null
  }

  $headSubject = Get-OptionalString -Value (Get-NestedValue -Object $PreviewPair -Path @('comparison', 'headSubject'))
  if (-not [string]::IsNullOrWhiteSpace($headSubject)) {
    $lines.Add('Head: {0}' -f $headSubject) | Out-Null
  }

  return @($lines | ForEach-Object { $_ })
}

function Get-ReviewerPreviewTitle {
  param(
    [Parameter(Mandatory = $true)]
    [object]$PreviewPair
  )

  return [string]$PreviewPair.targetPath
}

function Get-ReviewerPreviewSubtitle {
  param(
    [Parameter(Mandatory = $true)]
    [object]$PreviewPair
  )

  return 'History pair {0}' -f (Get-ReviewerPreviewComparisonIndex -PreviewPair $PreviewPair)
}

function ConvertTo-PreviewPairArray {
  param(
    [AllowNull()]
    $Value
  )

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

function Get-ReviewerPreviewSurfaceLabel {
  param(
    [AllowNull()]
    [string]$SurfaceKind,
    [AllowNull()]
    [string]$FallbackLabel
  )

  switch ($SurfaceKind) {
    'front-panel' { return 'Front panel' }
    'block-diagram' { return 'Block diagram' }
    default {
      if (-not [string]::IsNullOrWhiteSpace($FallbackLabel)) {
        return $FallbackLabel
      }

      return 'Preview'
    }
  }
}

function New-MarkdownChangeDetailsLines {
  param(
    [AllowNull()]
    [object]$ChangeDetails
  )

  if ($null -eq $ChangeDetails) {
    return @()
  }

  $groups = @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $ChangeDetails -Path @('groups') -Default @()))
  $includedCategories = @(
    ConvertTo-ObjectArray -Value (Get-NestedValue -Object $ChangeDetails -Path @('includedCategories') -Default @()) |
      ForEach-Object { Get-OptionalString -Value $_ } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  )

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('#### Change details') | Out-Null
  $lines.Add('') | Out-Null
  if ($includedCategories.Count -gt 0) {
    $lines.Add(('- Included categories: `{0}`' -f ($includedCategories -join '`, `'))) | Out-Null
  }
  foreach ($group in $groups) {
    $heading = Get-OptionalString -Value (Get-NestedValue -Object $group -Path @('heading'))
    $sectionCount = [int](Get-NestedValue -Object $group -Path @('sectionCount') -Default 0)
    $detailCount = [int](Get-NestedValue -Object $group -Path @('detailCount') -Default 0)
    $lines.Add(('- `{0}`: `{1}` details across `{2}` sections' -f $heading, $detailCount, $sectionCount)) | Out-Null
    foreach ($sampleDetail in @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $group -Path @('sampleDetails') -Default @()))) {
      $lines.Add(('  - {0}' -f [string]$sampleDetail)) | Out-Null
    }
    $omittedDetailCount = [int](Get-NestedValue -Object $group -Path @('omittedDetailCount') -Default 0)
    if ($omittedDetailCount -gt 0) {
      $lines.Add(('  - +{0} more details in report' -f $omittedDetailCount)) | Out-Null
    }
  }
  $omittedGroupCount = [int](Get-NestedValue -Object $ChangeDetails -Path @('omittedGroupCount') -Default 0)
  if ($omittedGroupCount -gt 0) {
    $lines.Add(('- Additional change-detail groups omitted: `{0}`' -f $omittedGroupCount)) | Out-Null
  }
  $reportHtmlRelativePath = Get-OptionalString -Value (Get-NestedValue -Object $ChangeDetails -Path @('reportHtmlRelativePath'))
  if (-not [string]::IsNullOrWhiteSpace($reportHtmlRelativePath)) {
    $lines.Add(('- Report: [{0}]({0})' -f $reportHtmlRelativePath)) | Out-Null
  }
  $lines.Add('') | Out-Null
  return @($lines | ForEach-Object { $_ })
}

function New-HtmlChangeDetailsBlock {
  param(
    [AllowNull()]
    [object]$ChangeDetails
  )

  if ($null -eq $ChangeDetails) {
    return ''
  }

  $items = New-Object System.Collections.Generic.List[string]
  $includedCategories = @(
    ConvertTo-ObjectArray -Value (Get-NestedValue -Object $ChangeDetails -Path @('includedCategories') -Default @()) |
      ForEach-Object { Get-OptionalString -Value $_ } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  )
  if ($includedCategories.Count -gt 0) {
    $items.Add('<li><strong>Included categories:</strong> ' + (Escape-Html ($includedCategories -join ', ')) + '</li>') | Out-Null
  }
  foreach ($group in @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $ChangeDetails -Path @('groups') -Default @()))) {
    $heading = Escape-Html (Get-OptionalString -Value (Get-NestedValue -Object $group -Path @('heading')))
    $sectionCount = [int](Get-NestedValue -Object $group -Path @('sectionCount') -Default 0)
    $detailCount = [int](Get-NestedValue -Object $group -Path @('detailCount') -Default 0)
    $sampleList = New-Object System.Collections.Generic.List[string]
    foreach ($sampleDetail in @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $group -Path @('sampleDetails') -Default @()))) {
      $sampleList.Add('<li>' + (Escape-Html ([string]$sampleDetail)) + '</li>') | Out-Null
    }
    $omittedDetailCount = [int](Get-NestedValue -Object $group -Path @('omittedDetailCount') -Default 0)
    if ($omittedDetailCount -gt 0) {
      $sampleList.Add('<li>+' + $omittedDetailCount + ' more details in report</li>') | Out-Null
    }
    $nestedList = if ($sampleList.Count -gt 0) { '<ul>' + ($sampleList -join '') + '</ul>' } else { '' }
    $items.Add('<li><strong>' + $heading + ':</strong> ' + $detailCount + ' details across ' + $sectionCount + ' sections' + $nestedList + '</li>') | Out-Null
  }
  $omittedGroupCount = [int](Get-NestedValue -Object $ChangeDetails -Path @('omittedGroupCount') -Default 0)
  if ($omittedGroupCount -gt 0) {
    $items.Add('<li><strong>Additional change-detail groups omitted:</strong> ' + $omittedGroupCount + '</li>') | Out-Null
  }
  $reportHtmlRelativePath = Get-OptionalString -Value (Get-NestedValue -Object $ChangeDetails -Path @('reportHtmlRelativePath'))
  if (-not [string]::IsNullOrWhiteSpace($reportHtmlRelativePath)) {
    $items.Add('<li><a href="' + (Escape-Html $reportHtmlRelativePath) + '">open change details report</a></li>') | Out-Null
  }

  return '<section class="preview-change-details"><h4>Change details</h4><ul>' + ($items -join '') + '</ul></section>'
}

function New-ReviewerPreviewSurface {
  param(
    [Parameter(Mandatory = $true)]
    [object]$PreviewPair
  )

  $surfaceKind = Get-OptionalString -Value (Get-NestedValue -Object $PreviewPair -Path @('surfaceKind'))
  if ([string]::IsNullOrWhiteSpace($surfaceKind)) {
    switch ([string]$PreviewPair.mode) {
      'front-panel' { $surfaceKind = 'front-panel' }
      'block-diagram' { $surfaceKind = 'block-diagram' }
      default { $surfaceKind = 'preview' }
    }
  }

  return [ordered]@{
    surfaceKind = $surfaceKind
    surfaceLabel = Get-ReviewerPreviewSurfaceLabel -SurfaceKind $surfaceKind -FallbackLabel (Get-OptionalString -Value (Get-NestedValue -Object $PreviewPair -Path @('surfaceLabel') -Default $PreviewPair.label))
    reportHtmlRelativePath = Get-OptionalString -Value $PreviewPair.reportHtmlRelativePath
    baseImageRelativePath = Get-OptionalString -Value $PreviewPair.baseImageRelativePath
    headImageRelativePath = Get-OptionalString -Value $PreviewPair.headImageRelativePath
  }
}

function Get-ReviewerPreviewCardKey {
  param(
    [Parameter(Mandatory = $true)]
    [object]$PreviewPair
  )

  return '{0}|{1}' -f `
    [string]$PreviewPair.targetId, `
    [int](Get-NestedValue -Object $PreviewPair -Path @('comparison', 'index') -Default 0)
}

function New-ReviewerPreviewCards {
  param(
    [AllowEmptyCollection()]
    [object[]]$SelectedPreviewPairs = @(),
    [AllowEmptyCollection()]
    [object[]]$AllPreviewPairs = @(),
    [AllowEmptyCollection()]
    [object[]]$ExistingCards = @()
  )

  if ($ExistingCards.Count -gt 0) {
    return @(
      ConvertTo-ObjectArray -Value $ExistingCards |
        Sort-Object {
          $comparisonIndex = [int](Get-NestedValue -Object $_ -Path @('comparison', 'index') -Default 0)
          '{0}|{1:D4}' -f [string]$_.targetPath, $comparisonIndex
        }
    )
  }

  $orderedAllPreviewPairs = @(ConvertTo-PreviewPairArray -Value $AllPreviewPairs)
  if ($orderedAllPreviewPairs.Count -eq 0) {
    $orderedAllPreviewPairs = @(ConvertTo-PreviewPairArray -Value $SelectedPreviewPairs)
  }

  $cards = New-Object System.Collections.Generic.List[object]
  $seenCards = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($selectedPreviewPair in @(ConvertTo-PreviewPairArray -Value $SelectedPreviewPairs)) {
    $cardKey = Get-ReviewerPreviewCardKey -PreviewPair $selectedPreviewPair
    if (-not $seenCards.Add($cardKey)) {
      continue
    }

    $matchingPairs = @(
      $orderedAllPreviewPairs |
        Where-Object { (Get-ReviewerPreviewCardKey -PreviewPair $_) -eq $cardKey }
    )
    if ($matchingPairs.Count -eq 0) {
      $matchingPairs = @($selectedPreviewPair)
    }

    $surfaces = New-Object System.Collections.Generic.List[object]
    $seenSurfaces = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($matchingPair in $matchingPairs) {
      $surface = New-ReviewerPreviewSurface -PreviewPair $matchingPair
      if ([string]::IsNullOrWhiteSpace([string]$surface.surfaceKind)) {
        continue
      }

      if (-not $seenSurfaces.Add([string]$surface.surfaceKind)) {
        continue
      }

      $surfaces.Add($surface) | Out-Null
    }

    if ($surfaces.Count -eq 0) {
      $surfaces.Add((New-ReviewerPreviewSurface -PreviewPair $selectedPreviewPair)) | Out-Null
    }

    $cards.Add([ordered]@{
        targetId = [string]$selectedPreviewPair.targetId
        targetPath = [string]$selectedPreviewPair.targetPath
        comparison = $selectedPreviewPair.comparison
        surfaces = @($surfaces | ForEach-Object { $_ })
      }) | Out-Null
  }

  return @($cards | ForEach-Object { $_ })
}

function New-MarkdownPreviewGallery {
  param(
    [AllowEmptyCollection()]
    [object[]]$PreviewCards
  )

  if ($PreviewCards.Count -eq 0) {
    return ''
  }

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('## Preview gallery') | Out-Null
  $lines.Add('') | Out-Null
  foreach ($previewCard in @(ConvertTo-ObjectArray -Value $PreviewCards)) {
    $title = Get-ReviewerPreviewTitle -PreviewPair $previewCard
    $subtitle = Get-ReviewerPreviewSubtitle -PreviewPair $previewCard
    $revisionContext = Get-ReviewerPreviewRevisionContext -PreviewPair $previewCard
    $detailLines = @(Get-ReviewerPreviewDetailLines -PreviewPair $previewCard)
    $lines.Add(('### `{0}`' -f $title)) | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add($subtitle) | Out-Null
    $lines.Add('') | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($revisionContext)) {
      $lines.Add(('`{0}`' -f $revisionContext)) | Out-Null
      $lines.Add('') | Out-Null
    }
    foreach ($detailLine in $detailLines) {
      $lines.Add($detailLine) | Out-Null
    }
    if ($detailLines.Count -gt 0) {
      $lines.Add('') | Out-Null
    }
    foreach ($changeDetailLine in @(New-MarkdownChangeDetailsLines -ChangeDetails (Get-NestedValue -Object $previewCard -Path @('changeDetails')))) {
      $lines.Add($changeDetailLine) | Out-Null
    }
    foreach ($surface in @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $previewCard -Path @('surfaces') -Default @()))) {
      $surfaceLabel = Get-ReviewerPreviewSurfaceLabel -SurfaceKind (Get-OptionalString -Value $surface.surfaceKind) -FallbackLabel (Get-OptionalString -Value $surface.surfaceLabel)
      $lines.Add(('#### {0}' -f $surfaceLabel)) | Out-Null
      $lines.Add('') | Out-Null
      $lines.Add('**Base**') | Out-Null
      $lines.Add((
          '![{0}]({1})' -f
            ('{0} base' -f $surfaceLabel),
            [string]$surface.baseImageRelativePath
        )) | Out-Null
      $lines.Add('') | Out-Null
      $lines.Add('**Head**') | Out-Null
      $lines.Add((
          '![{0}]({1})' -f
            ('{0} head' -f $surfaceLabel),
            [string]$surface.headImageRelativePath
        )) | Out-Null
      if (-not [string]::IsNullOrWhiteSpace([string]$surface.reportHtmlRelativePath)) {
        $lines.Add(('- Report: [{0}]({0})' -f [string]$surface.reportHtmlRelativePath)) | Out-Null
      }
      $lines.Add('') | Out-Null
    }
  }

  return $lines -join "`n"
}

function New-HtmlPreviewGallery {
  param(
    [AllowEmptyCollection()]
    [object[]]$PreviewCards
  )

  if ($PreviewCards.Count -eq 0) {
    return ''
  }

  $cards = New-Object System.Collections.Generic.List[string]
  foreach ($previewCard in @(ConvertTo-ObjectArray -Value $PreviewCards)) {
    $title = Get-ReviewerPreviewTitle -PreviewPair $previewCard
    $subtitle = Get-ReviewerPreviewSubtitle -PreviewPair $previewCard
    $comparisonIndex = Get-ReviewerPreviewComparisonIndex -PreviewPair $previewCard
    $revisionContext = Get-ReviewerPreviewRevisionContext -PreviewPair $previewCard
    $detailLines = @(Get-ReviewerPreviewDetailLines -PreviewPair $previewCard)
    $detailHtml = if ($detailLines.Count -eq 0) {
      ''
    } else {
      '<div class="preview-card-history">' + (($detailLines | ForEach-Object { '<p>' + (Escape-Html $_) + '</p>' }) -join '') + '</div>'
    }
    $changeDetailsHtml = New-HtmlChangeDetailsBlock -ChangeDetails (Get-NestedValue -Object $previewCard -Path @('changeDetails'))
    $surfaceBlocks = New-Object System.Collections.Generic.List[string]
    foreach ($surface in @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $previewCard -Path @('surfaces') -Default @()))) {
      $surfaceLabel = Get-ReviewerPreviewSurfaceLabel -SurfaceKind (Get-OptionalString -Value $surface.surfaceKind) -FallbackLabel (Get-OptionalString -Value $surface.surfaceLabel)
      $reportLink = if ([string]::IsNullOrWhiteSpace([string]$surface.reportHtmlRelativePath)) {
        ''
      } else {
        '<p><a href="' + (Escape-Html ([string]$surface.reportHtmlRelativePath)) + '">open ' + (Escape-Html $surfaceLabel.ToLowerInvariant()) + ' report</a></p>'
      }
      $surfaceBlocks.Add(@"
  <section class="preview-surface">
    <h4>$(Escape-Html $surfaceLabel)</h4>
    <div class="preview-image-grid">
      <figure>
        <img alt="$(Escape-Html ($surfaceLabel + ' base'))" src="$(Escape-Html ([string]$surface.baseImageRelativePath))">
        <figcaption>Base</figcaption>
      </figure>
      <figure>
        <img alt="$(Escape-Html ($surfaceLabel + ' head'))" src="$(Escape-Html ([string]$surface.headImageRelativePath))">
        <figcaption>Head</figcaption>
      </figure>
    </div>
    $reportLink
  </section>
"@) | Out-Null
    }
    $cards.Add(@"
<article class="preview-card">
  <h3>$(Escape-Html $title)</h3>
  <p class="preview-card-subtitle">$(Escape-Html $subtitle)</p>
  <div class="preview-card-meta">
    <strong>History pair</strong><span><code>$(Escape-Html ([string]$comparisonIndex))</code></span>
    <strong>Revisions</strong><span><code>$(Escape-Html $revisionContext)</code></span>
  </div>
  $detailHtml
  $changeDetailsHtml
  $($surfaceBlocks -join "`n  ")
</article>
"@) | Out-Null
  }

  return @"
  <section class="preview-gallery">
    <h2>Preview gallery</h2>
    <div class="preview-grid">
      $($cards -join "`n      ")
    </div>
  </section>
"@
}

$basePath = (Get-Location).Path
$discoveryPathResolved = Resolve-AbsolutePath -Path $DiscoveryPath -BasePath $basePath
$resultsDirResolved = Resolve-AbsolutePath -Path $ResultsDir -BasePath $basePath
$targetRunsManifestPathResolved = if ([string]::IsNullOrWhiteSpace($TargetRunsManifestPath)) { $null } else { Resolve-AbsolutePath -Path $TargetRunsManifestPath -BasePath $basePath }
$prRunPath = Join-Path $resultsDirResolved 'pr-run.json'
$publicCommentPath = Join-Path $resultsDirResolved 'pr-comment.md'
$publicStepSummaryPath = Join-Path $resultsDirResolved 'pr-step-summary.md'
$indexMdPath = Join-Path $resultsDirResolved 'index.md'
$indexHtmlPath = Join-Path $resultsDirResolved 'index.html'

if (-not (Test-Path -LiteralPath $discoveryPathResolved -PathType Leaf)) {
  throw "Discovery receipt not found: $discoveryPathResolved"
}

New-Item -ItemType Directory -Path $resultsDirResolved -Force | Out-Null

$discovery = Read-JsonFile -Path $discoveryPathResolved
if ([string]$discovery.schema -ne 'comparevi-history/changed-vi-discovery@v2') {
  throw "Unsupported discovery schema in '$discoveryPathResolved': $($discovery.schema)"
}

$targetManifest = $null
if ($null -ne $targetRunsManifestPathResolved -and (Test-Path -LiteralPath $targetRunsManifestPathResolved -PathType Leaf)) {
  $targetManifest = Read-JsonFile -Path $targetRunsManifestPathResolved
  if ([string]$targetManifest.schema -ne 'comparevi-history/pr-target-runs-manifest@v2') {
    throw "Unsupported target-runs manifest schema in '$targetRunsManifestPathResolved': $($targetManifest.schema)"
  }
}

$policy = Get-NestedValue -Object $discovery -Path @('prPolicy')
$selectionMode = Get-OptionalString -Value (Get-NestedValue -Object $discovery -Path @('executionContext', 'selectionMode'))
$forkBehavior = Get-OptionalString -Value (Get-NestedValue -Object $discovery -Path @('executionContext', 'forkBehavior'))
$emitCommentBody = [bool](Get-NestedValue -Object $policy -Path @('reviewerSurface', 'emitCommentBody') -Default $true)
$emitStepSummary = [bool](Get-NestedValue -Object $policy -Path @('reviewerSurface', 'emitStepSummary') -Default $true)
$fullSurface = Get-OptionalString -Value (Get-NestedValue -Object $policy -Path @('reviewerSurface', 'fullSurface'))
$policyPath = Get-OptionalString -Value (Get-NestedValue -Object $policy -Path @('path'))
$discoveryStatus = [string]$discovery.summary.executionStatus
$discoveryReason = [string]$discovery.summary.executionReason
$changedViCount = [int]$discovery.summary.changedViCount
$eligibleChangedViCount = if ($null -eq $discovery.summary.eligibleChangedViCount) { $changedViCount } else { [int]$discovery.summary.eligibleChangedViCount }
$excludedViCount = if ($null -eq $discovery.summary.excludedViCount) { 0 } else { [int]$discovery.summary.excludedViCount }
$selectedTargetCount = if ($null -eq $discovery.summary.selectedTargetCount) { 0 } else { [int]$discovery.summary.selectedTargetCount }
$overflowed = [bool](Get-NestedValue -Object $discovery -Path @('summary', 'overflowed') -Default $false)
$overflowChangedViCount = if ($null -eq $discovery.summary.overflowChangedViCount) { 0 } else { [int]$discovery.summary.overflowChangedViCount }
$excludedViFiles = @($discovery.excludedViFiles | ForEach-Object { $_ })
$selectedTargets = @($discovery.selectedTargets | ForEach-Object { $_ })

$targets = @()
$executedTargetCount = 0
$failedTargetCount = 0
$totalProcessed = 0
$totalDiffs = 0
$previewManifest = $null
$previewManifestPathResolved = $null
$rawPreviewPairCount = 0
$reviewerPreviewPairCount = 0
$commentPreviewPairCount = 0
$commentPreviewPairOmittedCount = 0
$commentPreviewCardCount = 0
$indexPreviewPairCount = 0
$indexPreviewPairOmittedCount = 0
$indexPreviewCardCount = 0
$commentPreviewPairCap = 0
$indexPreviewPairCap = 0
$indexPreviewCards = @()
$previewTargetPairCountById = @{}
if ($null -ne $targetManifest) {
  $targets = @($targetManifest.targets | ForEach-Object { $_ })
  $executedTargetCount = [int]$targetManifest.summary.executedTargetCount
  $failedTargetCount = [int]$targetManifest.summary.failedTargetCount
  foreach ($target in @($targets)) {
    if ($null -ne $target.totalProcessed) {
      $totalProcessed += [int]$target.totalProcessed
    }
    if ($null -ne $target.totalDiffs) {
      $totalDiffs += [int]$target.totalDiffs
    }
  }

  $previewManifestPathResolved = Join-Path $resultsDirResolved 'pr-preview-manifest.json'
  & (Join-Path $PSScriptRoot 'Write-CompareVIHistoryPullRequestPreviewManifest.ps1') `
    -TargetRunsManifestPath $targetRunsManifestPathResolved `
    -ResultsDir $resultsDirResolved `
    -OutputPath $previewManifestPathResolved | Out-Null
  $previewManifest = Read-JsonFile -Path $previewManifestPathResolved
  if ([string]$previewManifest.schema -ne 'comparevi-history/pr-preview-manifest@v1') {
    throw "Unsupported preview manifest schema in '$previewManifestPathResolved': $($previewManifest.schema)"
  }
  $rawPreviewPairCount = [int](Get-NestedValue -Object $previewManifest -Path @('summary', 'rawPreviewPairCount') -Default $previewManifest.summary.previewPairCount)
  $reviewerPreviewPairCount = [int](Get-NestedValue -Object $previewManifest -Path @('summary', 'reviewerPreviewPairCount') -Default $previewManifest.summary.previewPairCount)
  $commentPreviewPairCap = [int]$previewManifest.summary.commentPreviewPairCap
  $commentPreviewPairCount = [int]$previewManifest.summary.commentPreviewPairCount
  $commentPreviewPairOmittedCount = [int]$previewManifest.summary.commentPreviewPairOmittedCount
  $commentPreviewCardCount = [int](Get-NestedValue -Object $previewManifest -Path @('summary', 'commentPreviewCardCount') -Default 0)
  $indexPreviewPairCap = [int]$previewManifest.summary.indexPreviewPairCap
  $indexPreviewPairCount = [int]$previewManifest.summary.indexPreviewPairCount
  $indexPreviewPairOmittedCount = [int]$previewManifest.summary.indexPreviewPairOmittedCount
  $indexPreviewCardCount = [int](Get-NestedValue -Object $previewManifest -Path @('summary', 'indexPreviewCardCount') -Default 0)
  $indexPreviewCards = @(New-ReviewerPreviewCards `
      -SelectedPreviewPairs @($previewManifest.indexPreviewPairs | ForEach-Object { $_ }) `
      -AllPreviewPairs @($previewManifest.previewPairs | ForEach-Object { $_ }) `
      -ExistingCards @($previewManifest.indexPreviewCards | ForEach-Object { $_ }))
  foreach ($previewTarget in @($previewManifest.targets | ForEach-Object { $_ })) {
    $previewTargetPairCountById[[string]$previewTarget.targetId] = [int]$previewTarget.previewPairCount
  }
}

$finalStatus = 'unknown'
$finalReason = 'unknown'
if ($discoveryStatus -in @('blocked', 'skipped')) {
  $finalStatus = $discoveryStatus
  $finalReason = $discoveryReason
} elseif ($null -eq $targetManifest) {
  $finalStatus = 'failed'
  $finalReason = 'missing-target-runs-manifest'
} elseif ($failedTargetCount -gt 0) {
  $finalStatus = 'failed'
  $finalReason = 'one-or-more-targets-failed'
} elseif ($executedTargetCount -eq 0) {
  $finalStatus = 'skipped'
  $finalReason = 'no-targets-executed'
} else {
  $finalStatus = 'succeeded'
  $finalReason = 'completed'
}

$commentLines = New-Object System.Collections.Generic.List[string]
$commentLines.Add($stickyMarker) | Out-Null
$commentLines.Add('## comparevi-history PR diagnostics') | Out-Null
$commentLines.Add('') | Out-Null
$commentLines.Add(('- Final status: `{0}`' -f $finalStatus)) | Out-Null
$commentLines.Add(('- Final reason: `{0}`' -f $finalReason)) | Out-Null
$commentLines.Add(('- Selection mode: `{0}`' -f $(if ([string]::IsNullOrWhiteSpace($selectionMode)) { 'dynamic-paths' } else { $selectionMode }))) | Out-Null
$commentLines.Add(('- Fork behavior: `{0}`' -f $(if ([string]::IsNullOrWhiteSpace($forkBehavior)) { 'hosted-auto' } else { $forkBehavior }))) | Out-Null
$commentLines.Add(('- PR policy: `{0}`' -f $(if ([string]::IsNullOrWhiteSpace($policyPath)) { 'n/a' } else { $policyPath }))) | Out-Null
$commentLines.Add(('- Changed VIs: `{0}`' -f $changedViCount)) | Out-Null
$commentLines.Add(('- Policy-eligible changed VIs: `{0}`' -f $eligibleChangedViCount)) | Out-Null
$commentLines.Add(('- Selected targets: `{0}`' -f $selectedTargetCount)) | Out-Null
$commentLines.Add(('- Excluded changed VIs: `{0}`' -f $excludedViCount)) | Out-Null
if ($overflowed) {
  $commentLines.Add(('- Overflowed changed VIs: `{0}`' -f $overflowChangedViCount)) | Out-Null
}
$commentLines.Add(('- Executed targets: `{0}`' -f $executedTargetCount)) | Out-Null
$commentLines.Add(('- Failed targets: `{0}`' -f $failedTargetCount)) | Out-Null
$commentLines.Add(('- Total processed pairs: `{0}`' -f $totalProcessed)) | Out-Null
$commentLines.Add(('- Total diffs: `{0}`' -f $totalDiffs)) | Out-Null
if ($reviewerPreviewPairCount -gt 0) {
  $commentLines.Add(('- Reviewer preview gallery: `{0}` history pairs shown, `{1}` omitted, cap `{2}`' -f $commentPreviewCardCount, $commentPreviewPairOmittedCount, $commentPreviewPairCap)) | Out-Null
  if ($rawPreviewPairCount -gt $reviewerPreviewPairCount) {
    $commentLines.Add(('- Raw preview surfaces collapsed for review: `{0}` raw -> `{1}` reviewer-canonical' -f $rawPreviewPairCount, $reviewerPreviewPairCount)) | Out-Null
  }
}
if (-not [string]::IsNullOrWhiteSpace($RunUrl)) {
  $commentLines.Add(('- Workflow run: [view run]({0})' -f $RunUrl)) | Out-Null
}
if (-not [string]::IsNullOrWhiteSpace($ArtifactName)) {
  $commentLines.Add(('- Artifact bundle: `{0}` (open the workflow run above, then download the artifact and start with `index.html` or `index.md`) ' -f $ArtifactName.Trim())) | Out-Null
}
$commentLines.Add('') | Out-Null

if ($selectedTargets.Count -gt 0) {
  $commentLines.Add('### Changed VIs') | Out-Null
  $commentLines.Add('') | Out-Null
  $commentLines.Add('| VI path | Status | Result |') | Out-Null
  $commentLines.Add('| --- | --- | --- |') | Out-Null
  foreach ($selectedTarget in @($selectedTargets | Sort-Object { [string]$_.targetPath })) {
    $resultTarget = @($targets | Where-Object { [string]$_.targetId -eq [string]$selectedTarget.targetId } | Select-Object -First 1)
    $statusLabel = if ($null -eq $resultTarget) { 'not-executed' } else { [string]$resultTarget.finalStatus }
    $commentLines.Add(('| `{0}` | `{1}` | `{2}` |' -f [string]$selectedTarget.targetPath, [string]$selectedTarget.changeStatus, $statusLabel)) | Out-Null
  }
  $commentLines.Add('') | Out-Null
}

if ($excludedViFiles.Count -gt 0) {
  $commentLines.Add('### Excluded changed VIs') | Out-Null
  $commentLines.Add('') | Out-Null
  foreach ($excluded in @($excludedViFiles | Sort-Object { [string]$_.currentPath })) {
    $commentLines.Add(('- `{0}` ({1}) reason=`{2}`' -f [string]$excluded.currentPath, [string]$excluded.status, [string]$excluded.exclusionReason)) | Out-Null
  }
  $commentLines.Add('') | Out-Null
}

$commentLines.Add('The full unsuppressed history suite lives in the uploaded artifact bundle. Use the workflow run entry above, download the artifact, and start at `index.html` or `index.md`.') | Out-Null
$commentBody = $commentLines -join "`n"
if ($emitCommentBody) {
  $commentBody | Set-Content -LiteralPath $publicCommentPath -Encoding utf8
}

$indexLines = New-Object System.Collections.Generic.List[string]
$indexLines.Add('# comparevi-history PR diagnostics index') | Out-Null
$indexLines.Add('') | Out-Null
$indexLines.Add(('- Final status: `{0}`' -f $finalStatus)) | Out-Null
$indexLines.Add(('- Final reason: `{0}`' -f $finalReason)) | Out-Null
if (-not [string]::IsNullOrWhiteSpace($RunUrl)) {
  $indexLines.Add(('- Workflow run: [{0}]({0})' -f $RunUrl)) | Out-Null
}
if (-not [string]::IsNullOrWhiteSpace($ArtifactName)) {
  $indexLines.Add(('- Artifact bundle: `{0}`' -f $ArtifactName.Trim())) | Out-Null
}
$indexLines.Add(('- Discovery receipt: [changed-vi-discovery.json](changed-vi-discovery.json)')) | Out-Null
$indexLines.Add(('- Aggregate receipt: [pr-run.json](pr-run.json)')) | Out-Null
if ($null -ne $previewManifestPathResolved -and (Test-Path -LiteralPath $previewManifestPathResolved -PathType Leaf)) {
  $indexLines.Add(('- Preview manifest: [pr-preview-manifest.json](pr-preview-manifest.json)')) | Out-Null
}
if ($reviewerPreviewPairCount -gt 0) {
  $indexLines.Add(('- Reviewer preview gallery: `{0}` history pairs shown, `{1}` omitted, cap `{2}`' -f $indexPreviewCardCount, $indexPreviewPairOmittedCount, $indexPreviewPairCap)) | Out-Null
  if ($rawPreviewPairCount -gt $reviewerPreviewPairCount) {
    $indexLines.Add(('- Raw preview surfaces collapsed for review: `{0}` raw -> `{1}` reviewer-canonical' -f $rawPreviewPairCount, $reviewerPreviewPairCount)) | Out-Null
  }
}
$indexLines.Add('') | Out-Null
$previewGalleryMarkdown = New-MarkdownPreviewGallery -PreviewCards $indexPreviewCards
if (-not [string]::IsNullOrWhiteSpace($previewGalleryMarkdown)) {
  $indexLines.Add($previewGalleryMarkdown) | Out-Null
  $indexLines.Add('') | Out-Null
}
$indexLines.Add('| VI path | Status | Public run | Shared evidence | History report | Indexable surfaces |') | Out-Null
$indexLines.Add('| --- | --- | --- | --- | --- | --- |') | Out-Null
foreach ($target in @($targets | Sort-Object { [string]$_.targetPath }, { [string]$_.targetId })) {
  $publicRunRel = Resolve-RelativePath -Path ([string]$target.publicRunPath) -ResultsRoot $resultsDirResolved
  $sharedEvidenceRel = Resolve-RelativePath -Path ([string]$target.sharedEvidencePath) -ResultsRoot $resultsDirResolved
  $historyHtmlRel = Resolve-RelativePath -Path ([string]$target.historyReportHtmlPath) -ResultsRoot $resultsDirResolved
  $modeSummaryRel = Resolve-RelativePath -Path ([string]$target.modeSummaryPath) -ResultsRoot $resultsDirResolved
  $surfaceLinks = @()
  if ($modeSummaryRel) {
    $surfaceLinks += "[mode summary]($modeSummaryRel)"
  }
  $requestRel = Resolve-RelativePath -Path ([string]$target.requestPath) -ResultsRoot $resultsDirResolved
  if ($requestRel) {
    $surfaceLinks += "[request]($requestRel)"
  }
  $indexLines.Add((
    '| `{0}` | `{1}` | {2} | {3} | {4} | {5} |' -f
      [string]$target.targetPath,
      [string]$target.finalStatus,
      $(if ($publicRunRel) { "[public run]($publicRunRel)" } else { 'n/a' }),
      $(if ($sharedEvidenceRel) { "[shared evidence]($sharedEvidenceRel)" } else { 'n/a' }),
      $(if ($historyHtmlRel) { "[history report]($historyHtmlRel)" } else { 'n/a' }),
      $(if ($surfaceLinks.Count -gt 0) { $surfaceLinks -join ', ' } else { 'n/a' })
  )) | Out-Null
}
if ($targets.Count -eq 0) {
  $indexLines.Add('| n/a | n/a | n/a | n/a | n/a | n/a |') | Out-Null
}
$indexLines.Add('') | Out-Null
$indexMarkdown = $indexLines -join "`n"
$indexMarkdown | Set-Content -LiteralPath $indexMdPath -Encoding utf8

$htmlRows = New-Object System.Collections.Generic.List[string]
foreach ($target in @($targets | Sort-Object { [string]$_.targetPath }, { [string]$_.targetId })) {
  $publicRunRel = Resolve-RelativePath -Path ([string]$target.publicRunPath) -ResultsRoot $resultsDirResolved
  $sharedEvidenceRel = Resolve-RelativePath -Path ([string]$target.sharedEvidencePath) -ResultsRoot $resultsDirResolved
  $historyHtmlRel = Resolve-RelativePath -Path ([string]$target.historyReportHtmlPath) -ResultsRoot $resultsDirResolved
  $modeSummaryRel = Resolve-RelativePath -Path ([string]$target.modeSummaryPath) -ResultsRoot $resultsDirResolved
  $requestRel = Resolve-RelativePath -Path ([string]$target.requestPath) -ResultsRoot $resultsDirResolved
  $surfaceParts = New-Object System.Collections.Generic.List[string]
  if ($modeSummaryRel) {
    $surfaceParts.Add('<a href="' + (Escape-Html $modeSummaryRel) + '">mode summary</a>') | Out-Null
  }
  if ($requestRel) {
    $surfaceParts.Add('<a href="' + (Escape-Html $requestRel) + '">request</a>') | Out-Null
  }
  $htmlRows.Add((
    '<tr><td><code>{0}</code></td><td><code>{1}</code></td><td>{2}</td><td>{3}</td><td>{4}</td><td>{5}</td></tr>' -f
      (Escape-Html ([string]$target.targetPath)),
      (Escape-Html ([string]$target.finalStatus)),
      $(if ($publicRunRel) { '<a href="' + (Escape-Html $publicRunRel) + '">public run</a>' } else { 'n/a' }),
      $(if ($sharedEvidenceRel) { '<a href="' + (Escape-Html $sharedEvidenceRel) + '">shared evidence</a>' } else { 'n/a' }),
      $(if ($historyHtmlRel) { '<a href="' + (Escape-Html $historyHtmlRel) + '">history report</a>' } else { 'n/a' }),
      $(if ($surfaceParts.Count -gt 0) { $surfaceParts -join ', ' } else { 'n/a' })
  )) | Out-Null
}
if ($htmlRows.Count -eq 0) {
  $htmlRows.Add('<tr><td colspan="6">No target results were produced for this pull request.</td></tr>') | Out-Null
}

$indexHtml = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>comparevi-history PR diagnostics index</title>
  <style>
    body { font-family: Segoe UI, sans-serif; margin: 2rem; color: #1f2933; background: #f8fafc; }
    code { background: #e2e8f0; padding: 0.1rem 0.3rem; border-radius: 4px; }
    table { width: 100%; border-collapse: collapse; margin-top: 1rem; background: #ffffff; }
    th, td { border: 1px solid #cbd5e1; padding: 0.6rem; text-align: left; vertical-align: top; }
    th { background: #e2e8f0; }
    h1 { margin-top: 0; }
    ul { padding-left: 1.2rem; }
    .preview-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(24rem, 1fr)); gap: 1rem; margin: 1.5rem 0; }
    .preview-card { background: #ffffff; border: 1px solid #cbd5e1; padding: 1rem; }
    .preview-card-subtitle { color: #334155; margin-top: -0.35rem; margin-bottom: 1rem; }
    .preview-card-meta { display: grid; grid-template-columns: max-content 1fr; gap: 0.25rem 0.75rem; margin-bottom: 1rem; }
    .preview-surface + .preview-surface { margin-top: 1rem; }
    .preview-surface h4 { margin-bottom: 0.75rem; }
    .preview-image-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 0.75rem; }
    .preview-image-grid figure { margin: 0; }
    .preview-image-grid img { max-width: 100%; height: auto; border: 1px solid #cbd5e1; background: #ffffff; }
    .preview-image-grid figcaption { font-size: 0.85rem; color: #52606d; margin-top: 0.35rem; }
  </style>
</head>
<body>
  <h1>comparevi-history PR diagnostics index</h1>
  <ul>
    <li>Final status: <code>$(Escape-Html $finalStatus)</code></li>
    <li>Final reason: <code>$(Escape-Html $finalReason)</code></li>
    $(if (-not [string]::IsNullOrWhiteSpace($RunUrl)) { '<li>Workflow run: <a href="' + (Escape-Html $RunUrl) + '">' + (Escape-Html $RunUrl) + '</a></li>' } else { '' })
    $(if (-not [string]::IsNullOrWhiteSpace($ArtifactName)) { '<li>Artifact bundle: <code>' + (Escape-Html $ArtifactName.Trim()) + '</code></li>' } else { '' })
    <li>Discovery receipt: <a href="changed-vi-discovery.json">changed-vi-discovery.json</a></li>
    <li>Aggregate receipt: <a href="pr-run.json">pr-run.json</a></li>
    $(if ($null -ne $previewManifestPathResolved -and (Test-Path -LiteralPath $previewManifestPathResolved -PathType Leaf)) { '<li>Preview manifest: <a href="pr-preview-manifest.json">pr-preview-manifest.json</a></li>' } else { '' })
    $(if ($reviewerPreviewPairCount -gt 0) { '<li>Reviewer preview gallery: <code>' + $indexPreviewCardCount + '</code> history pairs shown, <code>' + $indexPreviewPairOmittedCount + '</code> omitted, cap <code>' + $indexPreviewPairCap + '</code></li>' } else { '' })
    $(if ($rawPreviewPairCount -gt $reviewerPreviewPairCount) { '<li>Raw preview surfaces collapsed for review: <code>' + $rawPreviewPairCount + '</code> raw -> <code>' + $reviewerPreviewPairCount + '</code> reviewer-canonical</li>' } else { '' })
  </ul>
  $(New-HtmlPreviewGallery -PreviewCards $indexPreviewCards)
  <table>
    <thead>
      <tr>
        <th>VI path</th>
        <th>Status</th>
        <th>Public run</th>
        <th>Shared evidence</th>
        <th>History report</th>
        <th>Indexable surfaces</th>
      </tr>
    </thead>
    <tbody>
      $($htmlRows -join "`n      ")
    </tbody>
  </table>
</body>
</html>
"@
$indexHtml | Set-Content -LiteralPath $indexHtmlPath -Encoding utf8

$stepSummaryLines = New-Object System.Collections.Generic.List[string]
$stepSummaryLines.Add('## comparevi-history automatic pull request run') | Out-Null
$stepSummaryLines.Add('') | Out-Null
$stepSummaryLines.Add(('- Final status: `{0}`' -f $finalStatus)) | Out-Null
$stepSummaryLines.Add(('- Final reason: `{0}`' -f $finalReason)) | Out-Null
$stepSummaryLines.Add(('- Discovery receipt: `{0}`' -f $discoveryPathResolved)) | Out-Null
$stepSummaryLines.Add(('- Aggregate receipt: `{0}`' -f $prRunPath)) | Out-Null
$stepSummaryLines.Add(('- Index markdown: `{0}`' -f $indexMdPath)) | Out-Null
$stepSummaryLines.Add(('- Index HTML: `{0}`' -f $indexHtmlPath)) | Out-Null
$stepSummaryLines.Add(('- Preview manifest: `{0}`' -f $(if ($null -eq $previewManifestPathResolved) { 'n/a' } else { $previewManifestPathResolved }))) | Out-Null
$stepSummaryLines.Add(('- Reviewer preview gallery: `{0}` history pairs shown, `{1}` omitted, cap `{2}`' -f $commentPreviewCardCount, $commentPreviewPairOmittedCount, $commentPreviewPairCap)) | Out-Null
$stepSummaryLines.Add(('- Index preview gallery: `{0}` history pairs shown, `{1}` omitted, cap `{2}`' -f $indexPreviewCardCount, $indexPreviewPairOmittedCount, $indexPreviewPairCap)) | Out-Null
if ($rawPreviewPairCount -gt $reviewerPreviewPairCount) {
  $stepSummaryLines.Add(('- Raw preview surfaces collapsed for review: `{0}` raw -> `{1}` reviewer-canonical' -f $rawPreviewPairCount, $reviewerPreviewPairCount)) | Out-Null
}
$stepSummaryLines.Add(('- Public comment body enabled: `{0}`' -f $emitCommentBody.ToString().ToLowerInvariant())) | Out-Null
$stepSummaryLines.Add(('- Public step summary enabled: `{0}`' -f $emitStepSummary.ToString().ToLowerInvariant())) | Out-Null
$stepSummaryLines.Add('') | Out-Null
$stepSummaryLines.Add($commentBody) | Out-Null
$stepSummaryContent = $stepSummaryLines -join "`n"
if ($emitStepSummary) {
  $stepSummaryContent | Set-Content -LiteralPath $publicStepSummaryPath -Encoding utf8
}

$receiptTargets = New-Object System.Collections.Generic.List[object]
foreach ($target in @($targets)) {
  $receiptTargets.Add([ordered]@{
      targetId = [string]$target.targetId
      targetSource = Get-OptionalString -Value $target.targetSource
      targetPath = [string]$target.targetPath
      requestedModes = @(
        @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $target -Path @('requestedModes'))) |
          ForEach-Object { Get-OptionalString -Value $_ } |
          Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
      )
      requestedModeSource = Get-OptionalString -Value (Get-NestedValue -Object $target -Path @('requestedModeSource'))
      sourceBranchRef = Get-OptionalString -Value (Get-NestedValue -Object $target -Path @('sourceBranchRef'))
      keepArtifactsOnNoDiff = [bool](Get-NestedValue -Object $target -Path @('keepArtifactsOnNoDiff') -Default $false)
      currentPath = Get-OptionalString -Value $target.currentPath
      previousPath = Get-OptionalString -Value $target.previousPath
      changeStatus = Get-OptionalString -Value $target.changeStatus
      finalStatus = [string]$target.finalStatus
      finalReason = [string]$target.finalReason
      requestPath = Get-OptionalString -Value $target.requestPath
      publicRunPath = Get-OptionalString -Value $target.publicRunPath
      sharedEvidencePath = Get-OptionalString -Value $target.sharedEvidencePath
      historySummaryJsonPath = Get-OptionalString -Value $target.historySummaryJsonPath
      historyReportMdPath = Get-OptionalString -Value $target.historyReportMdPath
      historyReportHtmlPath = Get-OptionalString -Value $target.historyReportHtmlPath
      modeSummaryJsonPath = Get-OptionalString -Value $target.modeSummaryJsonPath
      modeSummaryPath = Get-OptionalString -Value $target.modeSummaryPath
      manifestPath = Get-OptionalString -Value (Get-NestedValue -Object $target -Path @('manifestPath'))
      totalProcessed = if ($null -eq $target.totalProcessed) { $null } else { [int]$target.totalProcessed }
      totalDiffs = if ($null -eq $target.totalDiffs) { $null } else { [int]$target.totalDiffs }
      previewPairCount = if ($previewTargetPairCountById.ContainsKey([string]$target.targetId)) { [int]$previewTargetPairCountById[[string]$target.targetId] } else { 0 }
    }) | Out-Null
}

$receipt = [ordered]@{
  schema = 'comparevi-history/pr-run@v2'
  generatedAtUtc = [DateTime]::UtcNow.ToString('o')
  pullRequest = [ordered]@{
    number = [int]$discovery.pullRequest.number
    htmlUrl = Get-OptionalString -Value $discovery.pullRequest.htmlUrl
    baseRepository = [string]$discovery.pullRequest.baseRepository
    baseRef = [string]$discovery.pullRequest.baseRef
    baseSha = [string]$discovery.pullRequest.baseSha
    headRepository = [string]$discovery.pullRequest.headRepository
    headRef = [string]$discovery.pullRequest.headRef
    headSha = [string]$discovery.pullRequest.headSha
    isFork = [bool]$discovery.pullRequest.isFork
  }
  prPolicy = $policy
  executionContext = [ordered]@{
    selectionMode = $(if ([string]::IsNullOrWhiteSpace($selectionMode)) { 'dynamic-paths' } else { $selectionMode })
    forkBehavior = $(if ([string]::IsNullOrWhiteSpace($forkBehavior)) { 'hosted-auto' } else { $forkBehavior })
    fullSurface = $(if ([string]::IsNullOrWhiteSpace($fullSurface)) { 'artifact-index' } else { $fullSurface })
  }
  discovery = [ordered]@{
    schema = 'comparevi-history/changed-vi-discovery@v2'
    path = $discoveryPathResolved
    status = $discoveryStatus
    reason = $discoveryReason
    changedViCount = $changedViCount
    eligibleChangedViCount = $eligibleChangedViCount
    excludedViCount = $excludedViCount
    selectedTargetCount = $selectedTargetCount
    overflowed = $overflowed
    overflowChangedViCount = $overflowChangedViCount
  }
  outputs = [ordered]@{
    resultsDir = $resultsDirResolved
    prRunPath = $prRunPath
    publicCommentPath = if ($emitCommentBody) { $publicCommentPath } else { $null }
    publicStepSummaryPath = if ($emitStepSummary) { $publicStepSummaryPath } else { $null }
    targetRunsManifestPath = if ($null -eq $targetManifest) { $null } else { $targetRunsManifestPathResolved }
    previewManifestPath = if ($null -eq $previewManifestPathResolved) { $null } else { $previewManifestPathResolved }
    indexMarkdownPath = $indexMdPath
    indexHtmlPath = $indexHtmlPath
    workflowRunUrl = if ([string]::IsNullOrWhiteSpace($RunUrl)) { $null } else { $RunUrl }
    artifactName = if ([string]::IsNullOrWhiteSpace($ArtifactName)) { $null } else { $ArtifactName.Trim() }
  }
  summary = [ordered]@{
    finalStatus = $finalStatus
    finalReason = $finalReason
    changedViCount = $changedViCount
    eligibleChangedViCount = $eligibleChangedViCount
    excludedViCount = $excludedViCount
    selectedTargetCount = $selectedTargetCount
    overflowed = $overflowed
    overflowChangedViCount = $overflowChangedViCount
    executedTargetCount = $executedTargetCount
    failedTargetCount = $failedTargetCount
    totalProcessed = $totalProcessed
    totalDiffs = $totalDiffs
    previewPairCount = $rawPreviewPairCount
    rawPreviewPairCount = $rawPreviewPairCount
    reviewerPreviewPairCount = $reviewerPreviewPairCount
    commentPreviewPairCap = $commentPreviewPairCap
    commentPreviewPairCount = $commentPreviewPairCount
    commentPreviewPairOmittedCount = $commentPreviewPairOmittedCount
    indexPreviewPairCap = $indexPreviewPairCap
    indexPreviewPairCount = $indexPreviewPairCount
    indexPreviewPairOmittedCount = $indexPreviewPairOmittedCount
  }
  excludedViFiles = @(
    $excludedViFiles |
      ForEach-Object {
        [ordered]@{
          status = [string]$_.status
          currentPath = [string]$_.currentPath
          previousPath = Get-OptionalString -Value $_.previousPath
          exclusionReason = [string]$_.exclusionReason
        }
      }
  )
  targets = @($receiptTargets | ForEach-Object { $_ })
}

$receipt | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $prRunPath -Encoding utf8

Write-ActionOutput -Key 'pr-run-path' -Value $prRunPath
Write-ActionOutput -Key 'public-comment-path' -Value $(if ($emitCommentBody) { $publicCommentPath } else { '' })
Write-ActionOutput -Key 'public-step-summary-path' -Value $(if ($emitStepSummary) { $publicStepSummaryPath } else { '' })
Write-ActionOutput -Key 'preview-manifest-path' -Value $(if ($null -eq $previewManifestPathResolved) { '' } else { $previewManifestPathResolved })
Write-ActionOutput -Key 'index-markdown-path' -Value $indexMdPath
Write-ActionOutput -Key 'index-html-path' -Value $indexHtmlPath
Write-ActionOutput -Key 'results-dir' -Value $resultsDirResolved
Write-ActionOutput -Key 'final-status' -Value $finalStatus
Write-ActionOutput -Key 'final-reason' -Value $finalReason

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  $stepSummaryContent | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
}

$receipt | ConvertTo-Json -Depth 64
