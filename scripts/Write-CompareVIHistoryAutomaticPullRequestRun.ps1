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

function Get-ReportAnchorId {
  param(
    [AllowNull()]
    [string]$Path
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }

  $hashIndex = $Path.IndexOf('#', [System.StringComparison]::Ordinal)
  if ($hashIndex -lt 0 -or $hashIndex -ge ($Path.Length - 1)) {
    return $null
  }

  return $Path.Substring($hashIndex + 1)
}

function Add-AnchorToRelativePath {
  param(
    [AllowNull()]
    [string]$Path,
    [AllowNull()]
    [string]$AnchorId
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }

  if ([string]::IsNullOrWhiteSpace($AnchorId)) {
    return $Path
  }

  return '{0}#{1}' -f $Path, $AnchorId
}

function Resolve-RelativeLinkFromPage {
  param(
    [Parameter(Mandatory = $true)]
    [string]$PageRelativePath,
    [AllowNull()]
    [string]$TargetRelativePath
  )

  if ([string]::IsNullOrWhiteSpace($TargetRelativePath)) {
    return $null
  }

  $anchorId = Get-ReportAnchorId -Path $TargetRelativePath
  $pathWithoutAnchor = $TargetRelativePath
  $hashIndex = $TargetRelativePath.IndexOf('#', [System.StringComparison]::Ordinal)
  if ($hashIndex -ge 0) {
    $pathWithoutAnchor = $TargetRelativePath.Substring(0, $hashIndex)
  }

  $pageDirectory = [System.IO.Path]::GetDirectoryName(($PageRelativePath -replace '/', '\'))
  $targetPath = $pathWithoutAnchor -replace '/', '\'
  $relativePath = if ([string]::IsNullOrWhiteSpace($pageDirectory)) {
    $targetPath
  } else {
    [System.IO.Path]::GetRelativePath($pageDirectory, $targetPath)
  }

  return Add-AnchorToRelativePath -Path ($relativePath.Replace('\', '/')) -AnchorId $anchorId
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

function ConvertTo-Slug {
  param(
    [AllowNull()]
    [string]$Value,
    [string]$Fallback = 'item'
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

function Get-WorkspaceCardAnchorId {
  param(
    [Parameter(Mandatory = $true)]
    [object]$PreviewCard
  )

  $comparisonIndex = Get-ReviewerPreviewComparisonIndex -PreviewPair $PreviewCard
  $targetSlug = ConvertTo-Slug -Value (Get-OptionalString -Value $PreviewCard.targetPath) -Fallback (ConvertTo-Slug -Value (Get-OptionalString -Value $PreviewCard.targetId) -Fallback 'target')
  return 'history-pair-{0:D2}-{1}' -f $comparisonIndex, $targetSlug
}

function Get-WorkspacePairPageRootRelativePath {
  param(
    [Parameter(Mandatory = $true)]
    [object]$PreviewCard,
    [Parameter(Mandatory = $true)]
    [int]$Ordinal
  )

  return 'history-pairs/{0:D3}-{1}' -f $Ordinal, (Get-WorkspaceCardAnchorId -PreviewCard $PreviewCard)
}

function Get-WorkspacePairPageHtmlRelativePath {
  param(
    [Parameter(Mandatory = $true)]
    [object]$PreviewCard,
    [Parameter(Mandatory = $true)]
    [int]$Ordinal
  )

  return '{0}/index.html' -f (Get-WorkspacePairPageRootRelativePath -PreviewCard $PreviewCard -Ordinal $Ordinal)
}

function Get-WorkspacePairPageMarkdownRelativePath {
  param(
    [Parameter(Mandatory = $true)]
    [object]$PreviewCard,
    [Parameter(Mandatory = $true)]
    [int]$Ordinal
  )

  return '{0}/index.md' -f (Get-WorkspacePairPageRootRelativePath -PreviewCard $PreviewCard -Ordinal $Ordinal)
}

function Get-WorkspaceSurfaceReportLink {
  param(
    [Parameter(Mandatory = $true)]
    [object]$PreviewCard,
    [Parameter(Mandatory = $true)]
    [string]$SurfaceKind
  )

  $surface = @(
    ConvertTo-ObjectArray -Value (Get-NestedValue -Object $PreviewCard -Path @('surfaces') -Default @()) |
      Where-Object { [string]$_.surfaceKind -eq $SurfaceKind } |
      Select-Object -First 1
  )
  if ($null -eq $surface) {
    return $null
  }

  return Get-OptionalString -Value $surface.reportHtmlRelativePath
}

function Get-WorkspaceTargetLinks {
  param(
    [Parameter(Mandatory = $true)]
    [object]$PreviewCard,
    [AllowEmptyCollection()]
    [object[]]$Targets = @(),
    [Parameter(Mandatory = $true)]
    [string]$ResultsRoot
  )

  $target = @(
    ConvertTo-ObjectArray -Value $Targets |
      Where-Object { [string]$_.targetId -eq [string]$PreviewCard.targetId } |
      Select-Object -First 1
  )
  if ($null -eq $target) {
    return [ordered]@{}
  }

  return [ordered]@{
    publicRun = Resolve-RelativePath -Path ([string]$target.publicRunPath) -ResultsRoot $ResultsRoot
    sharedEvidence = Resolve-RelativePath -Path ([string]$target.sharedEvidencePath) -ResultsRoot $ResultsRoot
    historyReport = Resolve-RelativePath -Path ([string]$target.historyReportHtmlPath) -ResultsRoot $ResultsRoot
    modeSummary = Resolve-RelativePath -Path ([string]$target.modeSummaryPath) -ResultsRoot $ResultsRoot
    request = Resolve-RelativePath -Path ([string]$target.requestPath) -ResultsRoot $ResultsRoot
  }
}

function Get-WorkspaceReviewerHeadline {
  param(
    [Parameter(Mandatory = $true)]
    [object]$PreviewCard
  )

  return Get-OptionalString -Value (Get-NestedValue -Object $PreviewCard -Path @('reviewerSummary', 'headline'))
}

function Get-WorkspaceReviewerSeverity {
  param(
    [Parameter(Mandatory = $true)]
    [object]$PreviewCard
  )

  $severity = Get-OptionalString -Value (Get-NestedValue -Object $PreviewCard -Path @('reviewerSummary', 'overallSeverity'))
  if ([string]::IsNullOrWhiteSpace($severity)) {
    return 'unknown'
  }

  return $severity
}

function New-MarkdownWorkspaceQuickLinkLine {
  param(
    [Parameter(Mandatory = $true)]
    [object]$PreviewCard,
    [AllowEmptyCollection()]
    [object[]]$Targets = @(),
    [Parameter(Mandatory = $true)]
    [string]$ResultsRoot
  )

  $linkItems = New-Object System.Collections.Generic.List[string]
  $linkItems.Add(('[card](#{0})' -f (Get-WorkspaceCardAnchorId -PreviewCard $PreviewCard))) | Out-Null

  $frontPanelLink = Get-WorkspaceSurfaceReportLink -PreviewCard $PreviewCard -SurfaceKind 'front-panel'
  if (-not [string]::IsNullOrWhiteSpace($frontPanelLink)) {
    $linkItems.Add(('[front panel]({0})' -f $frontPanelLink)) | Out-Null
  }

  $blockDiagramLink = Get-WorkspaceSurfaceReportLink -PreviewCard $PreviewCard -SurfaceKind 'block-diagram'
  if (-not [string]::IsNullOrWhiteSpace($blockDiagramLink)) {
    $linkItems.Add(('[block diagram]({0})' -f $blockDiagramLink)) | Out-Null
  }

  $changeDetailsLink = Get-OptionalString -Value (Get-NestedValue -Object $PreviewCard -Path @('changeDetails', 'reportHtmlRelativePath'))
  if (-not [string]::IsNullOrWhiteSpace($changeDetailsLink)) {
    $linkItems.Add(('[change details]({0})' -f $changeDetailsLink)) | Out-Null
  }

  $targetLinks = Get-WorkspaceTargetLinks -PreviewCard $PreviewCard -Targets $Targets -ResultsRoot $ResultsRoot
  foreach ($key in @('historyReport', 'sharedEvidence', 'publicRun', 'modeSummary', 'request')) {
    $path = Get-OptionalString -Value (Get-NestedValue -Object $targetLinks -Path @($key))
    if ([string]::IsNullOrWhiteSpace($path)) {
      continue
    }

    $label = switch ($key) {
      'historyReport' { 'history report' }
      'sharedEvidence' { 'shared evidence' }
      'publicRun' { 'public run' }
      'modeSummary' { 'mode summary' }
      'request' { 'request' }
      default { $key }
    }
    $linkItems.Add(('[{0}]({1})' -f $label, $path)) | Out-Null
  }

  if ($linkItems.Count -eq 0) {
    return $null
  }

  return 'Quick links: {0}' -f ($linkItems -join ', ')
}

function New-HtmlWorkspaceQuickLinks {
  param(
    [Parameter(Mandatory = $true)]
    [object]$PreviewCard,
    [AllowEmptyCollection()]
    [object[]]$Targets = @(),
    [Parameter(Mandatory = $true)]
    [string]$ResultsRoot
  )

  $links = New-Object System.Collections.Generic.List[string]
  $links.Add('<a href="#' + (Escape-Html (Get-WorkspaceCardAnchorId -PreviewCard $PreviewCard)) + '">card</a>') | Out-Null

  $frontPanelLink = Get-WorkspaceSurfaceReportLink -PreviewCard $PreviewCard -SurfaceKind 'front-panel'
  if (-not [string]::IsNullOrWhiteSpace($frontPanelLink)) {
    $links.Add('<a href="' + (Escape-Html $frontPanelLink) + '">front panel</a>') | Out-Null
  }

  $blockDiagramLink = Get-WorkspaceSurfaceReportLink -PreviewCard $PreviewCard -SurfaceKind 'block-diagram'
  if (-not [string]::IsNullOrWhiteSpace($blockDiagramLink)) {
    $links.Add('<a href="' + (Escape-Html $blockDiagramLink) + '">block diagram</a>') | Out-Null
  }

  $changeDetailsLink = Get-OptionalString -Value (Get-NestedValue -Object $PreviewCard -Path @('changeDetails', 'reportHtmlRelativePath'))
  if (-not [string]::IsNullOrWhiteSpace($changeDetailsLink)) {
    $links.Add('<a href="' + (Escape-Html $changeDetailsLink) + '">change details</a>') | Out-Null
  }

  $targetLinks = Get-WorkspaceTargetLinks -PreviewCard $PreviewCard -Targets $Targets -ResultsRoot $ResultsRoot
  foreach ($key in @('historyReport', 'sharedEvidence', 'publicRun', 'modeSummary', 'request')) {
    $path = Get-OptionalString -Value (Get-NestedValue -Object $targetLinks -Path @($key))
    if ([string]::IsNullOrWhiteSpace($path)) {
      continue
    }

    $label = switch ($key) {
      'historyReport' { 'history report' }
      'sharedEvidence' { 'shared evidence' }
      'publicRun' { 'public run' }
      'modeSummary' { 'mode summary' }
      'request' { 'request' }
      default { $key }
    }
    $links.Add('<a href="' + (Escape-Html $path) + '">' + (Escape-Html $label) + '</a>') | Out-Null
  }

  if ($links.Count -eq 0) {
    return ''
  }

  return '<p class="workspace-quick-links">' + ($links -join ' <span aria-hidden="true">/</span> ') + '</p>'
}

function Get-WorkspaceSummaryCounts {
  param(
    [AllowEmptyCollection()]
    [object[]]$PreviewCards = @(),
    [AllowEmptyCollection()]
    [object[]]$Targets = @()
  )

  $highCount = 0
  $mediumCount = 0
  $lowCount = 0
  foreach ($previewCard in @(ConvertTo-ObjectArray -Value $PreviewCards)) {
    switch (Get-WorkspaceReviewerSeverity -PreviewCard $previewCard) {
      'high' { $highCount += 1 }
      'medium' { $mediumCount += 1 }
      'low' { $lowCount += 1 }
    }
  }

  return [ordered]@{
    pairCount = @(ConvertTo-ObjectArray -Value $PreviewCards).Count
    targetCount = @(ConvertTo-ObjectArray -Value $Targets).Count
    highCount = $highCount
    mediumCount = $mediumCount
    lowCount = $lowCount
  }
}

function New-MarkdownWorkspaceSummary {
  param(
    [AllowEmptyCollection()]
    [object[]]$PreviewCards = @(),
    [AllowEmptyCollection()]
    [object[]]$Targets = @()
  )

  $counts = Get-WorkspaceSummaryCounts -PreviewCards $PreviewCards -Targets $Targets
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('## Workspace summary') | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add(('- History pairs in workspace: `{0}`' -f $counts.pairCount)) | Out-Null
  $lines.Add(('- Targets in workspace: `{0}`' -f $counts.targetCount)) | Out-Null
  $lines.Add(('- Severity mix: `{0}` high / `{1}` medium / `{2}` low' -f $counts.highCount, $counts.mediumCount, $counts.lowCount)) | Out-Null
  $lines.Add('') | Out-Null
  return @($lines | ForEach-Object { $_ })
}

function New-MarkdownWorkspaceNavigation {
  param(
    [AllowEmptyCollection()]
    [object[]]$PreviewCards = @(),
    [AllowEmptyCollection()]
    [object[]]$Targets = @(),
    [Parameter(Mandatory = $true)]
    [string]$ResultsRoot
  )

  if ($PreviewCards.Count -eq 0) {
    return @()
  }

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('## Workspace navigation') | Out-Null
  $lines.Add('') | Out-Null
  foreach ($previewCard in @(ConvertTo-ObjectArray -Value $PreviewCards)) {
    $anchorId = Get-WorkspaceCardAnchorId -PreviewCard $previewCard
    $subtitle = Get-ReviewerPreviewSubtitle -PreviewPair $previewCard
    $headline = Get-WorkspaceReviewerHeadline -PreviewCard $previewCard
    $severity = Get-WorkspaceReviewerSeverity -PreviewCard $previewCard
    $lines.Add(('- [{0}](#{1}) `{2}` {3}' -f $subtitle, $anchorId, $severity, $(if ([string]::IsNullOrWhiteSpace($headline)) { '' } else { ('- ' + $headline) }))) | Out-Null
    $quickLinkLine = New-MarkdownWorkspaceQuickLinkLine -PreviewCard $previewCard -Targets $Targets -ResultsRoot $ResultsRoot
    if (-not [string]::IsNullOrWhiteSpace($quickLinkLine)) {
      $lines.Add(('  {0}' -f $quickLinkLine)) | Out-Null
    }
  }
  $lines.Add('') | Out-Null
  return @($lines | ForEach-Object { $_ })
}

function New-HtmlWorkspaceSummary {
  param(
    [AllowEmptyCollection()]
    [object[]]$PreviewCards = @(),
    [AllowEmptyCollection()]
    [object[]]$Targets = @()
  )

  $counts = Get-WorkspaceSummaryCounts -PreviewCards $PreviewCards -Targets $Targets
  return @"
  <section class="workspace-summary">
    <div class="workspace-summary-card"><strong>History pairs</strong><span><code>$(Escape-Html ([string]$counts.pairCount))</code></span></div>
    <div class="workspace-summary-card"><strong>Targets</strong><span><code>$(Escape-Html ([string]$counts.targetCount))</code></span></div>
    <div class="workspace-summary-card"><strong>Severity mix</strong><span><code>$(Escape-Html ('{0} high / {1} medium / {2} low' -f $counts.highCount, $counts.mediumCount, $counts.lowCount))</code></span></div>
  </section>
"@
}

function New-HtmlWorkspaceNavigation {
  param(
    [AllowEmptyCollection()]
    [object[]]$PreviewCards = @(),
    [AllowEmptyCollection()]
    [object[]]$Targets = @(),
    [Parameter(Mandatory = $true)]
    [string]$ResultsRoot
  )

  if ($PreviewCards.Count -eq 0) {
    return ''
  }

  $items = New-Object System.Collections.Generic.List[string]
  foreach ($previewCard in @(ConvertTo-ObjectArray -Value $PreviewCards)) {
    $anchorId = Get-WorkspaceCardAnchorId -PreviewCard $previewCard
    $subtitle = Get-ReviewerPreviewSubtitle -PreviewPair $previewCard
    $headline = Get-WorkspaceReviewerHeadline -PreviewCard $previewCard
    $severity = Get-WorkspaceReviewerSeverity -PreviewCard $previewCard
    $quickLinks = New-HtmlWorkspaceQuickLinks -PreviewCard $previewCard -Targets $Targets -ResultsRoot $ResultsRoot
    $headlineHtml = if ([string]::IsNullOrWhiteSpace($headline)) { '' } else { '<p class="workspace-nav-headline">' + (Escape-Html $headline) + '</p>' }
    $items.Add(@"
      <li class="workspace-nav-item">
        <a class="workspace-nav-link" href="#$(Escape-Html $anchorId)">$(Escape-Html $subtitle)</a>
        <p class="workspace-nav-severity"><code>$(Escape-Html $severity)</code></p>
        $headlineHtml
        $quickLinks
      </li>
"@) | Out-Null
  }

  return @"
  <aside class="workspace-nav">
    <h2>Workspace navigation</h2>
    <ul class="workspace-nav-list">
      $($items -join "`n")
    </ul>
  </aside>
"@
}

function New-MarkdownChangeDetailSectionLinkLine {
  param(
    [AllowNull()]
    [object[]]$SectionLinks = @()
  )

  $sectionLinkItems = @(
    ConvertTo-ObjectArray -Value $SectionLinks |
      ForEach-Object {
        $label = Get-OptionalString -Value (Get-NestedValue -Object $_ -Path @('label'))
        $path = Get-OptionalString -Value (Get-NestedValue -Object $_ -Path @('reportHtmlRelativePath'))
        if ([string]::IsNullOrWhiteSpace($label) -or [string]::IsNullOrWhiteSpace($path)) {
          return $null
        }

        '[{0}]({1})' -f $label, $path
      } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  )

  if ($sectionLinkItems.Count -eq 0) {
    return $null
  }

  return '  - Exact sections: {0}' -f ($sectionLinkItems -join ', ')
}

function New-HtmlChangeDetailSectionLinks {
  param(
    [AllowNull()]
    [object[]]$SectionLinks = @()
  )

  $linkItems = @(
    ConvertTo-ObjectArray -Value $SectionLinks |
      ForEach-Object {
        $label = Get-OptionalString -Value (Get-NestedValue -Object $_ -Path @('label'))
        $path = Get-OptionalString -Value (Get-NestedValue -Object $_ -Path @('reportHtmlRelativePath'))
        if ([string]::IsNullOrWhiteSpace($label) -or [string]::IsNullOrWhiteSpace($path)) {
          return $null
        }

        '<a href="' + (Escape-Html $path) + '">' + (Escape-Html $label) + '</a>'
      } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  )

  if ($linkItems.Count -eq 0) {
    return ''
  }

  return '<li><strong>Exact sections:</strong> ' + ($linkItems -join ', ') + '</li>'
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
    $primaryReportHtmlRelativePath = Get-OptionalString -Value (Get-NestedValue -Object $group -Path @('primaryReportHtmlRelativePath'))
    $sectionCount = [int](Get-NestedValue -Object $group -Path @('sectionCount') -Default 0)
    $detailCount = [int](Get-NestedValue -Object $group -Path @('detailCount') -Default 0)
    $headingLabel = if ([string]::IsNullOrWhiteSpace($primaryReportHtmlRelativePath)) {
      ('`{0}`' -f $heading)
    } else {
      ('[`{0}`]({1})' -f $heading, $primaryReportHtmlRelativePath)
    }
    $lines.Add(('- {0}: `{1}` details across `{2}` sections' -f $headingLabel, $detailCount, $sectionCount)) | Out-Null
    foreach ($sampleDetail in @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $group -Path @('sampleDetails') -Default @()))) {
      $lines.Add(('  - {0}' -f [string]$sampleDetail)) | Out-Null
    }
    $omittedDetailCount = [int](Get-NestedValue -Object $group -Path @('omittedDetailCount') -Default 0)
    if ($omittedDetailCount -gt 0) {
      $lines.Add(('  - +{0} more details in report' -f $omittedDetailCount)) | Out-Null
    }
    $sectionLinkLine = New-MarkdownChangeDetailSectionLinkLine -SectionLinks @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $group -Path @('sectionLinks') -Default @()))
    if (-not [string]::IsNullOrWhiteSpace($sectionLinkLine)) {
      $lines.Add($sectionLinkLine) | Out-Null
    }
  }
  $omittedGroupCount = [int](Get-NestedValue -Object $ChangeDetails -Path @('omittedGroupCount') -Default 0)
  if ($omittedGroupCount -gt 0) {
    $lines.Add(('- Additional change-detail groups omitted: `{0}`' -f $omittedGroupCount)) | Out-Null
  }
  $reportHtmlRelativePath = Get-OptionalString -Value (Get-NestedValue -Object $ChangeDetails -Path @('reportHtmlRelativePath'))
  if (-not [string]::IsNullOrWhiteSpace($reportHtmlRelativePath)) {
    $lines.Add(('- Review page: [{0}]({0})' -f $reportHtmlRelativePath)) | Out-Null
  }
  $lines.Add('') | Out-Null
  return @($lines | ForEach-Object { $_ })
}

function New-MarkdownReviewerSummaryLines {
  param(
    [AllowNull()]
    [object]$ReviewerSummary
  )

  if ($null -eq $ReviewerSummary) {
    return @()
  }

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('#### Reviewer summary') | Out-Null
  $lines.Add('') | Out-Null
  $headline = Get-OptionalString -Value (Get-NestedValue -Object $ReviewerSummary -Path @('headline'))
  if (-not [string]::IsNullOrWhiteSpace($headline)) {
    $lines.Add(('- Headline: `{0}`' -f $headline)) | Out-Null
  }
  $overallSeverity = Get-OptionalString -Value (Get-NestedValue -Object $ReviewerSummary -Path @('overallSeverity'))
  if (-not [string]::IsNullOrWhiteSpace($overallSeverity)) {
    $lines.Add(('- Overall severity: `{0}`' -f $overallSeverity)) | Out-Null
  }
  foreach ($signal in @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $ReviewerSummary -Path @('signals') -Default @()))) {
    $label = Get-OptionalString -Value (Get-NestedValue -Object $signal -Path @('label'))
    $primaryPath = Get-OptionalString -Value (Get-NestedValue -Object $signal -Path @('primaryReportHtmlRelativePath'))
    $detailCount = [int](Get-NestedValue -Object $signal -Path @('detailCount') -Default 0)
    $sectionCount = [int](Get-NestedValue -Object $signal -Path @('sectionCount') -Default 0)
    $severity = Get-OptionalString -Value (Get-NestedValue -Object $signal -Path @('severity'))
    $labelText = if ([string]::IsNullOrWhiteSpace($primaryPath)) {
      ('`{0}`' -f $label)
    } else {
      ('[`{0}`]({1})' -f $label, $primaryPath)
    }
    $lines.Add(('- {0}: `{1}` severity, `{2}` details across `{3}` sections' -f $labelText, $severity, $detailCount, $sectionCount)) | Out-Null
    $sectionLinkLine = New-MarkdownChangeDetailSectionLinkLine -SectionLinks @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $signal -Path @('sectionLinks') -Default @()))
    if (-not [string]::IsNullOrWhiteSpace($sectionLinkLine)) {
      $lines.Add($sectionLinkLine) | Out-Null
    }
  }
  $omittedSignalCount = [int](Get-NestedValue -Object $ReviewerSummary -Path @('omittedSignalCount') -Default 0)
  if ($omittedSignalCount -gt 0) {
    $lines.Add(('- Additional reviewer signals omitted: `{0}`' -f $omittedSignalCount)) | Out-Null
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
    $headingText = Get-OptionalString -Value (Get-NestedValue -Object $group -Path @('heading'))
    $primaryReportHtmlRelativePath = Get-OptionalString -Value (Get-NestedValue -Object $group -Path @('primaryReportHtmlRelativePath'))
    $heading = if ([string]::IsNullOrWhiteSpace($primaryReportHtmlRelativePath)) {
      Escape-Html $headingText
    } else {
      '<a href="' + (Escape-Html $primaryReportHtmlRelativePath) + '">' + (Escape-Html $headingText) + '</a>'
    }
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
    $sectionLinksHtml = New-HtmlChangeDetailSectionLinks -SectionLinks @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $group -Path @('sectionLinks') -Default @()))
    if (-not [string]::IsNullOrWhiteSpace($sectionLinksHtml)) {
      $sampleList.Add($sectionLinksHtml) | Out-Null
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
    $items.Add('<li><a href="' + (Escape-Html $reportHtmlRelativePath) + '">open change details review</a></li>') | Out-Null
  }

  return '<section class="preview-change-details"><h4>Change details</h4><ul>' + ($items -join '') + '</ul></section>'
}

function New-HtmlReviewerSummaryBlock {
  param(
    [AllowNull()]
    [object]$ReviewerSummary
  )

  if ($null -eq $ReviewerSummary) {
    return ''
  }

  $items = New-Object System.Collections.Generic.List[string]
  $headline = Get-OptionalString -Value (Get-NestedValue -Object $ReviewerSummary -Path @('headline'))
  if (-not [string]::IsNullOrWhiteSpace($headline)) {
    $items.Add('<li><strong>Headline:</strong> ' + (Escape-Html $headline) + '</li>') | Out-Null
  }
  $overallSeverity = Get-OptionalString -Value (Get-NestedValue -Object $ReviewerSummary -Path @('overallSeverity'))
  if (-not [string]::IsNullOrWhiteSpace($overallSeverity)) {
    $items.Add('<li><strong>Overall severity:</strong> ' + (Escape-Html $overallSeverity) + '</li>') | Out-Null
  }
  foreach ($signal in @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $ReviewerSummary -Path @('signals') -Default @()))) {
    $labelText = Get-OptionalString -Value (Get-NestedValue -Object $signal -Path @('label'))
    $primaryPath = Get-OptionalString -Value (Get-NestedValue -Object $signal -Path @('primaryReportHtmlRelativePath'))
    $detailCount = [int](Get-NestedValue -Object $signal -Path @('detailCount') -Default 0)
    $sectionCount = [int](Get-NestedValue -Object $signal -Path @('sectionCount') -Default 0)
    $severity = Get-OptionalString -Value (Get-NestedValue -Object $signal -Path @('severity'))
    $heading = if ([string]::IsNullOrWhiteSpace($primaryPath)) {
      Escape-Html $labelText
    } else {
      '<a href="' + (Escape-Html $primaryPath) + '">' + (Escape-Html $labelText) + '</a>'
    }
    $signalItems = New-Object System.Collections.Generic.List[string]
    $sectionLinksHtml = New-HtmlChangeDetailSectionLinks -SectionLinks @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $signal -Path @('sectionLinks') -Default @()))
    if (-not [string]::IsNullOrWhiteSpace($sectionLinksHtml)) {
      $signalItems.Add($sectionLinksHtml) | Out-Null
    }
    $nestedList = if ($signalItems.Count -gt 0) { '<ul>' + ($signalItems -join '') + '</ul>' } else { '' }
    $items.Add('<li><strong>' + $heading + ':</strong> ' + (Escape-Html $severity) + ' severity, ' + $detailCount + ' details across ' + $sectionCount + ' sections' + $nestedList + '</li>') | Out-Null
  }
  $omittedSignalCount = [int](Get-NestedValue -Object $ReviewerSummary -Path @('omittedSignalCount') -Default 0)
  if ($omittedSignalCount -gt 0) {
    $items.Add('<li><strong>Additional reviewer signals omitted:</strong> ' + $omittedSignalCount + '</li>') | Out-Null
  }

  return '<section class="preview-reviewer-summary"><h4>Reviewer summary</h4><ul>' + ($items -join '') + '</ul></section>'
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

function ConvertTo-WorkspaceReviewerSectionLink {
  param(
    [Parameter(Mandatory = $true)]
    [object]$SectionLink,
    [Parameter(Mandatory = $true)]
    [string]$PairPageHtmlRelativePath,
    [string]$FallbackAnchorId = 'change-details'
  )

  $rawReportHtmlRelativePath = Get-OptionalString -Value (Get-NestedValue -Object $SectionLink -Path @('reportHtmlRelativePath'))
  $anchorId = Get-ReportAnchorId -Path $rawReportHtmlRelativePath
  if ([string]::IsNullOrWhiteSpace($anchorId)) {
    $anchorId = ConvertTo-Slug -Value (Get-OptionalString -Value (Get-NestedValue -Object $SectionLink -Path @('label'))) -Fallback $FallbackAnchorId
  }

  return [ordered]@{
    sectionOrdinal = [int](Get-NestedValue -Object $SectionLink -Path @('sectionOrdinal') -Default 0)
    label = Get-OptionalString -Value (Get-NestedValue -Object $SectionLink -Path @('label'))
    reportHtmlRelativePath = Add-AnchorToRelativePath -Path $PairPageHtmlRelativePath -AnchorId $anchorId
    debugReportHtmlRelativePath = $rawReportHtmlRelativePath
  }
}

function ConvertTo-WorkspaceReviewerSummary {
  param(
    [AllowNull()]
    [object]$ReviewerSummary,
    [Parameter(Mandatory = $true)]
    [string]$PairPageHtmlRelativePath
  )

  if ($null -eq $ReviewerSummary) {
    return $null
  }

  $signals = New-Object System.Collections.Generic.List[object]
  foreach ($signal in @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $ReviewerSummary -Path @('signals') -Default @()))) {
    $rawPrimaryPath = Get-OptionalString -Value (Get-NestedValue -Object $signal -Path @('primaryReportHtmlRelativePath'))
    $primaryAnchorId = Get-ReportAnchorId -Path $rawPrimaryPath
    if ([string]::IsNullOrWhiteSpace($primaryAnchorId)) {
      $primaryAnchorId = ConvertTo-Slug -Value (Get-OptionalString -Value (Get-NestedValue -Object $signal -Path @('label'))) -Fallback 'reviewer-signal'
    }

    $signals.Add([ordered]@{
        signalKey = Get-OptionalString -Value (Get-NestedValue -Object $signal -Path @('signalKey'))
        label = Get-OptionalString -Value (Get-NestedValue -Object $signal -Path @('label'))
        severity = Get-OptionalString -Value (Get-NestedValue -Object $signal -Path @('severity'))
        detailCount = [int](Get-NestedValue -Object $signal -Path @('detailCount') -Default 0)
        sectionCount = [int](Get-NestedValue -Object $signal -Path @('sectionCount') -Default 0)
        summary = Get-OptionalString -Value (Get-NestedValue -Object $signal -Path @('summary'))
        primaryReportHtmlRelativePath = Add-AnchorToRelativePath -Path $PairPageHtmlRelativePath -AnchorId $primaryAnchorId
        debugPrimaryReportHtmlRelativePath = $rawPrimaryPath
        sectionLinks = @(
          ConvertTo-ObjectArray -Value (Get-NestedValue -Object $signal -Path @('sectionLinks') -Default @()) |
            ForEach-Object { ConvertTo-WorkspaceReviewerSectionLink -SectionLink $_ -PairPageHtmlRelativePath $PairPageHtmlRelativePath -FallbackAnchorId $primaryAnchorId }
        )
      }) | Out-Null
  }

  return [ordered]@{
    label = Get-OptionalString -Value (Get-NestedValue -Object $ReviewerSummary -Path @('label'))
    overallSeverity = Get-OptionalString -Value (Get-NestedValue -Object $ReviewerSummary -Path @('overallSeverity'))
    headline = Get-OptionalString -Value (Get-NestedValue -Object $ReviewerSummary -Path @('headline'))
    signalCount = [int](Get-NestedValue -Object $ReviewerSummary -Path @('signalCount') -Default 0)
    omittedSignalCount = [int](Get-NestedValue -Object $ReviewerSummary -Path @('omittedSignalCount') -Default 0)
    signals = @($signals | ForEach-Object { $_ })
  }
}

function ConvertTo-WorkspaceChangeDetails {
  param(
    [AllowNull()]
    [object]$ChangeDetails,
    [Parameter(Mandatory = $true)]
    [string]$PairPageHtmlRelativePath
  )

  if ($null -eq $ChangeDetails) {
    return $null
  }

  $groups = New-Object System.Collections.Generic.List[object]
  foreach ($group in @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $ChangeDetails -Path @('groups') -Default @()))) {
    $rawPrimaryPath = Get-OptionalString -Value (Get-NestedValue -Object $group -Path @('primaryReportHtmlRelativePath'))
    $primaryAnchorId = Get-ReportAnchorId -Path $rawPrimaryPath
    if ([string]::IsNullOrWhiteSpace($primaryAnchorId)) {
      $primaryAnchorId = ConvertTo-Slug -Value (Get-OptionalString -Value (Get-NestedValue -Object $group -Path @('heading'))) -Fallback 'change-group'
    }

    $groups.Add([ordered]@{
        heading = Get-OptionalString -Value (Get-NestedValue -Object $group -Path @('heading'))
        sectionCount = [int](Get-NestedValue -Object $group -Path @('sectionCount') -Default 0)
        detailCount = [int](Get-NestedValue -Object $group -Path @('detailCount') -Default 0)
        sampleDetails = @(
          ConvertTo-ObjectArray -Value (Get-NestedValue -Object $group -Path @('sampleDetails') -Default @()) |
            ForEach-Object { [string]$_ }
        )
        omittedDetailCount = [int](Get-NestedValue -Object $group -Path @('omittedDetailCount') -Default 0)
        primaryReportHtmlRelativePath = Add-AnchorToRelativePath -Path $PairPageHtmlRelativePath -AnchorId $primaryAnchorId
        debugPrimaryReportHtmlRelativePath = $rawPrimaryPath
        sectionLinks = @(
          ConvertTo-ObjectArray -Value (Get-NestedValue -Object $group -Path @('sectionLinks') -Default @()) |
            ForEach-Object { ConvertTo-WorkspaceReviewerSectionLink -SectionLink $_ -PairPageHtmlRelativePath $PairPageHtmlRelativePath -FallbackAnchorId $primaryAnchorId }
        )
      }) | Out-Null
  }

  return [ordered]@{
    label = Get-OptionalString -Value (Get-NestedValue -Object $ChangeDetails -Path @('label'))
    sourceMode = Get-OptionalString -Value (Get-NestedValue -Object $ChangeDetails -Path @('sourceMode'))
    reportHtmlRelativePath = Add-AnchorToRelativePath -Path $PairPageHtmlRelativePath -AnchorId 'change-details'
    debugReportHtmlRelativePath = Get-OptionalString -Value (Get-NestedValue -Object $ChangeDetails -Path @('reportHtmlRelativePath'))
    includedCategories = @(
      ConvertTo-ObjectArray -Value (Get-NestedValue -Object $ChangeDetails -Path @('includedCategories') -Default @()) |
        ForEach-Object { [string]$_ }
    )
    groupCount = [int](Get-NestedValue -Object $ChangeDetails -Path @('groupCount') -Default 0)
    omittedGroupCount = [int](Get-NestedValue -Object $ChangeDetails -Path @('omittedGroupCount') -Default 0)
    sectionCount = [int](Get-NestedValue -Object $ChangeDetails -Path @('sectionCount') -Default 0)
    detailCount = [int](Get-NestedValue -Object $ChangeDetails -Path @('detailCount') -Default 0)
    groups = @($groups | ForEach-Object { $_ })
  }
}

function ConvertTo-WorkspacePreviewCard {
  param(
    [Parameter(Mandatory = $true)]
    [object]$PreviewCard,
    [Parameter(Mandatory = $true)]
    [int]$Ordinal
  )

  $pairPageHtmlRelativePath = Get-WorkspacePairPageHtmlRelativePath -PreviewCard $PreviewCard -Ordinal $Ordinal
  $pairPageMarkdownRelativePath = Get-WorkspacePairPageMarkdownRelativePath -PreviewCard $PreviewCard -Ordinal $Ordinal

  $surfaces = New-Object System.Collections.Generic.List[object]
  foreach ($surface in @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $PreviewCard -Path @('surfaces') -Default @()))) {
    $surfaceKind = Get-OptionalString -Value $surface.surfaceKind
    $surfaceAnchorId = switch ($surfaceKind) {
      'front-panel' { 'front-panel' }
      'block-diagram' { 'block-diagram' }
      default { ConvertTo-Slug -Value $surfaceKind -Fallback 'preview-surface' }
    }

    $surfaces.Add([ordered]@{
        surfaceKind = $surfaceKind
        surfaceLabel = Get-ReviewerPreviewSurfaceLabel -SurfaceKind $surfaceKind -FallbackLabel (Get-OptionalString -Value $surface.surfaceLabel)
        reportHtmlRelativePath = Add-AnchorToRelativePath -Path $pairPageHtmlRelativePath -AnchorId $surfaceAnchorId
        debugReportHtmlRelativePath = Get-OptionalString -Value $surface.reportHtmlRelativePath
        baseImageRelativePath = Get-OptionalString -Value $surface.baseImageRelativePath
        headImageRelativePath = Get-OptionalString -Value $surface.headImageRelativePath
      }) | Out-Null
  }

  return [ordered]@{
    targetId = [string]$PreviewCard.targetId
    targetPath = [string]$PreviewCard.targetPath
    comparison = $PreviewCard.comparison
    pairPageHtmlRelativePath = $pairPageHtmlRelativePath
    pairPageMarkdownRelativePath = $pairPageMarkdownRelativePath
    reviewerSummary = ConvertTo-WorkspaceReviewerSummary -ReviewerSummary (Get-NestedValue -Object $PreviewCard -Path @('reviewerSummary')) -PairPageHtmlRelativePath $pairPageHtmlRelativePath
    changeDetails = ConvertTo-WorkspaceChangeDetails -ChangeDetails (Get-NestedValue -Object $PreviewCard -Path @('changeDetails')) -PairPageHtmlRelativePath $pairPageHtmlRelativePath
    surfaces = @($surfaces | ForEach-Object { $_ })
  }
}

function New-WorkspacePrimaryPreviewCards {
  param(
    [AllowEmptyCollection()]
    [object[]]$PreviewCards = @()
  )

  $convertedCards = New-Object System.Collections.Generic.List[object]
  $ordinal = 1
  foreach ($previewCard in @(ConvertTo-ObjectArray -Value $PreviewCards)) {
    $convertedCards.Add((ConvertTo-WorkspacePreviewCard -PreviewCard $previewCard -Ordinal $ordinal)) | Out-Null
    $ordinal += 1
  }

  return @($convertedCards | ForEach-Object { $_ })
}

function New-WorkspacePrimaryPreviewPairs {
  param(
    [AllowEmptyCollection()]
    [object[]]$PreviewCards = @()
  )

  $previewPairs = New-Object System.Collections.Generic.List[object]
  foreach ($previewCard in @(ConvertTo-ObjectArray -Value $PreviewCards)) {
    $representativeSurface = @(
      ConvertTo-ObjectArray -Value (Get-NestedValue -Object $previewCard -Path @('surfaces') -Default @()) |
        Select-Object -First 1
    )
    if ($null -eq $representativeSurface) {
      continue
    }

    $previewPairs.Add([ordered]@{
        targetId = [string]$previewCard.targetId
        targetPath = [string]$previewCard.targetPath
        mode = Get-OptionalString -Value $representativeSurface.surfaceKind
        label = Get-OptionalString -Value $representativeSurface.surfaceLabel
        sectionKind = 'review-pair'
        comparison = $previewCard.comparison
        reportHtmlRelativePath = Get-OptionalString -Value $representativeSurface.reportHtmlRelativePath
        debugReportHtmlRelativePath = Get-OptionalString -Value $representativeSurface.debugReportHtmlRelativePath
        baseImageRelativePath = Get-OptionalString -Value $representativeSurface.baseImageRelativePath
        headImageRelativePath = Get-OptionalString -Value $representativeSurface.headImageRelativePath
      }) | Out-Null
  }

  return @($previewPairs | ForEach-Object { $_ })
}

function New-MarkdownWorkspacePairPage {
  param(
    [Parameter(Mandatory = $true)]
    [object]$PreviewCard,
    [AllowEmptyCollection()]
    [object[]]$Targets = @(),
    [Parameter(Mandatory = $true)]
    [string]$ResultsRoot
  )

  $pageRelativePath = Get-OptionalString -Value $PreviewCard.pairPageMarkdownRelativePath
  $workspaceHtmlLink = Resolve-RelativeLinkFromPage -PageRelativePath $pageRelativePath -TargetRelativePath (Add-AnchorToRelativePath -Path 'index.html' -AnchorId (Get-WorkspaceCardAnchorId -PreviewCard $PreviewCard))
  $workspaceMarkdownLink = Resolve-RelativeLinkFromPage -PageRelativePath $pageRelativePath -TargetRelativePath (Add-AnchorToRelativePath -Path 'index.md' -AnchorId (Get-WorkspaceCardAnchorId -PreviewCard $PreviewCard))
  $lines = New-Object System.Collections.Generic.List[string]
  $title = Get-ReviewerPreviewTitle -PreviewPair $PreviewCard
  $subtitle = Get-ReviewerPreviewSubtitle -PreviewPair $PreviewCard
  $revisionContext = Get-ReviewerPreviewRevisionContext -PreviewPair $PreviewCard
  $detailLines = @(Get-ReviewerPreviewDetailLines -PreviewPair $PreviewCard)

  $lines.Add(('# `{0}`' -f $title)) | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add(('## {0}' -f $subtitle)) | Out-Null
  $lines.Add('') | Out-Null
  if (-not [string]::IsNullOrWhiteSpace($revisionContext)) {
    $lines.Add(('`{0}`' -f $revisionContext)) | Out-Null
    $lines.Add('') | Out-Null
  }
  foreach ($detailLine in $detailLines) {
    $lines.Add(('- {0}' -f $detailLine)) | Out-Null
  }
  if ($detailLines.Count -gt 0) {
    $lines.Add('') | Out-Null
  }
  $lines.Add(('Back to workspace: [index.html]({0}), [index.md]({1})' -f $workspaceHtmlLink, $workspaceMarkdownLink)) | Out-Null
  $lines.Add('') | Out-Null

  foreach ($surface in @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $PreviewCard -Path @('surfaces') -Default @()))) {
    $surfaceLabel = Get-ReviewerPreviewSurfaceLabel -SurfaceKind (Get-OptionalString -Value $surface.surfaceKind) -FallbackLabel (Get-OptionalString -Value $surface.surfaceLabel)
    $baseImageRelativePath = Resolve-RelativeLinkFromPage -PageRelativePath $pageRelativePath -TargetRelativePath (Get-OptionalString -Value $surface.baseImageRelativePath)
    $headImageRelativePath = Resolve-RelativeLinkFromPage -PageRelativePath $pageRelativePath -TargetRelativePath (Get-OptionalString -Value $surface.headImageRelativePath)
    $debugReportLink = Resolve-RelativeLinkFromPage -PageRelativePath $pageRelativePath -TargetRelativePath (Get-OptionalString -Value $surface.debugReportHtmlRelativePath)

    $lines.Add(('## {0}' -f $surfaceLabel)) | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add('**Base**') | Out-Null
    $lines.Add(('![{0}]({1})' -f ('{0} base' -f $surfaceLabel), $baseImageRelativePath)) | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add('**Head**') | Out-Null
    $lines.Add(('![{0}]({1})' -f ('{0} head' -f $surfaceLabel), $headImageRelativePath)) | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($debugReportLink)) {
      $lines.Add('') | Out-Null
      $lines.Add(('- Debug raw report: [{0}]({0})' -f $debugReportLink)) | Out-Null
    }
    $lines.Add('') | Out-Null
  }

  foreach ($reviewerSummaryLine in @(New-MarkdownReviewerSummaryLines -ReviewerSummary (Get-NestedValue -Object $PreviewCard -Path @('reviewerSummary')))) {
    $lines.Add($reviewerSummaryLine) | Out-Null
  }
  foreach ($changeDetailLine in @(New-MarkdownChangeDetailsLines -ChangeDetails (Get-NestedValue -Object $PreviewCard -Path @('changeDetails')))) {
    $lines.Add($changeDetailLine) | Out-Null
  }

  $targetLinks = Get-WorkspaceTargetLinks -PreviewCard $PreviewCard -Targets $Targets -ResultsRoot $ResultsRoot
  $debugLinks = New-Object System.Collections.Generic.List[string]
  foreach ($key in @('historyReport', 'sharedEvidence', 'publicRun', 'modeSummary', 'request')) {
    $path = Resolve-RelativeLinkFromPage -PageRelativePath $pageRelativePath -TargetRelativePath (Get-OptionalString -Value (Get-NestedValue -Object $targetLinks -Path @($key)))
    if ([string]::IsNullOrWhiteSpace($path)) {
      continue
    }
    $label = switch ($key) {
      'historyReport' { 'history report' }
      'sharedEvidence' { 'shared evidence' }
      'publicRun' { 'public run' }
      'modeSummary' { 'mode summary' }
      'request' { 'request' }
      default { $key }
    }
    $debugLinks.Add(('[{0}]({1})' -f $label, $path)) | Out-Null
  }
  if ($debugLinks.Count -gt 0) {
    $lines.Add('## Debug evidence') | Out-Null
    $lines.Add('') | Out-Null
    foreach ($debugLink in $debugLinks) {
      $lines.Add(('- {0}' -f $debugLink)) | Out-Null
    }
    $lines.Add('') | Out-Null
  }

  return ($lines -join "`n").TrimEnd() + "`n"
}

function New-HtmlWorkspacePairPage {
  param(
    [Parameter(Mandatory = $true)]
    [object]$PreviewCard,
    [AllowEmptyCollection()]
    [object[]]$Targets = @(),
    [Parameter(Mandatory = $true)]
    [string]$ResultsRoot
  )

  $pageRelativePath = Get-OptionalString -Value $PreviewCard.pairPageHtmlRelativePath
  $workspaceHtmlLink = Resolve-RelativeLinkFromPage -PageRelativePath $pageRelativePath -TargetRelativePath (Add-AnchorToRelativePath -Path 'index.html' -AnchorId (Get-WorkspaceCardAnchorId -PreviewCard $PreviewCard))
  $workspaceMarkdownLink = Resolve-RelativeLinkFromPage -PageRelativePath $pageRelativePath -TargetRelativePath (Add-AnchorToRelativePath -Path 'index.md' -AnchorId (Get-WorkspaceCardAnchorId -PreviewCard $PreviewCard))
  $title = Get-ReviewerPreviewTitle -PreviewPair $PreviewCard
  $subtitle = Get-ReviewerPreviewSubtitle -PreviewPair $PreviewCard
  $revisionContext = Get-ReviewerPreviewRevisionContext -PreviewPair $PreviewCard
  $detailLines = @(Get-ReviewerPreviewDetailLines -PreviewPair $PreviewCard)

  $surfaceSections = New-Object System.Collections.Generic.List[string]
  foreach ($surface in @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $PreviewCard -Path @('surfaces') -Default @()))) {
    $surfaceKind = Get-OptionalString -Value $surface.surfaceKind
    $surfaceAnchorId = switch ($surfaceKind) {
      'front-panel' { 'front-panel' }
      'block-diagram' { 'block-diagram' }
      default { ConvertTo-Slug -Value $surfaceKind -Fallback 'preview-surface' }
    }
    $surfaceLabel = Get-ReviewerPreviewSurfaceLabel -SurfaceKind $surfaceKind -FallbackLabel (Get-OptionalString -Value $surface.surfaceLabel)
    $baseImageRelativePath = Resolve-RelativeLinkFromPage -PageRelativePath $pageRelativePath -TargetRelativePath (Get-OptionalString -Value $surface.baseImageRelativePath)
    $headImageRelativePath = Resolve-RelativeLinkFromPage -PageRelativePath $pageRelativePath -TargetRelativePath (Get-OptionalString -Value $surface.headImageRelativePath)
    $debugReportLink = Resolve-RelativeLinkFromPage -PageRelativePath $pageRelativePath -TargetRelativePath (Get-OptionalString -Value $surface.debugReportHtmlRelativePath)

    $surfaceSections.Add(@"
  <section class="pair-surface" id="$(Escape-Html $surfaceAnchorId)">
    <h2>$(Escape-Html $surfaceLabel)</h2>
    <div class="pair-image-grid">
      <figure>
        <img alt="$(Escape-Html ($surfaceLabel + ' base'))" src="$(Escape-Html $baseImageRelativePath)">
        <figcaption>Base</figcaption>
      </figure>
      <figure>
        <img alt="$(Escape-Html ($surfaceLabel + ' head'))" src="$(Escape-Html $headImageRelativePath)">
        <figcaption>Head</figcaption>
      </figure>
    </div>
    $(if (-not [string]::IsNullOrWhiteSpace($debugReportLink)) { '<p class="pair-debug-links"><strong>Debug raw report:</strong> <a href="' + (Escape-Html $debugReportLink) + '">open raw report</a></p>' } else { '' })
  </section>
"@) | Out-Null
  }

  $reviewerSummaryHtml = New-HtmlReviewerSummaryBlock -ReviewerSummary (Get-NestedValue -Object $PreviewCard -Path @('reviewerSummary'))

  $changeDetailItems = New-Object System.Collections.Generic.List[string]
  $changeDetails = Get-NestedValue -Object $PreviewCard -Path @('changeDetails')
  if ($null -ne $changeDetails) {
    $includedCategories = @(
      ConvertTo-ObjectArray -Value (Get-NestedValue -Object $changeDetails -Path @('includedCategories') -Default @()) |
        ForEach-Object { Get-OptionalString -Value $_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($includedCategories.Count -gt 0) {
      $changeDetailItems.Add('<li><strong>Included categories:</strong> ' + (Escape-Html ($includedCategories -join ', ')) + '</li>') | Out-Null
    }
    foreach ($group in @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $changeDetails -Path @('groups') -Default @()))) {
      $groupAnchorId = Get-ReportAnchorId -Path (Get-OptionalString -Value (Get-NestedValue -Object $group -Path @('primaryReportHtmlRelativePath')))
      $heading = Escape-Html (Get-OptionalString -Value (Get-NestedValue -Object $group -Path @('heading')))
      $detailCount = [int](Get-NestedValue -Object $group -Path @('detailCount') -Default 0)
      $sectionCount = [int](Get-NestedValue -Object $group -Path @('sectionCount') -Default 0)
      $sampleItems = New-Object System.Collections.Generic.List[string]
      foreach ($sampleDetail in @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $group -Path @('sampleDetails') -Default @()))) {
        $sampleItems.Add('<li>' + (Escape-Html ([string]$sampleDetail)) + '</li>') | Out-Null
      }
      $omittedDetailCount = [int](Get-NestedValue -Object $group -Path @('omittedDetailCount') -Default 0)
      if ($omittedDetailCount -gt 0) {
        $sampleItems.Add('<li>+' + $omittedDetailCount + ' more details in report</li>') | Out-Null
      }
      $sectionLinksHtml = New-HtmlChangeDetailSectionLinks -SectionLinks @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $group -Path @('sectionLinks') -Default @()))
      if (-not [string]::IsNullOrWhiteSpace($sectionLinksHtml)) {
        $sampleItems.Add($sectionLinksHtml) | Out-Null
      }
      $debugPrimaryPath = Resolve-RelativeLinkFromPage -PageRelativePath $pageRelativePath -TargetRelativePath (Get-OptionalString -Value (Get-NestedValue -Object $group -Path @('debugPrimaryReportHtmlRelativePath')))
      if (-not [string]::IsNullOrWhiteSpace($debugPrimaryPath)) {
        $sampleItems.Add('<li><strong>Debug raw section:</strong> <a href="' + (Escape-Html $debugPrimaryPath) + '">open raw section</a></li>') | Out-Null
      }
      $changeDetailItems.Add(@"
<li>
  <a id="$(Escape-Html $groupAnchorId)"></a>
  <strong>${heading}:</strong> $detailCount details across $sectionCount sections
  <ul>$($sampleItems -join '')</ul>
</li>
"@) | Out-Null
    }
    $debugReportLink = Resolve-RelativeLinkFromPage -PageRelativePath $pageRelativePath -TargetRelativePath (Get-OptionalString -Value (Get-NestedValue -Object $changeDetails -Path @('debugReportHtmlRelativePath')))
    if (-not [string]::IsNullOrWhiteSpace($debugReportLink)) {
      $changeDetailItems.Add('<li><a href="' + (Escape-Html $debugReportLink) + '">open raw attributes report</a></li>') | Out-Null
    }
  }

  $targetLinks = Get-WorkspaceTargetLinks -PreviewCard $PreviewCard -Targets $Targets -ResultsRoot $ResultsRoot
  $debugEvidenceItems = New-Object System.Collections.Generic.List[string]
  foreach ($key in @('historyReport', 'sharedEvidence', 'publicRun', 'modeSummary', 'request')) {
    $path = Resolve-RelativeLinkFromPage -PageRelativePath $pageRelativePath -TargetRelativePath (Get-OptionalString -Value (Get-NestedValue -Object $targetLinks -Path @($key)))
    if ([string]::IsNullOrWhiteSpace($path)) {
      continue
    }
    $label = switch ($key) {
      'historyReport' { 'history report' }
      'sharedEvidence' { 'shared evidence' }
      'publicRun' { 'public run' }
      'modeSummary' { 'mode summary' }
      'request' { 'request' }
      default { $key }
    }
    $debugEvidenceItems.Add('<li><a href="' + (Escape-Html $path) + '">' + (Escape-Html $label) + '</a></li>') | Out-Null
  }

  return @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>$(Escape-Html $title)</title>
  <style>
    body { font-family: Segoe UI, sans-serif; margin: 0; color: #1f2933; background: #f8fafc; }
    .page-shell { max-width: 1200px; margin: 0 auto; padding: 2rem; }
    code { background: #e2e8f0; padding: 0.1rem 0.3rem; border-radius: 4px; }
    .pair-nav, .pair-meta, .pair-debug { background: #ffffff; border: 1px solid #cbd5e1; border-radius: 8px; padding: 1rem; margin-bottom: 1rem; }
    .pair-image-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 0.75rem; }
    .pair-image-grid figure { margin: 0; }
    .pair-image-grid img { max-width: 100%; height: auto; border: 1px solid #cbd5e1; background: #ffffff; }
    .pair-surface, .pair-section { background: #ffffff; border: 1px solid #cbd5e1; border-radius: 8px; padding: 1rem; margin-bottom: 1rem; }
    .pair-debug-links { color: #334155; }
  </style>
</head>
<body>
  <div class="page-shell">
    <h1><code>$(Escape-Html $title)</code></h1>
    <div class="pair-meta">
      <p><strong>History pair:</strong> $(Escape-Html $subtitle)</p>
      $(if (-not [string]::IsNullOrWhiteSpace($revisionContext)) { '<p><code>' + (Escape-Html $revisionContext) + '</code></p>' } else { '' })
      $(if ($detailLines.Count -gt 0) { '<div>' + (($detailLines | ForEach-Object { '<p>' + (Escape-Html $_) + '</p>' }) -join '') + '</div>' } else { '' })
    </div>
    <div class="pair-nav">
      <strong>Navigation:</strong>
      <a href="$(Escape-Html $workspaceHtmlLink)">workspace html</a>,
      <a href="$(Escape-Html $workspaceMarkdownLink)">workspace markdown</a>,
      <a href="#front-panel">front panel</a>,
      <a href="#block-diagram">block diagram</a>,
      <a href="#reviewer-summary">reviewer summary</a>,
      <a href="#change-details">change details</a>
    </div>
    $($surfaceSections -join "`n")
    <section class="pair-section" id="reviewer-summary">
      <h2>Reviewer summary</h2>
      $reviewerSummaryHtml
    </section>
    <section class="pair-section" id="change-details">
      <h2>Change details</h2>
      <ul>$($changeDetailItems -join '')</ul>
    </section>
    $(if ($debugEvidenceItems.Count -gt 0) {
      '<section class="pair-debug"><h2>Debug evidence</h2><ul>' + ($debugEvidenceItems -join '') + '</ul></section>'
    } else { '' })
  </div>
</body>
</html>
"@
}

function Write-WorkspacePairPages {
  param(
    [AllowEmptyCollection()]
    [object[]]$PreviewCards = @(),
    [AllowEmptyCollection()]
    [object[]]$Targets = @(),
    [Parameter(Mandatory = $true)]
    [string]$ResultsRoot
  )

  foreach ($previewCard in @(ConvertTo-ObjectArray -Value $PreviewCards)) {
    $markdownRelativePath = Get-OptionalString -Value $previewCard.pairPageMarkdownRelativePath
    $htmlRelativePath = Get-OptionalString -Value $previewCard.pairPageHtmlRelativePath
    if ([string]::IsNullOrWhiteSpace($markdownRelativePath) -or [string]::IsNullOrWhiteSpace($htmlRelativePath)) {
      continue
    }

    $markdownPath = Join-Path $ResultsRoot ($markdownRelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    $htmlPath = Join-Path $ResultsRoot ($htmlRelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    New-Item -ItemType Directory -Path (Split-Path -Parent $markdownPath) -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $htmlPath) -Force | Out-Null
    (New-MarkdownWorkspacePairPage -PreviewCard $previewCard -Targets $Targets -ResultsRoot $ResultsRoot) | Set-Content -LiteralPath $markdownPath -Encoding utf8
    (New-HtmlWorkspacePairPage -PreviewCard $previewCard -Targets $Targets -ResultsRoot $ResultsRoot) | Set-Content -LiteralPath $htmlPath -Encoding utf8
  }
}

function New-MarkdownPreviewGallery {
  param(
    [AllowEmptyCollection()]
    [object[]]$PreviewCards,
    [AllowEmptyCollection()]
    [object[]]$Targets = @(),
    [Parameter(Mandatory = $true)]
    [string]$ResultsRoot
  )

  if ($PreviewCards.Count -eq 0) {
    return ''
  }

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('## Review workspace') | Out-Null
  $lines.Add('') | Out-Null
  foreach ($previewCard in @(ConvertTo-ObjectArray -Value $PreviewCards)) {
    $anchorId = Get-WorkspaceCardAnchorId -PreviewCard $previewCard
    $title = Get-ReviewerPreviewTitle -PreviewPair $previewCard
    $subtitle = Get-ReviewerPreviewSubtitle -PreviewPair $previewCard
    $revisionContext = Get-ReviewerPreviewRevisionContext -PreviewPair $previewCard
    $detailLines = @(Get-ReviewerPreviewDetailLines -PreviewPair $previewCard)
    $quickLinkLine = New-MarkdownWorkspaceQuickLinkLine -PreviewCard $previewCard -Targets $Targets -ResultsRoot $ResultsRoot
    $lines.Add(('<a id="{0}"></a>' -f $anchorId)) | Out-Null
    $lines.Add('') | Out-Null
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
    if (-not [string]::IsNullOrWhiteSpace($quickLinkLine)) {
      $lines.Add($quickLinkLine) | Out-Null
      $lines.Add('') | Out-Null
    }
    foreach ($reviewerSummaryLine in @(New-MarkdownReviewerSummaryLines -ReviewerSummary (Get-NestedValue -Object $previewCard -Path @('reviewerSummary')))) {
      $lines.Add($reviewerSummaryLine) | Out-Null
    }
    foreach ($changeDetailLine in @(New-MarkdownChangeDetailsLines -ChangeDetails (Get-NestedValue -Object $previewCard -Path @('changeDetails')))) {
      $lines.Add($changeDetailLine) | Out-Null
    }
    foreach ($surface in @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $previewCard -Path @('surfaces') -Default @()))) {
      $surfaceLabel = Get-ReviewerPreviewSurfaceLabel -SurfaceKind (Get-OptionalString -Value $surface.surfaceKind) -FallbackLabel (Get-OptionalString -Value $surface.surfaceLabel)
      $surfaceReportPath = Get-OptionalString -Value $surface.reportHtmlRelativePath
      $lines.Add(('#### {0}' -f $surfaceLabel)) | Out-Null
      $lines.Add('') | Out-Null
      $lines.Add('**Base**') | Out-Null
      $baseImageMarkdown = (
        '![{0}]({1})' -f
          ('{0} base' -f $surfaceLabel),
          [string]$surface.baseImageRelativePath
      )
      if (-not [string]::IsNullOrWhiteSpace($surfaceReportPath)) {
        $baseImageMarkdown = '[{0}]({1})' -f $baseImageMarkdown, $surfaceReportPath
      }
      $lines.Add($baseImageMarkdown) | Out-Null
      $lines.Add('') | Out-Null
      $lines.Add('**Head**') | Out-Null
      $headImageMarkdown = (
        '![{0}]({1})' -f
          ('{0} head' -f $surfaceLabel),
          [string]$surface.headImageRelativePath
      )
      if (-not [string]::IsNullOrWhiteSpace($surfaceReportPath)) {
        $headImageMarkdown = '[{0}]({1})' -f $headImageMarkdown, $surfaceReportPath
      }
      $lines.Add($headImageMarkdown) | Out-Null
      if (-not [string]::IsNullOrWhiteSpace($surfaceReportPath)) {
        $lines.Add(('- Review page: [{0}]({0})' -f $surfaceReportPath)) | Out-Null
      }
      $lines.Add('') | Out-Null
    }
  }

  return $lines -join "`n"
}

function New-HtmlPreviewGallery {
  param(
    [AllowEmptyCollection()]
    [object[]]$PreviewCards,
    [AllowEmptyCollection()]
    [object[]]$Targets = @(),
    [Parameter(Mandatory = $true)]
    [string]$ResultsRoot
  )

  if ($PreviewCards.Count -eq 0) {
    return ''
  }

  $cards = New-Object System.Collections.Generic.List[string]
  foreach ($previewCard in @(ConvertTo-ObjectArray -Value $PreviewCards)) {
    $anchorId = Get-WorkspaceCardAnchorId -PreviewCard $previewCard
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
    $quickLinksHtml = New-HtmlWorkspaceQuickLinks -PreviewCard $previewCard -Targets $Targets -ResultsRoot $ResultsRoot
    $reviewerSummaryHtml = New-HtmlReviewerSummaryBlock -ReviewerSummary (Get-NestedValue -Object $previewCard -Path @('reviewerSummary'))
    $changeDetailsHtml = New-HtmlChangeDetailsBlock -ChangeDetails (Get-NestedValue -Object $previewCard -Path @('changeDetails'))
    $surfaceBlocks = New-Object System.Collections.Generic.List[string]
    foreach ($surface in @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $previewCard -Path @('surfaces') -Default @()))) {
      $surfaceLabel = Get-ReviewerPreviewSurfaceLabel -SurfaceKind (Get-OptionalString -Value $surface.surfaceKind) -FallbackLabel (Get-OptionalString -Value $surface.surfaceLabel)
      $reportLink = if ([string]::IsNullOrWhiteSpace([string]$surface.reportHtmlRelativePath)) {
        ''
      } else {
        '<p><a href="' + (Escape-Html ([string]$surface.reportHtmlRelativePath)) + '">open ' + (Escape-Html $surfaceLabel.ToLowerInvariant()) + ' review</a></p>'
      }
      $baseImageHtml = '<img alt="' + (Escape-Html ($surfaceLabel + ' base')) + '" src="' + (Escape-Html ([string]$surface.baseImageRelativePath)) + '">'
      if (-not [string]::IsNullOrWhiteSpace([string]$surface.reportHtmlRelativePath)) {
        $baseImageHtml = '<a href="' + (Escape-Html ([string]$surface.reportHtmlRelativePath)) + '">' + $baseImageHtml + '</a>'
      }
      $headImageHtml = '<img alt="' + (Escape-Html ($surfaceLabel + ' head')) + '" src="' + (Escape-Html ([string]$surface.headImageRelativePath)) + '">'
      if (-not [string]::IsNullOrWhiteSpace([string]$surface.reportHtmlRelativePath)) {
        $headImageHtml = '<a href="' + (Escape-Html ([string]$surface.reportHtmlRelativePath)) + '">' + $headImageHtml + '</a>'
      }
      $surfaceBlocks.Add(@"
  <section class="preview-surface">
    <h4>$(Escape-Html $surfaceLabel)</h4>
    <div class="preview-image-grid">
      <figure>
        $baseImageHtml
        <figcaption>Base</figcaption>
      </figure>
      <figure>
        $headImageHtml
        <figcaption>Head</figcaption>
      </figure>
    </div>
    $reportLink
  </section>
"@) | Out-Null
    }
    $cards.Add(@"
<article class="preview-card" id="$(Escape-Html $anchorId)">
  <h3>$(Escape-Html $title)</h3>
  <p class="preview-card-subtitle">$(Escape-Html $subtitle)</p>
  <div class="preview-card-meta">
    <strong>History pair</strong><span><code>$(Escape-Html ([string]$comparisonIndex))</code></span>
    <strong>Revisions</strong><span><code>$(Escape-Html $revisionContext)</code></span>
  </div>
  $detailHtml
  $quickLinksHtml
  $reviewerSummaryHtml
  $changeDetailsHtml
  $($surfaceBlocks -join "`n  ")
</article>
"@) | Out-Null
  }

  return @"
  <section class="preview-gallery">
    <h2>Review workspace</h2>
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
$commentPreviewCards = @()
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
  $commentPreviewCards = @(New-ReviewerPreviewCards `
      -SelectedPreviewPairs @($previewManifest.commentPreviewPairs | ForEach-Object { $_ }) `
      -AllPreviewPairs @($previewManifest.previewPairs | ForEach-Object { $_ }) `
      -ExistingCards @($previewManifest.commentPreviewCards | ForEach-Object { $_ }))
  $indexPreviewCards = @(New-WorkspacePrimaryPreviewCards -PreviewCards $indexPreviewCards)
  $commentPreviewCards = @(New-WorkspacePrimaryPreviewCards -PreviewCards $commentPreviewCards)
  Write-WorkspacePairPages -PreviewCards $indexPreviewCards -Targets $targets -ResultsRoot $resultsDirResolved
  $previewManifest.indexPreviewCards = @($indexPreviewCards | ForEach-Object { $_ })
  $previewManifest.indexPreviewPairs = @(New-WorkspacePrimaryPreviewPairs -PreviewCards $indexPreviewCards)
  $previewManifest.commentPreviewCards = @($commentPreviewCards | ForEach-Object { $_ })
  $previewManifest.commentPreviewPairs = @(New-WorkspacePrimaryPreviewPairs -PreviewCards $commentPreviewCards)
  $previewManifest.summary.indexPreviewCardCount = $indexPreviewCards.Count
  $previewManifest.summary.commentPreviewCardCount = $commentPreviewCards.Count
  ($previewManifest | ConvertTo-Json -Depth 100) | Set-Content -LiteralPath $previewManifestPathResolved -Encoding utf8
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
$indexLines.Add('# comparevi-history PR diagnostics workspace') | Out-Null
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
foreach ($summaryLine in @(New-MarkdownWorkspaceSummary -PreviewCards $indexPreviewCards -Targets $targets)) {
  $indexLines.Add($summaryLine) | Out-Null
}
foreach ($navigationLine in @(New-MarkdownWorkspaceNavigation -PreviewCards $indexPreviewCards -Targets $targets -ResultsRoot $resultsDirResolved)) {
  $indexLines.Add($navigationLine) | Out-Null
}
$previewGalleryMarkdown = New-MarkdownPreviewGallery -PreviewCards $indexPreviewCards -Targets $targets -ResultsRoot $resultsDirResolved
if (-not [string]::IsNullOrWhiteSpace($previewGalleryMarkdown)) {
  $indexLines.Add($previewGalleryMarkdown) | Out-Null
  $indexLines.Add('') | Out-Null
}
$indexLines.Add('## Raw evidence inventory') | Out-Null
$indexLines.Add('') | Out-Null
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
  <title>comparevi-history PR diagnostics workspace</title>
  <style>
    body { font-family: Segoe UI, sans-serif; margin: 0; color: #1f2933; background: #f8fafc; }
    .page-shell { max-width: 1600px; margin: 0 auto; padding: 2rem; }
    code { background: #e2e8f0; padding: 0.1rem 0.3rem; border-radius: 4px; }
    table { width: 100%; border-collapse: collapse; margin-top: 1rem; background: #ffffff; }
    th, td { border: 1px solid #cbd5e1; padding: 0.6rem; text-align: left; vertical-align: top; }
    th { background: #e2e8f0; }
    h1 { margin-top: 0; margin-bottom: 1rem; }
    ul { padding-left: 1.2rem; }
    .workspace-shell { display: grid; grid-template-columns: minmax(18rem, 24rem) minmax(0, 1fr); gap: 1.5rem; align-items: start; }
    .workspace-main { min-width: 0; }
    .workspace-meta { margin: 0 0 1.25rem 0; padding-left: 1.2rem; }
    .workspace-summary { display: grid; grid-template-columns: repeat(auto-fit, minmax(12rem, 1fr)); gap: 0.75rem; margin: 0 0 1.5rem 0; }
    .workspace-summary-card { background: #ffffff; border: 1px solid #cbd5e1; border-radius: 8px; padding: 0.9rem 1rem; display: grid; gap: 0.4rem; }
    .workspace-nav { position: sticky; top: 1rem; background: #ffffff; border: 1px solid #cbd5e1; border-radius: 8px; padding: 1rem; }
    .workspace-nav h2 { margin-top: 0; }
    .workspace-nav-list { list-style: none; padding: 0; margin: 0; display: grid; gap: 0.85rem; }
    .workspace-nav-item { border-top: 1px solid #e2e8f0; padding-top: 0.85rem; }
    .workspace-nav-item:first-child { border-top: none; padding-top: 0; }
    .workspace-nav-link { font-weight: 600; color: #0f172a; text-decoration: none; }
    .workspace-nav-severity { margin: 0.25rem 0 0.35rem 0; }
    .workspace-nav-headline { margin: 0 0 0.45rem 0; color: #334155; }
    .workspace-quick-links { margin: 0.5rem 0 0 0; font-size: 0.92rem; color: #334155; line-height: 1.5; }
    .workspace-quick-links a { white-space: nowrap; }
    .preview-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(24rem, 1fr)); gap: 1rem; margin: 1.5rem 0; }
    .preview-card { background: #ffffff; border: 1px solid #cbd5e1; border-radius: 8px; padding: 1rem; scroll-margin-top: 1rem; }
    .preview-card-subtitle { color: #334155; margin-top: -0.35rem; margin-bottom: 1rem; }
    .preview-card-meta { display: grid; grid-template-columns: max-content 1fr; gap: 0.25rem 0.75rem; margin-bottom: 1rem; }
    .preview-surface + .preview-surface { margin-top: 1rem; }
    .preview-surface h4 { margin-bottom: 0.75rem; }
    .preview-image-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 0.75rem; }
    .preview-image-grid figure { margin: 0; }
    .preview-image-grid img { max-width: 100%; height: auto; border: 1px solid #cbd5e1; background: #ffffff; }
    .preview-image-grid figcaption { font-size: 0.85rem; color: #52606d; margin-top: 0.35rem; }
    .raw-evidence { margin-top: 2rem; }
    @media (max-width: 1100px) {
      .workspace-shell { grid-template-columns: 1fr; }
      .workspace-nav { position: static; }
    }
  </style>
</head>
<body>
  <div class="page-shell">
    <h1>comparevi-history PR diagnostics workspace</h1>
    <div class="workspace-shell">
      $(New-HtmlWorkspaceNavigation -PreviewCards $indexPreviewCards -Targets $targets -ResultsRoot $resultsDirResolved)
      <main class="workspace-main">
        <ul class="workspace-meta">
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
        $(New-HtmlWorkspaceSummary -PreviewCards $indexPreviewCards -Targets $targets)
        $(New-HtmlPreviewGallery -PreviewCards $indexPreviewCards -Targets $targets -ResultsRoot $resultsDirResolved)
        <section class="raw-evidence">
          <h2>Raw evidence inventory</h2>
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
              $($htmlRows -join "`n              ")
            </tbody>
          </table>
        </section>
      </main>
    </div>
  </div>
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
