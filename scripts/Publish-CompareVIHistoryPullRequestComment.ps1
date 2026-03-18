param(
  [Parameter(Mandatory = $true)]
  [string]$Repository,
  [Parameter(Mandatory = $true)]
  [string]$WorkflowRunId,
  [Parameter(Mandatory = $true)]
  [string]$GitHubToken,
  [string]$ArtifactName,
  [string]$ResultsDir = 'tests/results/pr-diagnostics/publish',
  [string]$StickyMarker = '<!-- comparevi-history:pull-request-diagnostics -->',
  [string]$PreviewBranch = 'comparevi-history-pr-previews',
  [string]$PreviewRoot = '.comparevi-history/pr-diagnostics/previews',
  [string]$GitHubOutputPath,
  [string]$StepSummaryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'CompareVIHistoryReviewBundleProjection.psm1') -Force

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

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][string]$Path)

  $raw = Get-Content -LiteralPath $Path -Raw
  if ([string]::IsNullOrWhiteSpace($raw)) {
    throw "JSON file was empty: $Path"
  }

  return $raw | ConvertFrom-Json -Depth 100
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

function Get-GitHubHeaders {
  return @{
    Accept = 'application/vnd.github+json'
    Authorization = "Bearer $GitHubToken"
    'User-Agent' = 'comparevi-history-pr-publish'
    'X-GitHub-Api-Version' = '2022-11-28'
  }
}

function Invoke-GitHubJson {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Method,
    [Parameter(Mandatory = $true)]
    [string]$Uri,
    [AllowNull()]
    $Body = $null
  )

  $invokeArgs = @{
    Method = $Method
    Uri = $Uri
    Headers = Get-GitHubHeaders
  }
  if ($null -ne $Body) {
    $invokeArgs.Body = ($Body | ConvertTo-Json -Depth 20)
    $invokeArgs.ContentType = 'application/json'
  }

  return Invoke-RestMethod @invokeArgs
}

function Invoke-GitHubJsonOptional {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Method,
    [Parameter(Mandatory = $true)]
    [string]$Uri,
    [AllowNull()]
    $Body = $null
  )

  try {
    return Invoke-GitHubJson -Method $Method -Uri $Uri -Body $Body
  } catch {
    $responseProperty = $_.Exception.PSObject.Properties['Response']
    $response = if ($null -eq $responseProperty) { $null } else { $responseProperty.Value }
    if ($null -ne $response -and [int]$response.StatusCode -eq 404) {
      return $null
    }

    throw
  }
}

function Find-Artifact {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepositorySlug,
    [Parameter(Mandatory = $true)]
    [string]$RunId,
    [Parameter(Mandatory = $true)]
    [string]$RequestedArtifactName
  )

  $uri = "https://api.github.com/repos/$RepositorySlug/actions/runs/$RunId/artifacts?per_page=100"
  $response = Invoke-GitHubJson -Method Get -Uri $uri
  $artifacts = @($response.artifacts | Where-Object { $null -ne $_ })
  $exact = @($artifacts | Where-Object { [string]$_.name -eq $RequestedArtifactName } | Select-Object -First 1)
  if ($exact) {
    return $exact
  }

  return @($artifacts | Where-Object { [string]$_.name -like "$RequestedArtifactName*" } | Select-Object -First 1)
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

function ConvertTo-HtmlText {
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
  param([Parameter(Mandatory = $true)][object]$PreviewPair)

  return [int](Get-NestedValue -Object $PreviewPair -Path @('comparison', 'index') -Default 0)
}

function Get-ReviewerPreviewRevisionContext {
  param([Parameter(Mandatory = $true)][object]$PreviewPair)

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
  param([Parameter(Mandatory = $true)][object]$PreviewPair)

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
  param([Parameter(Mandatory = $true)][object]$PreviewPair)

  return [string]$PreviewPair.targetPath
}

function Get-ReviewerPreviewSubtitle {
  param([Parameter(Mandatory = $true)][object]$PreviewPair)

  return 'History pair {0}' -f (Get-ReviewerPreviewComparisonIndex -PreviewPair $PreviewPair)
}

function Get-ReviewerPreviewSurfaceKind {
  param([Parameter(Mandatory = $true)][object]$PreviewPair)

  switch ([string]$PreviewPair.mode) {
    'front-panel' { return 'front-panel' }
    'block-diagram' { return 'block-diagram' }
    default { return $null }
  }
}

function Get-ReviewerPreviewSurfaceLabel {
  param(
    [AllowNull()][string]$SurfaceKind,
    [AllowNull()][string]$FallbackLabel
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

function New-CommentChangeDetailsMarkdown {
  param(
    [AllowNull()]
    [object]$ChangeDetails
  )

  if ($null -eq $ChangeDetails) {
    return ''
  }

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('<p><strong>Change details</strong></p>') | Out-Null
  $lines.Add('<ul>') | Out-Null
  $includedCategories = @(
    ConvertTo-ObjectArray -Value (Get-NestedValue -Object $ChangeDetails -Path @('includedCategories') -Default @()) |
      ForEach-Object { Get-OptionalString -Value $_ } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  )
  if ($includedCategories.Count -gt 0) {
    $lines.Add(('<li><strong>Included categories:</strong> {0}</li>' -f (ConvertTo-HtmlText ($includedCategories -join ', ')))) | Out-Null
  }
  foreach ($group in @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $ChangeDetails -Path @('groups') -Default @()))) {
    $headingText = Get-OptionalString -Value (Get-NestedValue -Object $group -Path @('heading'))
    $primaryReportUrl = Get-OptionalString -Value (Get-NestedValue -Object $group -Path @('primaryReportUrl'))
    $primaryReportHtmlRelativePath = Get-OptionalString -Value (Get-NestedValue -Object $group -Path @('primaryReportHtmlRelativePath'))
    $headingLink = if ([string]::IsNullOrWhiteSpace($primaryReportUrl)) { $primaryReportHtmlRelativePath } else { $primaryReportUrl }
    $headingMarkup = if ([string]::IsNullOrWhiteSpace($headingLink)) {
      ConvertTo-HtmlText $headingText
    } else {
      '<a href="{0}">{1}</a>' -f (ConvertTo-HtmlText $headingLink), (ConvertTo-HtmlText $headingText)
    }
    $lines.Add(('<li><strong>{0}:</strong> {1} details across {2} sections' -f `
          $headingMarkup, `
          [int](Get-NestedValue -Object $group -Path @('detailCount') -Default 0), `
          [int](Get-NestedValue -Object $group -Path @('sectionCount') -Default 0))) | Out-Null
    $lines.Add('<ul>') | Out-Null
    foreach ($sampleDetail in @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $group -Path @('sampleDetails') -Default @()))) {
      $lines.Add(('<li>{0}</li>' -f (ConvertTo-HtmlText ([string]$sampleDetail)))) | Out-Null
    }
    $omittedDetailCount = [int](Get-NestedValue -Object $group -Path @('omittedDetailCount') -Default 0)
    if ($omittedDetailCount -gt 0) {
      $lines.Add(('<li>+{0} more details in report</li>' -f $omittedDetailCount)) | Out-Null
    }
    $sectionLinks = @(
      ConvertTo-ObjectArray -Value (Get-NestedValue -Object $group -Path @('sectionLinks') -Default @()) |
        ForEach-Object {
          $label = Get-OptionalString -Value (Get-NestedValue -Object $_ -Path @('label'))
          $path = Get-OptionalString -Value (Get-NestedValue -Object $_ -Path @('reportUrl'))
          if ([string]::IsNullOrWhiteSpace($path)) {
            $path = Get-OptionalString -Value (Get-NestedValue -Object $_ -Path @('reportHtmlRelativePath'))
          }
          if ([string]::IsNullOrWhiteSpace($label) -or [string]::IsNullOrWhiteSpace($path)) {
            return $null
          }

          '<a href="{0}">{1}</a>' -f (ConvertTo-HtmlText $path), (ConvertTo-HtmlText $label)
        } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($sectionLinks.Count -gt 0) {
      $lines.Add(('<li><strong>Exact sections:</strong> {0}</li>' -f ($sectionLinks -join ', '))) | Out-Null
    }
    $lines.Add('</ul>') | Out-Null
    $lines.Add('</li>') | Out-Null
  }
  $omittedGroupCount = [int](Get-NestedValue -Object $ChangeDetails -Path @('omittedGroupCount') -Default 0)
  if ($omittedGroupCount -gt 0) {
    $lines.Add(('<li><strong>Additional change-detail groups omitted:</strong> {0}</li>' -f $omittedGroupCount)) | Out-Null
  }
  $reportUrl = Get-OptionalString -Value (Get-NestedValue -Object $ChangeDetails -Path @('reportUrl'))
  if ([string]::IsNullOrWhiteSpace($reportUrl)) {
    $reportUrl = Get-OptionalString -Value (Get-NestedValue -Object $ChangeDetails -Path @('reportHtmlRelativePath'))
  }
  if (-not [string]::IsNullOrWhiteSpace($reportUrl)) {
    $lines.Add(('<li><a href="{0}">open change details report</a></li>' -f (ConvertTo-HtmlText $reportUrl))) | Out-Null
  }
  $lines.Add('</ul>') | Out-Null

  return $lines -join "`n"
}

function New-CommentReviewerSummaryMarkdown {
  param(
    [AllowNull()]
    [object]$ReviewerSummary
  )

  if ($null -eq $ReviewerSummary) {
    return ''
  }

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('<p><strong>Reviewer summary</strong></p>') | Out-Null
  $lines.Add('<ul>') | Out-Null
  $headline = Get-OptionalString -Value (Get-NestedValue -Object $ReviewerSummary -Path @('headline'))
  if (-not [string]::IsNullOrWhiteSpace($headline)) {
    $lines.Add(('<li><strong>Headline:</strong> {0}</li>' -f (ConvertTo-HtmlText $headline))) | Out-Null
  }
  $overallSeverity = Get-OptionalString -Value (Get-NestedValue -Object $ReviewerSummary -Path @('overallSeverity'))
  if (-not [string]::IsNullOrWhiteSpace($overallSeverity)) {
    $lines.Add(('<li><strong>Overall severity:</strong> {0}</li>' -f (ConvertTo-HtmlText $overallSeverity))) | Out-Null
  }
  foreach ($signal in @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $ReviewerSummary -Path @('signals') -Default @()))) {
    $labelText = Get-OptionalString -Value (Get-NestedValue -Object $signal -Path @('label'))
    $primaryReportUrl = Get-OptionalString -Value (Get-NestedValue -Object $signal -Path @('primaryReportUrl'))
    $primaryReportHtmlRelativePath = Get-OptionalString -Value (Get-NestedValue -Object $signal -Path @('primaryReportHtmlRelativePath'))
    $labelLink = if ([string]::IsNullOrWhiteSpace($primaryReportUrl)) { $primaryReportHtmlRelativePath } else { $primaryReportUrl }
    $labelMarkup = if ([string]::IsNullOrWhiteSpace($labelLink)) {
      ConvertTo-HtmlText $labelText
    } else {
      '<a href="{0}">{1}</a>' -f (ConvertTo-HtmlText $labelLink), (ConvertTo-HtmlText $labelText)
    }
    $lines.Add(('<li><strong>{0}:</strong> {1} severity, {2} details across {3} sections' -f `
          $labelMarkup, `
          (ConvertTo-HtmlText (Get-OptionalString -Value (Get-NestedValue -Object $signal -Path @('severity')))), `
          [int](Get-NestedValue -Object $signal -Path @('detailCount') -Default 0), `
          [int](Get-NestedValue -Object $signal -Path @('sectionCount') -Default 0))) | Out-Null
    $lines.Add('<ul>') | Out-Null
    $sectionLinks = @(
      ConvertTo-ObjectArray -Value (Get-NestedValue -Object $signal -Path @('sectionLinks') -Default @()) |
        ForEach-Object {
          $label = Get-OptionalString -Value (Get-NestedValue -Object $_ -Path @('label'))
          $path = Get-OptionalString -Value (Get-NestedValue -Object $_ -Path @('reportUrl'))
          if ([string]::IsNullOrWhiteSpace($path)) {
            $path = Get-OptionalString -Value (Get-NestedValue -Object $_ -Path @('reportHtmlRelativePath'))
          }
          if ([string]::IsNullOrWhiteSpace($label) -or [string]::IsNullOrWhiteSpace($path)) {
            return $null
          }

          '<a href="{0}">{1}</a>' -f (ConvertTo-HtmlText $path), (ConvertTo-HtmlText $label)
        } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($sectionLinks.Count -gt 0) {
      $lines.Add(('<li><strong>Exact sections:</strong> {0}</li>' -f ($sectionLinks -join ', '))) | Out-Null
    }
    $lines.Add('</ul>') | Out-Null
    $lines.Add('</li>') | Out-Null
  }
  $omittedSignalCount = [int](Get-NestedValue -Object $ReviewerSummary -Path @('omittedSignalCount') -Default 0)
  if ($omittedSignalCount -gt 0) {
    $lines.Add(('<li><strong>Additional reviewer signals omitted:</strong> {0}</li>' -f $omittedSignalCount)) | Out-Null
  }
  $lines.Add('</ul>') | Out-Null

  return $lines -join "`n"
}

function Get-ReviewerPreviewCardKey {
  param([Parameter(Mandatory = $true)][object]$PreviewPair)

  return '{0}|{1}' -f `
    [string]$PreviewPair.targetId, `
    [int](Get-NestedValue -Object $PreviewPair -Path @('comparison', 'index') -Default 0)
}

function New-ReviewerPreviewManifestSurface {
  param([Parameter(Mandatory = $true)][object]$PreviewPair)

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
  }
}

function New-ReviewerPreviewCards {
  param(
    [AllowEmptyCollection()][object[]]$SelectedPreviewPairs = @(),
    [AllowEmptyCollection()][object[]]$AllPreviewPairs = @(),
    [AllowEmptyCollection()][object[]]$ExistingCards = @()
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

  $orderedAllPreviewPairs = @(
    ConvertTo-ObjectArray -Value $AllPreviewPairs |
      Sort-Object {
        $sortKey = Get-OptionalString -Value $_.sortKey
        if ([string]::IsNullOrWhiteSpace($sortKey)) {
          [string]$_.label
        } else {
          $sortKey
        }
      }
  )
  if ($orderedAllPreviewPairs.Count -eq 0) {
    $orderedAllPreviewPairs = @(
      ConvertTo-ObjectArray -Value $SelectedPreviewPairs |
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

  $cards = New-Object System.Collections.Generic.List[object]
  $seenCards = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($selectedPreviewPair in @(
      ConvertTo-ObjectArray -Value $SelectedPreviewPairs |
        Sort-Object {
          $sortKey = Get-OptionalString -Value $_.sortKey
          if ([string]::IsNullOrWhiteSpace($sortKey)) {
            [string]$_.label
          } else {
            $sortKey
          }
        }
    )) {
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
      $surface = New-ReviewerPreviewManifestSurface -PreviewPair $matchingPair
      if (-not $seenSurfaces.Add([string]$surface.surfaceKind)) {
        continue
      }

      $surfaces.Add($surface) | Out-Null
    }

    if ($surfaces.Count -eq 0) {
      $surfaces.Add((New-ReviewerPreviewManifestSurface -PreviewPair $selectedPreviewPair)) | Out-Null
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

function ConvertTo-GitHubContentPath {
  param([Parameter(Mandatory = $true)][string]$Path)

  return (($Path -split '[\\/]' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) | ForEach-Object {
      [uri]::EscapeDataString($_)
    }) -join '/'
}

function Get-RepositoryInfo {
  param([Parameter(Mandatory = $true)][string]$RepositorySlug)

  return Invoke-GitHubJson -Method Get -Uri "https://api.github.com/repos/$RepositorySlug"
}

function Get-GitRef {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepositorySlug,
    [Parameter(Mandatory = $true)]
    [string]$BranchName
  )

  $encodedRef = ConvertTo-GitHubContentPath -Path ("heads/$BranchName")
  return Invoke-GitHubJsonOptional -Method Get -Uri "https://api.github.com/repos/$RepositorySlug/git/ref/$encodedRef"
}

function Ensure-PreviewBranch {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepositorySlug,
    [Parameter(Mandatory = $true)]
    [string]$BranchName
  )

  $existing = Get-GitRef -RepositorySlug $RepositorySlug -BranchName $BranchName
  if ($null -ne $existing) {
    return [string]$existing.object.sha
  }

  $repositoryInfo = Get-RepositoryInfo -RepositorySlug $RepositorySlug
  $defaultBranch = [string]$repositoryInfo.default_branch
  if ([string]::IsNullOrWhiteSpace($defaultBranch)) {
    throw "Repository '$RepositorySlug' did not declare a default branch."
  }

  $defaultRef = Get-GitRef -RepositorySlug $RepositorySlug -BranchName $defaultBranch
  if ($null -eq $defaultRef) {
    throw "Failed to resolve default branch '$defaultBranch' for repository '$RepositorySlug'."
  }

  $created = Invoke-GitHubJson -Method Post -Uri "https://api.github.com/repos/$RepositorySlug/git/refs" -Body @{
    ref = "refs/heads/$BranchName"
    sha = [string]$defaultRef.object.sha
  }

  return [string]$created.object.sha
}

function Get-RepositoryContent {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepositorySlug,
    [Parameter(Mandatory = $true)]
    [string]$BranchName,
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $encodedPath = ConvertTo-GitHubContentPath -Path $Path
  $uri = "https://api.github.com/repos/$RepositorySlug/contents/${encodedPath}?ref=$([uri]::EscapeDataString($BranchName))"
  return Invoke-GitHubJsonOptional -Method Get -Uri $uri
}

function Set-RepositoryContent {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepositorySlug,
    [Parameter(Mandatory = $true)]
    [string]$BranchName,
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [byte[]]$Bytes,
    [Parameter(Mandatory = $true)]
    [string]$Message
  )

  $existing = Get-RepositoryContent -RepositorySlug $RepositorySlug -BranchName $BranchName -Path $Path
  $encodedPath = ConvertTo-GitHubContentPath -Path $Path
  $body = [ordered]@{
    message = $Message
    content = [Convert]::ToBase64String($Bytes)
    branch = $BranchName
  }
  if ($null -ne $existing) {
    $body.sha = [string]$existing.sha
  }

  return Invoke-GitHubJson -Method Put -Uri "https://api.github.com/repos/$RepositorySlug/contents/$encodedPath" -Body $body
}

function ConvertTo-RawGitHubUrl {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepositorySlug,
    [Parameter(Mandatory = $true)]
    [string]$BranchName,
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  return 'https://raw.githubusercontent.com/{0}/{1}/{2}' -f $RepositorySlug, $BranchName, ($Path -replace '\\', '/')
}

function ConvertTo-BlobGitHubUrl {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepositorySlug,
    [Parameter(Mandatory = $true)]
    [string]$BranchName,
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  return 'https://github.com/{0}/blob/{1}/{2}' -f $RepositorySlug, $BranchName, ($Path -replace '\\', '/')
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

function Add-AnchorToUrl {
  param(
    [AllowNull()]
    [string]$Url,
    [AllowNull()]
    [string]$AnchorId
  )

  if ([string]::IsNullOrWhiteSpace($Url)) {
    return $null
  }

  if ([string]::IsNullOrWhiteSpace($AnchorId)) {
    return $Url
  }

  return '{0}#{1}' -f $Url, $AnchorId
}

function New-CommentChangeDetailsEvidenceMarkdown {
  param(
    [Parameter(Mandatory = $true)]
    [object]$PreviewCard,
    [AllowNull()]
    [string]$PairReviewUrl
  )

  $lines = New-Object System.Collections.Generic.List[string]
  $title = Get-ReviewerPreviewTitle -PreviewPair $PreviewCard
  $subtitle = Get-ReviewerPreviewSubtitle -PreviewPair $PreviewCard
  $revisionContext = Get-ReviewerPreviewRevisionContext -PreviewPair $PreviewCard
  $detailLines = @(Get-ReviewerPreviewDetailLines -PreviewPair $PreviewCard)
  $changeDetails = Get-NestedValue -Object $PreviewCard -Path @('changeDetails')
  $reviewerSummary = Get-NestedValue -Object $PreviewCard -Path @('reviewerSummary')

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

  if ($null -ne $reviewerSummary) {
    $lines.Add('## Reviewer summary') | Out-Null
    $lines.Add('') | Out-Null
    $headline = Get-OptionalString -Value (Get-NestedValue -Object $reviewerSummary -Path @('headline'))
    if (-not [string]::IsNullOrWhiteSpace($headline)) {
      $lines.Add(('- Headline: `{0}`' -f $headline)) | Out-Null
    }
    $overallSeverity = Get-OptionalString -Value (Get-NestedValue -Object $reviewerSummary -Path @('overallSeverity'))
    if (-not [string]::IsNullOrWhiteSpace($overallSeverity)) {
      $lines.Add(('- Overall severity: `{0}`' -f $overallSeverity)) | Out-Null
    }
    foreach ($signal in @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $reviewerSummary -Path @('signals') -Default @()))) {
      $label = Get-OptionalString -Value (Get-NestedValue -Object $signal -Path @('label'))
      $severity = Get-OptionalString -Value (Get-NestedValue -Object $signal -Path @('severity'))
      $detailCount = [int](Get-NestedValue -Object $signal -Path @('detailCount') -Default 0)
      $sectionCount = [int](Get-NestedValue -Object $signal -Path @('sectionCount') -Default 0)
      $lines.Add(('- `{0}`: `{1}` severity, `{2}` details across `{3}` sections' -f $label, $severity, $detailCount, $sectionCount)) | Out-Null
    }
    $lines.Add('') | Out-Null
  }

  if ($null -ne $changeDetails) {
    $lines.Add('## Change details') | Out-Null
    $lines.Add('') | Out-Null
    $includedCategories = @(
      ConvertTo-ObjectArray -Value (Get-NestedValue -Object $changeDetails -Path @('includedCategories') -Default @()) |
        ForEach-Object { Get-OptionalString -Value $_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($includedCategories.Count -gt 0) {
      $lines.Add(('Included categories: `{0}`' -f ($includedCategories -join '`, `'))) | Out-Null
      $lines.Add('') | Out-Null
    }
    foreach ($group in @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $changeDetails -Path @('groups') -Default @()))) {
      $anchorId = Get-ReportAnchorId -Path (Get-OptionalString -Value (Get-NestedValue -Object $group -Path @('primaryReportHtmlRelativePath')))
      if (-not [string]::IsNullOrWhiteSpace($anchorId)) {
        $lines.Add(('<a id="{0}"></a>' -f (ConvertTo-HtmlText $anchorId))) | Out-Null
      }
      $heading = Get-OptionalString -Value (Get-NestedValue -Object $group -Path @('heading'))
      $lines.Add(('### {0}' -f $heading)) | Out-Null
      $lines.Add('') | Out-Null
      $lines.Add(('- `{0}` details across `{1}` sections' -f [int](Get-NestedValue -Object $group -Path @('detailCount') -Default 0), [int](Get-NestedValue -Object $group -Path @('sectionCount') -Default 0))) | Out-Null
      foreach ($sampleDetail in @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $group -Path @('sampleDetails') -Default @()))) {
        $lines.Add(('  - {0}' -f [string]$sampleDetail)) | Out-Null
      }
      $omittedDetailCount = [int](Get-NestedValue -Object $group -Path @('omittedDetailCount') -Default 0)
      if ($omittedDetailCount -gt 0) {
        $lines.Add(('  - +{0} more details in report' -f $omittedDetailCount)) | Out-Null
      }
      $lines.Add('') | Out-Null
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($PairReviewUrl)) {
    $lines.Add('') | Out-Null
    $lines.Add(('[Unified pair review]({0})' -f $PairReviewUrl)) | Out-Null
  }

  return ($lines -join "`n").TrimEnd() + "`n"
}

function New-CommentSurfaceEvidenceMarkdown {
  param(
    [Parameter(Mandatory = $true)]
    [object]$PreviewCard,
    [Parameter(Mandatory = $true)]
    [object]$Surface,
    [AllowNull()]
    [string]$ChangeDetailsEvidenceUrl,
    [AllowNull()]
    [string]$PairReviewUrl
  )

  $lines = New-Object System.Collections.Generic.List[string]
  $title = Get-ReviewerPreviewTitle -PreviewPair $PreviewCard
  $subtitle = Get-ReviewerPreviewSubtitle -PreviewPair $PreviewCard
  $revisionContext = Get-ReviewerPreviewRevisionContext -PreviewPair $PreviewCard
  $detailLines = @(Get-ReviewerPreviewDetailLines -PreviewPair $PreviewCard)
  $surfaceLabel = Get-ReviewerPreviewSurfaceLabel -SurfaceKind (Get-OptionalString -Value $Surface.surfaceKind) -FallbackLabel (Get-OptionalString -Value $Surface.surfaceLabel)

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
  $lines.Add(('## {0}' -f $surfaceLabel)) | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add('**Base**') | Out-Null
  $lines.Add(('![{0}]({1})' -f ('{0} base' -f $surfaceLabel), [string]$Surface.baseImageUrl)) | Out-Null
  $lines.Add('') | Out-Null
  $lines.Add('**Head**') | Out-Null
  $lines.Add(('![{0}]({1})' -f ('{0} head' -f $surfaceLabel), [string]$Surface.headImageUrl)) | Out-Null
  if (-not [string]::IsNullOrWhiteSpace($ChangeDetailsEvidenceUrl)) {
    $lines.Add('') | Out-Null
    $lines.Add(('[Change details evidence]({0})' -f $ChangeDetailsEvidenceUrl)) | Out-Null
  }
  if (-not [string]::IsNullOrWhiteSpace($PairReviewUrl)) {
    $lines.Add('') | Out-Null
    $lines.Add(('[Unified pair review]({0})' -f $PairReviewUrl)) | Out-Null
  }

  return ($lines -join "`n").TrimEnd() + "`n"
}

function ConvertTo-PublishedSectionLink {
  param(
    [Parameter(Mandatory = $true)]
    [object]$SectionLink,
    [AllowNull()]
    [string]$EvidencePath,
    [AllowNull()]
    [string]$EvidenceUrl,
    [AllowNull()]
    [string]$DebugEvidenceUrl
  )

  $rawReportHtmlRelativePath = Get-OptionalString -Value (Get-NestedValue -Object $SectionLink -Path @('reportHtmlRelativePath'))
  $anchorId = Get-ReportAnchorId -Path $rawReportHtmlRelativePath
  return [ordered]@{
    sectionOrdinal = [int](Get-NestedValue -Object $SectionLink -Path @('sectionOrdinal') -Default 0)
    label = Get-OptionalString -Value (Get-NestedValue -Object $SectionLink -Path @('label'))
    reportHtmlRelativePath = Add-AnchorToUrl -Url $EvidencePath -AnchorId $anchorId
    debugReportHtmlRelativePath = $rawReportHtmlRelativePath
    reportUrl = Add-AnchorToUrl -Url $EvidenceUrl -AnchorId $anchorId
    debugReportUrl = Add-AnchorToUrl -Url $DebugEvidenceUrl -AnchorId $anchorId
  }
}

function ConvertTo-PublishedChangeDetails {
  param(
    [AllowNull()]
    [object]$ChangeDetails,
    [AllowNull()]
    [string]$EvidencePath,
    [AllowNull()]
    [string]$EvidenceUrl,
    [AllowNull()]
    [string]$DebugEvidenceUrl
  )

  if ($null -eq $ChangeDetails) {
    return $null
  }

  $groups = New-Object System.Collections.Generic.List[object]
  foreach ($group in @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $ChangeDetails -Path @('groups') -Default @()))) {
    $rawPrimaryReportHtmlRelativePath = Get-OptionalString -Value (Get-NestedValue -Object $group -Path @('primaryReportHtmlRelativePath'))
    $primaryAnchorId = Get-ReportAnchorId -Path $rawPrimaryReportHtmlRelativePath
    $groups.Add([ordered]@{
        heading = Get-OptionalString -Value (Get-NestedValue -Object $group -Path @('heading'))
        sectionCount = [int](Get-NestedValue -Object $group -Path @('sectionCount') -Default 0)
        detailCount = [int](Get-NestedValue -Object $group -Path @('detailCount') -Default 0)
        sampleDetails = @(
          ConvertTo-ObjectArray -Value (Get-NestedValue -Object $group -Path @('sampleDetails') -Default @()) |
            ForEach-Object { [string]$_ }
        )
        omittedDetailCount = [int](Get-NestedValue -Object $group -Path @('omittedDetailCount') -Default 0)
        primaryReportHtmlRelativePath = Add-AnchorToUrl -Url $EvidencePath -AnchorId $primaryAnchorId
        debugPrimaryReportHtmlRelativePath = $rawPrimaryReportHtmlRelativePath
        primaryReportUrl = Add-AnchorToUrl -Url $EvidenceUrl -AnchorId $primaryAnchorId
        debugPrimaryReportUrl = Add-AnchorToUrl -Url $DebugEvidenceUrl -AnchorId $primaryAnchorId
        sectionLinks = @(
          ConvertTo-ObjectArray -Value (Get-NestedValue -Object $group -Path @('sectionLinks') -Default @()) |
            ForEach-Object { ConvertTo-PublishedSectionLink -SectionLink $_ -EvidencePath $EvidencePath -EvidenceUrl $EvidenceUrl -DebugEvidenceUrl $DebugEvidenceUrl }
        )
      }) | Out-Null
  }

  $rawReportHtmlRelativePath = Get-OptionalString -Value (Get-NestedValue -Object $ChangeDetails -Path @('reportHtmlRelativePath'))

  return [ordered]@{
    label = Get-OptionalString -Value (Get-NestedValue -Object $ChangeDetails -Path @('label'))
    sourceMode = Get-OptionalString -Value (Get-NestedValue -Object $ChangeDetails -Path @('sourceMode'))
    reportHtmlRelativePath = Add-AnchorToUrl -Url $EvidencePath -AnchorId 'change-details'
    debugReportHtmlRelativePath = $rawReportHtmlRelativePath
    reportUrl = Add-AnchorToUrl -Url $EvidenceUrl -AnchorId 'change-details'
    debugReportUrl = $DebugEvidenceUrl
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

function ConvertTo-PublishedReviewerSummary {
  param(
    [AllowNull()]
    [object]$ReviewerSummary,
    [AllowNull()]
    [string]$EvidencePath,
    [AllowNull()]
    [string]$EvidenceUrl,
    [AllowNull()]
    [string]$DebugEvidenceUrl
  )

  if ($null -eq $ReviewerSummary) {
    return $null
  }

  $signals = New-Object System.Collections.Generic.List[object]
  foreach ($signal in @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $ReviewerSummary -Path @('signals') -Default @()))) {
    $rawPrimaryReportHtmlRelativePath = Get-OptionalString -Value (Get-NestedValue -Object $signal -Path @('primaryReportHtmlRelativePath'))
    $primaryAnchorId = Get-ReportAnchorId -Path $rawPrimaryReportHtmlRelativePath
    $signals.Add([ordered]@{
        signalKey = Get-OptionalString -Value (Get-NestedValue -Object $signal -Path @('signalKey'))
        label = Get-OptionalString -Value (Get-NestedValue -Object $signal -Path @('label'))
        severity = Get-OptionalString -Value (Get-NestedValue -Object $signal -Path @('severity'))
        detailCount = [int](Get-NestedValue -Object $signal -Path @('detailCount') -Default 0)
        sectionCount = [int](Get-NestedValue -Object $signal -Path @('sectionCount') -Default 0)
        summary = Get-OptionalString -Value (Get-NestedValue -Object $signal -Path @('summary'))
        primaryReportHtmlRelativePath = Add-AnchorToUrl -Url $EvidencePath -AnchorId $primaryAnchorId
        debugPrimaryReportHtmlRelativePath = $rawPrimaryReportHtmlRelativePath
        primaryReportUrl = Add-AnchorToUrl -Url $EvidenceUrl -AnchorId $primaryAnchorId
        debugPrimaryReportUrl = Add-AnchorToUrl -Url $DebugEvidenceUrl -AnchorId $primaryAnchorId
        sectionLinks = @(
          ConvertTo-ObjectArray -Value (Get-NestedValue -Object $signal -Path @('sectionLinks') -Default @()) |
            ForEach-Object { ConvertTo-PublishedSectionLink -SectionLink $_ -EvidencePath $EvidencePath -EvidenceUrl $EvidenceUrl -DebugEvidenceUrl $DebugEvidenceUrl }
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

function New-CommentPairReviewMarkdown {
  param(
    [Parameter(Mandatory = $true)]
    [object]$PreviewCard,
    [Parameter(Mandatory = $true)]
    [string]$PairReviewUrl
  )

  $lines = New-Object System.Collections.Generic.List[string]
  $title = Get-ReviewerPreviewTitle -PreviewPair $PreviewCard
  $subtitle = Get-ReviewerPreviewSubtitle -PreviewPair $PreviewCard
  $revisionContext = Get-ReviewerPreviewRevisionContext -PreviewPair $PreviewCard
  $detailLines = @(Get-ReviewerPreviewDetailLines -PreviewPair $PreviewCard)
  $changeDetails = Get-NestedValue -Object $PreviewCard -Path @('changeDetails')
  $reviewerSummary = Get-NestedValue -Object $PreviewCard -Path @('reviewerSummary')

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

  foreach ($surface in @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $PreviewCard -Path @('surfaces') -Default @()))) {
    $surfaceKind = Get-OptionalString -Value $surface.surfaceKind
    $surfaceLabel = Get-ReviewerPreviewSurfaceLabel -SurfaceKind $surfaceKind -FallbackLabel (Get-OptionalString -Value $surface.surfaceLabel)
    $debugEvidenceUrl = Get-OptionalString -Value (Get-NestedValue -Object $surface -Path @('debugEvidenceUrl'))
    $lines.Add(('<a id="{0}"></a>' -f (ConvertTo-HtmlText $surfaceKind))) | Out-Null
    $lines.Add(('## {0}' -f $surfaceLabel)) | Out-Null
    $lines.Add('') | Out-Null
    $baseMarkdown = ('![{0}]({1})' -f ('{0} base' -f $surfaceLabel), [string]$surface.baseImageUrl)
    if (-not [string]::IsNullOrWhiteSpace($debugEvidenceUrl)) {
      $baseMarkdown = '[{0}]({1})' -f $baseMarkdown, $debugEvidenceUrl
    }
    $headMarkdown = ('![{0}]({1})' -f ('{0} head' -f $surfaceLabel), [string]$surface.headImageUrl)
    if (-not [string]::IsNullOrWhiteSpace($debugEvidenceUrl)) {
      $headMarkdown = '[{0}]({1})' -f $headMarkdown, $debugEvidenceUrl
    }
    $lines.Add('**Base**') | Out-Null
    $lines.Add($baseMarkdown) | Out-Null
    $lines.Add('') | Out-Null
    $lines.Add('**Head**') | Out-Null
    $lines.Add($headMarkdown) | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($debugEvidenceUrl)) {
      $lines.Add('') | Out-Null
      $lines.Add(('[Debug surface page]({0})' -f $debugEvidenceUrl)) | Out-Null
    }
    $lines.Add('') | Out-Null
  }

  $lines.Add('<a id="reviewer-summary"></a>') | Out-Null
  $reviewerSummaryMarkdown = New-CommentReviewerSummaryMarkdown -ReviewerSummary $reviewerSummary
  if (-not [string]::IsNullOrWhiteSpace($reviewerSummaryMarkdown)) {
    $lines.Add($reviewerSummaryMarkdown) | Out-Null
    $lines.Add('') | Out-Null
  }

  if ($null -ne $changeDetails) {
    $lines.Add('<a id="change-details"></a>') | Out-Null
    $lines.Add('<p><strong>Change details</strong></p>') | Out-Null
    $lines.Add('<ul>') | Out-Null
    $includedCategories = @(
      ConvertTo-ObjectArray -Value (Get-NestedValue -Object $changeDetails -Path @('includedCategories') -Default @()) |
        ForEach-Object { Get-OptionalString -Value $_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($includedCategories.Count -gt 0) {
      $lines.Add(('<li><strong>Included categories:</strong> {0}</li>' -f (ConvertTo-HtmlText ($includedCategories -join ', ')))) | Out-Null
    }
    foreach ($group in @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $changeDetails -Path @('groups') -Default @()))) {
      $anchorId = Get-ReportAnchorId -Path (Get-OptionalString -Value (Get-NestedValue -Object $group -Path @('primaryReportUrl')))
      if (-not [string]::IsNullOrWhiteSpace($anchorId)) {
        $lines.Add(('<a id="{0}"></a>' -f (ConvertTo-HtmlText $anchorId))) | Out-Null
      }
      $headingText = Get-OptionalString -Value (Get-NestedValue -Object $group -Path @('heading'))
      $primaryReportUrl = Get-OptionalString -Value (Get-NestedValue -Object $group -Path @('primaryReportUrl'))
      $headingMarkup = if ([string]::IsNullOrWhiteSpace($primaryReportUrl)) {
        ConvertTo-HtmlText $headingText
      } else {
        '<a href="{0}">{1}</a>' -f (ConvertTo-HtmlText $primaryReportUrl), (ConvertTo-HtmlText $headingText)
      }
      $lines.Add(('<li><strong>{0}:</strong> {1} details across {2} sections' -f `
            $headingMarkup, `
            [int](Get-NestedValue -Object $group -Path @('detailCount') -Default 0), `
            [int](Get-NestedValue -Object $group -Path @('sectionCount') -Default 0))) | Out-Null
      $lines.Add('<ul>') | Out-Null
      foreach ($sampleDetail in @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $group -Path @('sampleDetails') -Default @()))) {
        $lines.Add(('<li>{0}</li>' -f (ConvertTo-HtmlText ([string]$sampleDetail)))) | Out-Null
      }
      $omittedDetailCount = [int](Get-NestedValue -Object $group -Path @('omittedDetailCount') -Default 0)
      if ($omittedDetailCount -gt 0) {
        $lines.Add(('<li>+{0} more details in report</li>' -f $omittedDetailCount)) | Out-Null
      }
      $sectionLinks = @(
        ConvertTo-ObjectArray -Value (Get-NestedValue -Object $group -Path @('sectionLinks') -Default @()) |
          ForEach-Object {
            $label = Get-OptionalString -Value (Get-NestedValue -Object $_ -Path @('label'))
            $path = Get-OptionalString -Value (Get-NestedValue -Object $_ -Path @('reportUrl'))
            if ([string]::IsNullOrWhiteSpace($label) -or [string]::IsNullOrWhiteSpace($path)) {
              return $null
            }

            '<a href="{0}">{1}</a>' -f (ConvertTo-HtmlText $path), (ConvertTo-HtmlText $label)
          } |
          Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
      )
      if ($sectionLinks.Count -gt 0) {
        $lines.Add(('<li><strong>Exact sections:</strong> {0}</li>' -f ($sectionLinks -join ', '))) | Out-Null
      }
      $debugPrimaryReportUrl = Get-OptionalString -Value (Get-NestedValue -Object $group -Path @('debugPrimaryReportUrl'))
      if (-not [string]::IsNullOrWhiteSpace($debugPrimaryReportUrl)) {
        $lines.Add(('<li><strong>Debug section page:</strong> <a href="{0}">open debug evidence</a></li>' -f (ConvertTo-HtmlText $debugPrimaryReportUrl))) | Out-Null
      }
      $lines.Add('</ul>') | Out-Null
      $lines.Add('</li>') | Out-Null
    }
    $debugChangeDetailsUrl = Get-OptionalString -Value (Get-NestedValue -Object $changeDetails -Path @('debugReportUrl'))
    if (-not [string]::IsNullOrWhiteSpace($debugChangeDetailsUrl)) {
      $lines.Add(('<li><a href="{0}">open debug change-details page</a></li>' -f (ConvertTo-HtmlText $debugChangeDetailsUrl))) | Out-Null
    }
    $lines.Add('</ul>') | Out-Null
  }

  return ($lines -join "`n").TrimEnd() + "`n"
}

function New-CommentPreviewMarkdown {
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$PreviewCards,
    [AllowNull()]
    [string]$RunUrl
  )

  if ($PreviewCards.Count -eq 0) {
    return ''
  }

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('### Preview gallery') | Out-Null
  $lines.Add('') | Out-Null
  foreach ($previewCard in $PreviewCards) {
    $title = Get-ReviewerPreviewTitle -PreviewPair $previewCard
    $subtitle = Get-ReviewerPreviewSubtitle -PreviewPair $previewCard
    $revisionContext = Get-ReviewerPreviewRevisionContext -PreviewPair $previewCard
    $detailLines = @(Get-ReviewerPreviewDetailLines -PreviewPair $previewCard)
    $detailHtml = if ($detailLines.Count -eq 0) {
      ''
    } else {
      '<div class="comparevi-preview-history">' + (($detailLines | ForEach-Object { '<p>' + (ConvertTo-HtmlText $_) + '</p>' }) -join '') + '</div>'
    }
    $lines.Add(('<h4><code>{0}</code></h4>' -f (ConvertTo-HtmlText $title))) | Out-Null
    $lines.Add(('<p>{0}</p>' -f (ConvertTo-HtmlText $subtitle))) | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($revisionContext)) {
      $lines.Add(('<p><code>{0}</code></p>' -f (ConvertTo-HtmlText $revisionContext))) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($detailHtml)) {
      $lines.Add($detailHtml) | Out-Null
    }
    $reviewerSummaryMarkdown = New-CommentReviewerSummaryMarkdown -ReviewerSummary (Get-NestedValue -Object $previewCard -Path @('reviewerSummary'))
    if (-not [string]::IsNullOrWhiteSpace($reviewerSummaryMarkdown)) {
      $lines.Add($reviewerSummaryMarkdown) | Out-Null
    }
    $changeDetailsMarkdown = New-CommentChangeDetailsMarkdown -ChangeDetails (Get-NestedValue -Object $previewCard -Path @('changeDetails'))
    if (-not [string]::IsNullOrWhiteSpace($changeDetailsMarkdown)) {
      $lines.Add($changeDetailsMarkdown) | Out-Null
    }
    foreach ($surface in @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $previewCard -Path @('surfaces') -Default @()))) {
      $surfaceLabel = Get-ReviewerPreviewSurfaceLabel -SurfaceKind (Get-OptionalString -Value $surface.surfaceKind) -FallbackLabel (Get-OptionalString -Value $surface.surfaceLabel)
      $baseUrl = [string]$surface.baseImageUrl
      $headUrl = [string]$surface.headImageUrl
      $linkUrl = Get-OptionalString -Value (Get-NestedValue -Object $surface -Path @('evidenceUrl'))
      if ([string]::IsNullOrWhiteSpace($linkUrl)) {
        $linkUrl = if ([string]::IsNullOrWhiteSpace($RunUrl)) { $headUrl } else { $RunUrl }
      }
      $baseAlt = '{0} base' -f $surfaceLabel
      $headAlt = '{0} head' -f $surfaceLabel
      $lines.Add('') | Out-Null
      $lines.Add(('<p><strong>{0}</strong></p>' -f (ConvertTo-HtmlText $surfaceLabel))) | Out-Null
      $lines.Add('<table>') | Out-Null
      $lines.Add('<thead><tr><th>Base</th><th>Head</th></tr></thead>') | Out-Null
      $lines.Add('<tbody><tr>') | Out-Null
      $lines.Add(('<td><a href="{0}"><img alt="{1}" src="{2}" width="320"></a></td>' -f (ConvertTo-HtmlText $linkUrl), (ConvertTo-HtmlText $baseAlt), (ConvertTo-HtmlText $baseUrl))) | Out-Null
      $lines.Add(('<td><a href="{0}"><img alt="{1}" src="{2}" width="320"></a></td>' -f (ConvertTo-HtmlText $linkUrl), (ConvertTo-HtmlText $headAlt), (ConvertTo-HtmlText $headUrl))) | Out-Null
      $lines.Add('</tr></tbody>') | Out-Null
      $lines.Add('</table>') | Out-Null
    }
    $lines.Add('') | Out-Null
  }

  return $lines -join "`n"
}

function Insert-PreviewGallery {
  param(
    [Parameter(Mandatory = $true)]
    [string]$CommentBody,
    [Parameter(Mandatory = $true)]
    [string]$PreviewMarkdown
  )

  if ([string]::IsNullOrWhiteSpace($PreviewMarkdown)) {
    return $CommentBody
  }

  $footer = 'The full unsuppressed history suite lives in the uploaded artifact bundle. Use the workflow run entry above, download the artifact, and start at `index.html` or `index.md`.'
  if ($CommentBody.Contains($footer)) {
    return $CommentBody.Replace($footer, ($PreviewMarkdown + "`n`n" + $footer))
  }

  return ($CommentBody.TrimEnd() + "`n`n" + $PreviewMarkdown + "`n")
}

function Publish-CommentPreviewSurface {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepositorySlug,
    [Parameter(Mandatory = $true)]
    [string]$BranchName,
    [Parameter(Mandatory = $true)]
    [string]$RootPath,
    [Parameter(Mandatory = $true)]
    [string]$ExecutionRunId,
    [Parameter(Mandatory = $true)]
    [string]$ArtifactRoot,
    [Parameter(Mandatory = $true)]
    [object]$PreviewManifest,
    [AllowEmptyCollection()]
    [object[]]$ReviewCards = @()
  )

  Ensure-PreviewBranch -RepositorySlug $RepositorySlug -BranchName $BranchName | Out-Null

  $prNumber = [int](Get-OptionalString -Value (Get-NestedValue -Object $PreviewManifest -Path @('pullRequest', 'number') -Default 0))
  $previewCards = @($ReviewCards | ForEach-Object { $_ })
  if ($previewCards.Count -eq 0) {
    return [ordered]@{
      status = 'not-required'
      reason = 'no-comment-preview-pairs'
      branch = $BranchName
      root = $RootPath
      manifestPath = $null
      manifestUrl = $null
      previewPairCount = 0
      publishedImageCount = 0
      publishedSurfaceCount = 0
      commentPreviewCards = @()
      commentPreviewPairs = @()
    }
  }

  $runRoot = '{0}/pull-request-{1}/workflow-run-{2}' -f $RootPath.TrimEnd('/'), ('{0:D5}' -f $prNumber), $ExecutionRunId
  $publishedPreviewCards = New-Object System.Collections.Generic.List[object]
  $publishedPreviewPairs = New-Object System.Collections.Generic.List[object]
  $publishedImageCount = 0
  $publishedSurfaceCount = 0
  $publishedPairPageCount = 0
  $cardOrdinal = 1
  foreach ($previewCard in $previewCards) {
    $cardRoot = '{0}/{1}-{2}' -f $runRoot, ('{0:D3}' -f $cardOrdinal), ('history-pair-' + ('{0:D2}' -f (Get-ReviewerPreviewComparisonIndex -PreviewPair $previewCard)))
    $pairReviewPath = '{0}/index.md' -f $cardRoot
    $pairReviewUrl = ConvertTo-BlobGitHubUrl -RepositorySlug $RepositorySlug -BranchName $BranchName -Path $pairReviewPath
    $changeDetailsEvidencePath = '{0}/change-details.md' -f $cardRoot
    $changeDetailsEvidenceUrl = $null
    if ($null -ne (Get-NestedValue -Object $previewCard -Path @('changeDetails')) -or
      $null -ne (Get-NestedValue -Object $previewCard -Path @('reviewerSummary'))) {
      $changeDetailsEvidenceUrl = ConvertTo-BlobGitHubUrl -RepositorySlug $RepositorySlug -BranchName $BranchName -Path $changeDetailsEvidencePath
    }
    $publishedSurfaces = New-Object System.Collections.Generic.List[object]
    $surfaceOrdinal = 1
    foreach ($surface in @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $previewCard -Path @('surfaces') -Default @()))) {
      $surfaceLabel = Get-ReviewerPreviewSurfaceLabel -SurfaceKind (Get-OptionalString -Value $surface.surfaceKind) -FallbackLabel (Get-OptionalString -Value $surface.surfaceLabel)
      $surfaceSlug = ConvertTo-Slug -Value (Get-OptionalString -Value $surface.surfaceKind) -Fallback ('surface-' + ('{0:D2}' -f $surfaceOrdinal))
      $surfaceRoot = '{0}/{1}-{2}' -f $cardRoot, ('{0:D2}' -f $surfaceOrdinal), $surfaceSlug
      $baseRelativePath = [string]$surface.baseImageRelativePath
      $headRelativePath = [string]$surface.headImageRelativePath
      $baseImagePath = Join-Path $ArtifactRoot ($baseRelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
      $headImagePath = Join-Path $ArtifactRoot ($headRelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
      if (-not (Test-Path -LiteralPath $baseImagePath -PathType Leaf)) {
        throw "Preview base image was missing from the downloaded artifact: $baseRelativePath"
      }
      if (-not (Test-Path -LiteralPath $headImagePath -PathType Leaf)) {
        throw "Preview head image was missing from the downloaded artifact: $headRelativePath"
      }

      $baseExtension = [System.IO.Path]::GetExtension($baseImagePath)
      $headExtension = [System.IO.Path]::GetExtension($headImagePath)
      $basePublishPath = '{0}/base{1}' -f $surfaceRoot, $baseExtension
      $headPublishPath = '{0}/head{1}' -f $surfaceRoot, $headExtension
      $surfaceEvidencePath = '{0}/evidence.md' -f $surfaceRoot

      $messageBase = 'comparevi-history: publish PR preview images for run {0}' -f $ExecutionRunId
      Set-RepositoryContent -RepositorySlug $RepositorySlug -BranchName $BranchName -Path $basePublishPath -Bytes ([System.IO.File]::ReadAllBytes($baseImagePath)) -Message $messageBase | Out-Null
      Set-RepositoryContent -RepositorySlug $RepositorySlug -BranchName $BranchName -Path $headPublishPath -Bytes ([System.IO.File]::ReadAllBytes($headImagePath)) -Message $messageBase | Out-Null
      $publishedImageCount += 2
      $publishedSurfaceCount += 1

      $publishedSurface = [ordered]@{
        surfaceKind = Get-OptionalString -Value $surface.surfaceKind
        surfaceLabel = $surfaceLabel
        reportHtmlRelativePath = Add-AnchorToUrl -Url $pairReviewPath -AnchorId (Get-OptionalString -Value $surface.surfaceKind)
        debugReportHtmlRelativePath = Get-OptionalString -Value $surface.reportHtmlRelativePath
        reportUrl = Add-AnchorToUrl -Url $pairReviewUrl -AnchorId (Get-OptionalString -Value $surface.surfaceKind)
        baseImagePath = $basePublishPath
        baseImageUrl = ConvertTo-RawGitHubUrl -RepositorySlug $RepositorySlug -BranchName $BranchName -Path $basePublishPath
        headImagePath = $headPublishPath
        headImageUrl = ConvertTo-RawGitHubUrl -RepositorySlug $RepositorySlug -BranchName $BranchName -Path $headPublishPath
        evidencePath = Add-AnchorToUrl -Url $pairReviewPath -AnchorId (Get-OptionalString -Value $surface.surfaceKind)
        evidenceUrl = Add-AnchorToUrl -Url $pairReviewUrl -AnchorId (Get-OptionalString -Value $surface.surfaceKind)
        debugEvidencePath = $surfaceEvidencePath
        debugEvidenceUrl = ConvertTo-BlobGitHubUrl -RepositorySlug $RepositorySlug -BranchName $BranchName -Path $surfaceEvidencePath
      }
      $surfaceEvidenceMarkdown = New-CommentSurfaceEvidenceMarkdown -PreviewCard $previewCard -Surface $publishedSurface -ChangeDetailsEvidenceUrl $changeDetailsEvidenceUrl -PairReviewUrl $pairReviewUrl
      Set-RepositoryContent -RepositorySlug $RepositorySlug -BranchName $BranchName -Path $surfaceEvidencePath -Bytes ([System.Text.Encoding]::UTF8.GetBytes($surfaceEvidenceMarkdown)) -Message ('comparevi-history: publish PR preview evidence for run {0}' -f $ExecutionRunId) | Out-Null
      $publishedSurfaces.Add($publishedSurface) | Out-Null
      $surfaceOrdinal += 1
    }

    if (-not [string]::IsNullOrWhiteSpace($changeDetailsEvidenceUrl)) {
      $changeDetailsEvidenceMarkdown = New-CommentChangeDetailsEvidenceMarkdown -PreviewCard $previewCard -PairReviewUrl $pairReviewUrl
      Set-RepositoryContent -RepositorySlug $RepositorySlug -BranchName $BranchName -Path $changeDetailsEvidencePath -Bytes ([System.Text.Encoding]::UTF8.GetBytes($changeDetailsEvidenceMarkdown)) -Message ('comparevi-history: publish PR preview evidence for run {0}' -f $ExecutionRunId) | Out-Null
    }

    $publishedReviewerSummary = ConvertTo-PublishedReviewerSummary -ReviewerSummary (Get-NestedValue -Object $previewCard -Path @('reviewerSummary')) -EvidencePath $pairReviewPath -EvidenceUrl $pairReviewUrl -DebugEvidenceUrl $changeDetailsEvidenceUrl
    $publishedChangeDetails = ConvertTo-PublishedChangeDetails -ChangeDetails (Get-NestedValue -Object $previewCard -Path @('changeDetails')) -EvidencePath $pairReviewPath -EvidenceUrl $pairReviewUrl -DebugEvidenceUrl $changeDetailsEvidenceUrl

    $publishedCard = [ordered]@{
      targetId = [string]$previewCard.targetId
      targetPath = [string]$previewCard.targetPath
      comparison = $previewCard.comparison
      pairReviewPath = $pairReviewPath
      pairReviewUrl = $pairReviewUrl
      reviewerSummary = $publishedReviewerSummary
      changeDetails = $publishedChangeDetails
      surfaces = @($publishedSurfaces | ForEach-Object { $_ })
    }
    $pairReviewMarkdown = New-CommentPairReviewMarkdown -PreviewCard $publishedCard -PairReviewUrl $pairReviewUrl
    Set-RepositoryContent -RepositorySlug $RepositorySlug -BranchName $BranchName -Path $pairReviewPath -Bytes ([System.Text.Encoding]::UTF8.GetBytes($pairReviewMarkdown)) -Message ('comparevi-history: publish PR preview evidence for run {0}' -f $ExecutionRunId) | Out-Null
    $publishedPairPageCount += 1
    $publishedPreviewCards.Add($publishedCard) | Out-Null

    $representativeSurface = @($publishedSurfaces | Select-Object -First 1)
    if ($null -ne $representativeSurface) {
      $publishedPreviewPairs.Add([ordered]@{
          targetId = [string]$previewCard.targetId
          targetPath = [string]$previewCard.targetPath
          mode = Get-OptionalString -Value $representativeSurface.surfaceKind
          label = Get-OptionalString -Value $representativeSurface.surfaceLabel
          sectionKind = 'review-pair'
          comparison = $previewCard.comparison
          reportHtmlRelativePath = Get-OptionalString -Value $representativeSurface.reportHtmlRelativePath
          reportUrl = Get-OptionalString -Value $representativeSurface.reportUrl
          baseImagePath = [string]$representativeSurface.baseImagePath
          baseImageUrl = [string]$representativeSurface.baseImageUrl
          headImagePath = [string]$representativeSurface.headImagePath
          headImageUrl = [string]$representativeSurface.headImageUrl
          evidencePath = Get-OptionalString -Value $representativeSurface.evidencePath
          evidenceUrl = Get-OptionalString -Value $representativeSurface.evidenceUrl
          debugEvidencePath = Get-OptionalString -Value $representativeSurface.debugEvidencePath
          debugEvidenceUrl = Get-OptionalString -Value $representativeSurface.debugEvidenceUrl
        }) | Out-Null
    }

    $cardOrdinal += 1
  }

  $publishedManifestPath = "$runRoot/preview-manifest.json"
  $publishedManifest = [ordered]@{
    schema = 'comparevi-history/pr-comment-preview-publication@v1'
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    repository = $RepositorySlug
    branch = $BranchName
    root = $runRoot
    previewCards = @($publishedPreviewCards | ForEach-Object { $_ })
    previewPairs = @($publishedPreviewPairs | ForEach-Object { $_ })
  }
  $publishedManifestBytes = [System.Text.Encoding]::UTF8.GetBytes(($publishedManifest | ConvertTo-Json -Depth 32))
  Set-RepositoryContent -RepositorySlug $RepositorySlug -BranchName $BranchName -Path $publishedManifestPath -Bytes $publishedManifestBytes -Message ('comparevi-history: publish PR preview manifest for run {0}' -f $ExecutionRunId) | Out-Null

  return [ordered]@{
    status = 'succeeded'
    reason = 'preview-images-published'
    branch = $BranchName
    root = $runRoot
    manifestPath = $publishedManifestPath
    manifestUrl = ConvertTo-BlobGitHubUrl -RepositorySlug $RepositorySlug -BranchName $BranchName -Path $publishedManifestPath
    previewPairCount = $publishedPreviewCards.Count
    publishedImageCount = $publishedImageCount
    publishedSurfaceCount = $publishedSurfaceCount
    publishedPairPageCount = $publishedPairPageCount
    commentPreviewCards = @($publishedPreviewCards | ForEach-Object { $_ })
    commentPreviewPairs = @($publishedPreviewPairs | ForEach-Object { $_ })
  }
}

function Get-CommentPages {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepositorySlug,
    [Parameter(Mandatory = $true)]
    [string]$PullRequestNumber
  )

  $comments = New-Object System.Collections.Generic.List[object]
  $page = 1
  while ($true) {
    $uri = "https://api.github.com/repos/$RepositorySlug/issues/$PullRequestNumber/comments?per_page=100&page=$page"
    $response = Invoke-GitHubJson -Method Get -Uri $uri
    $pageEntries = @($response | Where-Object { $null -ne $_ })
    foreach ($entry in $pageEntries) {
      $comments.Add($entry) | Out-Null
    }

    if ($pageEntries.Count -lt 100) {
      break
    }

    $page += 1
  }

  return @($comments | ForEach-Object { $_ })
}

$basePath = (Get-Location).Path
$resultsDirResolved = Resolve-AbsolutePath -Path $ResultsDir -BasePath $basePath
New-Item -ItemType Directory -Path $resultsDirResolved -Force | Out-Null

$effectiveArtifactName = if ([string]::IsNullOrWhiteSpace($ArtifactName)) {
  "comparevi-history-pr-diagnostics-$WorkflowRunId"
} else {
  $ArtifactName.Trim()
}

$receiptPath = Join-Path $resultsDirResolved 'pr-comment-publication.json'
$downloadZipPath = Join-Path $resultsDirResolved 'artifact.zip'
$artifactRoot = Join-Path $resultsDirResolved 'artifact'
if (Test-Path -LiteralPath $artifactRoot) {
  Remove-Item -LiteralPath $artifactRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null

$status = 'failed'
$reason = 'unknown'
$commentId = $null
$commentUrl = $null
$commentAction = 'none'
$prRunPath = $null
$commentBodyPath = $null
$pullRequestNumber = $null
$workflowRunUrl = $null
$previewPublication = [ordered]@{
  status = 'not-required'
  reason = 'preview-manifest-not-present'
  branch = $PreviewBranch
  root = $PreviewRoot
  manifestPath = $null
  manifestUrl = $null
  previewPairCount = 0
  publishedImageCount = 0
  publishedSurfaceCount = 0
  commentPreviewCards = @()
  commentPreviewPairs = @()
}

try {
  $artifact = Find-Artifact -RepositorySlug $Repository -RunId $WorkflowRunId -RequestedArtifactName $effectiveArtifactName
  if (-not $artifact) {
    throw "Workflow run $WorkflowRunId did not publish artifact '$effectiveArtifactName'."
  }

  Invoke-WebRequest -Uri ([string]$artifact.archive_download_url) -Headers (Get-GitHubHeaders) -OutFile $downloadZipPath
  Expand-Archive -Path $downloadZipPath -DestinationPath $artifactRoot -Force

  $prRunFile = Get-ChildItem -LiteralPath $artifactRoot -Recurse -Filter 'pr-run.json' | Select-Object -First 1
  if (-not $prRunFile) {
    throw 'Downloaded artifact did not contain pr-run.json.'
  }
  $prRunPath = $prRunFile.FullName
  $prRun = Read-JsonFile -Path $prRunPath
  if ([string]$prRun.schema -ne 'comparevi-history/pr-run@v2') {
    throw "Unsupported PR run schema in '$prRunPath': $($prRun.schema)"
  }

  $commentFile = Get-ChildItem -LiteralPath $artifactRoot -Recurse -Filter 'pr-comment.md' | Select-Object -First 1
  if (-not $commentFile) {
    throw 'Downloaded artifact did not contain pr-comment.md.'
  }
  $commentBodyPath = $commentFile.FullName
  $commentBody = Get-Content -LiteralPath $commentBodyPath -Raw
  if ([string]::IsNullOrWhiteSpace($commentBody)) {
    throw 'Downloaded artifact contained an empty pr-comment.md.'
  }
  if ($commentBody -notmatch [regex]::Escape($StickyMarker)) {
    throw 'Prepared PR comment body did not include the sticky marker.'
  }

  $pullRequestNumber = [string]$prRun.pullRequest.number
  if ([string]::IsNullOrWhiteSpace($pullRequestNumber)) {
    throw 'PR run receipt did not declare pullRequest.number.'
  }
  $workflowRunUrl = Get-OptionalString -Value $prRun.outputs.workflowRunUrl

  $previewManifestFile = Get-ChildItem -LiteralPath $artifactRoot -Recurse -Filter 'pr-preview-manifest.json' | Select-Object -First 1
  if ($previewManifestFile) {
      $previewManifest = Read-JsonFile -Path $previewManifestFile.FullName
      if ([string]$previewManifest.schema -ne 'comparevi-history/pr-preview-manifest@v1') {
        throw "Unsupported preview manifest schema in '$($previewManifestFile.FullName)': $($previewManifest.schema)"
      }

      $previewManifest | Add-Member -NotePropertyName pullRequest -NotePropertyValue $prRun.pullRequest -Force
      if ([int](Get-NestedValue -Object $previewManifest -Path @('summary', 'commentPreviewPairCount') -Default 0) -gt 0) {
        $reviewBundleFile = Get-ChildItem -LiteralPath $artifactRoot -Recurse -Filter 'review-bundle.json' | Select-Object -First 1
        if (-not $reviewBundleFile) {
          throw 'Downloaded artifact did not contain review-bundle.json.'
        }
        $reviewBundle = Read-JsonFile -Path $reviewBundleFile.FullName
        if ([string]$reviewBundle.schema -ne 'comparevi-history/review-bundle@v1') {
          throw "Unsupported review bundle schema in '$($reviewBundleFile.FullName)': $($reviewBundle.schema)"
        }

        $commentPreviewCards = @(Get-CompareVIHistoryReviewBundleCards `
            -ReviewBundle $reviewBundle `
            -SelectedPreviewPairs @($previewManifest.commentPreviewPairs | ForEach-Object { $_ }) `
            -UseSelectedPreviewPairs)
        $previewPublication = Publish-CommentPreviewSurface `
          -RepositorySlug $Repository `
          -BranchName $PreviewBranch `
          -RootPath $PreviewRoot `
          -ExecutionRunId $WorkflowRunId `
          -ArtifactRoot $artifactRoot `
          -PreviewManifest $previewManifest `
          -ReviewCards $commentPreviewCards
        $previewMarkdown = New-CommentPreviewMarkdown -PreviewCards @($previewPublication.commentPreviewCards | ForEach-Object { $_ }) -RunUrl $workflowRunUrl
        $commentBody = Insert-PreviewGallery -CommentBody $commentBody -PreviewMarkdown $previewMarkdown
        $commentBody | Set-Content -LiteralPath $commentBodyPath -Encoding utf8
      } else {
        $previewPublication = [ordered]@{
        status = 'not-required'
        reason = 'no-comment-preview-pairs'
        branch = $PreviewBranch
        root = $PreviewRoot
        manifestPath = $null
        manifestUrl = $null
        previewPairCount = 0
        publishedImageCount = 0
        publishedSurfaceCount = 0
        commentPreviewCards = @()
        commentPreviewPairs = @()
      }
    }
  }

  $existingComments = Get-CommentPages -RepositorySlug $Repository -PullRequestNumber $pullRequestNumber
  $existingComment = @(
    $existingComments |
      Where-Object { [string]$_.body -match [regex]::Escape($StickyMarker) } |
      Sort-Object { [DateTime]$_.updated_at } -Descending |
      Select-Object -First 1
  )

  if ($existingComment) {
    $commentId = [string]$existingComment.id
    $commentUrl = [string]$existingComment.html_url
    if ([string]$existingComment.body -eq $commentBody) {
      $status = 'succeeded'
      $reason = 'comment-unchanged'
      $commentAction = 'unchanged'
    } else {
      $updateUri = "https://api.github.com/repos/$Repository/issues/comments/$commentId"
      $updated = Invoke-GitHubJson -Method Patch -Uri $updateUri -Body @{ body = $commentBody }
      $status = 'succeeded'
      $reason = 'comment-updated'
      $commentAction = 'updated'
      $commentUrl = [string]$updated.html_url
    }
  } else {
    $createUri = "https://api.github.com/repos/$Repository/issues/$pullRequestNumber/comments"
    $created = Invoke-GitHubJson -Method Post -Uri $createUri -Body @{ body = $commentBody }
    $status = 'succeeded'
    $reason = 'comment-created'
    $commentAction = 'created'
    $commentId = [string]$created.id
    $commentUrl = [string]$created.html_url
  }
} catch {
  $status = 'failed'
  $reason = $_.Exception.Message
}

$receipt = [ordered]@{
  schema = 'comparevi-history/pr-comment-publication@v1'
  generatedAtUtc = [DateTime]::UtcNow.ToString('o')
  repository = $Repository
  workflowRunId = $WorkflowRunId
  artifactName = $effectiveArtifactName
  artifactZipPath = $downloadZipPath
  artifactRoot = $artifactRoot
  prRunPath = $prRunPath
  commentBodyPath = $commentBodyPath
  pullRequestNumber = if ([string]::IsNullOrWhiteSpace($pullRequestNumber)) { $null } else { [int]$pullRequestNumber }
  workflowRunUrl = if ([string]::IsNullOrWhiteSpace($workflowRunUrl)) { $null } else { $workflowRunUrl }
  previewPublication = $previewPublication
  summary = [ordered]@{
    status = $status
    reason = $reason
    commentAction = $commentAction
    commentId = if ([string]::IsNullOrWhiteSpace($commentId)) { $null } else { [int64]$commentId }
    commentUrl = if ([string]::IsNullOrWhiteSpace($commentUrl)) { $null } else { $commentUrl }
  }
}
$receipt | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $receiptPath -Encoding utf8

Write-ActionOutput -Key 'publication-receipt-path' -Value $receiptPath
Write-ActionOutput -Key 'publication-status' -Value $status
Write-ActionOutput -Key 'publication-reason' -Value $reason
Write-ActionOutput -Key 'comment-id' -Value $(if ([string]::IsNullOrWhiteSpace($commentId)) { '' } else { $commentId })
Write-ActionOutput -Key 'comment-url' -Value $(if ([string]::IsNullOrWhiteSpace($commentUrl)) { '' } else { $commentUrl })
Write-ActionOutput -Key 'artifact-name' -Value $effectiveArtifactName
Write-ActionOutput -Key 'preview-publication-status' -Value ([string]$previewPublication.status)
Write-ActionOutput -Key 'preview-publication-reason' -Value ([string]$previewPublication.reason)
Write-ActionOutput -Key 'preview-manifest-url' -Value $(if ([string]::IsNullOrWhiteSpace([string]$previewPublication.manifestUrl)) { '' } else { [string]$previewPublication.manifestUrl })
Write-ActionOutput -Key 'preview-pair-count' -Value ([string]$previewPublication.previewPairCount)
Write-ActionOutput -Key 'published-image-count' -Value ([string]$previewPublication.publishedImageCount)
Write-ActionOutput -Key 'published-surface-count' -Value ([string](Get-NestedValue -Object $previewPublication -Path @('publishedSurfaceCount') -Default 0))

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  @(
    '## comparevi-history PR comment publication'
    ''
    ('- Workflow run id: `{0}`' -f $WorkflowRunId)
    ('- Artifact name: `{0}`' -f $effectiveArtifactName)
    ('- Publication status: `{0}`' -f $status)
    ('- Publication reason: `{0}`' -f $reason)
    ('- Comment action: `{0}`' -f $commentAction)
    ('- Comment id: `{0}`' -f $(if ([string]::IsNullOrWhiteSpace($commentId)) { 'n/a' } else { $commentId }))
    ('- Comment URL: `{0}`' -f $(if ([string]::IsNullOrWhiteSpace($commentUrl)) { 'n/a' } else { $commentUrl }))
    ('- Preview publication status: `{0}`' -f [string]$previewPublication.status)
    ('- Preview publication reason: `{0}`' -f [string]$previewPublication.reason)
    ('- Preview publication manifest: `{0}`' -f $(if ([string]::IsNullOrWhiteSpace([string]$previewPublication.manifestUrl)) { 'n/a' } else { [string]$previewPublication.manifestUrl }))
    ('- Published preview pairs: `{0}`' -f [string]$previewPublication.previewPairCount)
    ('- Published preview surfaces: `{0}`' -f [string](Get-NestedValue -Object $previewPublication -Path @('publishedSurfaceCount') -Default 0))
    ('- Published preview images: `{0}`' -f [string]$previewPublication.publishedImageCount)
    ('- Receipt: `{0}`' -f $receiptPath)
  ) | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
}

if ($status -eq 'failed') {
  throw $reason
}

$receipt | ConvertTo-Json -Depth 32
