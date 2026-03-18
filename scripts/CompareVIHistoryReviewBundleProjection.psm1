Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ProjectionOptionalString {
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

function Get-ProjectionNestedValue {
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

function ConvertTo-ProjectionObjectArray {
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

function Get-ReviewPairSelectionKey {
  param(
    [Parameter(Mandatory = $true)]
    [string]$TargetId,
    [Parameter(Mandatory = $true)]
    [int]$ComparisonIndex
  )

  return '{0}|{1}' -f $TargetId, $ComparisonIndex
}

function Convert-ProjectionSectionLink {
  param([Parameter(Mandatory = $true)][object]$SectionLink)

  $reportHtmlRelativePath = Get-ProjectionOptionalString -Value (Get-ProjectionNestedValue -Object $SectionLink -Path @('reviewerRelativePath'))
  if ([string]::IsNullOrWhiteSpace($reportHtmlRelativePath)) {
    $reportHtmlRelativePath = Get-ProjectionOptionalString -Value (Get-ProjectionNestedValue -Object $SectionLink -Path @('debugReportHtmlRelativePath'))
  }

  return [ordered]@{
    sectionOrdinal = [int](Get-ProjectionNestedValue -Object $SectionLink -Path @('sectionOrdinal') -Default 0)
    label = [string](Get-ProjectionNestedValue -Object $SectionLink -Path @('label') -Default '')
    reportHtmlRelativePath = $reportHtmlRelativePath
    debugReportHtmlRelativePath = Get-ProjectionOptionalString -Value (Get-ProjectionNestedValue -Object $SectionLink -Path @('debugReportHtmlRelativePath'))
  }
}

function Convert-ProjectionChangeDetailGroup {
  param([Parameter(Mandatory = $true)][object]$Group)

  $primaryReportHtmlRelativePath = Get-ProjectionOptionalString -Value (Get-ProjectionNestedValue -Object $Group -Path @('primaryReviewerRelativePath'))
  if ([string]::IsNullOrWhiteSpace($primaryReportHtmlRelativePath)) {
    $primaryReportHtmlRelativePath = Get-ProjectionOptionalString -Value (Get-ProjectionNestedValue -Object $Group -Path @('primaryDebugReportHtmlRelativePath'))
  }

  return [ordered]@{
    heading = [string](Get-ProjectionNestedValue -Object $Group -Path @('heading') -Default '')
    sectionCount = [int](Get-ProjectionNestedValue -Object $Group -Path @('sectionCount') -Default 0)
    detailCount = [int](Get-ProjectionNestedValue -Object $Group -Path @('detailCount') -Default 0)
    sampleDetails = @(ConvertTo-ProjectionObjectArray -Value (Get-ProjectionNestedValue -Object $Group -Path @('sampleDetails') -Default @()))
    omittedDetailCount = [int](Get-ProjectionNestedValue -Object $Group -Path @('omittedDetailCount') -Default 0)
    primaryReportHtmlRelativePath = $primaryReportHtmlRelativePath
    debugPrimaryReportHtmlRelativePath = Get-ProjectionOptionalString -Value (Get-ProjectionNestedValue -Object $Group -Path @('primaryDebugReportHtmlRelativePath'))
    sectionLinks = @(
      ConvertTo-ProjectionObjectArray -Value (Get-ProjectionNestedValue -Object $Group -Path @('sectionLinks') -Default @()) |
        ForEach-Object { Convert-ProjectionSectionLink -SectionLink $_ }
    )
  }
}

function Convert-ProjectionChangeDetails {
  param([AllowNull()][object]$ChangeDetails)

  if ($null -eq $ChangeDetails) {
    return $null
  }

  $reportHtmlRelativePath = Get-ProjectionOptionalString -Value (Get-ProjectionNestedValue -Object $ChangeDetails -Path @('primaryReviewerRelativePath'))
  if ([string]::IsNullOrWhiteSpace($reportHtmlRelativePath)) {
    $reportHtmlRelativePath = Get-ProjectionOptionalString -Value (Get-ProjectionNestedValue -Object $ChangeDetails -Path @('debugReportHtmlRelativePath'))
  }

  return [ordered]@{
    label = [string](Get-ProjectionNestedValue -Object $ChangeDetails -Path @('label') -Default 'Change details')
    sourceMode = Get-ProjectionOptionalString -Value (Get-ProjectionNestedValue -Object $ChangeDetails -Path @('sourceMode'))
    reportHtmlRelativePath = $reportHtmlRelativePath
    debugReportHtmlRelativePath = Get-ProjectionOptionalString -Value (Get-ProjectionNestedValue -Object $ChangeDetails -Path @('debugReportHtmlRelativePath'))
    includedCategories = @(ConvertTo-ProjectionObjectArray -Value (Get-ProjectionNestedValue -Object $ChangeDetails -Path @('includedCategories') -Default @()))
    groupCount = [int](Get-ProjectionNestedValue -Object $ChangeDetails -Path @('groupCount') -Default 0)
    omittedGroupCount = [int](Get-ProjectionNestedValue -Object $ChangeDetails -Path @('omittedGroupCount') -Default 0)
    sectionCount = [int](Get-ProjectionNestedValue -Object $ChangeDetails -Path @('sectionCount') -Default 0)
    detailCount = [int](Get-ProjectionNestedValue -Object $ChangeDetails -Path @('detailCount') -Default 0)
    groups = @(
      ConvertTo-ProjectionObjectArray -Value (Get-ProjectionNestedValue -Object $ChangeDetails -Path @('groups') -Default @()) |
        ForEach-Object { Convert-ProjectionChangeDetailGroup -Group $_ }
    )
  }
}

function Convert-ProjectionReviewerSignal {
  param([Parameter(Mandatory = $true)][object]$Signal)

  $primaryReportHtmlRelativePath = Get-ProjectionOptionalString -Value (Get-ProjectionNestedValue -Object $Signal -Path @('primaryReviewerRelativePath'))
  if ([string]::IsNullOrWhiteSpace($primaryReportHtmlRelativePath)) {
    $primaryReportHtmlRelativePath = Get-ProjectionOptionalString -Value (Get-ProjectionNestedValue -Object $Signal -Path @('primaryDebugReportHtmlRelativePath'))
  }

  return [ordered]@{
    signalKey = Get-ProjectionOptionalString -Value (Get-ProjectionNestedValue -Object $Signal -Path @('signalKey'))
    label = [string](Get-ProjectionNestedValue -Object $Signal -Path @('label') -Default '')
    severity = Get-ProjectionOptionalString -Value (Get-ProjectionNestedValue -Object $Signal -Path @('severity'))
    detailCount = [int](Get-ProjectionNestedValue -Object $Signal -Path @('detailCount') -Default 0)
    sectionCount = [int](Get-ProjectionNestedValue -Object $Signal -Path @('sectionCount') -Default 0)
    summary = [string](Get-ProjectionNestedValue -Object $Signal -Path @('summary') -Default '')
    primaryReportHtmlRelativePath = $primaryReportHtmlRelativePath
    debugPrimaryReportHtmlRelativePath = Get-ProjectionOptionalString -Value (Get-ProjectionNestedValue -Object $Signal -Path @('primaryDebugReportHtmlRelativePath'))
    sectionLinks = @(
      ConvertTo-ProjectionObjectArray -Value (Get-ProjectionNestedValue -Object $Signal -Path @('sectionLinks') -Default @()) |
        ForEach-Object { Convert-ProjectionSectionLink -SectionLink $_ }
    )
  }
}

function Convert-ProjectionReviewerSummary {
  param([AllowNull()][object]$ReviewerSummary)

  if ($null -eq $ReviewerSummary) {
    return $null
  }

  return [ordered]@{
    label = [string](Get-ProjectionNestedValue -Object $ReviewerSummary -Path @('label') -Default 'Reviewer summary')
    overallSeverity = Get-ProjectionOptionalString -Value (Get-ProjectionNestedValue -Object $ReviewerSummary -Path @('overallSeverity'))
    headline = [string](Get-ProjectionNestedValue -Object $ReviewerSummary -Path @('headline') -Default '')
    signalCount = [int](Get-ProjectionNestedValue -Object $ReviewerSummary -Path @('signalCount') -Default 0)
    omittedSignalCount = [int](Get-ProjectionNestedValue -Object $ReviewerSummary -Path @('omittedSignalCount') -Default 0)
    signals = @(
      ConvertTo-ProjectionObjectArray -Value (Get-ProjectionNestedValue -Object $ReviewerSummary -Path @('signals') -Default @()) |
        ForEach-Object { Convert-ProjectionReviewerSignal -Signal $_ }
    )
  }
}

function Convert-ProjectionSurface {
  param([Parameter(Mandatory = $true)][object]$Surface)

  $reportHtmlRelativePath = Get-ProjectionOptionalString -Value (Get-ProjectionNestedValue -Object $Surface -Path @('primaryReviewerRelativePath'))
  if ([string]::IsNullOrWhiteSpace($reportHtmlRelativePath)) {
    $reportHtmlRelativePath = Get-ProjectionOptionalString -Value (Get-ProjectionNestedValue -Object $Surface -Path @('debugReportHtmlRelativePath'))
  }

  return [ordered]@{
    surfaceKind = Get-ProjectionOptionalString -Value (Get-ProjectionNestedValue -Object $Surface -Path @('surfaceKind'))
    surfaceLabel = [string](Get-ProjectionNestedValue -Object $Surface -Path @('surfaceLabel') -Default '')
    mode = Get-ProjectionOptionalString -Value (Get-ProjectionNestedValue -Object $Surface -Path @('mode'))
    label = Get-ProjectionOptionalString -Value (Get-ProjectionNestedValue -Object $Surface -Path @('label'))
    reportHtmlRelativePath = $reportHtmlRelativePath
    debugReportHtmlRelativePath = Get-ProjectionOptionalString -Value (Get-ProjectionNestedValue -Object $Surface -Path @('debugReportHtmlRelativePath'))
    baseImageRelativePath = [string](Get-ProjectionNestedValue -Object $Surface -Path @('baseImageRelativePath') -Default '')
    headImageRelativePath = [string](Get-ProjectionNestedValue -Object $Surface -Path @('headImageRelativePath') -Default '')
    baseByteLength = [int64](Get-ProjectionNestedValue -Object $Surface -Path @('baseByteLength') -Default 0)
    headByteLength = [int64](Get-ProjectionNestedValue -Object $Surface -Path @('headByteLength') -Default 0)
    baseImageSha256 = Get-ProjectionOptionalString -Value (Get-ProjectionNestedValue -Object $Surface -Path @('baseImageSha256'))
    headImageSha256 = Get-ProjectionOptionalString -Value (Get-ProjectionNestedValue -Object $Surface -Path @('headImageSha256'))
    sortKey = Get-ProjectionOptionalString -Value (Get-ProjectionNestedValue -Object $Surface -Path @('sortKey'))
  }
}

function Convert-ProjectionReviewPairCard {
  param([Parameter(Mandatory = $true)][object]$ReviewPair)

  return [ordered]@{
    targetId = [string]$ReviewPair.targetId
    targetPath = [string]$ReviewPair.targetPath
    comparison = Get-ProjectionNestedValue -Object $ReviewPair -Path @('comparison')
    sortKey = Get-ProjectionOptionalString -Value (Get-ProjectionNestedValue -Object $ReviewPair -Path @('sortKey'))
    surfaces = @(
      ConvertTo-ProjectionObjectArray -Value (Get-ProjectionNestedValue -Object $ReviewPair -Path @('surfaces') -Default @()) |
        ForEach-Object { Convert-ProjectionSurface -Surface $_ }
    )
    reviewerSummary = Convert-ProjectionReviewerSummary -ReviewerSummary (Get-ProjectionNestedValue -Object $ReviewPair -Path @('reviewerSummary'))
    changeDetails = Convert-ProjectionChangeDetails -ChangeDetails (Get-ProjectionNestedValue -Object $ReviewPair -Path @('changeDetails'))
  }
}

function Sort-ProjectionCards {
  param([AllowNull()]$Cards)

  return @(
    ConvertTo-ProjectionObjectArray -Value $Cards |
      Sort-Object {
        $sortKey = Get-ProjectionOptionalString -Value $_.sortKey
        if ([string]::IsNullOrWhiteSpace($sortKey)) {
          '{0}|{1:D4}' -f [string]$_.targetPath, [int](Get-ProjectionNestedValue -Object $_ -Path @('comparison', 'index') -Default 0)
        } else {
          $sortKey
        }
      }
  )
}

function Get-CompareVIHistoryReviewBundleCards {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [object]$ReviewBundle,
    [AllowEmptyCollection()]
    [object[]]$SelectedPreviewPairs = @(),
    [switch]$UseSelectedPreviewPairs
  )

  $allCards = Sort-ProjectionCards -Cards @(
    ConvertTo-ProjectionObjectArray -Value (Get-ProjectionNestedValue -Object $ReviewBundle -Path @('reviewPairs') -Default @()) |
      ForEach-Object { Convert-ProjectionReviewPairCard -ReviewPair $_ }
  )

  if (-not $UseSelectedPreviewPairs.IsPresent) {
    return $allCards
  }

  if ($SelectedPreviewPairs.Count -eq 0) {
    return @()
  }

  $cardsByKey = @{}
  foreach ($card in $allCards) {
    $pairKey = Get-ReviewPairSelectionKey `
      -TargetId ([string]$card.targetId) `
      -ComparisonIndex ([int](Get-ProjectionNestedValue -Object $card -Path @('comparison', 'index') -Default 0))
    $cardsByKey[$pairKey] = $card
  }

  $selectedCards = New-Object System.Collections.Generic.List[object]
  $seenKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $missingKeys = New-Object System.Collections.Generic.List[string]
  foreach ($selectedPreviewPair in @(ConvertTo-ProjectionObjectArray -Value $SelectedPreviewPairs)) {
    $pairKey = Get-ReviewPairSelectionKey `
      -TargetId ([string]$selectedPreviewPair.targetId) `
      -ComparisonIndex ([int](Get-ProjectionNestedValue -Object $selectedPreviewPair -Path @('comparison', 'index') -Default 0))
    if (-not $seenKeys.Add($pairKey)) {
      continue
    }

    if (-not $cardsByKey.ContainsKey($pairKey)) {
      $missingKeys.Add($pairKey) | Out-Null
      continue
    }

    $selectedCards.Add($cardsByKey[$pairKey]) | Out-Null
  }

  if ($missingKeys.Count -gt 0) {
    throw ('review-bundle selection was missing review pairs for: {0}' -f ($missingKeys -join ', '))
  }

  return @($selectedCards | ForEach-Object { $_ })
}

Export-ModuleMember -Function Get-CompareVIHistoryReviewBundleCards
