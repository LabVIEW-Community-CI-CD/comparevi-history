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

$policy = Get-NestedValue -Object $discovery -Path @('prPolicy')
$emitCommentBody = [bool](Get-NestedValue -Object $policy -Path @('reviewerSurface', 'emitCommentBody') -Default $true)
$emitStepSummary = [bool](Get-NestedValue -Object $policy -Path @('reviewerSurface', 'emitStepSummary') -Default $true)
$policyPath = Get-OptionalString -Value (Get-NestedValue -Object $policy -Path @('path'))
$policyApplied = [bool](Get-NestedValue -Object $policy -Path @('applied') -Default $false)

$discoveryStatus = [string]$discovery.summary.executionStatus
$discoveryReason = [string]$discovery.summary.executionReason
$changedViCount = [int]$discovery.summary.changedViCount
$eligibleChangedViCount = if ($null -eq $discovery.summary.eligibleChangedViCount) { $changedViCount } else { [int]$discovery.summary.eligibleChangedViCount }
$excludedViCount = if ($null -eq $discovery.summary.excludedViCount) { 0 } else { [int]$discovery.summary.excludedViCount }
$unmatchedViCount = if ($null -eq $discovery.summary.unmatchedViCount) { 0 } else { [int]$discovery.summary.unmatchedViCount }
$matchedTargetCount = [int]$discovery.summary.matchedTargetCount
$excludedViFiles = @($discovery.excludedViFiles | ForEach-Object { $_ })

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
$commentLines.Add(('- PR policy: `{0}`' -f $(if ([string]::IsNullOrWhiteSpace($policyPath)) { 'platform defaults' } else { $policyPath }))) | Out-Null
$commentLines.Add(('- PR policy applied: `{0}`' -f $policyApplied.ToString().ToLowerInvariant())) | Out-Null
$commentLines.Add(('- Changed VIs: `{0}`' -f $changedViCount)) | Out-Null
$commentLines.Add(('- Policy-eligible changed VIs: `{0}`' -f $eligibleChangedViCount)) | Out-Null
$commentLines.Add(('- Excluded changed VIs: `{0}`' -f $excludedViCount)) | Out-Null
$commentLines.Add(('- Unmatched changed VIs: `{0}`' -f $unmatchedViCount)) | Out-Null
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

if (@($excludedViFiles).Count -gt 0) {
  $commentLines.Add('### Excluded VI files') | Out-Null
  foreach ($excluded in @($excludedViFiles)) {
    $commentLines.Add(('- `{0}` ({1}) reason=`{2}`' -f [string]$excluded.currentPath, [string]$excluded.status, [string]$excluded.exclusionReason)) | Out-Null
  }
  $commentLines.Add('') | Out-Null
}

if (@($targets).Count -gt 0) {
  $commentLines.Add('### Target results') | Out-Null
  $commentLines.Add('') | Out-Null
  $commentLines.Add('| Target | Requested modes | Status | Reason |') | Out-Null
  $commentLines.Add('| --- | --- | --- | --- |') | Out-Null
  foreach ($target in @($targets)) {
    $requestedModes = @(
      @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $target -Path @('requestedModes'))) |
        ForEach-Object { Get-OptionalString -Value $_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    $requestedModeLabel = if ($requestedModes.Count -eq 0) { 'n/a' } else { $requestedModes -join ', ' }
    $commentLines.Add(('| `{0}` | `{1}` | `{2}` | `{3}` |' -f [string]$target.targetPath, $requestedModeLabel, [string]$target.finalStatus, [string]$target.finalReason)) | Out-Null
  }
  $commentLines.Add('') | Out-Null
} else {
  $commentLines.Add('### Target results') | Out-Null
  $commentLines.Add('No per-target runs were produced for this pull request.') | Out-Null
  $commentLines.Add('') | Out-Null
}

$commentLines.Add('Artifacts in this run contain the discovery receipt, per-target public run receipts, shared evidence receipts, and reviewer-facing markdown/html surfaces.') | Out-Null
$commentBody = $commentLines -join "`n"
if ($emitCommentBody) {
  $commentBody | Set-Content -LiteralPath $publicCommentPath -Encoding utf8
}

$stepSummaryLines = New-Object System.Collections.Generic.List[string]
$stepSummaryLines.Add('## comparevi-history pull request run') | Out-Null
$stepSummaryLines.Add('') | Out-Null
$stepSummaryLines.Add(('- Final status: `{0}`' -f $finalStatus)) | Out-Null
$stepSummaryLines.Add(('- Final reason: `{0}`' -f $finalReason)) | Out-Null
$stepSummaryLines.Add(('- Discovery receipt: `{0}`' -f $discoveryPathResolved)) | Out-Null
$stepSummaryLines.Add(('- Aggregate receipt: `{0}`' -f $prRunPath)) | Out-Null
$stepSummaryLines.Add(('- Public comment body enabled: `{0}`' -f $emitCommentBody.ToString().ToLowerInvariant())) | Out-Null
$stepSummaryLines.Add(('- Public step summary enabled: `{0}`' -f $emitStepSummary.ToString().ToLowerInvariant())) | Out-Null
$stepSummaryLines.Add(('- Public comment body: `{0}`' -f $(if ($emitCommentBody) { $publicCommentPath } else { 'disabled-by-pr-policy' }))) | Out-Null
$stepSummaryLines.Add(('- Public step summary: `{0}`' -f $(if ($emitStepSummary) { $publicStepSummaryPath } else { 'disabled-by-pr-policy' }))) | Out-Null
if ($null -ne $targetManifest) {
  $stepSummaryLines.Add(('- Target runs manifest: `{0}`' -f $targetRunsManifestPathResolved)) | Out-Null
}
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
      targetPath = [string]$target.targetPath
      requestedModes = @(
        @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $target -Path @('requestedModes'))) |
          ForEach-Object { Get-OptionalString -Value $_ } |
          Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
      )
      requestedModeSource = Get-OptionalString -Value (Get-NestedValue -Object $target -Path @('requestedModeSource'))
      sourceBranchRef = Get-OptionalString -Value (Get-NestedValue -Object $target -Path @('sourceBranchRef'))
      maxBranchCommits = if ($null -eq (Get-NestedValue -Object $target -Path @('maxBranchCommits'))) { $null } else { [int](Get-NestedValue -Object $target -Path @('maxBranchCommits')) }
      keepArtifactsOnNoDiff = [bool](Get-NestedValue -Object $target -Path @('keepArtifactsOnNoDiff') -Default $false)
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
  prPolicy = $policy
  discovery = [ordered]@{
    schema = 'comparevi-history/changed-vi-discovery@v1'
    path = $discoveryPathResolved
    status = $discoveryStatus
    reason = $discoveryReason
    changedViCount = $changedViCount
    eligibleChangedViCount = $eligibleChangedViCount
    excludedViCount = $excludedViCount
    unmatchedViCount = $unmatchedViCount
    matchedTargetCount = $matchedTargetCount
  }
  outputs = [ordered]@{
    resultsDir = $resultsDirResolved
    prRunPath = $prRunPath
    publicCommentPath = if ($emitCommentBody) { $publicCommentPath } else { $null }
    publicStepSummaryPath = if ($emitStepSummary) { $publicStepSummaryPath } else { $null }
    targetRunsManifestPath = if ($null -eq $targetManifest) { $null } else { $targetRunsManifestPathResolved }
  }
  summary = [ordered]@{
    finalStatus = $finalStatus
    finalReason = $finalReason
    changedViCount = $changedViCount
    eligibleChangedViCount = $eligibleChangedViCount
    excludedViCount = $excludedViCount
    unmatchedViCount = $unmatchedViCount
    matchedTargetCount = $matchedTargetCount
    executedTargetCount = $executedTargetCount
    failedTargetCount = $failedTargetCount
    totalProcessed = $totalProcessed
    totalDiffs = $totalDiffs
  }
  excludedViFiles = @($excludedViFiles | ForEach-Object { $_ })
  targets = @($receiptTargets | ForEach-Object { $_ })
}

$receipt | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $prRunPath -Encoding utf8

Write-ActionOutput -Key 'pr-run-path' -Value $prRunPath
Write-ActionOutput -Key 'public-comment-path' -Value $(if ($emitCommentBody) { $publicCommentPath } else { '' })
Write-ActionOutput -Key 'public-step-summary-path' -Value $(if ($emitStepSummary) { $publicStepSummaryPath } else { '' })
Write-ActionOutput -Key 'results-dir' -Value $resultsDirResolved
Write-ActionOutput -Key 'final-status' -Value $finalStatus
Write-ActionOutput -Key 'final-reason' -Value $finalReason

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath) -and $emitStepSummary) {
  $stepSummaryContent | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
}

$receipt | ConvertTo-Json -Depth 32
