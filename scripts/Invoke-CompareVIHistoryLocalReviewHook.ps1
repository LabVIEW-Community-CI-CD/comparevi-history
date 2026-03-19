param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$ConsumerRepositoryRoot,
  [Parameter(Mandatory = $true, Position = 1)]
  [string]$TargetId,
  [Parameter(Mandatory = $true, Position = 2)]
  [string]$TargetPath,
  [Parameter(Position = 3)]
  [string]$SourceBranchRef,
  [Parameter(Mandatory = $true, Position = 4)]
  [string]$ConsumerRepository,
  [Parameter(Mandatory = $true, Position = 5)]
  [string]$ConsumerRef,
  [Parameter(Mandatory = $true, Position = 6)]
  [string]$RequestedModes,
  [Parameter(Position = 7)]
  [string]$RequestedModeSource = 'pr-policy',
  [Parameter(Position = 8)]
  [string]$TargetSource = 'dynamic-path',
  [Parameter(Position = 9)]
  [string]$CurrentPath,
  [Parameter(Position = 10)]
  [string]$PreviousPath,
  [Parameter(Position = 11)]
  [string]$ChangeStatus = 'modified',
  [Parameter(Position = 12)]
  [AllowNull()]$KeepArtifactsOnNoDiff = $false
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function ConvertTo-NormalizedModeList {
  param([Parameter(Mandatory = $true)][string]$Value)

  $modes = New-Object System.Collections.Generic.List[string]
  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($segment in @($Value -split '[,;]')) {
    $trimmed = Get-OptionalString -Value $segment
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
      continue
    }

    $normalized = $trimmed.ToLowerInvariant()
    if ($seen.Add($normalized)) {
      $modes.Add($normalized) | Out-Null
    }
  }

  if ($modes.Count -eq 0) {
    throw 'RequestedModes must resolve to at least one explicit public mode.'
  }

  return @($modes | ForEach-Object { $_ })
}

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][string]$Path)

  $raw = Get-Content -LiteralPath $Path -Raw
  if ([string]::IsNullOrWhiteSpace($raw)) {
    throw "JSON file was empty: $Path"
  }

  return $raw | ConvertFrom-Json -Depth 100
}

function Get-OptionalPropertyValue {
  param(
    [AllowNull()]$InputObject,
    [Parameter(Mandatory = $true)][string]$PropertyName,
    $Default = $null
  )

  if ($null -eq $InputObject) {
    return $Default
  }

  $property = $InputObject.PSObject.Properties[$PropertyName]
  if ($null -eq $property) {
    return $Default
  }

  return $property.Value
}

function Get-NestedValue {
  param(
    [AllowNull()]$Object,
    [Parameter(Mandatory = $true)][string[]]$Path,
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

function Resolve-FirstExistingFile {
  param([Parameter(Mandatory = $true)][string[]]$Candidates)

  foreach ($candidate in $Candidates) {
    if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
      return [System.IO.Path]::GetFullPath($candidate)
    }
  }

  return $null
}

function Get-OptionalInt {
  param([AllowNull()]$Value)

  if ($null -eq $Value) {
    return $null
  }

  $stringValue = [string]$Value
  if ([string]::IsNullOrWhiteSpace($stringValue)) {
    return $null
  }

  return [int]$stringValue
}

function ConvertTo-NormalizedBoolean {
  param(
    [AllowNull()]$Value,
    [bool]$Default = $false
  )

  if ($null -eq $Value) {
    return $Default
  }

  if ($Value -is [bool]) {
    return [bool]$Value
  }

  $stringValue = [string]$Value
  if ([string]::IsNullOrWhiteSpace($stringValue)) {
    return $Default
  }

  switch ($stringValue.Trim().ToLowerInvariant()) {
    'true' { return $true }
    'false' { return $false }
    '1' { return $true }
    '0' { return $false }
    'yes' { return $true }
    'no' { return $false }
    default { throw "Unsupported boolean value '$stringValue'." }
  }
}

function Get-HistoryMetric {
  param(
    [AllowNull()]$HistorySummary,
    [Parameter(Mandatory = $true)][string]$Name
  )

  foreach ($path in @(
      @('summary', $Name),
      @('totals', $Name),
      @($Name)
    )) {
    $value = Get-NestedValue -Object $HistorySummary -Path $path
    $intValue = Get-OptionalInt -Value $value
    if ($null -ne $intValue) {
      return $intValue
    }
  }

  return $null
}

$consumerRootResolved = Resolve-AbsolutePath -Path $ConsumerRepositoryRoot -BasePath (Get-Location).Path
$localRefinementReceiptPath = Get-OptionalString -Value $env:COMPAREVI_LOCAL_REFINEMENT_RECEIPT_PATH
if ([string]::IsNullOrWhiteSpace($localRefinementReceiptPath) -or -not (Test-Path -LiteralPath $localRefinementReceiptPath -PathType Leaf)) {
  throw 'COMPAREVI_LOCAL_REFINEMENT_RECEIPT_PATH must point to a valid comparevi/local-refinement@v1 receipt.'
}

$localRefinementReceipt = Read-JsonFile -Path $localRefinementReceiptPath
if ([string]$localRefinementReceipt.schema -ne 'comparevi/local-refinement@v1') {
  throw "Unsupported local refinement receipt schema in '$localRefinementReceiptPath': $($localRefinementReceipt.schema)"
}

$localRefinementResultsRoot = Get-OptionalString -Value $env:COMPAREVI_LOCAL_REFINEMENT_RESULTS_ROOT
if ([string]::IsNullOrWhiteSpace($localRefinementResultsRoot)) {
  $localRefinementResultsRoot = Get-OptionalString -Value $localRefinementReceipt.resultsRoot
}
if ([string]::IsNullOrWhiteSpace($localRefinementResultsRoot)) {
  throw 'Local review hook could not resolve the local refinement results root.'
}
$localRefinementResultsRoot = Resolve-AbsolutePath -Path $localRefinementResultsRoot -BasePath (Get-Location).Path

$reviewReceiptPath = Get-OptionalString -Value $env:COMPAREVI_REVIEW_RECEIPT_PATH
if ([string]::IsNullOrWhiteSpace($reviewReceiptPath)) {
  $reviewReceiptPath = Join-Path $localRefinementResultsRoot 'local-target-review.json'
} else {
  $reviewReceiptPath = Resolve-AbsolutePath -Path $reviewReceiptPath -BasePath (Get-Location).Path
}
$reviewReceiptParent = Split-Path -Parent $reviewReceiptPath
if (-not [string]::IsNullOrWhiteSpace($reviewReceiptParent)) {
  New-Item -ItemType Directory -Path $reviewReceiptParent -Force | Out-Null
}

$requestedModeList = ConvertTo-NormalizedModeList -Value $RequestedModes
$keepArtifactsOnNoDiffValue = ConvertTo-NormalizedBoolean -Value $KeepArtifactsOnNoDiff
$historyArtifactsRoot = $null
foreach ($candidateRoot in @(
    (Join-Path $localRefinementResultsRoot 'vi-history-report' 'results'),
    (Join-Path $localRefinementResultsRoot 'results'),
    $localRefinementResultsRoot
  )) {
  if (Test-Path -LiteralPath $candidateRoot -PathType Container) {
    $historyArtifactsRoot = [System.IO.Path]::GetFullPath($candidateRoot)
    break
  }
}

if ($null -eq $historyArtifactsRoot) {
  throw "Local review hook could not find history artifacts under '$localRefinementResultsRoot'."
}

$suiteManifestPath = Resolve-FirstExistingFile -Candidates @(
  (Join-Path $historyArtifactsRoot 'suite-manifest.json'),
  (Join-Path $historyArtifactsRoot 'manifest.json')
)
if ([string]::IsNullOrWhiteSpace($suiteManifestPath)) {
  throw "Local review hook could not find suite-manifest.json under '$historyArtifactsRoot'."
}

$historySummaryJsonPath = Resolve-FirstExistingFile -Candidates @(
  (Join-Path $historyArtifactsRoot 'history-summary.json')
)
$historyReportMdPath = Resolve-FirstExistingFile -Candidates @(
  (Join-Path $historyArtifactsRoot 'history-report.md')
)
$historyReportHtmlPath = Resolve-FirstExistingFile -Candidates @(
  (Join-Path $historyArtifactsRoot 'history-report.html')
)

$historySummary = $null
if (-not [string]::IsNullOrWhiteSpace($historySummaryJsonPath)) {
  try {
    $historySummary = Read-JsonFile -Path $historySummaryJsonPath
  } catch {
    $historySummary = $null
  }
}

$suiteManifest = Read-JsonFile -Path $suiteManifestPath
$modeCount = $requestedModeList.Count
$totalProcessed = Get-HistoryMetric -HistorySummary $historySummary -Name 'totalProcessed'
$totalDiffs = Get-HistoryMetric -HistorySummary $historySummary -Name 'totalDiffs'
if ($null -eq $totalProcessed -or $null -eq $totalDiffs) {
  $firstModeEntry = @(Get-NestedValue -Object $suiteManifest -Path @('modes') -Default @()) | Select-Object -First 1
  $firstModeManifestPath = if ($null -eq $firstModeEntry) { $null } else { Get-OptionalString -Value $firstModeEntry.manifestPath }
  if (-not [string]::IsNullOrWhiteSpace($firstModeManifestPath)) {
    $firstModeManifestPath = Resolve-AbsolutePath -Path $firstModeManifestPath -BasePath (Split-Path -Parent $suiteManifestPath)
    if (Test-Path -LiteralPath $firstModeManifestPath -PathType Leaf) {
      $firstModeManifest = Read-JsonFile -Path $firstModeManifestPath
      $comparisonCount = @($firstModeManifest.comparisons).Count
      if ($null -eq $totalProcessed) {
        $totalProcessed = $comparisonCount
      }
      if ($null -eq $totalDiffs) {
        $totalDiffs = $comparisonCount
      }
    }
  }
}

$finalStatus = Get-OptionalString -Value $localRefinementReceipt.finalStatus
if ([string]::IsNullOrWhiteSpace($finalStatus)) {
  $finalStatus = 'succeeded'
}
$finalReason = if ($finalStatus -eq 'succeeded') { 'completed' } else { 'local-refinement-failed' }

$publicRoot = Join-Path $localRefinementResultsRoot 'public'
New-Item -ItemType Directory -Path $publicRoot -Force | Out-Null
$requestPath = Join-Path $publicRoot 'request.json'
$publicRunPath = Join-Path $publicRoot 'public-run.json'
$publicCommentPath = Join-Path $publicRoot 'comment.md'
$publicStepSummaryPath = Join-Path $publicRoot 'step-summary.md'
$operatorSessionPath = Get-OptionalString -Value $env:COMPAREVI_LOCAL_OPERATOR_SESSION_PATH

$request = [ordered]@{
  schema = 'comparevi-history/request@v1'
  generatedAtUtc = [DateTime]::UtcNow.ToString('o')
  consumer = [ordered]@{
    repository = $ConsumerRepository
    ref = $ConsumerRef
    repositoryRoot = $consumerRootResolved
  }
  targetSpec = $null
  target = [ordered]@{
    id = $TargetId
    path = $TargetPath
    requestedModes = @($requestedModeList)
    publicModes = @($requestedModeList)
  }
  history = [ordered]@{
    startRef = $ConsumerRef
    endRef = $null
    sourceBranchRef = $SourceBranchRef
    maxBranchCommits = $null
    maxPairs = $null
    maxSignalPairs = $null
    noisePolicy = 'include'
    resultsDir = $historyArtifactsRoot
    renderReport = $true
    reportFormat = 'html'
    failFast = $false
    failOnDiff = $false
    quiet = $false
    detailed = $true
    keepArtifactsOnNoDiff = $keepArtifactsOnNoDiffValue
    includeMergeParents = $false
    compareTimeoutSeconds = $null
  }
  reviewerSurface = [ordered]@{
    kind = 'none'
    issueNumber = $null
    pullRequestNumber = $null
    isFork = $null
    containerImage = Get-OptionalString -Value $env:COMPAREVI_LOCAL_REFINEMENT_IMAGE
  }
  results = [ordered]@{
    resultsDir = $historyArtifactsRoot
    publicRoot = $publicRoot
    requestPath = $requestPath
    publicRunPath = $publicRunPath
    publicCommentPath = $publicCommentPath
    publicStepSummaryPath = $publicStepSummaryPath
  }
}
$request | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $requestPath -Encoding utf8

$publicRun = [ordered]@{
  schema = 'comparevi-history/public-run@v1'
  generatedAtUtc = [DateTime]::UtcNow.ToString('o')
  requestPath = $requestPath
  request = $request
  backend = [ordered]@{
    repository = $null
    ref = $null
    toolingPath = $null
    toolingSource = Get-OptionalString -Value $env:COMPAREVI_LOCAL_REFINEMENT_TOOL_SOURCE
    historyFacadeSchema = 'comparevi-tools/history-facade@v1'
    localRefinementSchema = [string]$localRefinementReceipt.schema
    localOperatorSessionPath = $operatorSessionPath
    historySummaryPath = $historySummaryJsonPath
    diagnosticsRendererPath = $null
  }
  outputs = [ordered]@{
    resultsDir = $historyArtifactsRoot
    manifestPath = $suiteManifestPath
    historySummaryJson = $historySummaryJsonPath
    historyReportMd = $historyReportMdPath
    historyReportHtml = $historyReportHtmlPath
    modeSummaryPath = $null
    modeSummaryJsonPath = $null
    publicCommentPath = $null
    publicStepSummaryPath = $null
  }
  summary = [ordered]@{
    modeCount = $modeCount
    requestedModes = @($requestedModeList)
    executedModes = @($requestedModeList)
    totalProcessed = $totalProcessed
    totalDiffs = $totalDiffs
    stopReason = 'completed'
    finalStatus = $finalStatus
    finalReason = $finalReason
  }
  replay = [ordered]@{
    status = if ($null -ne $historySummary) { 'ready' } else { 'not-available' }
    reason = if ($null -ne $historySummary) { 'history-summary-present' } else { 'history-summary-missing' }
  }
}
$publicRun | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $publicRunPath -Encoding utf8

$reviewReceipt = [ordered]@{
  schema = 'comparevi-history/local-target-review@v1'
  generatedAtUtc = [DateTime]::UtcNow.ToString('o')
  target = [ordered]@{
    targetId = $TargetId
    targetSource = $TargetSource
    targetPath = $TargetPath
    requestedModes = @($requestedModeList)
    requestedModeSource = $RequestedModeSource
    sourceBranchRef = $SourceBranchRef
    keepArtifactsOnNoDiff = $keepArtifactsOnNoDiffValue
    currentPath = Get-OptionalString -Value $CurrentPath
    previousPath = Get-OptionalString -Value $PreviousPath
    changeStatus = $ChangeStatus
  }
  runtime = [ordered]@{
    profile = Get-OptionalString -Value $env:COMPAREVI_RUNTIME_PROFILE
    image = Get-OptionalString -Value $env:COMPAREVI_LOCAL_REFINEMENT_IMAGE
    toolSource = Get-OptionalString -Value $env:COMPAREVI_LOCAL_REFINEMENT_TOOL_SOURCE
    localRefinementReceiptPath = $localRefinementReceiptPath
    localRefinementResultsRoot = $localRefinementResultsRoot
    operatorSessionPath = $operatorSessionPath
  }
  projections = [ordered]@{
    requestPath = $requestPath
    publicRunPath = $publicRunPath
    sharedEvidencePath = $null
    historySummaryJsonPath = $historySummaryJsonPath
    manifestPath = $suiteManifestPath
    historyReportMdPath = $historyReportMdPath
    historyReportHtmlPath = $historyReportHtmlPath
    modeSummaryJsonPath = $null
    modeSummaryPath = $null
  }
  summary = [ordered]@{
    modeCount = $modeCount
    totalProcessed = $totalProcessed
    totalDiffs = $totalDiffs
    finalStatus = $finalStatus
    finalReason = $finalReason
  }
}
$reviewReceipt | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $reviewReceiptPath -Encoding utf8
