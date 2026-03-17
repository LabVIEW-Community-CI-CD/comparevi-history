Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'Invoke-CompareVIHistoryPullRequestDiagnostics.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('comparevi-history-pr-diag-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
  $candidateRoot = Join-Path $tempRoot 'candidate'
  $trustedRoot = Join-Path $tempRoot 'trusted'
  $platformRoot = Join-Path $tempRoot 'platform'
  $toolingRoot = Join-Path $tempRoot 'tooling'
  $resultsDir = Join-Path $tempRoot 'results'
  foreach ($path in @($candidateRoot, $trustedRoot, $platformRoot, $toolingRoot, $resultsDir, (Join-Path $platformRoot 'scripts'), (Join-Path $toolingRoot 'tools'), (Join-Path $trustedRoot 'Tooling'))) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
  }

  'stub' | Set-Content -LiteralPath (Join-Path $trustedRoot 'Tooling/Invoke-CompareVIHistoryHostedNILinux.ps1') -Encoding utf8

  $targetSpecPath = Join-Path $trustedRoot '.github/comparevi-history-targets.json'
  New-Item -ItemType Directory -Path (Split-Path -Parent $targetSpecPath) -Force | Out-Null
  @'
{
  "schema": "comparevi-history/consumer-targets@v1",
  "targets": [
    {
      "id": "target-success",
      "path": "Tooling/deployment/VIP_Post-Install Custom Action.vi",
      "publicModes": ["attributes", "front-panel", "block-diagram"]
    },
    {
      "id": "target-fail",
      "path": "Tooling/deployment/VIP_Pre-Install Custom Action.vi",
      "publicModes": ["attributes", "front-panel", "block-diagram"]
    }
  ]
}
'@ | Set-Content -LiteralPath $targetSpecPath -Encoding utf8

  $discoveryPath = Join-Path $resultsDir 'changed-vi-discovery.json'
  @'
{
  "schema": "comparevi-history/changed-vi-discovery@v1",
  "generatedAtUtc": "2026-03-17T00:00:00Z",
  "repository": "LabVIEW-Community-CI-CD/labview-icon-editor-demo",
  "eventName": "pull_request",
  "targetCatalog": {
    "schema": "comparevi-history/consumer-targets@v1",
    "path": "placeholder"
  },
  "pullRequest": {
    "number": 22,
    "htmlUrl": null,
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
  "matchedTargets": [
    {
      "targetId": "target-success",
      "targetPath": "Tooling/deployment/VIP_Post-Install Custom Action.vi",
      "matchKind": "current-path",
      "currentPath": "Tooling/deployment/VIP_Post-Install Custom Action.vi",
      "previousPath": null,
      "changeStatus": "modified"
    },
    {
      "targetId": "target-fail",
      "targetPath": "Tooling/deployment/VIP_Pre-Install Custom Action.vi",
      "matchKind": "current-path",
      "currentPath": "Tooling/deployment/VIP_Pre-Install Custom Action.vi",
      "previousPath": null,
      "changeStatus": "modified"
    }
  ],
  "summary": {
    "executionStatus": "ready",
    "executionReason": "matched-targets",
    "changedViCount": 2,
    "matchedTargetCount": 2
  }
}
'@ | Set-Content -LiteralPath $discoveryPath -Encoding utf8

  @'
param(
  [string]$RepositoryRoot,
  [string]$TargetSpecPath,
  [string]$TargetId,
  [string]$StartRef,
  [string]$NoisePolicy,
  [string]$ResultsDir,
  [string]$ConsumerRepository,
  [string]$ConsumerRef,
  [string]$SourceBranchRef,
  [string]$ReviewerSurface,
  [string]$ReviewerPullRequestNumber,
  [string]$ReviewerIsFork,
  [string]$ContainerImage,
  [string]$GitHubOutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$targetPath = if ($TargetId -eq 'target-success') {
  'Tooling/deployment/VIP_Post-Install Custom Action.vi'
} else {
  'Tooling/deployment/VIP_Pre-Install Custom Action.vi'
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
    path = $targetPath
    requestedModes = @('attributes', 'front-panel', 'block-diagram')
    publicModes = @('attributes', 'front-panel', 'block-diagram')
  }
  history = [ordered]@{
    renderReport = $true
  }
  results = [ordered]@{
    resultsDir = $ResultsDir
    publicRunPath = (Join-Path $publicRoot 'public-run.json')
    publicCommentPath = (Join-Path $publicRoot 'comment.md')
    publicStepSummaryPath = (Join-Path $publicRoot 'step-summary.md')
  }
} | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $requestPath -Encoding utf8
"target-path=$targetPath" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
"request-path=$requestPath" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
"results-dir=$ResultsDir" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
"requested-mode-list=attributes,front-panel,block-diagram" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
"source-branch-ref=$SourceBranchRef" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
'@ | Set-Content -LiteralPath (Join-Path $platformRoot 'scripts/Resolve-CompareVIHistoryRequest.ps1') -Encoding utf8

  @'
param(
  [string]$RepositoryRoot,
  [string]$ToolingRoot,
  [string]$TargetPath,
  [string]$ResultsDir,
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
"requested-mode-list=attributes,front-panel,block-diagram" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
"executed-mode-list=attributes,front-panel,block-diagram" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
"mode-count=3" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
"stop-reason=completed" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
if ($TargetPath -like '*Pre-Install*') {
  "total-processed=0" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
  "total-diffs=0" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
  throw 'simulated failure'
}
"total-processed=5" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
"total-diffs=2" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
'@ | Set-Content -LiteralPath (Join-Path $platformRoot 'scripts/Invoke-CompareVIHistoryFacade.ps1') -Encoding utf8

  @'
param(
  [string]$RequestedModeList,
  [string]$ExecutedModeList,
  [string]$TotalProcessed,
  [string]$TotalDiffs,
  [string]$StopReason,
  [string]$JsonOutputPath,
  [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

@"
{
  ""schema"": ""comparevi-history/mode-summary@v1"",
  ""requestedModes"": [""attributes"", ""front-panel"", ""block-diagram""],
  ""executedModes"": [""attributes"", ""front-panel"", ""block-diagram""],
  ""totalProcessed"": $TotalProcessed,
  ""totalDiffs"": $TotalDiffs,
  ""stopReason"": ""$StopReason"",
  ""categoryCounts"": {},
  ""comparisonPairs"": [],
  ""bucketCounts"": {},
  ""previewImages"": [],
  ""metadata"": {
    ""comparisonArtifactCount"": 0,
    ""captureCount"": 0,
    ""imageArtifactCount"": 0,
    ""imageMimeTypes"": []
  }
}
"@ | Set-Content -LiteralPath $JsonOutputPath -Encoding utf8
'mode summary' | Set-Content -LiteralPath $OutputPath -Encoding utf8
'@ | Set-Content -LiteralPath (Join-Path $platformRoot 'scripts/Format-CompareVIHistoryModeSummary.ps1') -Encoding utf8

  @'
param(
  [string]$RequestPath,
  [string]$ToolingRoot,
  [string]$CompareviRepository,
  [string]$CompareviRef,
  [string]$ToolingSource,
  [string]$ActionRef,
  [string]$HistorySummaryJson,
  [string]$ManifestPath,
  [string]$ResultsDir,
  [string]$HistoryReportMd,
  [string]$HistoryReportHtml,
  [string]$ModeSummaryJsonPath,
  [string]$ModeSummaryPath,
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
  [string]$GitHubOutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$request = Get-Content -LiteralPath $RequestPath -Raw | ConvertFrom-Json -Depth 50
$publicRunPath = $request.results.publicRunPath
$sharedEvidencePath = Join-Path (Split-Path -Parent $publicRunPath) 'shared-evidence.json'
$commentPath = $request.results.publicCommentPath
$stepSummaryPath = $request.results.publicStepSummaryPath
$finalStatus = if ($RunOutcome -eq 'success') { 'succeeded' } else { 'failed' }
$finalReason = if ($RunOutcome -eq 'success') { 'completed' } else { 'facade-step-failed' }
[ordered]@{
  schema = 'comparevi-history/public-run@v1'
  target = [ordered]@{
    id = [string]$request.target.id
    path = [string]$request.target.path
  }
  summary = [ordered]@{
    totalProcessed = [int]$TotalProcessed
    totalDiffs = [int]$TotalDiffs
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

  $outputPath = Join-Path $tempRoot 'pr-diag.out'
  $manifestJson = & $scriptPath `
    -CandidateRepositoryRoot $candidateRoot `
    -TrustedRepositoryRoot $trustedRoot `
    -DiscoveryPath $discoveryPath `
    -TargetSpecPath $targetSpecPath `
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
  if ($manifest.summary.executionStatus -ne 'failed') {
    throw 'Expected one simulated target failure.'
  }
  if ($manifest.summary.failedTargetCount -ne 1) {
    throw 'Failed target count mismatch.'
  }
  if ($manifest.summary.executedTargetCount -ne 2) {
    throw 'Executed target count mismatch.'
  }
  if (-not ($manifest.targets | Where-Object { $_.targetId -eq 'target-success' -and $_.finalStatus -eq 'succeeded' })) {
    throw 'Successful target was not recorded.'
  }
  if (-not ($manifest.targets | Where-Object { $_.targetId -eq 'target-fail' -and $_.finalStatus -eq 'failed' })) {
    throw 'Failed target was not recorded.'
  }

  $outputText = Get-Content -LiteralPath $outputPath -Raw
  foreach ($requiredKey in @('target-runs-manifest-path=', 'execution-status=failed', 'failed-target-count=1', 'executed-target-count=2')) {
    if ($outputText -notmatch [regex]::Escape($requiredKey)) {
      throw "Expected GitHub output '$requiredKey'."
    }
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
