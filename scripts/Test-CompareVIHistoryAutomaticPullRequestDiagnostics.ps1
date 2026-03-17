Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'Invoke-CompareVIHistoryAutomaticPullRequestDiagnostics.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('comparevi-history-auto-pr-diag-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
  $candidateRoot = Join-Path $tempRoot 'candidate'
  $trustedRoot = Join-Path $tempRoot 'trusted'
  $platformRoot = Join-Path $tempRoot 'platform'
  $toolingRoot = Join-Path $tempRoot 'tooling'
  $resultsDir = Join-Path $tempRoot 'results'
  foreach ($path in @(
      $candidateRoot,
      $trustedRoot,
      $platformRoot,
      $toolingRoot,
      $resultsDir,
      (Join-Path $platformRoot 'scripts'),
      (Join-Path $toolingRoot 'tools'),
      (Join-Path $trustedRoot 'Tooling')
    )) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
  }

  'stub invoke adapter' | Set-Content -LiteralPath (Join-Path $trustedRoot 'Tooling/Invoke-CompareVIHistoryHostedNILinux.ps1') -Encoding utf8

  $discoveryPath = Join-Path $resultsDir 'changed-vi-discovery.json'
  @"
{
  "schema": "comparevi-history/changed-vi-discovery@v2",
  "generatedAtUtc": "2026-03-17T00:00:00Z",
  "repository": "LabVIEW-Community-CI-CD/labview-icon-editor-demo",
  "eventName": "pull_request",
  "prPolicy": {
    "schema": "comparevi-history/pr-policy@v2",
    "path": "C:/repo/.github/comparevi-history-pr-policy.json",
    "applied": true,
    "discovery": {
      "selectionMode": "dynamic-paths",
      "includePaths": ["**/*.vi"],
      "excludePaths": [],
      "maxChangedViCount": 10,
      "overflowBehavior": "block"
    },
    "execution": {
      "publicModes": ["attributes", "front-panel", "block-diagram"],
      "noisePolicy": "include",
      "history": {
        "sourceBranchRefStrategy": "pull-request-base",
        "keepArtifactsOnNoDiff": true
      }
    },
    "reviewerSurface": {
      "emitCommentBody": true,
      "emitStepSummary": true,
      "fullSurface": "artifact-index"
    },
    "trust": {
      "forkBehavior": "hosted-auto"
    }
  },
  "executionContext": {
    "selectionMode": "dynamic-paths",
    "forkBehavior": "hosted-auto",
    "fullSurface": "artifact-index"
  },
  "pullRequest": {
    "number": 22,
    "htmlUrl": "https://github.com/example/repo/pull/22",
    "baseRepository": "LabVIEW-Community-CI-CD/labview-icon-editor-demo",
    "baseRef": "develop",
    "baseSha": "base-sha",
    "headRepository": "LabVIEW-Community-CI-CD/labview-icon-editor-demo",
    "headRef": "feature/history",
    "headSha": "head-sha",
    "isFork": false,
    "changedFileCount": 2
  },
  "changedViFiles": [
    {
      "status": "modified",
      "currentPath": "Tooling/deployment/VIP_Post-Install Custom Action.vi",
      "previousPath": null
    },
    {
      "status": "modified",
      "currentPath": "Tooling/deployment/VIP_Pre-Install Custom Action.vi",
      "previousPath": null
    }
  ],
  "excludedViFiles": [],
  "selectedTargets": [
    {
      "targetId": "dynamic-vip-post-install-custom-action-a1b2c3d4e5f6",
      "targetSource": "dynamic-path",
      "targetPath": "Tooling/deployment/VIP_Post-Install Custom Action.vi",
      "requestedModes": ["attributes", "front-panel", "block-diagram"],
      "requestedModeSource": "pr-policy",
      "history": {
        "branchBudget": {
          "sourceBranchRef": "develop",
          "maxCommitCount": null,
          "source": "pull-request-base"
        }
      },
      "keepArtifactsOnNoDiff": true,
      "currentPath": "Tooling/deployment/VIP_Post-Install Custom Action.vi",
      "previousPath": null,
      "changeStatus": "modified"
    },
    {
      "targetId": "dynamic-vip-pre-install-custom-action-0f1e2d3c4b5a",
      "targetSource": "dynamic-path",
      "targetPath": "Tooling/deployment/VIP_Pre-Install Custom Action.vi",
      "requestedModes": ["attributes", "front-panel", "block-diagram"],
      "requestedModeSource": "pr-policy",
      "history": {
        "branchBudget": {
          "sourceBranchRef": "develop",
          "maxCommitCount": null,
          "source": "pull-request-base"
        }
      },
      "keepArtifactsOnNoDiff": true,
      "currentPath": "Tooling/deployment/VIP_Pre-Install Custom Action.vi",
      "previousPath": null,
      "changeStatus": "modified"
    }
  ],
  "summary": {
    "selectionMode": "dynamic-paths",
    "executionStatus": "ready",
    "executionReason": "selected-targets",
    "changedViCount": 2,
    "eligibleChangedViCount": 2,
    "excludedViCount": 0,
    "selectedTargetCount": 2,
    "overflowBehavior": "block",
    "overflowed": false,
    "overflowChangedViCount": 0
  }
}
"@ | Set-Content -LiteralPath $discoveryPath -Encoding utf8

  @'
param(
  [string]$RepositoryRoot,
  [string]$TargetPath,
  [string]$TargetId,
  [string]$StartRef,
  [string]$NoisePolicy,
  [string]$Mode,
  [string]$ResultsDir,
  [string]$ConsumerRepository,
  [string]$ConsumerRef,
  [string]$SourceBranchRef,
  [switch]$KeepArtifactsOnNoDiff,
  [string]$ReviewerSurface,
  [string]$ReviewerPullRequestNumber,
  [string]$ReviewerIsFork,
  [string]$ContainerImage,
  [string]$GitHubOutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSBoundParameters.ContainsKey('MaxPairs')) {
  throw 'Automatic PR diagnostics should not pass MaxPairs in dynamic-path mode.'
}
if ($PSBoundParameters.ContainsKey('MaxSignalPairs')) {
  throw 'Automatic PR diagnostics should not pass MaxSignalPairs in dynamic-path mode.'
}
if ($PSBoundParameters.ContainsKey('MaxBranchCommits')) {
  throw 'Automatic PR diagnostics should not pass MaxBranchCommits in dynamic-path mode.'
}

$publicRoot = Join-Path $ResultsDir 'public'
New-Item -ItemType Directory -Path $publicRoot -Force | Out-Null
$requestPath = Join-Path $publicRoot 'request.json'
[ordered]@{
  schema = 'comparevi-history/request@v1'
  consumer = [ordered]@{
    repositoryRoot = $RepositoryRoot
    repository = $ConsumerRepository
    ref = $ConsumerRef
  }
  target = [ordered]@{
    id = $TargetId
    path = $TargetPath
    requestedModes = @($Mode -split ',')
    publicModes = @('attributes', 'front-panel', 'block-diagram')
  }
  history = [ordered]@{
    sourceBranchRef = $SourceBranchRef
    maxBranchCommits = $null
    keepArtifactsOnNoDiff = [bool]$KeepArtifactsOnNoDiff.IsPresent
  }
  reviewer = [ordered]@{
    surface = $ReviewerSurface
    pullRequestNumber = $ReviewerPullRequestNumber
    isFork = $ReviewerIsFork
  }
} | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $requestPath -Encoding utf8
"target-path=$TargetPath" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
"request-path=$requestPath" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
"results-dir=$ResultsDir" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
"requested-mode-list=$Mode" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
"source-branch-ref=$SourceBranchRef" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
'@ | Set-Content -LiteralPath (Join-Path $platformRoot 'scripts/Resolve-CompareVIHistoryRequest.ps1') -Encoding utf8

  @'
param(
  [string]$RepositoryRoot,
  [string]$ToolingRoot,
  [string]$TargetPath,
  [string]$ResultsDir,
  [string]$SourceBranchRef,
  [string]$Mode,
  [string]$GitHubOutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

New-Item -ItemType Directory -Path $ResultsDir -Force | Out-Null
$historySummaryPath = Join-Path $ResultsDir 'history-summary.json'
$manifestPath = Join-Path $ResultsDir 'manifest.json'
$reportMdPath = Join-Path $ResultsDir 'history-report.md'
$reportHtmlPath = Join-Path $ResultsDir 'history-report.html'
'{}' | Set-Content -LiteralPath $historySummaryPath -Encoding utf8
'{}' | Set-Content -LiteralPath $manifestPath -Encoding utf8
'# report' | Set-Content -LiteralPath $reportMdPath -Encoding utf8
'<html></html>' | Set-Content -LiteralPath $reportHtmlPath -Encoding utf8
"history-summary-json=$historySummaryPath" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
"manifest-path=$manifestPath" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
"results-dir=$ResultsDir" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
"history-report-md=$reportMdPath" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
"history-report-html=$reportHtmlPath" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
"requested-mode-list=$Mode" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
"executed-mode-list=$Mode" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
"mode-count=3" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
"stop-reason=completed" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
if ($TargetPath -like '*Pre-Install*') {
  "total-processed=0" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
  "total-diffs=0" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
  throw 'simulated target failure'
}
"total-processed=5" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
"total-diffs=2" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
'@ | Set-Content -LiteralPath (Join-Path $platformRoot 'scripts/Invoke-CompareVIHistoryFacade.ps1') -Encoding utf8

  @'
param(
  [string]$RequestedModeList,
  [string]$ExecutedModeList,
  [string]$JsonOutputPath,
  [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

@"
{
  "schema": "comparevi-history/mode-summary@v1",
  "requestedModes": ["attributes", "front-panel", "block-diagram"],
  "executedModes": ["attributes", "front-panel", "block-diagram"],
  "categoryCounts": {},
  "comparisonPairs": [],
  "bucketCounts": {},
  "previewImages": [],
  "metadata": {
    "comparisonArtifactCount": 0,
    "captureCount": 0,
    "imageArtifactCount": 0,
    "imageMimeTypes": []
  }
}
"@ | Set-Content -LiteralPath $JsonOutputPath -Encoding utf8
'mode summary' | Set-Content -LiteralPath $OutputPath -Encoding utf8
'@ | Set-Content -LiteralPath (Join-Path $platformRoot 'scripts/Format-CompareVIHistoryModeSummary.ps1') -Encoding utf8

  @'
param(
  [string]$RequestPath,
  [string]$ToolingRoot,
  [string]$HistorySummaryJson,
  [string]$ManifestPath,
  [string]$ResultsDir,
  [string]$HistoryReportMd,
  [string]$HistoryReportHtml,
  [string]$ModeSummaryJsonPath,
  [string]$ModeSummaryPath,
  [string]$RunOutcome,
  [string]$GitHubOutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$request = Get-Content -LiteralPath $RequestPath -Raw | ConvertFrom-Json -Depth 50
$publicRunPath = Join-Path (Split-Path -Parent $RequestPath) 'public-run.json'
$sharedEvidencePath = Join-Path (Split-Path -Parent $RequestPath) 'shared-evidence.json'
$commentPath = Join-Path (Split-Path -Parent $RequestPath) 'comment.md'
$stepSummaryPath = Join-Path (Split-Path -Parent $RequestPath) 'step-summary.md'
$finalStatus = if ($RunOutcome -eq 'success') { 'succeeded' } else { 'failed' }
$finalReason = if ($RunOutcome -eq 'success') { 'completed' } else { 'facade-step-failed' }
[ordered]@{
  schema = 'comparevi-history/public-run@v1'
  target = [ordered]@{
    id = [string]$request.target.id
    path = [string]$request.target.path
  }
  summary = [ordered]@{
    totalProcessed = 5
    totalDiffs = 2
    finalStatus = $finalStatus
    finalReason = $finalReason
  }
  outputs = [ordered]@{
    publicCommentPath = $commentPath
    publicStepSummaryPath = $stepSummaryPath
  }
  evidence = [ordered]@{
    schema = 'comparevi-history/shared-evidence@v1'
    path = $sharedEvidencePath
  }
} | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $publicRunPath -Encoding utf8
[ordered]@{
  schema = 'comparevi-history/shared-evidence@v1'
  source = [ordered]@{
    schema = 'comparevi-history/public-run@v1'
  }
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $sharedEvidencePath -Encoding utf8
'comment' | Set-Content -LiteralPath $commentPath -Encoding utf8
'summary' | Set-Content -LiteralPath $stepSummaryPath -Encoding utf8
"public-run-path=$publicRunPath" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
"shared-evidence-path=$sharedEvidencePath" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
"public-comment-path=$commentPath" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
"public-step-summary-path=$stepSummaryPath" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
"final-status=$finalStatus" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
"final-reason=$finalReason" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
'@ | Set-Content -LiteralPath (Join-Path $platformRoot 'scripts/Write-CompareVIHistoryPublicRun.ps1') -Encoding utf8

  $outputPath = Join-Path $tempRoot 'auto-pr-diag.out'
  $manifestJson = & $scriptPath `
    -CandidateRepositoryRoot $candidateRoot `
    -TrustedRepositoryRoot $trustedRoot `
    -DiscoveryPath $discoveryPath `
    -ResultsDir $resultsDir `
    -HeadSha 'head-sha' `
    -HeadRef 'feature/history' `
    -HeadRepository 'LabVIEW-Community-CI-CD/labview-icon-editor-demo' `
    -PullRequestNumber '22' `
    -ReviewerIsFork 'false' `
    -ToolingRoot $toolingRoot `
    -PlatformRoot $platformRoot `
    -GitHubOutputPath $outputPath

  $manifest = $manifestJson | ConvertFrom-Json -Depth 100
  if ($manifest.schema -ne 'comparevi-history/pr-target-runs-manifest@v2') {
    throw 'Automatic PR diagnostics manifest schema mismatch.'
  }
  if ($manifest.summary.executionStatus -ne 'failed' -or $manifest.summary.executionReason -ne 'one-or-more-targets-failed') {
    throw 'Expected one simulated target failure.'
  }
  if ($manifest.summary.executedTargetCount -ne 2 -or $manifest.summary.failedTargetCount -ne 1) {
    throw 'Execution summary counts mismatch.'
  }

  $successTarget = @($manifest.targets | Where-Object { [string]$_.targetId -eq 'dynamic-vip-post-install-custom-action-a1b2c3d4e5f6' } | Select-Object -First 1)
  if ($null -eq $successTarget -or $successTarget.finalStatus -ne 'succeeded') {
    throw 'Successful dynamic target was not recorded.'
  }
  if ($successTarget.targetSource -ne 'dynamic-path') {
    throw 'Successful target should preserve targetSource=dynamic-path.'
  }
  if (($successTarget.requestedModes -join ',') -ne 'attributes,front-panel,block-diagram') {
    throw 'Requested mode list mismatch on the successful target.'
  }
  if ($successTarget.sourceBranchRef -ne 'develop') {
    throw 'sourceBranchRef did not flow from discovery into the execution manifest.'
  }
  if ($successTarget.keepArtifactsOnNoDiff -ne $true) {
    throw 'keepArtifactsOnNoDiff did not flow from discovery into the execution manifest.'
  }
  if ($successTarget.PSObject.Properties['maxBranchCommits']) {
    throw 'Dynamic-path execution manifest must not carry a maxBranchCommits property.'
  }

  $requestPath = [string]$successTarget.requestPath
  $request = Get-Content -LiteralPath $requestPath -Raw | ConvertFrom-Json -Depth 50
  if ([string]$request.target.id -ne 'dynamic-vip-post-install-custom-action-a1b2c3d4e5f6') {
    throw 'Dynamic TargetId was not preserved into the normalized request receipt.'
  }
  if ([string]$request.target.path -ne 'Tooling/deployment/VIP_Post-Install Custom Action.vi') {
    throw 'Dynamic target path mismatch in the normalized request receipt.'
  }
  if ($request.history.keepArtifactsOnNoDiff -ne $true -or [string]$request.history.sourceBranchRef -ne 'develop') {
    throw 'Normalized request history state mismatch.'
  }

  $failedTarget = @($manifest.targets | Where-Object { [string]$_.targetId -eq 'dynamic-vip-pre-install-custom-action-0f1e2d3c4b5a' } | Select-Object -First 1)
  if ($null -eq $failedTarget -or $failedTarget.finalStatus -ne 'failed' -or $failedTarget.finalReason -ne 'facade-step-failed') {
    throw 'Failed target was not recorded correctly.'
  }

  $outputText = Get-Content -LiteralPath $outputPath -Raw
  foreach ($requiredKey in @(
      'target-runs-manifest-path=',
      'tooling-source=provided-tooling-root',
      'executed-target-count=2',
      'failed-target-count=1',
      'execution-status=failed',
      'execution-reason=one-or-more-targets-failed'
    )) {
    if ($outputText -notmatch [regex]::Escape($requiredKey)) {
      throw "Expected GitHub output '$requiredKey'."
    }
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
