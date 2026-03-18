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

$reviewerChangeDetailGroupCap = 3
$reviewerChangeDetailSampleCap = 3

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

$gitCommitSubjectCache = @{}

function Resolve-TargetRepositoryRoot {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Target,
    [Parameter(Mandatory = $true)]
    [string]$BasePath
  )

  $publicRunPath = Resolve-ExistingPath -Path (Get-OptionalString -Value (Get-NestedValue -Object $Target -Path @('publicRunPath'))) -BasePath $BasePath -PathType Leaf
  if ($null -eq $publicRunPath) {
    return $null
  }

  try {
    $publicRun = Read-JsonFile -Path $publicRunPath
  } catch {
    return $null
  }

  $repositoryRoot = Get-OptionalString -Value (Get-NestedValue -Object $publicRun -Path @('request', 'consumer', 'repositoryRoot'))
  if ([string]::IsNullOrWhiteSpace($repositoryRoot)) {
    return $null
  }

  $resolvedRepositoryRoot = Resolve-ExistingPath -Path $repositoryRoot -BasePath $BasePath -PathType Container
  if ($null -eq $resolvedRepositoryRoot) {
    return $null
  }

  if (-not (Test-Path -LiteralPath (Join-Path $resolvedRepositoryRoot '.git'))) {
    return $null
  }

  return $resolvedRepositoryRoot
}

function Get-GitCommitSubject {
  param(
    [AllowNull()]
    [string]$RepositoryRoot,
    [AllowNull()]
    [string]$Ref
  )

  $resolvedRepositoryRoot = Get-OptionalString -Value $RepositoryRoot
  $resolvedRef = Get-OptionalString -Value $Ref
  if ([string]::IsNullOrWhiteSpace($resolvedRepositoryRoot) -or [string]::IsNullOrWhiteSpace($resolvedRef)) {
    return $null
  }

  $cacheKey = '{0}|{1}' -f $resolvedRepositoryRoot, $resolvedRef
  if ($gitCommitSubjectCache.ContainsKey($cacheKey)) {
    return $gitCommitSubjectCache[$cacheKey]
  }

  $subject = $null
  try {
    $subject = (& git -C $resolvedRepositoryRoot show -s --format=%s $resolvedRef 2>$null)
    if ($LASTEXITCODE -ne 0) {
      $subject = $null
    }
  } catch {
    $subject = $null
  }

  $subject = Get-OptionalString -Value $subject
  $gitCommitSubjectCache[$cacheKey] = $subject
  return $subject
}

function New-PreviewPairComparison {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Comparison,
    [AllowNull()]
    [string]$RepositoryRoot
  )

  $index = [int](Get-NestedValue -Object $Comparison -Path @('index') -Default 0)
  $baseRef = Get-OptionalString -Value (Get-NestedValue -Object $Comparison -Path @('base', 'ref'))
  $headRef = Get-OptionalString -Value (Get-NestedValue -Object $Comparison -Path @('head', 'ref'))
  $baseShortRef = Get-OptionalString -Value (Get-NestedValue -Object $Comparison -Path @('base', 'short'))
  if ([string]::IsNullOrWhiteSpace($baseShortRef)) {
    $baseShortRef = ConvertTo-ShortRef -Ref $baseRef
  }

  $headShortRef = Get-OptionalString -Value (Get-NestedValue -Object $Comparison -Path @('head', 'short'))
  if ([string]::IsNullOrWhiteSpace($headShortRef)) {
    $headShortRef = ConvertTo-ShortRef -Ref $headRef
  }

  return [ordered]@{
    index = $index
    baseRef = $baseRef
    headRef = $headRef
    baseShortRef = $baseShortRef
    headShortRef = $headShortRef
    baseSubject = Get-GitCommitSubject -RepositoryRoot $RepositoryRoot -Ref $baseRef
    headSubject = Get-GitCommitSubject -RepositoryRoot $RepositoryRoot -Ref $headRef
  }
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

function Get-FileSha256Hex {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  return [string](Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-PreviewPairReviewerIdentityKey {
  param(
    [Parameter(Mandatory = $true)]
    [object]$PreviewPair
  )

  return '{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f `
    [string]$PreviewPair.targetId, `
    [int](Get-NestedValue -Object $PreviewPair -Path @('comparison', 'index') -Default 0), `
    [string]$PreviewPair.sectionKind, `
    [int](Get-NestedValue -Object $PreviewPair -Path @('sectionOrdinal') -Default 0), `
    [string]$PreviewPair.label, `
    $(if ([string]::IsNullOrWhiteSpace([string]$PreviewPair.baseImageSha256)) { [string]$PreviewPair.baseImageRelativePath } else { [string]$PreviewPair.baseImageSha256 }), `
    $(if ([string]::IsNullOrWhiteSpace([string]$PreviewPair.headImageSha256)) { [string]$PreviewPair.headImageRelativePath } else { [string]$PreviewPair.headImageSha256 })
}

function Get-ReviewerPreviewSurfaceKind {
  param(
    [Parameter(Mandatory = $true)]
    [object]$PreviewPair
  )

  switch ([string]$PreviewPair.mode) {
    'front-panel' { return 'front-panel' }
    'block-diagram' { return 'block-diagram' }
    default { return $null }
  }
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

function Normalize-ReviewerChangeDetailHeading {
  param(
    [AllowNull()]
    [string]$Heading
  )

  $normalizedHeading = Get-OptionalString -Value $Heading
  if ([string]::IsNullOrWhiteSpace($normalizedHeading)) {
    return $null
  }

  return (($normalizedHeading -replace '^\d+\.\s*', '').Trim())
}

function Get-ReviewerChangeDetailSectionOrdinal {
  param(
    [AllowNull()]
    [string]$Heading
  )

  $normalizedHeading = Get-OptionalString -Value $Heading
  if ([string]::IsNullOrWhiteSpace($normalizedHeading)) {
    return $null
  }

  $ordinalMatch = [regex]::Match($normalizedHeading, '^\s*(?<ordinal>\d+)\.')
  if (-not $ordinalMatch.Success) {
    return $null
  }

  return [int]$ordinalMatch.Groups['ordinal'].Value
}

function Get-ReviewerChangeDetailLineParts {
  param(
    [AllowNull()]
    [string]$DetailLine
  )

  $normalizedDetailLine = Get-OptionalString -Value $DetailLine
  if ([string]::IsNullOrWhiteSpace($normalizedDetailLine)) {
    return [ordered]@{
      subject = $null
      action = $null
    }
  }

  $prefix = $normalizedDetailLine
  $colonIndex = $prefix.IndexOf(':')
  if ($colonIndex -ge 0) {
    $prefix = $prefix.Substring(0, $colonIndex)
  }

  $prefix = ($prefix -replace '\s+', ' ').Trim()
  if ([string]::IsNullOrWhiteSpace($prefix)) {
    return [ordered]@{
      subject = $null
      action = $null
    }
  }

  $subject = $prefix
  $action = $null
  $actionMatch = [regex]::Match($prefix, '^(?<subject>.*?)\s*-\s*(?<action>[^-].+?)$')
  if ($actionMatch.Success) {
    $subject = ($actionMatch.Groups['subject'].Value -replace '\s+', ' ').Trim()
    $action = ($actionMatch.Groups['action'].Value -replace '\s+', ' ').Trim()
  }

  if ([string]::IsNullOrWhiteSpace($subject)) {
    $subject = $null
  }

  if ([string]::IsNullOrWhiteSpace($action)) {
    $action = $null
  }

  return [ordered]@{
    subject = $subject
    action = $action
  }
}

function Get-ReviewerSemanticHeadingFromSection {
  param(
    [Parameter(Mandatory = $true)]
    [string]$SectionHeading,
    [AllowNull()]
    [string]$DetailLine
  )

  $normalizedHeading = Normalize-ReviewerChangeDetailHeading -Heading $SectionHeading
  if ([string]::IsNullOrWhiteSpace($normalizedHeading)) {
    return 'Change details'
  }

  $detailParts = Get-ReviewerChangeDetailLineParts -DetailLine $DetailLine
  $subject = Get-OptionalString -Value $detailParts.subject
  $action = (Get-OptionalString -Value $detailParts.action)
  if (-not [string]::IsNullOrWhiteSpace($action)) {
    $action = $action.ToLowerInvariant()
  }

  switch -Regex ($normalizedHeading) {
    '^Block Diagram objects$' {
      switch ($action) {
        'moved' { return 'Block diagram moves' }
        'resized' { return 'Block diagram resizing' }
        'deleted' { return 'Removed block diagram objects' }
        'added' { return 'Added block diagram objects' }
        default { return 'Block diagram object changes' }
      }
    }
    '^Front Panel objects$' {
      switch ($action) {
        'moved' { return 'Front panel layout moves' }
        'resized' { return 'Front panel resizing' }
        'deleted' { return 'Removed front panel objects' }
        'added' { return 'Added front panel objects' }
        default { return 'Front panel object changes' }
      }
    }
    '^VI Attribute\b' {
      if ($subject -match '^VI Version$') {
        return 'VI version changes'
      }

      if ($subject -match '^Execution\b') {
        return 'Execution changes'
      }

      if ($subject -match '^Icon\b') {
        return 'Icon changes'
      }

      return 'VI attribute changes'
    }
    default {
      return $normalizedHeading
    }
  }
}

function Get-ReviewerAnchoredReportPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ReportHtmlPath
  )

  $directory = Split-Path -Parent $ReportHtmlPath
  $fileNameWithoutExtension = [System.IO.Path]::GetFileNameWithoutExtension($ReportHtmlPath)
  $extension = [System.IO.Path]::GetExtension($ReportHtmlPath)
  return Join-Path $directory ('{0}.reviewer-anchors{1}' -f $fileNameWithoutExtension, $extension)
}

function Get-ReviewerChangeDetailSectionsFromReport {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ReportHtmlPath,
    [Parameter(Mandatory = $true)]
    [string]$ResultsRoot
  )

  if (-not (Test-Path -LiteralPath $ReportHtmlPath -PathType Leaf)) {
    return [ordered]@{
      reportHtml = $null
      sections = @()
    }
  }

  $reportHtml = Get-Content -LiteralPath $ReportHtmlPath -Raw
  if ([string]::IsNullOrWhiteSpace($reportHtml)) {
    return [ordered]@{
      reportHtml = $reportHtml
      sections = @()
    }
  }

  $sections = New-Object System.Collections.Generic.List[object]
  $detailPattern = '(?is)(?<open><details(?<detailsAttributes>[^>]*)>)\s*<summary(?<summaryAttributes>[^>]*)>(?<summary>.*?)</summary>(?<body>.*?)</details>'
  $matches = [regex]::Matches($reportHtml, $detailPattern)
  if ($matches.Count -eq 0) {
    return [ordered]@{
      reportHtml = $reportHtml
      sections = @()
    }
  }

  $builder = New-Object System.Text.StringBuilder
  $cursor = 0
  $sectionIndex = 0
  $htmlChanged = $false

  foreach ($match in $matches) {
    $null = $builder.Append($reportHtml.Substring($cursor, $match.Index - $cursor))

    $blockHtml = [string]$match.Value
    $bodyHtml = [string]$match.Groups['body'].Value
    if ($bodyHtml -match 'detailed-description-list') {
      $sectionIndex += 1
      $summaryText = ConvertFrom-HtmlText -Value ([string]$match.Groups['summary'].Value)
      $heading = Normalize-ReviewerChangeDetailHeading -Heading $summaryText
      if ([string]::IsNullOrWhiteSpace($heading)) {
        $heading = 'Change details'
      }

      $sectionOrdinal = Get-ReviewerChangeDetailSectionOrdinal -Heading $summaryText
      if ($null -eq $sectionOrdinal) {
        $sectionOrdinal = $sectionIndex
      }

      $existingIdMatch = [regex]::Match([string]$match.Groups['detailsAttributes'].Value, '\bid="(?<id>[^"]+)"')
      $anchorId = Get-OptionalString -Value $existingIdMatch.Groups['id'].Value
      if ([string]::IsNullOrWhiteSpace($anchorId)) {
        $anchorId = 'comparevi-change-{0:D3}-{1}' -f $sectionOrdinal, (ConvertTo-Slug -Value $heading -Fallback 'change-detail')
        $openTag = [string]$match.Groups['open'].Value
        $updatedOpenTag = if ($openTag -match '\bid="[^"]+"') {
          $openTag
        } else {
          $openTag.Insert($openTag.Length - 1, (' id="{0}"' -f $anchorId))
        }
        $blockHtml = $updatedOpenTag + $blockHtml.Substring($openTag.Length)
        $htmlChanged = $true
      }

      $detailLines = @(
        [regex]::Matches($bodyHtml, '(?is)<li class="[^"]*diff-detail[^"]*">(?<detail>.*?)</li>') |
          ForEach-Object { ConvertFrom-HtmlText -Value ([string]$_.Groups['detail'].Value) } |
          Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
      )

      if ($detailLines.Count -gt 0) {
        $sections.Add([ordered]@{
            index = $sectionIndex
            ordinal = [int]$sectionOrdinal
            heading = $heading
            anchorId = $anchorId
            detailLines = $detailLines
          }) | Out-Null
      }
    }

    $null = $builder.Append($blockHtml)
    $cursor = $match.Index + $match.Length
  }

  if ($cursor -lt $reportHtml.Length) {
    $null = $builder.Append($reportHtml.Substring($cursor))
  }

  $updatedReportHtml = $builder.ToString()
  $effectiveReportHtmlPath = $ReportHtmlPath
  if ($htmlChanged -and -not [string]::Equals($updatedReportHtml, $reportHtml, [System.StringComparison]::Ordinal)) {
    $effectiveReportHtmlPath = Get-ReviewerAnchoredReportPath -ReportHtmlPath $ReportHtmlPath
    Set-Content -LiteralPath $effectiveReportHtmlPath -Encoding utf8 -Value $updatedReportHtml
  }

  $effectiveReportHtmlRelativePath = Resolve-RelativePath -Path $effectiveReportHtmlPath -ResultsRoot $ResultsRoot
  foreach ($section in @($sections | ForEach-Object { $_ })) {
    $section['reportHtmlRelativePath'] = '{0}#{1}' -f $effectiveReportHtmlRelativePath, [string]$section['anchorId']
  }

  return [ordered]@{
    reportHtml = $updatedReportHtml
    reportHtmlRelativePath = $effectiveReportHtmlRelativePath
    sections = @($sections | ForEach-Object { $_ })
  }
}

function Get-ReportIncludedCategories {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ReportHtml
  )

  $includedCategories = New-Object System.Collections.Generic.List[string]
  $includedBlockMatch = [regex]::Match($ReportHtml, '(?is)<div class="included-attributes".*?<ul[^>]*>(?<list>.*?)</ul>')
  if (-not $includedBlockMatch.Success) {
    return @()
  }

  foreach ($itemMatch in [regex]::Matches([string]$includedBlockMatch.Groups['list'].Value, '(?is)<li class="checked">(?<item>.*?)</li>')) {
    $itemText = ConvertFrom-HtmlText -Value ([string]$itemMatch.Groups['item'].Value)
    if ([string]::IsNullOrWhiteSpace($itemText)) {
      continue
    }

    $includedCategories.Add($itemText) | Out-Null
  }

  return @($includedCategories | ForEach-Object { $_ })
}

function Get-ReviewerChangeDetailsFromReport {
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
    [object]$Comparison,
    [AllowNull()]
    [string]$RepositoryRoot
  )

  if (-not (Test-Path -LiteralPath $ReportHtmlPath -PathType Leaf)) {
    return $null
  }

  $sectionReceipt = Get-ReviewerChangeDetailSectionsFromReport -ReportHtmlPath $ReportHtmlPath -ResultsRoot $ResultsRoot
  $reportHtml = [string](Get-NestedValue -Object $sectionReceipt -Path @('reportHtml') -Default '')
  if ([string]::IsNullOrWhiteSpace($reportHtml)) {
    return $null
  }

  $effectiveReportHtmlRelativePath = Get-OptionalString -Value (Get-NestedValue -Object $sectionReceipt -Path @('reportHtmlRelativePath'))
  if ([string]::IsNullOrWhiteSpace($effectiveReportHtmlRelativePath)) {
    $effectiveReportHtmlRelativePath = Resolve-RelativePath -Path $ReportHtmlPath -ResultsRoot $ResultsRoot
  }

  $includedCategories = @(Get-ReportIncludedCategories -ReportHtml $reportHtml)
  $groupMap = @{}
  $groupOrder = New-Object System.Collections.Generic.List[string]
  foreach ($section in @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $sectionReceipt -Path @('sections') -Default @()))) {
    $sectionHeading = Get-OptionalString -Value (Get-NestedValue -Object $section -Path @('heading'))
    $sectionOrdinal = [int](Get-NestedValue -Object $section -Path @('ordinal') -Default 0)
    $sectionPath = Get-OptionalString -Value (Get-NestedValue -Object $section -Path @('reportHtmlRelativePath'))
    $sectionLinkRecord = [ordered]@{
      sectionOrdinal = $sectionOrdinal
      label = ('section {0}' -f $sectionOrdinal)
      reportHtmlRelativePath = $sectionPath
    }

    $sectionGroupKeys = New-Object System.Collections.Generic.HashSet[string]
    foreach ($detailLine in @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $section -Path @('detailLines') -Default @()))) {
      $semanticHeading = Get-ReviewerSemanticHeadingFromSection -SectionHeading $sectionHeading -DetailLine ([string]$detailLine)
      if (-not $groupMap.ContainsKey($semanticHeading)) {
        $groupMap[$semanticHeading] = [ordered]@{
          heading = $semanticHeading
          sectionCount = 0
          detailCount = 0
          sampleDetails = New-Object System.Collections.Generic.List[string]
          sectionLinks = New-Object System.Collections.Generic.List[object]
        }
        $groupOrder.Add($semanticHeading) | Out-Null
      }

      $groupRecord = $groupMap[$semanticHeading]
      if ($sectionGroupKeys.Add($semanticHeading)) {
        $groupRecord.sectionCount = [int]$groupRecord.sectionCount + 1
        $groupRecord.sectionLinks.Add($sectionLinkRecord) | Out-Null
      }

      $groupRecord.detailCount = [int]$groupRecord.detailCount + 1
      if ($groupRecord.sampleDetails.Count -lt $reviewerChangeDetailSampleCap) {
        $groupRecord.sampleDetails.Add([string]$detailLine) | Out-Null
      }
    }
  }

  if ($groupOrder.Count -eq 0 -and $includedCategories.Count -eq 0) {
    return $null
  }

  $groupItems = New-Object System.Collections.Generic.List[object]
  $sectionCount = 0
  $detailCount = 0
  foreach ($heading in @($groupOrder | Select-Object -First $reviewerChangeDetailGroupCap)) {
    $groupRecord = $groupMap[$heading]
    $sectionCount += [int]$groupRecord.sectionCount
    $detailCount += [int]$groupRecord.detailCount
    $sampleDetails = @($groupRecord.sampleDetails | ForEach-Object { $_ })
    $groupItems.Add([ordered]@{
        heading = [string]$groupRecord.heading
        sectionCount = [int]$groupRecord.sectionCount
        detailCount = [int]$groupRecord.detailCount
        sampleDetails = $sampleDetails
        omittedDetailCount = [Math]::Max([int]$groupRecord.detailCount - $sampleDetails.Count, 0)
        primaryReportHtmlRelativePath = $(if ($groupRecord.sectionLinks.Count -gt 0) { Get-OptionalString -Value $groupRecord.sectionLinks[0].reportHtmlRelativePath } else { $null })
        sectionLinks = @($groupRecord.sectionLinks | ForEach-Object { $_ })
      }) | Out-Null
  }

  foreach ($heading in @($groupOrder | Select-Object -Skip $reviewerChangeDetailGroupCap)) {
    $groupRecord = $groupMap[$heading]
    $sectionCount += [int]$groupRecord.sectionCount
    $detailCount += [int]$groupRecord.detailCount
  }

  $comparisonReceipt = New-PreviewPairComparison -Comparison $Comparison -RepositoryRoot $RepositoryRoot
  return [ordered]@{
    targetId = $TargetId
    targetPath = $TargetPath
    comparison = $comparisonReceipt
    sortKey = '{0}|{1:D4}|change-details' -f $TargetPath, [int]$comparisonReceipt.index
    changeDetails = [ordered]@{
      label = 'Change details'
      sourceMode = 'attributes'
      reportHtmlRelativePath = $effectiveReportHtmlRelativePath
      includedCategories = $includedCategories
      groupCount = $groupOrder.Count
      omittedGroupCount = [Math]::Max($groupOrder.Count - $groupItems.Count, 0)
      sectionCount = $sectionCount
      detailCount = $detailCount
      groups = @($groupItems | ForEach-Object { $_ })
    }
  }
}

function New-PreviewSurfaceCandidate {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Label,
    [Parameter(Mandatory = $true)]
    [string]$BaseImagePath,
    [Parameter(Mandatory = $true)]
    [string]$HeadImagePath
  )

  return [ordered]@{
    label = $Label
    baseImagePath = $BaseImagePath
    headImagePath = $HeadImagePath
  }
}

function Get-ReportPreviewSurfaceCandidates {
  param(
    [Parameter(Mandatory = $true)]
    [string]$TableHtml,
    [Parameter(Mandatory = $true)]
    [string]$ReportDirectory
  )

  $candidates = New-Object System.Collections.Generic.List[object]
  $surfacePattern = '(?is)<tr class="compared-vi-image-captions">.*?<td class="compared-vi-image-caption">(?<caption>.*?)</td>.*?</tr>\s*<tr class="compared-images">(?<images>.*?)</tr>'
  foreach ($surfaceMatch in [regex]::Matches($TableHtml, $surfacePattern)) {
    $caption = ConvertFrom-HtmlText -Value ([string]$surfaceMatch.Groups['caption'].Value)
    $imageSources = @(
      [regex]::Matches([string]$surfaceMatch.Groups['images'].Value, '(?is)<img[^>]+src="(?<src>[^"]+)"') |
        ForEach-Object { Get-OptionalString -Value ([string]$_.Groups['src'].Value) } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($imageSources.Count -lt 2) {
      continue
    }

    $baseImagePath = Resolve-ExistingPath -Path $imageSources[0] -BasePath $ReportDirectory -PathType Leaf
    $headImagePath = Resolve-ExistingPath -Path $imageSources[1] -BasePath $ReportDirectory -PathType Leaf
    if ($null -eq $baseImagePath -or $null -eq $headImagePath) {
      continue
    }

    $candidates.Add((New-PreviewSurfaceCandidate -Label $caption -BaseImagePath $baseImagePath -HeadImagePath $headImagePath)) | Out-Null
  }

  return @($candidates | ForEach-Object { $_ })
}

function Test-PreviewSurfaceMatchesMode {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Candidate,
    [Parameter(Mandatory = $true)]
    [string]$Mode
  )

  $label = ([string]$Candidate.label).ToLowerInvariant()
  $baseName = [System.IO.Path]::GetFileName([string]$Candidate.baseImagePath).ToLowerInvariant()
  $headName = [System.IO.Path]::GetFileName([string]$Candidate.headImagePath).ToLowerInvariant()

  switch ($Mode) {
    'front-panel' {
      return $label -match 'front panel' -or $baseName -like 'fp_*' -or $headName -like 'fp_*'
    }
    'block-diagram' {
      return $label -match 'block diagram' -or $baseName -like 'bd_*' -or $headName -like 'bd_*'
    }
    'attributes' {
      return $label -match 'attribute'
    }
    default {
      return $false
    }
  }
}

function Select-PreviewSurfaceCandidateForMode {
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$Candidates,
    [Parameter(Mandatory = $true)]
    [string]$Mode
  )

  if ($Candidates.Count -eq 0) {
    return $null
  }

  $matchingCandidate = @(
    $Candidates |
      Where-Object { Test-PreviewSurfaceMatchesMode -Candidate $_ -Mode $Mode } |
      Select-Object -First 1
  )
  if ($matchingCandidate.Count -gt 0) {
    return $matchingCandidate[0]
  }

  if ($Mode -eq 'front-panel') {
    return $Candidates[0]
  }

  return $null
}

function Get-ReviewerPreviewPairArray {
  param(
    [AllowNull()]
    $Value
  )

  $selected = New-Object System.Collections.Generic.List[object]
  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($previewPair in @(ConvertTo-PreviewPairArray -Value $Value)) {
    $identityKey = Get-ReviewerPreviewCardKey -PreviewPair $previewPair
    if (-not $seen.Add($identityKey)) {
      continue
    }

    $selected.Add($previewPair) | Out-Null
  }

  return @($selected | ForEach-Object { $_ })
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

  return @(
    Get-ReviewerPreviewPairArray -Value $PreviewPairs |
      Select-Object -First $Limit
  )
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

function New-ReviewerPreviewSurface {
  param(
    [Parameter(Mandatory = $true)]
    [object]$PreviewPair
  )

  $surfaceKind = Get-ReviewerPreviewSurfaceKind -PreviewPair $PreviewPair
  if ([string]::IsNullOrWhiteSpace($surfaceKind)) {
    $surfaceKind = 'preview'
  }

  return [ordered]@{
    surfaceKind = $surfaceKind
    surfaceLabel = Get-ReviewerPreviewSurfaceLabel -SurfaceKind $surfaceKind -FallbackLabel ([string]$PreviewPair.label)
    mode = Get-OptionalString -Value $PreviewPair.mode
    label = [string]$PreviewPair.label
    reportHtmlRelativePath = Get-OptionalString -Value $PreviewPair.reportHtmlRelativePath
    baseImageRelativePath = [string]$PreviewPair.baseImageRelativePath
    headImageRelativePath = [string]$PreviewPair.headImageRelativePath
    baseByteLength = [int64](Get-NestedValue -Object $PreviewPair -Path @('baseByteLength') -Default 0)
    headByteLength = [int64](Get-NestedValue -Object $PreviewPair -Path @('headByteLength') -Default 0)
    baseImageSha256 = Get-OptionalString -Value $PreviewPair.baseImageSha256
    headImageSha256 = Get-OptionalString -Value $PreviewPair.headImageSha256
    sortKey = Get-OptionalString -Value $PreviewPair.sortKey
  }
}

function New-ReviewerPreviewCards {
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$SelectedPreviewPairs,
    [AllowEmptyCollection()]
    [object[]]$AllPreviewPairs = @(),
    [AllowEmptyCollection()]
    [object[]]$AllChangeDetails = @()
  )

  $orderedAllPreviewPairs = @(ConvertTo-PreviewPairArray -Value $AllPreviewPairs)
  if ($orderedAllPreviewPairs.Count -eq 0) {
    $orderedAllPreviewPairs = @(ConvertTo-PreviewPairArray -Value $SelectedPreviewPairs)
  }

  $cards = New-Object System.Collections.Generic.List[object]
  $seenCards = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $changeDetailsByCardKey = @{}
  foreach ($changeDetailRecord in @(ConvertTo-ObjectArray -Value $AllChangeDetails)) {
    $changeDetailKey = '{0}|{1}' -f `
      [string]$changeDetailRecord.targetId, `
      [int](Get-NestedValue -Object $changeDetailRecord -Path @('comparison', 'index') -Default 0)
    $changeDetailsByCardKey[$changeDetailKey] = Get-NestedValue -Object $changeDetailRecord -Path @('changeDetails')
  }
  foreach ($selectedPreviewPair in @(ConvertTo-PreviewPairArray -Value $SelectedPreviewPairs)) {
    $cardKey = Get-ReviewerPreviewCardKey -PreviewPair $selectedPreviewPair
    if (-not $seenCards.Add($cardKey)) {
      continue
    }

    $matchingPairs = @(
      $orderedAllPreviewPairs |
        Where-Object {
          (Get-ReviewerPreviewCardKey -PreviewPair $_) -eq $cardKey
        }
    )
    if ($matchingPairs.Count -eq 0) {
      $matchingPairs = @($selectedPreviewPair)
    }

    $surfaces = New-Object System.Collections.Generic.List[object]
    $seenSurfaceKinds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($matchingPair in $matchingPairs) {
      $surfaceKind = Get-ReviewerPreviewSurfaceKind -PreviewPair $matchingPair
      if ([string]::IsNullOrWhiteSpace($surfaceKind)) {
        continue
      }

      if (-not $seenSurfaceKinds.Add($surfaceKind)) {
        continue
      }

      $surfaces.Add((New-ReviewerPreviewSurface -PreviewPair $matchingPair)) | Out-Null
    }

    if ($surfaces.Count -eq 0) {
      $surfaces.Add((New-ReviewerPreviewSurface -PreviewPair $selectedPreviewPair)) | Out-Null
    }

    $cards.Add([ordered]@{
        targetId = [string]$selectedPreviewPair.targetId
        targetPath = [string]$selectedPreviewPair.targetPath
        comparison = $selectedPreviewPair.comparison
        sortKey = Get-OptionalString -Value $selectedPreviewPair.sortKey
        surfaces = @($surfaces | ForEach-Object { $_ })
        changeDetails = Get-NestedValue -Object $changeDetailsByCardKey -Path @($cardKey)
      }) | Out-Null
  }

  return @($cards | ForEach-Object { $_ })
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
    [object]$Comparison,
    [AllowNull()]
    [string]$RepositoryRoot
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
    $surfaceCandidates = @(Get-ReportPreviewSurfaceCandidates -TableHtml $tableHtml -ReportDirectory $reportDirectory)
    $selectedSurface = Select-PreviewSurfaceCandidateForMode -Candidates $surfaceCandidates -Mode $Mode
    if ($null -eq $selectedSurface) {
      continue
    }

    $sectionKind = if ($summaryAttrs -match 'difference-heading') { 'overview' } else { 'detail' }
    $label = if (-not [string]::IsNullOrWhiteSpace([string]$selectedSurface.label)) {
      [string]$selectedSurface.label
    } elseif (-not [string]::IsNullOrWhiteSpace($summaryText)) {
      $summaryText
    } else {
      'Preview'
    }

    $comparisonReceipt = New-PreviewPairComparison -Comparison $Comparison -RepositoryRoot $RepositoryRoot
    $comparisonIndex = [int]$comparisonReceipt.index
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
        comparison = $comparisonReceipt
        sectionKind = $sectionKind
        sectionOrdinal = $sectionOrdinal
        label = $label
        reportHtmlRelativePath = $reportHtmlRelativePath
        baseImageRelativePath = Resolve-RelativePath -Path ([string]$selectedSurface.baseImagePath) -ResultsRoot $ResultsRoot
        headImageRelativePath = Resolve-RelativePath -Path ([string]$selectedSurface.headImagePath) -ResultsRoot $ResultsRoot
        baseByteLength = [int64](Get-Item -LiteralPath ([string]$selectedSurface.baseImagePath)).Length
        headByteLength = [int64](Get-Item -LiteralPath ([string]$selectedSurface.headImagePath)).Length
        baseImageSha256 = Get-FileSha256Hex -Path ([string]$selectedSurface.baseImagePath)
        headImageSha256 = Get-FileSha256Hex -Path ([string]$selectedSurface.headImagePath)
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
$allChangeDetails = New-Object System.Collections.Generic.List[object]
$targetReceipts = New-Object System.Collections.Generic.List[object]

foreach ($target in @(ConvertTo-ObjectArray -Value $targetRunsManifest.targets)) {
  $targetPreviewPairs = New-Object System.Collections.Generic.List[object]
  $targetRepositoryRoot = Resolve-TargetRepositoryRoot -Target $target -BasePath $basePath
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

        if ($modeName -eq 'attributes') {
          $changeDetailsRecord = Get-ReviewerChangeDetailsFromReport -ReportHtmlPath $reportHtmlPath -ResultsRoot $resultsDirResolved -TargetId ([string]$target.targetId) -TargetPath ([string]$target.targetPath) -Comparison $comparison -RepositoryRoot $targetRepositoryRoot
          if ($null -ne $changeDetailsRecord) {
            $allChangeDetails.Add($changeDetailsRecord) | Out-Null
          }
        }

        foreach ($previewPair in @(Get-ReportPreviewPairs -ReportHtmlPath $reportHtmlPath -ResultsRoot $resultsDirResolved -TargetId ([string]$target.targetId) -TargetPath ([string]$target.targetPath) -Mode $modeName -Comparison $comparison -RepositoryRoot $targetRepositoryRoot)) {
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
$reviewerPreviewPairs = @(Get-ReviewerPreviewPairArray -Value $orderedPreviewPairs)
$commentPreviewPairs = @(Select-PreviewPairs -PreviewPairs $orderedPreviewPairs -Limit $CommentPreviewPairCap)
$indexPreviewPairs = @(Select-PreviewPairs -PreviewPairs $orderedPreviewPairs -Limit $IndexPreviewPairCap)
$allChangeDetailRecords = @($allChangeDetails | ForEach-Object { $_ })
$reviewerPreviewCards = @(New-ReviewerPreviewCards -SelectedPreviewPairs $reviewerPreviewPairs -AllPreviewPairs $orderedPreviewPairs -AllChangeDetails $allChangeDetailRecords)
$commentPreviewCards = @(New-ReviewerPreviewCards -SelectedPreviewPairs $commentPreviewPairs -AllPreviewPairs $orderedPreviewPairs -AllChangeDetails $allChangeDetailRecords)
$indexPreviewCards = @(New-ReviewerPreviewCards -SelectedPreviewPairs $indexPreviewPairs -AllPreviewPairs $orderedPreviewPairs -AllChangeDetails $allChangeDetailRecords)
$targetReceiptArray = @($targetReceipts | ForEach-Object { $_ })
$orderedPreviewPairArray = @($orderedPreviewPairs | ForEach-Object { $_ })
$commentPreviewPairArray = @($commentPreviewPairs | ForEach-Object { $_ })
$indexPreviewPairArray = @($indexPreviewPairs | ForEach-Object { $_ })
$reviewerPreviewCardArray = @($reviewerPreviewCards | ForEach-Object { $_ })
$commentPreviewCardArray = @($commentPreviewCards | ForEach-Object { $_ })
$indexPreviewCardArray = @($indexPreviewCards | ForEach-Object { $_ })
$reviewerPreviewSurfaceCount = [int](@($reviewerPreviewCards | ForEach-Object { @(ConvertTo-ObjectArray -Value $_.surfaces).Count } | Measure-Object -Sum).Sum)
$commentPreviewSurfaceCount = [int](@($commentPreviewCards | ForEach-Object { @(ConvertTo-ObjectArray -Value $_.surfaces).Count } | Measure-Object -Sum).Sum)
$indexPreviewSurfaceCount = [int](@($indexPreviewCards | ForEach-Object { @(ConvertTo-ObjectArray -Value $_.surfaces).Count } | Measure-Object -Sum).Sum)

$receipt = [ordered]@{
  schema = 'comparevi-history/pr-preview-manifest@v1'
  generatedAtUtc = [DateTime]::UtcNow.ToString('o')
  targetRunsManifestPath = $manifestPathResolved
  resultsDir = $resultsDirResolved
  summary = [ordered]@{
    targetCount = $targetReceiptArray.Count
    previewPairCount = $orderedPreviewPairs.Count
    rawPreviewPairCount = $orderedPreviewPairs.Count
    reviewerPreviewPairCount = $reviewerPreviewPairs.Count
    reviewerPreviewCardCount = $reviewerPreviewCards.Count
    reviewerPreviewSurfaceCount = $reviewerPreviewSurfaceCount
    commentPreviewPairCap = [int]$CommentPreviewPairCap
    commentSelectionPolicy = 'reviewer-canonical@v1'
    commentPreviewPairCount = $commentPreviewPairs.Count
    commentPreviewPairOmittedCount = [Math]::Max($reviewerPreviewPairs.Count - $commentPreviewPairs.Count, 0)
    commentPreviewCardCount = $commentPreviewCards.Count
    commentPreviewSurfaceCount = $commentPreviewSurfaceCount
    commentCardSelectionPolicy = 'reviewer-multisurface@v1'
    indexPreviewPairCap = [int]$IndexPreviewPairCap
    indexSelectionPolicy = 'reviewer-canonical@v1'
    indexPreviewPairCount = $indexPreviewPairs.Count
    indexPreviewPairOmittedCount = [Math]::Max($reviewerPreviewPairs.Count - $indexPreviewPairs.Count, 0)
    indexPreviewCardCount = $indexPreviewCards.Count
    indexPreviewSurfaceCount = $indexPreviewSurfaceCount
    indexCardSelectionPolicy = 'reviewer-multisurface@v1'
  }
  targets = $targetReceiptArray
  previewPairs = $orderedPreviewPairArray
  commentPreviewPairs = $commentPreviewPairArray
  indexPreviewPairs = $indexPreviewPairArray
  reviewerPreviewCards = $reviewerPreviewCardArray
  commentPreviewCards = $commentPreviewCardArray
  indexPreviewCards = $indexPreviewCardArray
}

$receipt | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $outputPathResolved -Encoding utf8

Write-ActionOutput -Key 'preview-manifest-path' -Value $outputPathResolved
Write-ActionOutput -Key 'preview-pair-count' -Value ([string]$reviewerPreviewPairs.Count)
Write-ActionOutput -Key 'raw-preview-pair-count' -Value ([string]$orderedPreviewPairs.Count)
Write-ActionOutput -Key 'reviewer-preview-pair-count' -Value ([string]$reviewerPreviewPairs.Count)
Write-ActionOutput -Key 'comment-preview-pair-count' -Value ([string]$commentPreviewPairs.Count)
Write-ActionOutput -Key 'comment-preview-pair-omitted-count' -Value ([string][Math]::Max($reviewerPreviewPairs.Count - $commentPreviewPairs.Count, 0))
Write-ActionOutput -Key 'index-preview-pair-count' -Value ([string]$indexPreviewPairs.Count)
Write-ActionOutput -Key 'index-preview-pair-omitted-count' -Value ([string][Math]::Max($reviewerPreviewPairs.Count - $indexPreviewPairs.Count, 0))
Write-ActionOutput -Key 'reviewer-preview-card-count' -Value ([string]$reviewerPreviewCards.Count)
Write-ActionOutput -Key 'reviewer-preview-surface-count' -Value ([string]$reviewerPreviewSurfaceCount)
Write-ActionOutput -Key 'comment-preview-card-count' -Value ([string]$commentPreviewCards.Count)
Write-ActionOutput -Key 'comment-preview-surface-count' -Value ([string]$commentPreviewSurfaceCount)
Write-ActionOutput -Key 'index-preview-card-count' -Value ([string]$indexPreviewCards.Count)
Write-ActionOutput -Key 'index-preview-surface-count' -Value ([string]$indexPreviewSurfaceCount)

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  @(
    '## comparevi-history PR preview manifest'
    ''
    ('- Preview manifest: `{0}`' -f $outputPathResolved)
    ('- Raw preview pairs: `{0}`' -f $orderedPreviewPairs.Count)
    ('- Reviewer preview cards: `{0}` across `{1}` visual surfaces' -f $reviewerPreviewCards.Count, $reviewerPreviewSurfaceCount)
    ('- Comment preview pairs: `{0}` shown, `{1}` omitted, cap `{2}`' -f $commentPreviewPairs.Count, [Math]::Max($reviewerPreviewPairs.Count - $commentPreviewPairs.Count, 0), [int]$CommentPreviewPairCap)
    ('- Index preview pairs: `{0}` shown, `{1}` omitted, cap `{2}`' -f $indexPreviewPairs.Count, [Math]::Max($reviewerPreviewPairs.Count - $indexPreviewPairs.Count, 0), [int]$IndexPreviewPairCap)
  ) | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
}

$receipt | ConvertTo-Json -Depth 64
