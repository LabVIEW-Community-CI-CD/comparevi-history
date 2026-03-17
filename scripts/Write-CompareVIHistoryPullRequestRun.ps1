param(
  [Parameter(Mandatory = $true)]
  [string]$DiscoveryPath,
  [Parameter(Mandatory = $true)]
  [string]$ResultsDir,
  [string]$TargetRunsManifestPath,
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

$basePath = (Get-Location).Path
$discoveryPathResolved = Resolve-AbsolutePath -Path $DiscoveryPath -BasePath $basePath
$resultsDirResolved = Resolve-AbsolutePath -Path $ResultsDir -BasePath $basePath
$targetRunsManifestPathResolved = if ([string]::IsNullOrWhiteSpace($TargetRunsManifestPath)) { $null } else { Resolve-AbsolutePath -Path $TargetRunsManifestPath -BasePath $basePath }
$prRunPath = Join-Path $resultsDirResolved 'pr-run.json'
$publicCommentPath = Join-Path $resultsDirResolved 'pr-comment.md'
$publicStepSummaryPath = Join-Path $resultsDirResolved 'pr-step-summary.md'

if (-not (Test-Path -LiteralPath $discoveryPathResolved -PathType Leaf)) {
  throw "Discovery receipt not found: $discoveryPathResolved"
}

New-Item -ItemType Directory -Path $resultsDirResolved -Force | Out-Null

$discovery = Read-JsonFile -Path $discoveryPathResolved
if ([string]$discovery.schema -ne 'comparevi-history/changed-vi-discovery@v1') {
  throw "Unsupported discovery schema in '$discoveryPathResolved': $($discovery.schema)"
}

$targetManifest = $null
if ($null -ne $targetRunsManifestPathResolved -and (Test-Path -LiteralPath $targetRunsManifestPathResolved -PathType Leaf)) {
  $targetManifest = Read-JsonFile -Path $targetRunsManifestPathResolved
}

$discoveryStatus = [string]$discovery.summary.executionStatus
$discoveryReason = [string]$discovery.summary.executionReason
$changedViCount = [int]$discovery.summary.changedViCount
$matchedTargetCount = [int]$discovery.summary.matchedTargetCount

$targets = @()
$executedTargetCount = 0
$failedTargetCount = 0
$totalProcessed = 0
$totalDiffs = 0

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
}

$finalStatus = 'unknown'
$finalReason = 'unknown'
if ($discoveryStatus -ne 'ready') {
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
$commentLines.Add('## comparevi-history PR diagnostics') | Out-Null
$commentLines.Add('') | Out-Null
$commentLines.Add(('- Final status: `{0}`' -f $finalStatus)) | Out-Null
$commentLines.Add(('- Final reason: `{0}`' -f $finalReason)) | Out-Null
$commentLines.Add(('- Changed VIs: `{0}`' -f $changedViCount)) | Out-Null
$commentLines.Add(('- Matched catalog targets: `{0}`' -f $matchedTargetCount)) | Out-Null
$commentLines.Add(('- Executed targets: `{0}`' -f $executedTargetCount)) | Out-Null
$commentLines.Add(('- Failed targets: `{0}`' -f $failedTargetCount)) | Out-Null
$commentLines.Add(('- Total processed pairs: `{0}`' -f $totalProcessed)) | Out-Null
$commentLines.Add(('- Total diffs: `{0}`' -f $totalDiffs)) | Out-Null
$commentLines.Add('') | Out-Null

if (@($discovery.changedViFiles).Count -gt 0) {
  $commentLines.Add('### Changed VI files') | Out-Null
  foreach ($change in @($discovery.changedViFiles)) {
    $commentLines.Add(('- `{0}` ({1})' -f [string]$change.currentPath, [string]$change.status)) | Out-Null
  }
  $commentLines.Add('') | Out-Null
}

if (@($targets).Count -gt 0) {
  $commentLines.Add('### Target results') | Out-Null
  $commentLines.Add('') | Out-Null
  $commentLines.Add('| Target | Status | Reason |') | Out-Null
  $commentLines.Add('| --- | --- | --- |') | Out-Null
  foreach ($target in @($targets)) {
    $commentLines.Add(('| `{0}` | `{1}` | `{2}` |' -f [string]$target.targetPath, [string]$target.finalStatus, [string]$target.finalReason)) | Out-Null
  }
  $commentLines.Add('') | Out-Null
} else {
  $commentLines.Add('### Target results') | Out-Null
  $commentLines.Add('No per-target runs were produced for this pull request.') | Out-Null
  $commentLines.Add('') | Out-Null
}

$commentLines.Add('Artifacts in this run contain the discovery receipt, per-target public run receipts, shared evidence receipts, and reviewer-facing markdown/html surfaces.') | Out-Null
$commentBody = $commentLines -join "`n"
$commentBody | Set-Content -LiteralPath $publicCommentPath -Encoding utf8

$stepSummaryLines = New-Object System.Collections.Generic.List[string]
$stepSummaryLines.Add('## comparevi-history pull request run') | Out-Null
$stepSummaryLines.Add('') | Out-Null
$stepSummaryLines.Add(('- Final status: `{0}`' -f $finalStatus)) | Out-Null
$stepSummaryLines.Add(('- Final reason: `{0}`' -f $finalReason)) | Out-Null
$stepSummaryLines.Add(('- Discovery receipt: `{0}`' -f $discoveryPathResolved)) | Out-Null
$stepSummaryLines.Add(('- Aggregate receipt: `{0}`' -f $prRunPath)) | Out-Null
$stepSummaryLines.Add(('- Public comment body: `{0}`' -f $publicCommentPath)) | Out-Null
$stepSummaryLines.Add(('- Public step summary: `{0}`' -f $publicStepSummaryPath)) | Out-Null
if ($null -ne $targetManifest) {
  $stepSummaryLines.Add(('- Target runs manifest: `{0}`' -f $targetRunsManifestPathResolved)) | Out-Null
}
$stepSummaryLines.Add('') | Out-Null
$stepSummaryLines.Add($commentBody) | Out-Null
$stepSummaryContent = $stepSummaryLines -join "`n"
$stepSummaryContent | Set-Content -LiteralPath $publicStepSummaryPath -Encoding utf8

$receiptTargets = New-Object System.Collections.Generic.List[object]
foreach ($target in @($targets)) {
  $receiptTargets.Add([ordered]@{
      targetId = [string]$target.targetId
      targetPath = [string]$target.targetPath
      matchKind = Get-OptionalString -Value $target.matchKind
      finalStatus = [string]$target.finalStatus
      finalReason = [string]$target.finalReason
      publicRunPath = Get-OptionalString -Value $target.publicRunPath
      sharedEvidencePath = Get-OptionalString -Value $target.sharedEvidencePath
      totalProcessed = if ($null -eq $target.totalProcessed) { $null } else { [int]$target.totalProcessed }
      totalDiffs = if ($null -eq $target.totalDiffs) { $null } else { [int]$target.totalDiffs }
    }) | Out-Null
}

$receipt = [ordered]@{
  schema = 'comparevi-history/pr-run@v1'
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
  discovery = [ordered]@{
    schema = 'comparevi-history/changed-vi-discovery@v1'
    path = $discoveryPathResolved
    status = $discoveryStatus
    reason = $discoveryReason
    changedViCount = $changedViCount
    matchedTargetCount = $matchedTargetCount
  }
  outputs = [ordered]@{
    resultsDir = $resultsDirResolved
    prRunPath = $prRunPath
    publicCommentPath = $publicCommentPath
    publicStepSummaryPath = $publicStepSummaryPath
    targetRunsManifestPath = if ($null -eq $targetManifest) { $null } else { $targetRunsManifestPathResolved }
  }
  summary = [ordered]@{
    finalStatus = $finalStatus
    finalReason = $finalReason
    changedViCount = $changedViCount
    matchedTargetCount = $matchedTargetCount
    executedTargetCount = $executedTargetCount
    failedTargetCount = $failedTargetCount
    totalProcessed = $totalProcessed
    totalDiffs = $totalDiffs
  }
  targets = @($receiptTargets | ForEach-Object { $_ })
}

$receipt | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $prRunPath -Encoding utf8

Write-ActionOutput -Key 'pr-run-path' -Value $prRunPath
Write-ActionOutput -Key 'public-comment-path' -Value $publicCommentPath
Write-ActionOutput -Key 'public-step-summary-path' -Value $publicStepSummaryPath
Write-ActionOutput -Key 'results-dir' -Value $resultsDirResolved
Write-ActionOutput -Key 'final-status' -Value $finalStatus
Write-ActionOutput -Key 'final-reason' -Value $finalReason

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  $stepSummaryContent | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
}

$receipt | ConvertTo-Json -Depth 32
