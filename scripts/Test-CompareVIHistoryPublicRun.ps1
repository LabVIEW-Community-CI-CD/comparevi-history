Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'Write-CompareVIHistoryPublicRun.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("comparevi-history-public-run-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
  $repoRoot = Join-Path $tempRoot 'consumer'
  $resultsRoot = Join-Path $repoRoot 'tests/results/ref-compare/history'
  $publicRoot = Join-Path $resultsRoot 'public'
  $toolingRoot = Join-Path $tempRoot 'tooling'
  New-Item -ItemType Directory -Path $resultsRoot -Force | Out-Null
  New-Item -ItemType Directory -Path $publicRoot -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $toolingRoot 'tools') -Force | Out-Null

$rendererScript = @'
param(
  [string]$Variant,
  [string]$ActionRef,
  [string]$IssueNumber,
  [string]$PullRequestNumber,
  [string]$TargetPath,
  [string]$ContainerImage,
  [string]$RequestedModes,
  [string]$ExecutedModes,
  [string]$TotalProcessed,
  [string]$TotalDiffs,
  [string]$ResultsDir,
  [string]$StepConclusion,
  [string]$IsFork,
  [string]$RunUrl,
  [string]$ModeSummaryMarkdown,
  [string]$OpeningSentence
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$label = if ($Variant -eq 'comment-gated') { $IssueNumber } else { $PullRequestNumber }
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add($(if ([string]::IsNullOrWhiteSpace($OpeningSentence)) { "comparevi-history diagnostics for $label" } else { $OpeningSentence })) | Out-Null
$lines.Add('') | Out-Null
$lines.Add("- Action ref: $ActionRef") | Out-Null
$lines.Add("- Target path: $TargetPath") | Out-Null
$lines.Add("- Requested modes: $RequestedModes") | Out-Null
$lines.Add("- Executed modes: $ExecutedModes") | Out-Null
$lines.Add("- Total processed: $TotalProcessed") | Out-Null
$lines.Add("- Total diffs: $TotalDiffs") | Out-Null
$lines.Add("- Container image: $ContainerImage") | Out-Null
$lines.Add('') | Out-Null
$lines.Add($ModeSummaryMarkdown) | Out-Null
$lines.Add('') | Out-Null
$lines.Add("- Run: $RunUrl") | Out-Null
$lines -join "`n"
'@
  $rendererScript | Set-Content -LiteralPath (Join-Path $toolingRoot 'tools/New-CompareVIHistoryDiagnosticsBody.ps1') -Encoding utf8

  $requestJson = @'
{
  "schema": "comparevi-history/request@v1",
  "generatedAtUtc": "2026-03-15T00:00:00Z",
  "consumer": {
    "repository": "ni/labview-icon-editor",
    "ref": "refs/pull/123/head",
    "repositoryRoot": "__REPO_ROOT__"
  },
  "targetSpec": {
    "path": "__REPO_ROOT__/.github/comparevi-history-targets.json",
    "targetId": "settings-init"
  },
  "target": {
    "id": "settings-init",
    "path": "resource/plugins/NIIconEditor/Miscellaneous/Settings Init.vi",
    "requestedModes": [
      "attributes",
      "front-panel",
      "block-diagram"
    ],
    "publicModes": [
      "attributes",
      "front-panel",
      "block-diagram"
    ]
  },
  "history": {
    "startRef": "refs/pull/123/head",
    "endRef": null,
    "sourceBranchRef": "feature/history",
    "maxBranchCommits": 32,
    "maxPairs": 5,
    "maxSignalPairs": 5,
    "noisePolicy": "collapse",
    "resultsDir": "__RESULTS_ROOT__",
    "renderReport": true,
    "reportFormat": "html",
    "failFast": false,
    "failOnDiff": false,
    "quiet": false,
    "detailed": true,
    "keepArtifactsOnNoDiff": false,
    "includeMergeParents": false,
    "compareTimeoutSeconds": null
  },
  "reviewerSurface": {
    "kind": "comment-gated",
    "issueNumber": "123",
    "pullRequestNumber": "123",
    "isFork": "true",
    "containerImage": "nationalinstruments/labview:2026q1-linux"
  },
  "results": {
    "resultsDir": "__RESULTS_ROOT__",
    "publicRoot": "__PUBLIC_ROOT__",
    "requestPath": "__PUBLIC_ROOT__/request.json",
    "publicRunPath": "__PUBLIC_ROOT__/public-run.json",
    "publicCommentPath": "__PUBLIC_ROOT__/comment.md",
    "publicStepSummaryPath": "__PUBLIC_ROOT__/step-summary.md"
  }
}
'@
  $requestJson = $requestJson.Replace('__REPO_ROOT__', ($repoRoot -replace '\\', '/'))
  $requestJson = $requestJson.Replace('__RESULTS_ROOT__', ($resultsRoot -replace '\\', '/'))
  $requestJson = $requestJson.Replace('__PUBLIC_ROOT__', ($publicRoot -replace '\\', '/'))
  $requestJson | Set-Content -LiteralPath (Join-Path $publicRoot 'request.json') -Encoding utf8

  '{}' | Set-Content -LiteralPath (Join-Path $resultsRoot 'manifest.json') -Encoding utf8
  '{}' | Set-Content -LiteralPath (Join-Path $resultsRoot 'history-summary.json') -Encoding utf8
  '# report' | Set-Content -LiteralPath (Join-Path $resultsRoot 'history-report.md') -Encoding utf8
  '<html></html>' | Set-Content -LiteralPath (Join-Path $resultsRoot 'history-report.html') -Encoding utf8

  $githubOutputPath = Join-Path $tempRoot 'public-run-output.txt'
  $publicRunJson = & $scriptPath `
    -RequestPath (Join-Path $publicRoot 'request.json') `
    -ToolingRoot $toolingRoot `
    -CompareviRepository 'LabVIEW-Community-CI-CD/compare-vi-cli-action' `
    -CompareviRef 'v0.6.3-tools.8' `
    -ToolingSource 'bundle' `
    -ActionRef 'LabVIEW-Community-CI-CD/comparevi-history@v1' `
    -HistorySummaryJson (Join-Path $resultsRoot 'history-summary.json') `
    -ManifestPath (Join-Path $resultsRoot 'manifest.json') `
    -ResultsDir $resultsRoot `
    -HistoryReportMd (Join-Path $resultsRoot 'history-report.md') `
    -HistoryReportHtml (Join-Path $resultsRoot 'history-report.html') `
    -RequestedModeList 'attributes,front-panel,block-diagram' `
    -ExecutedModeList 'attributes,front-panel,block-diagram' `
    -ModeSummaryMarkdown 'Requested modes: `attributes, front-panel, block-diagram`' `
    -ModeCount '3' `
    -TotalProcessed '5' `
    -TotalDiffs '2' `
    -StopReason 'completed' `
    -RunOutcome 'success' `
    -RunConclusion 'success' `
    -RunUrl 'https://github.com/example/run/1' `
    -GitHubOutputPath $githubOutputPath

  $publicRun = $publicRunJson | ConvertFrom-Json -Depth 20
  if ($publicRun.schema -ne 'comparevi-history/public-run@v1') {
    throw 'Public run schema mismatch.'
  }
  if ($publicRun.backend.historyFacadeSchema -ne 'comparevi-tools/history-facade@v1') {
    throw 'Backend facade schema mismatch.'
  }
  if ($publicRun.summary.finalStatus -ne 'succeeded') {
    throw 'Final status mismatch.'
  }
  if ($publicRun.replay.status -ne 'ready') {
    throw 'Replay status mismatch.'
  }
  if (-not (Test-Path -LiteralPath $publicRun.outputs.publicCommentPath -PathType Leaf)) {
    throw 'Public comment body was not written.'
  }
  if (-not (Test-Path -LiteralPath $publicRun.outputs.publicStepSummaryPath -PathType Leaf)) {
    throw 'Public step summary was not written.'
  }

  $publicComment = Get-Content -LiteralPath $publicRun.outputs.publicCommentPath -Raw
  if ($publicComment -notmatch 'Requested modes') {
    throw 'Rendered public comment did not include the renderer output.'
  }

  $githubOutputs = Get-Content -LiteralPath $githubOutputPath -Raw
  foreach ($requiredKey in @('history-summary-json=', 'public-run-path=', 'public-comment-path=', 'public-step-summary-path=', 'final-status=succeeded', 'final-reason=completed')) {
    if ($githubOutputs -notmatch [regex]::Escape($requiredKey)) {
      throw "Expected GitHub output '$requiredKey'."
    }
  }

  $failureOutputPath = Join-Path $tempRoot 'public-run-failure-output.txt'
  $failureJson = & $scriptPath `
    -RequestPath (Join-Path $publicRoot 'request.json') `
    -ToolingRoot $toolingRoot `
    -CompareviRepository 'LabVIEW-Community-CI-CD/compare-vi-cli-action' `
    -CompareviRef 'v0.6.3-tools.8' `
    -ToolingSource 'bundle' `
    -RunOutcome 'failure' `
    -RunConclusion 'failure' `
    -GitHubOutputPath $failureOutputPath
  $failure = $failureJson | ConvertFrom-Json -Depth 20
  if ($failure.summary.finalStatus -ne 'failed') {
    throw 'Failure final status mismatch.'
  }
  if ($failure.summary.finalReason -ne 'facade-step-failed') {
    throw 'Failure final reason mismatch.'
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
