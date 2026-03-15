param(
  [Parameter(Mandatory = $true)]
  [string]$RequestPath,
  [Parameter(Mandatory = $true)]
  [string]$ToolingRoot,
  [Parameter(Mandatory = $true)]
  [string]$CompareviRepository,
  [Parameter(Mandatory = $true)]
  [string]$CompareviRef,
  [Parameter(Mandatory = $true)]
  [string]$ToolingSource,
  [string]$ActionRef,
  [string]$HistorySummaryJson,
  [string]$ManifestPath,
  [string]$ResultsDir,
  [string]$HistoryReportMd,
  [string]$HistoryReportHtml,
  [string]$RequestedModeList,
  [string]$ExecutedModeList,
  [string]$ModeSummaryMarkdown,
  [string]$ModeCount,
  [string]$TotalProcessed,
  [string]$TotalDiffs,
  [string]$StopReason,
  [string]$RunOutcome,
  [string]$RunConclusion,
  [string]$RunUrl,
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

function Resolve-ExistingPath {
  param(
    [AllowNull()]
    [AllowEmptyString()]
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

  return @($modes.ToArray())
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

function Get-OptionalInt {
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

  return [int]$stringValue
}

function Resolve-RendererScriptPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ToolingRootPath
  )

  $metadataPath = Join-Path $ToolingRootPath 'comparevi-tools-release.json'
  if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
    $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json -Depth 32
    $rendererRelativePath = Get-OptionalString -Value $metadata.consumerContract.diagnosticsCommentRenderer.entryScriptPath
    if (-not [string]::IsNullOrWhiteSpace($rendererRelativePath)) {
      $resolvedRenderer = Join-Path $ToolingRootPath $rendererRelativePath
      if (Test-Path -LiteralPath $resolvedRenderer -PathType Leaf) {
        return [pscustomobject]@{
          RelativePath = $rendererRelativePath
          ResolvedPath = $resolvedRenderer
        }
      }
    }
  }

  $fallbackRelativePath = 'tools/New-CompareVIHistoryDiagnosticsBody.ps1'
  $fallbackResolvedPath = Join-Path $ToolingRootPath $fallbackRelativePath
  if (Test-Path -LiteralPath $fallbackResolvedPath -PathType Leaf) {
    return [pscustomobject]@{
      RelativePath = $fallbackRelativePath
      ResolvedPath = $fallbackResolvedPath
    }
  }

  return $null
}

$requestPathResolved = Resolve-AbsolutePath -Path $RequestPath -BasePath (Get-Location).Path
if (-not (Test-Path -LiteralPath $requestPathResolved -PathType Leaf)) {
  throw "Request receipt not found: $requestPathResolved"
}

$request = Get-Content -LiteralPath $requestPathResolved -Raw | ConvertFrom-Json -Depth 32
if ([string]$request.schema -ne 'comparevi-history/request@v1') {
  throw "Unsupported comparevi-history request schema in '$requestPathResolved': $($request.schema)"
}

$repositoryRoot = [string]$request.consumer.repositoryRoot
$resultsDirResolved = Resolve-ExistingPath -Path $(if ([string]::IsNullOrWhiteSpace($ResultsDir)) { [string]$request.results.resultsDir } else { $ResultsDir }) -BasePath $repositoryRoot -PathType Container
$toolingRootResolved = Resolve-AbsolutePath -Path $ToolingRoot -BasePath (Get-Location).Path
if (-not (Test-Path -LiteralPath $toolingRootResolved -PathType Container)) {
  throw "Tooling root not found: $toolingRootResolved"
}

$publicRunPathResolved = Resolve-AbsolutePath -Path ([string]$request.results.publicRunPath) -BasePath $repositoryRoot
$publicCommentPathResolved = Resolve-AbsolutePath -Path ([string]$request.results.publicCommentPath) -BasePath $repositoryRoot
$publicStepSummaryPathResolved = Resolve-AbsolutePath -Path ([string]$request.results.publicStepSummaryPath) -BasePath $repositoryRoot
foreach ($path in @($publicRunPathResolved, $publicCommentPathResolved, $publicStepSummaryPathResolved)) {
  $directory = Split-Path -Parent $path
  if (-not [string]::IsNullOrWhiteSpace($directory)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
  }
}

$historySummaryResolved = Resolve-ExistingPath -Path $HistorySummaryJson -BasePath $repositoryRoot -PathType Leaf
if ($null -eq $historySummaryResolved -and $null -ne $resultsDirResolved) {
  $candidateSummaryPath = Join-Path $resultsDirResolved 'history-summary.json'
  if (Test-Path -LiteralPath $candidateSummaryPath -PathType Leaf) {
    $historySummaryResolved = $candidateSummaryPath
  }
}
$manifestPathResolved = Resolve-ExistingPath -Path $ManifestPath -BasePath $repositoryRoot -PathType Leaf
$historyReportMdResolved = Resolve-ExistingPath -Path $HistoryReportMd -BasePath $repositoryRoot -PathType Leaf
$historyReportHtmlResolved = Resolve-ExistingPath -Path $HistoryReportHtml -BasePath $repositoryRoot -PathType Leaf

$requestedModes = if (-not [string]::IsNullOrWhiteSpace($RequestedModeList)) {
  @(ConvertTo-NormalizedModeList -Value $RequestedModeList)
} else {
  @($request.target.requestedModes | ForEach-Object { [string]$_ })
}
$executedModes = if (-not [string]::IsNullOrWhiteSpace($ExecutedModeList)) {
  @(ConvertTo-NormalizedModeList -Value $ExecutedModeList)
} else {
  @($requestedModes)
}

$effectiveOutcome = Get-OptionalString -Value $RunOutcome
if ([string]::IsNullOrWhiteSpace($effectiveOutcome)) {
  $effectiveOutcome = Get-OptionalString -Value $RunConclusion
}
$finalStatus = switch ($effectiveOutcome) {
  'success' { 'succeeded' }
  'failure' { 'failed' }
  'cancelled' { 'cancelled' }
  default { if ([string]::IsNullOrWhiteSpace($effectiveOutcome)) { 'unknown' } else { $effectiveOutcome } }
}
$finalReason = if (-not [string]::IsNullOrWhiteSpace($StopReason)) {
  $StopReason.Trim()
} elseif ($finalStatus -eq 'failed') {
  'facade-step-failed'
} elseif ($finalStatus -eq 'cancelled') {
  'facade-step-cancelled'
} else {
  'completed'
}

if ($finalStatus -eq 'succeeded' -and $null -eq $historySummaryResolved) {
  throw 'comparevi-history public run succeeded but did not emit history-summary.json.'
}
if ($finalStatus -eq 'succeeded' -and [bool]$request.history.renderReport) {
  if ($null -eq $historyReportMdResolved) {
    throw 'comparevi-history public run succeeded but did not emit history-report.md.'
  }
  if ($null -eq $historyReportHtmlResolved) {
    throw 'comparevi-history public run succeeded but did not emit history-report.html.'
  }
}

$renderer = $null
$reviewerSurfaceKind = [string]$request.reviewerSurface.kind
if ($reviewerSurfaceKind -ne 'none') {
  $renderer = Resolve-RendererScriptPath -ToolingRootPath $toolingRootResolved
  if ($null -eq $renderer) {
    throw "comparevi-history reviewer rendering requires a bundled diagnostics renderer under tooling-path '$toolingRootResolved'."
  }
}

if ([string]::IsNullOrWhiteSpace($ModeSummaryMarkdown)) {
  $modeSummaryLines = @(
    ('Requested modes: `{0}`' -f $(if ($requestedModes.Count -gt 0) { $requestedModes -join ', ' } else { 'n/a' }))
    ('Executed modes: `{0}`' -f $(if ($executedModes.Count -gt 0) { $executedModes -join ', ' } else { 'n/a' }))
    ('Total processed: `{0}`' -f $(if ([string]::IsNullOrWhiteSpace($TotalProcessed)) { 'n/a' } else { $TotalProcessed }))
    ('Total diffs: `{0}`' -f $(if ([string]::IsNullOrWhiteSpace($TotalDiffs)) { 'n/a' } else { $TotalDiffs }))
  )
  $ModeSummaryMarkdown = $modeSummaryLines -join [Environment]::NewLine
}

$commentBody = $null
if ($reviewerSurfaceKind -ne 'none') {
  $actionRefValue = Get-OptionalString -Value $ActionRef
  $openingSentence = if ($finalStatus -eq 'failed') {
    if ($reviewerSurfaceKind -eq 'comment-gated') {
      "comparevi-history diagnostics failed for PR #$($request.reviewerSurface.issueNumber)."
    } else {
      "comparevi-history manual diagnostics failed for PR #$($request.reviewerSurface.pullRequestNumber)."
    }
  } else {
    $null
  }

  $commentBody = & $renderer.ResolvedPath `
    -Variant $reviewerSurfaceKind `
    -ActionRef $(if ([string]::IsNullOrWhiteSpace($actionRefValue)) { 'n/a' } else { $actionRefValue }) `
    -IssueNumber $(Get-OptionalString -Value $request.reviewerSurface.issueNumber) `
    -PullRequestNumber $(Get-OptionalString -Value $request.reviewerSurface.pullRequestNumber) `
    -TargetPath ([string]$request.target.path) `
    -ContainerImage $(Get-OptionalString -Value $request.reviewerSurface.containerImage) `
    -RequestedModes ($requestedModes -join ',') `
    -ExecutedModes ($executedModes -join ',') `
    -TotalProcessed $TotalProcessed `
    -TotalDiffs $TotalDiffs `
    -ResultsDir $(if ($null -eq $resultsDirResolved) { $null } else { $resultsDirResolved }) `
    -StepConclusion $finalStatus `
    -IsFork $(Get-OptionalString -Value $request.reviewerSurface.isFork) `
    -RunUrl $RunUrl `
    -ModeSummaryMarkdown $ModeSummaryMarkdown `
    -OpeningSentence $openingSentence
  $commentBody | Set-Content -LiteralPath $publicCommentPathResolved -Encoding utf8
}

$stepSummaryLines = New-Object System.Collections.Generic.List[string]
$stepSummaryLines.Add('## comparevi-history public diagnostics') | Out-Null
$stepSummaryLines.Add('') | Out-Null
$stepSummaryLines.Add(('- Final status: `{0}`' -f $finalStatus)) | Out-Null
$stepSummaryLines.Add(('- Final reason: `{0}`' -f $finalReason)) | Out-Null
$stepSummaryLines.Add(('- Request receipt: `{0}`' -f $requestPathResolved)) | Out-Null
$stepSummaryLines.Add(('- Public run receipt: `{0}`' -f $publicRunPathResolved)) | Out-Null
if ($commentBody) {
  $stepSummaryLines.Add(('- Public comment body: `{0}`' -f $publicCommentPathResolved)) | Out-Null
}
$stepSummaryLines.Add('') | Out-Null
if ($commentBody) {
  foreach ($line in @($commentBody -split "`r?`n")) {
    $stepSummaryLines.Add($line) | Out-Null
  }
} else {
  $stepSummaryLines.Add(('- Target path: `{0}`' -f ([string]$request.target.path))) | Out-Null
  $stepSummaryLines.Add(('- Requested modes: `{0}`' -f ($requestedModes -join ', '))) | Out-Null
  $stepSummaryLines.Add(('- Executed modes: `{0}`' -f ($executedModes -join ', '))) | Out-Null
  $stepSummaryLines.Add('') | Out-Null
  foreach ($line in @($ModeSummaryMarkdown -split "`r?`n")) {
    $stepSummaryLines.Add($line) | Out-Null
  }
}
$stepSummaryText = $stepSummaryLines -join [Environment]::NewLine
$stepSummaryText | Set-Content -LiteralPath $publicStepSummaryPathResolved -Encoding utf8

$replayStatus = if ($null -ne $historySummaryResolved) { 'ready' } else { 'not-available' }
$replayReason = if ($null -ne $historySummaryResolved) { 'history-summary-present' } else { 'history-summary-missing' }

$publicRun = [ordered]@{
  schema = 'comparevi-history/public-run@v1'
  generatedAtUtc = [DateTime]::UtcNow.ToString('o')
  requestPath = $requestPathResolved
  request = $request
  backend = [ordered]@{
    repository = $CompareviRepository
    ref = $CompareviRef
    toolingPath = $toolingRootResolved
    toolingSource = $ToolingSource
    historyFacadeSchema = 'comparevi-tools/history-facade@v1'
    historySummaryPath = if ($null -eq $historySummaryResolved) { $null } else { $historySummaryResolved }
    diagnosticsRendererPath = if ($null -eq $renderer) { $null } else { $renderer.RelativePath }
  }
  outputs = [ordered]@{
    resultsDir = if ($null -eq $resultsDirResolved) { $null } else { $resultsDirResolved }
    manifestPath = if ($null -eq $manifestPathResolved) { $null } else { $manifestPathResolved }
    historySummaryJson = if ($null -eq $historySummaryResolved) { $null } else { $historySummaryResolved }
    historyReportMd = if ($null -eq $historyReportMdResolved) { $null } else { $historyReportMdResolved }
    historyReportHtml = if ($null -eq $historyReportHtmlResolved) { $null } else { $historyReportHtmlResolved }
    publicCommentPath = if ($commentBody) { $publicCommentPathResolved } else { $null }
    publicStepSummaryPath = $publicStepSummaryPathResolved
  }
  summary = [ordered]@{
    modeCount = Get-OptionalInt -Value $ModeCount
    requestedModes = @($requestedModes)
    executedModes = @($executedModes)
    totalProcessed = Get-OptionalInt -Value $TotalProcessed
    totalDiffs = Get-OptionalInt -Value $TotalDiffs
    stopReason = Get-OptionalString -Value $StopReason
    finalStatus = $finalStatus
    finalReason = $finalReason
  }
  replay = [ordered]@{
    status = $replayStatus
    reason = $replayReason
  }
}
$publicRun | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $publicRunPathResolved -Encoding utf8

Write-ActionOutput -Key 'history-summary-json' -Value $(if ($null -eq $historySummaryResolved) { '' } else { $historySummaryResolved })
Write-ActionOutput -Key 'public-run-path' -Value $publicRunPathResolved
Write-ActionOutput -Key 'public-comment-path' -Value $(if ($commentBody) { $publicCommentPathResolved } else { '' })
Write-ActionOutput -Key 'public-step-summary-path' -Value $publicStepSummaryPathResolved
Write-ActionOutput -Key 'final-status' -Value $finalStatus
Write-ActionOutput -Key 'final-reason' -Value $finalReason

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  @(
    '## comparevi-history public run'
    ''
    ('- Final status: `{0}`' -f $finalStatus)
    ('- Final reason: `{0}`' -f $finalReason)
    ('- Public run receipt: `{0}`' -f $publicRunPathResolved)
    ('- Public step summary: `{0}`' -f $publicStepSummaryPathResolved)
    ('- Public comment body: `{0}`' -f $(if ($commentBody) { $publicCommentPathResolved } else { 'n/a' }))
  ) | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
}

$publicRun | ConvertTo-Json -Depth 20
