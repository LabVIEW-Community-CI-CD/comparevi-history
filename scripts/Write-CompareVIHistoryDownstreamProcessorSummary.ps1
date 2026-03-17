param(
  [Parameter(Mandatory = $true)]
  [string]$DownstreamProcessingManifestPath,
  [ValidateRange(1, 100000)]
  [int]$StartPageOrdinal = 1,
  [ValidateRange(1, 100000)]
  [int]$MaxPages,
  [string]$OutputPath,
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

function ConvertTo-RelativePath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$BasePath,
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $normalizedBase = ([System.IO.Path]::GetFullPath($BasePath)).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
  $normalizedPath = [System.IO.Path]::GetFullPath($Path)
  return [System.IO.Path]::GetRelativePath($normalizedBase, $normalizedPath).Replace('\', '/')
}

function Get-OptionalPropertyValue {
  param(
    [AllowNull()]$InputObject,
    [Parameter(Mandatory = $true)][string]$PropertyName,
    [AllowNull()]$Default = $null
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

function Read-JsonReceipt {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$BasePath,
    [Parameter(Mandatory = $true)][string]$ExpectedSchema
  )

  $resolved = Resolve-AbsolutePath -Path $Path -BasePath $BasePath
  if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
    throw "Receipt not found: $resolved"
  }

  $receipt = Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json -Depth 100
  $schema = [string](Get-OptionalPropertyValue -InputObject $receipt -PropertyName 'schema' -Default '')
  if ($schema -ne $ExpectedSchema) {
    throw "Unsupported schema in '$resolved'. Expected '$ExpectedSchema', actual '$schema'"
  }

  return [pscustomobject]@{
    Path = $resolved
    Json = $receipt
  }
}

function Add-Count {
  param(
    [Parameter(Mandatory = $true)]
    [hashtable]$Map,
    [AllowNull()]
    [string]$Key,
    [int]$Amount = 1
  )

  $resolvedKey = if ([string]::IsNullOrWhiteSpace($Key)) { 'none' } else { $Key }
  if (-not $Map.ContainsKey($resolvedKey)) {
    $Map[$resolvedKey] = 0
  }

  $Map[$resolvedKey] = [int]$Map[$resolvedKey] + $Amount
}

function ConvertTo-OrderedCountMap {
  param([Parameter(Mandatory = $true)][hashtable]$Map)

  $orderedMap = [ordered]@{}
  foreach ($key in @($Map.Keys | Sort-Object)) {
    $orderedMap[[string]$key] = [int]$Map[$key]
  }

  return $orderedMap
}

function Get-IsTargetComplete {
  param(
    [Parameter(Mandatory = $true)][string]$FinalStatus,
    [AllowNull()][string]$GraphStatus
  )

  if ($FinalStatus -ne 'succeeded') {
    return $false
  }

  if (-not [string]::IsNullOrWhiteSpace($GraphStatus) -and $GraphStatus -ne 'complete') {
    return $false
  }

  return $true
}

$manifestReceipt = Read-JsonReceipt -Path $DownstreamProcessingManifestPath -BasePath (Get-Location).Path -ExpectedSchema 'comparevi-history/downstream-processing-manifest@v1'
$manifest = $manifestReceipt.Json
$manifestRoot = Split-Path -Parent $manifestReceipt.Path
$outputPathResolved = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
  Join-Path $manifestRoot 'downstream-processor-summary.json'
} else {
  Resolve-AbsolutePath -Path $OutputPath -BasePath (Get-Location).Path
}
New-Item -ItemType Directory -Path (Split-Path -Parent $outputPathResolved) -Force | Out-Null

$allCandidateUnits = @(
  ConvertTo-ObjectArray -Value (Get-OptionalPropertyValue -InputObject $manifest -PropertyName 'units') |
    Sort-Object { [int](Get-OptionalPropertyValue -InputObject $_ -PropertyName 'pageOrdinal' -Default 0) } |
    Where-Object { [int](Get-OptionalPropertyValue -InputObject $_ -PropertyName 'pageOrdinal' -Default 0) -ge $StartPageOrdinal }
)
if ($allCandidateUnits.Count -eq 0) {
  throw "No corpus pages are available at or after page ordinal $StartPageOrdinal."
}

$selectedUnits = @($allCandidateUnits)
if ($PSBoundParameters.ContainsKey('MaxPages')) {
  $selectedUnits = @($selectedUnits | Select-Object -First $MaxPages)
}

$hasMorePages = $selectedUnits.Count -lt $allCandidateUnits.Count
$nextUnit = if ($hasMorePages) { $allCandidateUnits[$selectedUnits.Count] } else { $null }

$pageInventory = New-Object System.Collections.Generic.List[object]
$targetInventory = New-Object System.Collections.Generic.List[object]
$entrypointCounts = @{}
$finalStatusCounts = @{}
$graphStatusCounts = @{}
$completeTargetCount = 0
$incompleteTargetCount = 0
$degradedTargetCount = 0
$replayReadyTargetCount = 0
$unsuppressedTargetCount = 0
$totalPreviewImageCount = 0
$totalImageArtifactCount = 0
$totalComparisonArtifactCount = 0

foreach ($unit in $selectedUnits) {
  $pageOrdinal = [int](Get-OptionalPropertyValue -InputObject $unit -PropertyName 'pageOrdinal' -Default 0)
  $pageReceipt = Read-JsonReceipt -Path ([string](Get-OptionalPropertyValue -InputObject $unit -PropertyName 'pagePath' -Default '')) -BasePath $manifestRoot -ExpectedSchema 'comparevi-history/corpus-page@v1'
  $page = $pageReceipt.Json

  if ([string]$page.corpus.repository -ne [string]$manifest.corpus.repository -or [string]$page.corpus.ref -ne [string]$manifest.corpus.ref) {
    throw "Corpus page '$($pageReceipt.Path)' does not match manifest repository/ref."
  }

  if ([int]$page.page.pageOrdinal -ne $pageOrdinal) {
    throw "Corpus page ordinal mismatch for '$($pageReceipt.Path)'."
  }

  if ([int]$page.page.targetCount -ne [int](Get-OptionalPropertyValue -InputObject $unit -PropertyName 'targetCount' -Default -1)) {
    throw "Corpus page target count mismatch for '$($pageReceipt.Path)'."
  }

  $pageInventory.Add([pscustomobject]@{
      pageOrdinal        = $pageOrdinal
      unitId             = [string](Get-OptionalPropertyValue -InputObject $unit -PropertyName 'unitId' -Default '')
      relativePath       = ConvertTo-RelativePath -BasePath $manifestRoot -Path $pageReceipt.Path
      targetCount        = [int]$page.page.targetCount
      targetOrdinalStart = [int]$page.page.targetOrdinalStart
      targetOrdinalEnd   = [int]$page.page.targetOrdinalEnd
      continuationToken  = [string](Get-OptionalPropertyValue -InputObject $unit -PropertyName 'continuationToken' -Default '')
      status             = [string](Get-OptionalPropertyValue -InputObject $unit -PropertyName 'status' -Default '')
      isComplete         = [bool]$page.completeness.isComplete
      reason             = [string]$page.completeness.reason
    }) | Out-Null

  foreach ($target in @(ConvertTo-ObjectArray -Value $page.targets | Sort-Object { [int](Get-OptionalPropertyValue -InputObject $_ -PropertyName 'targetOrdinal' -Default 0) })) {
    $targetSummary = Get-OptionalPropertyValue -InputObject $target -PropertyName 'summary'
    $targetCompleteness = Get-OptionalPropertyValue -InputObject $target -PropertyName 'completeness'
    $targetTarget = Get-OptionalPropertyValue -InputObject $target -PropertyName 'target'

    $entrypoint = [string](Get-OptionalPropertyValue -InputObject $target -PropertyName 'entrypoint' -Default 'unknown')
    $finalStatus = [string](Get-OptionalPropertyValue -InputObject $targetCompleteness -PropertyName 'finalStatus' -Default '')
    $graphStatusRaw = Get-OptionalPropertyValue -InputObject $targetCompleteness -PropertyName 'graphStatus'
    $graphStatus = if ([string]::IsNullOrWhiteSpace([string]$graphStatusRaw)) { $null } else { [string]$graphStatusRaw }
    $replayStatus = [string](Get-OptionalPropertyValue -InputObject $targetCompleteness -PropertyName 'replayStatus' -Default '')
    $suppressionProfile = [string](Get-OptionalPropertyValue -InputObject $targetSummary -PropertyName 'suppressionProfile' -Default 'unknown')
    $previewImageCount = [int](Get-OptionalPropertyValue -InputObject $targetSummary -PropertyName 'previewImageCount' -Default 0)
    $imageArtifactCount = [int](Get-OptionalPropertyValue -InputObject $targetSummary -PropertyName 'imageArtifactCount' -Default 0)
    $comparisonArtifactCount = [int](Get-OptionalPropertyValue -InputObject $targetSummary -PropertyName 'comparisonArtifactCount' -Default 0)

    $isTargetComplete = Get-IsTargetComplete -FinalStatus $finalStatus -GraphStatus $graphStatus
    if ($isTargetComplete) {
      $completeTargetCount++
    } else {
      $incompleteTargetCount++
    }

    if ($finalStatus -ne 'succeeded') {
      $degradedTargetCount++
    }

    if ($replayStatus -eq 'ready') {
      $replayReadyTargetCount++
    }

    if ($suppressionProfile -eq 'unsuppressed') {
      $unsuppressedTargetCount++
    }

    $totalPreviewImageCount += $previewImageCount
    $totalImageArtifactCount += $imageArtifactCount
    $totalComparisonArtifactCount += $comparisonArtifactCount

    Add-Count -Map $entrypointCounts -Key $entrypoint
    Add-Count -Map $finalStatusCounts -Key $finalStatus
    Add-Count -Map $graphStatusCounts -Key $graphStatus

    $targetInventory.Add([pscustomobject]@{
        pageOrdinal              = $pageOrdinal
        targetOrdinal            = [int](Get-OptionalPropertyValue -InputObject $target -PropertyName 'targetOrdinal' -Default 0)
        targetKey                = [string](Get-OptionalPropertyValue -InputObject $target -PropertyName 'targetKey' -Default '')
        entrypoint               = $entrypoint
        path                     = [string](Get-OptionalPropertyValue -InputObject $targetTarget -PropertyName 'path' -Default '')
        selectedRef              = [string](Get-OptionalPropertyValue -InputObject $targetTarget -PropertyName 'selectedRef' -Default '')
        targetId                 = Get-OptionalPropertyValue -InputObject $targetTarget -PropertyName 'targetId'
        finalStatus              = $finalStatus
        graphStatus              = $graphStatus
        replayStatus             = $replayStatus
        suppressionProfile       = $suppressionProfile
        previewImageCount        = $previewImageCount
        imageArtifactCount       = $imageArtifactCount
        comparisonArtifactCount  = $comparisonArtifactCount
        continuityStatus         = [string](Get-OptionalPropertyValue -InputObject $targetCompleteness -PropertyName 'continuityStatus' -Default '')
        continuityBreakCount     = [int](Get-OptionalPropertyValue -InputObject $targetCompleteness -PropertyName 'continuityBreakCount' -Default 0)
        segmentCount             = [int](Get-OptionalPropertyValue -InputObject $targetCompleteness -PropertyName 'segmentCount' -Default 0)
      }) | Out-Null
  }
}

$requestedMaxPagesValue = if ($PSBoundParameters.ContainsKey('MaxPages')) { [int]$MaxPages } else { $null }
$nextPageOrdinal = if ($null -ne $nextUnit) { [int](Get-OptionalPropertyValue -InputObject $nextUnit -PropertyName 'pageOrdinal' -Default 0) } else { $null }
$nextContinuationToken = if ($null -ne $nextUnit) { [string](Get-OptionalPropertyValue -InputObject $nextUnit -PropertyName 'continuationToken' -Default '') } else { $null }
$selectionIsComplete = (-not $hasMorePages) -and ($incompleteTargetCount -eq 0)
$selectionReason = if ($hasMorePages) {
  'continuation-required'
} elseif ($incompleteTargetCount -gt 0) {
  'target-degradation-present'
} else {
  'all-targets-complete'
}

$manifestPathRelative = ConvertTo-RelativePath -BasePath $manifestRoot -Path $manifestReceipt.Path
$acceptedSchemas = [ordered]@{
  sharedEvidence = [string](Get-OptionalPropertyValue -InputObject $manifest.acceptedSchemas -PropertyName 'sharedEvidence' -Default '')
  evidenceGraph = [string](Get-OptionalPropertyValue -InputObject $manifest.acceptedSchemas -PropertyName 'evidenceGraph' -Default '')
  corpusPage = [string](Get-OptionalPropertyValue -InputObject $manifest.acceptedSchemas -PropertyName 'corpusPage' -Default '')
}
$availablePageCount = [int](Get-OptionalPropertyValue -InputObject $manifest.processingModel -PropertyName 'pageCount' -Default 0)
$availableTargetCount = [int](Get-OptionalPropertyValue -InputObject $manifest.processingModel -PropertyName 'targetCount' -Default 0)
$continuationMode = [string](Get-OptionalPropertyValue -InputObject $manifest.processingModel -PropertyName 'continuationMode' -Default '')
$pageInventoryArray = $pageInventory.ToArray()
$targetInventoryArray = $targetInventory.ToArray()
$entrypointCountMap = ConvertTo-OrderedCountMap -Map $entrypointCounts
$finalStatusCountMap = ConvertTo-OrderedCountMap -Map $finalStatusCounts
$graphStatusCountMap = ConvertTo-OrderedCountMap -Map $graphStatusCounts

$summaryObject = [ordered]@{
  schema = 'comparevi-history/downstream-processor-summary@v1'
  generatedAtUtc = [DateTime]::UtcNow.ToString('o')
  source = [ordered]@{
    manifestSchema = [string]$manifest.schema
    manifestPath = $manifestPathRelative
    acceptedSchemas = $acceptedSchemas
  }
  corpus = [ordered]@{
    repository = [string]$manifest.corpus.repository
    ref = [string]$manifest.corpus.ref
  }
  selection = [ordered]@{
    requestedStartPageOrdinal = $StartPageOrdinal
    requestedMaxPages = $requestedMaxPagesValue
    availablePageCount = $availablePageCount
    availableTargetCount = $availableTargetCount
    processedPageCount = $selectedUnits.Count
    processedTargetCount = $targetInventoryArray.Count
    continuationMode = $continuationMode
    hasMorePages = $hasMorePages
    nextPageOrdinal = $nextPageOrdinal
    nextContinuationToken = $nextContinuationToken
  }
  inventory = [ordered]@{
    pages = $pageInventoryArray
    targets = $targetInventoryArray
  }
  summary = [ordered]@{
    pageCount = $selectedUnits.Count
    targetCount = $targetInventoryArray.Count
    completeTargetCount = $completeTargetCount
    incompleteTargetCount = $incompleteTargetCount
    degradedTargetCount = $degradedTargetCount
    replayReadyTargetCount = $replayReadyTargetCount
    unsuppressedTargetCount = $unsuppressedTargetCount
    totalPreviewImageCount = $totalPreviewImageCount
    totalImageArtifactCount = $totalImageArtifactCount
    totalComparisonArtifactCount = $totalComparisonArtifactCount
    entrypointCounts = $entrypointCountMap
    finalStatusCounts = $finalStatusCountMap
    graphStatusCounts = $graphStatusCountMap
  }
  completeness = [ordered]@{
    isComplete = $selectionIsComplete
    reason = $selectionReason
  }
}

$summaryJson = $summaryObject | ConvertTo-Json -Depth 100
$summaryJson | Set-Content -LiteralPath $outputPathResolved -Encoding utf8

Write-ActionOutput -Key 'downstream-processor-summary-path' -Value $outputPathResolved
Write-ActionOutput -Key 'processed-page-count' -Value ([string]$selectedUnits.Count)
Write-ActionOutput -Key 'processed-target-count' -Value ([string]$targetInventory.Count)
Write-ActionOutput -Key 'next-page-ordinal' -Value $(if ($null -eq $nextPageOrdinal) { '' } else { [string]$nextPageOrdinal })
Write-ActionOutput -Key 'next-continuation-token' -Value $(if ($null -eq $nextContinuationToken) { '' } else { [string]$nextContinuationToken })
Write-ActionOutput -Key 'selection-complete' -Value ($selectionIsComplete.ToString().ToLowerInvariant())
Write-ActionOutput -Key 'selection-reason' -Value $selectionReason

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  @(
    '## comparevi-history downstream processor summary'
    ('- Corpus: `{0}@{1}`' -f [string]$manifest.corpus.repository, [string]$manifest.corpus.ref)
    ('- Manifest: `{0}`' -f (ConvertTo-RelativePath -BasePath $manifestRoot -Path $manifestReceipt.Path))
    ('- Processed pages: `{0}` of `{1}` available from ordinal `{2}`' -f $selectedUnits.Count, [int](Get-OptionalPropertyValue -InputObject $manifest.processingModel -PropertyName 'pageCount' -Default 0), $StartPageOrdinal)
    ('- Processed targets: `{0}` of `{1}` available' -f $targetInventory.Count, [int](Get-OptionalPropertyValue -InputObject $manifest.processingModel -PropertyName 'targetCount' -Default 0))
    ('- Completeness: `{0}` (`{1}`)' -f ($selectionIsComplete.ToString().ToLowerInvariant()), $selectionReason)
    ('- Unsuppressed targets: `{0}`' -f $unsuppressedTargetCount)
    ('- Preview images: `{0}`' -f $totalPreviewImageCount)
    ('- Next continuation token: `{0}`' -f $(if ([string]::IsNullOrWhiteSpace([string]$nextContinuationToken)) { 'none' } else { [string]$nextContinuationToken }))
  ) | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
}

$summaryJson
