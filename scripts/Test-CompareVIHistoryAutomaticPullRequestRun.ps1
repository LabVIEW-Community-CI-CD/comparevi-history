Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'Write-CompareVIHistoryAutomaticPullRequestRun.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('comparevi-history-auto-pr-run-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

function New-PreviewReportFixture {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ModeRoot,
    [Parameter(Mandatory = $true)]
    [string]$ArtifactPrefix,
    [Parameter(Mandatory = $true)]
    [int]$ComparisonIndex,
    [Parameter(Mandatory = $true)]
    [string]$BaseRef,
    [Parameter(Mandatory = $true)]
    [string]$HeadRef
  )

  $artifactDir = Join-Path $ModeRoot ('{0}-{1:D3}-artifacts' -f $ArtifactPrefix, $ComparisonIndex)
  $reportFilesDir = Join-Path $artifactDir 'compare-report_files'
  New-Item -ItemType Directory -Path $reportFilesDir -Force | Out-Null
  foreach ($imageName in @('fp_1.png', 'fp_2.png')) {
    [System.IO.File]::WriteAllBytes((Join-Path $reportFilesDir $imageName), @(0xCA, 0xFE, 0xBA, 0xBE))
  }

  $reportHtmlPath = Join-Path $artifactDir 'compare-report.html'
  @'
<!DOCTYPE html>
<html>
<body>
<div class="compared-VIs">
<details><summary class="difference-heading"><div class="dropdown-left">First VI: /compare/base/Base.vi</div><div class="dropdown-right">Second VI: /compare/head/Head.vi</div></summary>
<table class="difference"><tr class="compared-vi-image-captions"><td class="compared-vi-image-caption">Front Panel Overview</td></tr>
<tr class="compared-images"><td class="diff-image"><img class="difference-image" src="compare-report_files/fp_1.png"/></td><td class="difference-divider"></td><td class="diff-image"><img class="difference-image" src="compare-report_files/fp_2.png"/></td></tr></table></details>
</div>
</body>
</html>
'@ | Set-Content -LiteralPath $reportHtmlPath -Encoding utf8

  return [ordered]@{
    index = $ComparisonIndex
    base = [ordered]@{
      ref = $BaseRef
      short = ('base-{0:D2}' -f $ComparisonIndex)
    }
    head = [ordered]@{
      ref = $HeadRef
      short = ('head-{0:D2}' -f $ComparisonIndex)
    }
    result = [ordered]@{
      reportHtml = $reportHtmlPath
    }
  }
}

function New-PreviewModeFixture {
  param(
    [Parameter(Mandatory = $true)]
    [string]$HistoryRoot,
    [Parameter(Mandatory = $true)]
    [string]$ModeName,
    [Parameter(Mandatory = $true)]
    [string]$ArtifactPrefix
  )

  $modeRoot = Join-Path $HistoryRoot $ModeName
  New-Item -ItemType Directory -Path $modeRoot -Force | Out-Null
  $modeManifestPath = Join-Path $modeRoot 'manifest.json'
  $comparisons = @(
    (New-PreviewReportFixture -ModeRoot $modeRoot -ArtifactPrefix $ArtifactPrefix -ComparisonIndex 1 -BaseRef ('{0}-base-1' -f $ModeName) -HeadRef ('{0}-head-1' -f $ModeName)),
    (New-PreviewReportFixture -ModeRoot $modeRoot -ArtifactPrefix $ArtifactPrefix -ComparisonIndex 2 -BaseRef ('{0}-base-2' -f $ModeName) -HeadRef ('{0}-head-2' -f $ModeName))
  )

  ([ordered]@{
      schema = 'vi-compare/history@v1'
      generatedAt = '2026-03-17T00:00:30Z'
      mode = $ModeName
      comparisons = $comparisons
    } | ConvertTo-Json -Depth 64) | Set-Content -LiteralPath $modeManifestPath -Encoding utf8

  return [ordered]@{
    name = $ModeName
    manifestPath = $modeManifestPath
  }
}

function Get-OrdinalPositions {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Content,
    [Parameter(Mandatory = $true)]
    [string[]]$Needles
  )

  $positions = New-Object System.Collections.Generic.List[int]
  foreach ($needle in $Needles) {
    $position = $Content.IndexOf($needle, [System.StringComparison]::Ordinal)
    if ($position -lt 0) {
      throw "Missing expected content: $needle"
    }

    $positions.Add($position) | Out-Null
  }

  return @($positions | ForEach-Object { $_ })
}

try {
  $resultsDir = Join-Path $tempRoot 'results'
  New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null

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
    "changedFileCount": 3
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
    },
    {
      "status": "removed",
      "currentPath": "Tooling/deployment/Removed.vi",
      "previousPath": null
    }
  ],
  "excludedViFiles": [
    {
      "status": "removed",
      "currentPath": "Tooling/deployment/Removed.vi",
      "previousPath": null,
      "exclusionReason": "deleted-vi-not-executable"
    }
  ],
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
    "changedViCount": 3,
    "eligibleChangedViCount": 3,
    "excludedViCount": 1,
    "selectedTargetCount": 2,
    "overflowBehavior": "block",
    "overflowed": false,
    "overflowChangedViCount": 0
  }
}
"@ | Set-Content -LiteralPath $discoveryPath -Encoding utf8

  $targetOneRoot = Join-Path $resultsDir 'targets/001-post/history/public'
  $targetTwoRoot = Join-Path $resultsDir 'targets/002-pre/history/public'
  foreach ($path in @($targetOneRoot, $targetTwoRoot)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
  }

  $targetOneHistoryRoot = Split-Path -Parent $targetOneRoot
  $targetOneSuiteManifestPath = Join-Path $targetOneHistoryRoot 'manifest.json'
  $targetOneModes = @(
    (New-PreviewModeFixture -HistoryRoot $targetOneHistoryRoot -ModeName 'front-panel' -ArtifactPrefix 'VIP_Post-Install_Custom_Action.vi'),
    (New-PreviewModeFixture -HistoryRoot $targetOneHistoryRoot -ModeName 'block-diagram' -ArtifactPrefix 'VIP_Post-Install_Custom_Action.vi'),
    (New-PreviewModeFixture -HistoryRoot $targetOneHistoryRoot -ModeName 'attributes' -ArtifactPrefix 'VIP_Post-Install_Custom_Action.vi')
  )
  ([ordered]@{
      schema = 'vi-compare/history-suite@v1'
      generatedAt = '2026-03-17T00:00:30Z'
      modes = $targetOneModes
    } | ConvertTo-Json -Depth 64) | Set-Content -LiteralPath $targetOneSuiteManifestPath -Encoding utf8

  foreach ($path in @(
      (Join-Path $targetOneRoot 'request.json'),
      (Join-Path $targetOneRoot 'public-run.json'),
      (Join-Path $targetOneRoot 'shared-evidence.json'),
      (Join-Path $targetOneRoot 'history-report.md'),
      (Join-Path $targetOneRoot 'history-report.html'),
      (Join-Path $targetOneRoot 'mode-summary.md'),
      (Join-Path $targetOneRoot 'mode-summary.json'),
      (Join-Path $targetTwoRoot 'request.json'),
      (Join-Path $targetTwoRoot 'public-run.json'),
      (Join-Path $targetTwoRoot 'shared-evidence.json'),
      (Join-Path $targetTwoRoot 'history-report.md'),
      (Join-Path $targetTwoRoot 'history-report.html'),
      (Join-Path $targetTwoRoot 'mode-summary.md'),
      (Join-Path $targetTwoRoot 'mode-summary.json')
    )) {
    'stub' | Set-Content -LiteralPath $path -Encoding utf8
  }

  $manifestPath = Join-Path $resultsDir 'pr-target-runs-manifest.json'
  @"
{
  "schema": "comparevi-history/pr-target-runs-manifest@v2",
  "generatedAtUtc": "2026-03-17T00:01:00Z",
  "summary": {
    "selectedTargetCount": 2,
    "executedTargetCount": 2,
    "failedTargetCount": 1,
    "skippedTargetCount": 0,
    "executionStatus": "failed",
    "executionReason": "one-or-more-targets-failed"
  },
  "targets": [
    {
      "targetId": "dynamic-vip-post-install-custom-action-a1b2c3d4e5f6",
      "targetSource": "dynamic-path",
      "targetPath": "Tooling/deployment/VIP_Post-Install Custom Action.vi",
      "requestedModes": ["attributes", "front-panel", "block-diagram"],
      "requestedModeSource": "pr-policy",
      "sourceBranchRef": "develop",
      "keepArtifactsOnNoDiff": true,
      "currentPath": "Tooling/deployment/VIP_Post-Install Custom Action.vi",
      "previousPath": null,
      "changeStatus": "modified",
      "finalStatus": "succeeded",
      "finalReason": "completed",
      "requestPath": "$((Join-Path $targetOneRoot 'request.json').Replace('\', '\\'))",
      "publicRunPath": "$((Join-Path $targetOneRoot 'public-run.json').Replace('\', '\\'))",
      "sharedEvidencePath": "$((Join-Path $targetOneRoot 'shared-evidence.json').Replace('\', '\\'))",
      "historySummaryJsonPath": null,
      "manifestPath": "$($targetOneSuiteManifestPath.Replace('\', '\\'))",
      "historyReportMdPath": "$((Join-Path $targetOneRoot 'history-report.md').Replace('\', '\\'))",
      "historyReportHtmlPath": "$((Join-Path $targetOneRoot 'history-report.html').Replace('\', '\\'))",
      "modeSummaryJsonPath": "$((Join-Path $targetOneRoot 'mode-summary.json').Replace('\', '\\'))",
      "modeSummaryPath": "$((Join-Path $targetOneRoot 'mode-summary.md').Replace('\', '\\'))",
      "totalProcessed": 5,
      "totalDiffs": 2
    },
    {
      "targetId": "dynamic-vip-pre-install-custom-action-0f1e2d3c4b5a",
      "targetSource": "dynamic-path",
      "targetPath": "Tooling/deployment/VIP_Pre-Install Custom Action.vi",
      "requestedModes": ["attributes", "front-panel", "block-diagram"],
      "requestedModeSource": "pr-policy",
      "sourceBranchRef": "develop",
      "keepArtifactsOnNoDiff": true,
      "currentPath": "Tooling/deployment/VIP_Pre-Install Custom Action.vi",
      "previousPath": null,
      "changeStatus": "modified",
      "finalStatus": "failed",
      "finalReason": "facade-step-failed",
      "requestPath": "$((Join-Path $targetTwoRoot 'request.json').Replace('\', '\\'))",
      "publicRunPath": "$((Join-Path $targetTwoRoot 'public-run.json').Replace('\', '\\'))",
      "sharedEvidencePath": "$((Join-Path $targetTwoRoot 'shared-evidence.json').Replace('\', '\\'))",
      "historySummaryJsonPath": null,
      "historyReportMdPath": "$((Join-Path $targetTwoRoot 'history-report.md').Replace('\', '\\'))",
      "historyReportHtmlPath": "$((Join-Path $targetTwoRoot 'history-report.html').Replace('\', '\\'))",
      "modeSummaryJsonPath": "$((Join-Path $targetTwoRoot 'mode-summary.json').Replace('\', '\\'))",
      "modeSummaryPath": "$((Join-Path $targetTwoRoot 'mode-summary.md').Replace('\', '\\'))",
      "totalProcessed": 0,
      "totalDiffs": 0
    }
  ]
}
"@ | Set-Content -LiteralPath $manifestPath -Encoding utf8

  $outputPath = Join-Path $tempRoot 'automatic-pr-run.out'
  $receiptJson = & $scriptPath `
    -DiscoveryPath $discoveryPath `
    -ResultsDir $resultsDir `
    -TargetRunsManifestPath $manifestPath `
    -RunUrl 'https://github.com/LabVIEW-Community-CI-CD/labview-icon-editor-demo/actions/runs/123456789' `
    -ArtifactName 'comparevi-history-pr-diagnostics-123456789' `
    -GitHubOutputPath $outputPath

  $receipt = $receiptJson | ConvertFrom-Json -Depth 64
  if ($receipt.schema -ne 'comparevi-history/pr-run@v2') {
    throw 'Automatic PR run schema mismatch.'
  }
  if ($receipt.summary.finalStatus -ne 'failed' -or $receipt.summary.finalReason -ne 'one-or-more-targets-failed') {
    throw 'Automatic PR run should surface the failed target aggregate status.'
  }
  if ($receipt.summary.changedViCount -ne 3 -or
    $receipt.summary.eligibleChangedViCount -ne 3 -or
    $receipt.summary.excludedViCount -ne 1 -or
    $receipt.summary.selectedTargetCount -ne 2) {
    throw 'Aggregate PR run summary counts mismatch.'
  }
  if ($receipt.summary.executedTargetCount -ne 2 -or $receipt.summary.failedTargetCount -ne 1) {
    throw 'Aggregate execution counts mismatch.'
  }
  if ($receipt.summary.totalProcessed -ne 5 -or $receipt.summary.totalDiffs -ne 2) {
    throw 'Aggregate totals mismatch.'
  }
  if ($receipt.summary.previewPairCount -ne 6 -or
    $receipt.summary.rawPreviewPairCount -ne 6 -or
    $receipt.summary.reviewerPreviewPairCount -ne 2 -or
    $receipt.summary.commentPreviewPairCount -ne 2 -or
    $receipt.summary.commentPreviewPairOmittedCount -ne 0 -or
    $receipt.summary.indexPreviewPairCount -ne 2 -or
    $receipt.summary.indexPreviewPairOmittedCount -ne 0) {
    throw 'Aggregate preview pair summary mismatch.'
  }
  if ($receipt.outputs.workflowRunUrl -ne 'https://github.com/LabVIEW-Community-CI-CD/labview-icon-editor-demo/actions/runs/123456789') {
    throw 'Workflow run URL mismatch.'
  }
  if ($receipt.outputs.artifactName -ne 'comparevi-history-pr-diagnostics-123456789') {
    throw 'Artifact name mismatch.'
  }
  if (-not (Test-Path -LiteralPath $receipt.outputs.indexMarkdownPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $receipt.outputs.indexHtmlPath -PathType Leaf)) {
    throw 'Aggregate index surfaces were not written.'
  }
  if (-not (Test-Path -LiteralPath $receipt.outputs.publicCommentPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $receipt.outputs.publicStepSummaryPath -PathType Leaf)) {
    throw 'Aggregate reviewer surfaces were not written.'
  }
  if (-not (Test-Path -LiteralPath $receipt.outputs.previewManifestPath -PathType Leaf)) {
    throw 'Aggregate preview manifest was not written.'
  }
  if ($receipt.excludedViFiles.Count -ne 1 -or [string]$receipt.excludedViFiles[0].exclusionReason -ne 'deleted-vi-not-executable') {
    throw 'Excluded VI state should flow into the aggregate PR run receipt.'
  }

  $commentBody = Get-Content -LiteralPath $receipt.outputs.publicCommentPath -Raw
  if ($commentBody -notmatch [regex]::Escape('<!-- comparevi-history:pull-request-diagnostics -->')) {
    throw 'PR comment body did not include the sticky marker.'
  }
  if ($commentBody -notmatch [regex]::Escape('`Tooling/deployment/VIP_Post-Install Custom Action.vi`')) {
    throw 'PR comment body should list selected changed VI paths.'
  }
  if ($commentBody -notmatch [regex]::Escape('comparevi-history-pr-diagnostics-123456789')) {
    throw 'PR comment body should point reviewers at the artifact bundle.'
  }
  if ($commentBody -notmatch [regex]::Escape('Reviewer preview gallery: `2` shown, `0` omitted, cap `4`')) {
    throw 'PR comment body should surface the corrected preview pair counts.'
  }
  if ($commentBody -match [regex]::Escape('| front-panel |') -or
    $commentBody -match [regex]::Escape('| block-diagram |') -or
    $commentBody -match [regex]::Escape('| attributes |') -or
    $commentBody -match [regex]::Escape('Front Panel Overview')) {
    throw 'PR comment body should not surface execution modes or report captions in the reviewer-facing preview gallery.'
  }

  $indexMarkdown = Get-Content -LiteralPath $receipt.outputs.indexMarkdownPath -Raw
  foreach ($requiredText in @(
      '[changed-vi-discovery.json](changed-vi-discovery.json)',
      '[pr-run.json](pr-run.json)',
      '[pr-preview-manifest.json](pr-preview-manifest.json)',
      '[public run](',
      '[shared evidence](',
      '[history report](',
      '[mode summary](',
      '[request]('
    )) {
    if ($indexMarkdown -notmatch [regex]::Escape($requiredText)) {
      throw "Index markdown is missing '$requiredText'."
    }
  }
  if ([regex]::Matches($indexMarkdown, [regex]::Escape('### `Tooling/deployment/VIP_Post-Install Custom Action.vi`')).Count -ne 2) {
    throw 'Index markdown should render two reviewer-canonical preview entries for the PR31-shaped fixture.'
  }
  if ($indexMarkdown -match [regex]::Escape('### Tooling/deployment/VIP_Post-Install Custom Action.vi | front-panel |') -or
    $indexMarkdown -match [regex]::Escape('### Tooling/deployment/VIP_Post-Install Custom Action.vi | block-diagram |') -or
    $indexMarkdown -match [regex]::Escape('### Tooling/deployment/VIP_Post-Install Custom Action.vi | attributes |') -or
    $indexMarkdown -match [regex]::Escape('Front Panel Overview')) {
    throw 'Index markdown should not surface execution modes or report captions in reviewer-facing preview titles.'
  }
  if ($indexMarkdown -notmatch [regex]::Escape('History pair 1') -or
    $indexMarkdown -notmatch [regex]::Escape('History pair 2') -or
    $indexMarkdown -notmatch [regex]::Escape('`base-01 -> head-01`') -or
    $indexMarkdown -notmatch [regex]::Escape('`base-02 -> head-02`')) {
    throw 'Index markdown should surface stable history-pair subtitles and revision refs.'
  }

  $markdownPositions = Get-OrdinalPositions -Content $indexMarkdown -Needles @(
    'targets/001-post/history/front-panel/VIP_Post-Install_Custom_Action.vi-001-artifacts/compare-report_files/fp_1.png',
    'targets/001-post/history/front-panel/VIP_Post-Install_Custom_Action.vi-002-artifacts/compare-report_files/fp_1.png'
  )
  if (-not ($markdownPositions[0] -lt $markdownPositions[1])) {
    throw 'Index markdown should preserve the reviewer-canonical comparison ordering.'
  }

  $indexHtml = Get-Content -LiteralPath $receipt.outputs.indexHtmlPath -Raw
  if ($indexHtml -notmatch [regex]::Escape('<section class="preview-gallery">')) {
    throw 'Index HTML should embed the preview gallery.'
  }
  if ([regex]::Matches($indexHtml, [regex]::Escape('<article class="preview-card">')).Count -ne 2) {
    throw 'Index HTML should render two reviewer-canonical preview cards for the PR31-shaped fixture.'
  }
  if ($indexHtml -match [regex]::Escape('<strong>Mode</strong>') -or
    $indexHtml -match [regex]::Escape('Front Panel Overview')) {
    throw 'Index HTML should not surface execution modes or report captions in reviewer-facing preview cards.'
  }
  if ($indexHtml -notmatch [regex]::Escape('History pair 1') -or
    $indexHtml -notmatch [regex]::Escape('History pair 2') -or
    $indexHtml -notmatch [regex]::Escape('base-01 -&gt; head-01') -or
    $indexHtml -notmatch [regex]::Escape('base-02 -&gt; head-02')) {
    throw 'Index HTML should surface stable history-pair subtitles and revision refs.'
  }

  $htmlPositions = Get-OrdinalPositions -Content $indexHtml -Needles @(
    'targets/001-post/history/front-panel/VIP_Post-Install_Custom_Action.vi-001-artifacts/compare-report_files/fp_1.png',
    'targets/001-post/history/front-panel/VIP_Post-Install_Custom_Action.vi-002-artifacts/compare-report_files/fp_1.png'
  )
  if (-not ($htmlPositions[0] -lt $htmlPositions[1])) {
    throw 'Index HTML should preserve the reviewer-canonical comparison ordering.'
  }

  $previewManifest = Get-Content -LiteralPath $receipt.outputs.previewManifestPath -Raw | ConvertFrom-Json -Depth 64
  if ($previewManifest.summary.previewPairCount -ne 6 -or
    $previewManifest.summary.rawPreviewPairCount -ne 6 -or
    $previewManifest.summary.reviewerPreviewPairCount -ne 2 -or
    $previewManifest.summary.commentPreviewPairCount -ne 2 -or
    $previewManifest.summary.indexPreviewPairCount -ne 2) {
    throw 'Preview manifest summary mismatch.'
  }

  $stepSummary = Get-Content -LiteralPath $receipt.outputs.publicStepSummaryPath -Raw
  if ($stepSummary -notmatch 'automatic pull request run' -or
    $stepSummary -notmatch 'Final status: `failed`' -or
    $stepSummary -notmatch 'Reviewer preview gallery: `2` shown, `0` omitted, cap `4`' -or
    $stepSummary -notmatch 'Raw preview surfaces collapsed for review: `6` raw -> `2` reviewer-canonical') {
    throw 'Public step summary content mismatch.'
  }

  $outputText = Get-Content -LiteralPath $outputPath -Raw
  foreach ($requiredKey in @(
      'pr-run-path=',
      'public-comment-path=',
      'public-step-summary-path=',
      'preview-manifest-path=',
      'index-markdown-path=',
      'index-html-path=',
      'final-status=failed',
      'final-reason=one-or-more-targets-failed'
    )) {
    if ($outputText -notmatch [regex]::Escape($requiredKey)) {
      throw "Expected GitHub output '$requiredKey'."
    }
  }

  $blockedDiscoveryPath = Join-Path $resultsDir 'blocked-discovery.json'
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
    "number": 23,
    "htmlUrl": null,
    "baseRepository": "LabVIEW-Community-CI-CD/labview-icon-editor-demo",
    "baseRef": "release/2026-q1",
    "baseSha": "base-sha",
    "headRepository": "some-user/labview-icon-editor-demo",
    "headRef": "feature/overflow",
    "headSha": "head-sha",
    "isFork": true,
    "changedFileCount": 11
  },
  "changedViFiles": [],
  "excludedViFiles": [],
  "selectedTargets": [],
  "summary": {
    "selectionMode": "dynamic-paths",
    "executionStatus": "blocked",
    "executionReason": "max-changed-vi-count-exceeded",
    "changedViCount": 0,
    "eligibleChangedViCount": 11,
    "excludedViCount": 0,
    "selectedTargetCount": 0,
    "overflowBehavior": "block",
    "overflowed": true,
    "overflowChangedViCount": 1
  }
}
"@ | Set-Content -LiteralPath $blockedDiscoveryPath -Encoding utf8

  $blockedJson = & $scriptPath `
    -DiscoveryPath $blockedDiscoveryPath `
    -ResultsDir (Join-Path $tempRoot 'blocked-results')
  $blockedReceipt = $blockedJson | ConvertFrom-Json -Depth 64
  if ($blockedReceipt.summary.finalStatus -ne 'blocked' -or
    $blockedReceipt.summary.finalReason -ne 'max-changed-vi-count-exceeded') {
    throw 'Blocked discovery should remain blocked in the aggregate PR run receipt.'
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
