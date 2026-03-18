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
    [string]$ModeName,
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
  [System.IO.File]::WriteAllBytes((Join-Path $reportFilesDir 'fp_1.png'), @(0xCA, 0xFE, 0xBA, 0xBE))
  [System.IO.File]::WriteAllBytes((Join-Path $reportFilesDir 'fp_2.png'), @(0xBE, 0xBA, 0xFE, 0xCA))
  [System.IO.File]::WriteAllBytes((Join-Path $reportFilesDir 'bd_1.png'), @(0x0B, 0xD1, 0xA6, 0x01))
  [System.IO.File]::WriteAllBytes((Join-Path $reportFilesDir 'bd_2.png'), @(0x10, 0x0C, 0xD1, 0xA6))

  $reportHtmlPath = Join-Path $artifactDir 'compare-report.html'
  $reportHtml = if ($ModeName -eq 'attributes') {
@"
<!DOCTYPE html>
<html>
<body>
<div class="compared-VIs">
<details><summary class="difference-heading"><div class="dropdown-left">First VI: /compare/base/Base.vi</div><div class="dropdown-right">Second VI: /compare/head/Head.vi</div></summary>
<table class="difference"><tr class="compared-vi-image-captions"><td class="compared-vi-image-caption">Front Panel Overview</td></tr>
<tr class="compared-images"><td class="diff-image"><img class="difference-image" src="compare-report_files/fp_1.png"/></td><td class="difference-divider"></td><td class="diff-image"><img class="difference-image" src="compare-report_files/fp_2.png"/></td></tr>
<tr class="compared-vi-image-captions"><td class="compared-vi-image-caption">Block Diagram Overview</td></tr>
<tr class="compared-images"><td class="diff-image"><img class="difference-image" src="compare-report_files/bd_1.png"/></td><td class="difference-divider"></td><td class="diff-image"><img class="difference-image" src="compare-report_files/bd_2.png"/></td></tr></table></details>
</div>
<div class="included-attributes">
<ul class="inclusion-list">
<li class="checked">Block Diagram Functional</li>
<li class="checked">VI Attribute</li>
</ul>
</div>
<h2 class="section-header">Detailed Information</h2>
$(if ($ComparisonIndex -eq 1) {
@'
<details open>
<summary class="difference-heading">1. Block Diagram objects</summary>
<ol class="detailed-description-list" type="A">
<li class="diff-detail">Property Node - moved : changed from "(-35,102)" to "(-55,77)"</li>
<li class="diff-detail">Tunnel - moved : changed from "(141,124)" to "(141,124)"</li>
<li class="diff-detail">Case Selector - moved : changed from "(141,143)" to "(141,143)"</li>
</ol>
</details>
<details open>
<summary class="difference-heading">2. Block Diagram objects</summary>
<ol class="detailed-description-list" type="A">
<li class="diff-detail">Case Structure - resized : changed from "702*298" to "702*370"</li>
<li class="diff-detail"> - resized : changed from "690*23" to "690*25"</li>
</ol>
</details>
'@
} else {
@'
<details open>
<summary class="difference-heading">1. VI Attribute - Miscellaneous</summary>
<ol class="detailed-description-list" type="A">
<li class="diff-detail">VI Version : changed from "21.0" to "20.0"</li>
</ol>
</details>
'@
})
</body>
</html>
"@
  } else {
@'
<!DOCTYPE html>
<html>
<body>
<div class="compared-VIs">
<details><summary class="difference-heading"><div class="dropdown-left">First VI: /compare/base/Base.vi</div><div class="dropdown-right">Second VI: /compare/head/Head.vi</div></summary>
<table class="difference"><tr class="compared-vi-image-captions"><td class="compared-vi-image-caption">Front Panel Overview</td></tr>
<tr class="compared-images"><td class="diff-image"><img class="difference-image" src="compare-report_files/fp_1.png"/></td><td class="difference-divider"></td><td class="diff-image"><img class="difference-image" src="compare-report_files/fp_2.png"/></td></tr>
<tr class="compared-vi-image-captions"><td class="compared-vi-image-caption">Block Diagram Overview</td></tr>
<tr class="compared-images"><td class="diff-image"><img class="difference-image" src="compare-report_files/bd_1.png"/></td><td class="difference-divider"></td><td class="diff-image"><img class="difference-image" src="compare-report_files/bd_2.png"/></td></tr></table></details>
</div>
</body>
</html>
'@
  }
  $reportHtml | Set-Content -LiteralPath $reportHtmlPath -Encoding utf8

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
    (New-PreviewReportFixture -ModeRoot $modeRoot -ModeName $ModeName -ArtifactPrefix $ArtifactPrefix -ComparisonIndex 1 -BaseRef ('{0}-base-1' -f $ModeName) -HeadRef ('{0}-head-1' -f $ModeName)),
    (New-PreviewReportFixture -ModeRoot $modeRoot -ModeName $ModeName -ArtifactPrefix $ArtifactPrefix -ComparisonIndex 2 -BaseRef ('{0}-base-2' -f $ModeName) -HeadRef ('{0}-head-2' -f $ModeName))
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
  if ($receipt.summary.previewPairCount -ne 4 -or
    $receipt.summary.rawPreviewPairCount -ne 4 -or
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
  if ($commentBody -notmatch [regex]::Escape('Reviewer preview gallery: `2` history pairs shown, `0` omitted, cap `4`')) {
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
  if ([regex]::Matches($indexMarkdown, [regex]::Escape('#### Front panel')).Count -ne 2 -or
    [regex]::Matches($indexMarkdown, [regex]::Escape('#### Block diagram')).Count -ne 2) {
    throw 'Index markdown should render both front-panel and block-diagram surfaces for each reviewer card.'
  }
  if ($indexMarkdown -notmatch [regex]::Escape('[![Front panel base](targets/001-post/history/front-panel/VIP_Post-Install_Custom_Action.vi-001-artifacts/compare-report_files/fp_1.png)](targets/001-post/history/front-panel/VIP_Post-Install_Custom_Action.vi-001-artifacts/compare-report.html)') -or
    $indexMarkdown -notmatch [regex]::Escape('[![Block diagram base](targets/001-post/history/block-diagram/VIP_Post-Install_Custom_Action.vi-001-artifacts/compare-report_files/bd_1.png)](targets/001-post/history/block-diagram/VIP_Post-Install_Custom_Action.vi-001-artifacts/compare-report.html)') -or
    $indexMarkdown -notmatch [regex]::Escape('[![Front panel head](targets/001-post/history/front-panel/VIP_Post-Install_Custom_Action.vi-002-artifacts/compare-report_files/fp_2.png)](targets/001-post/history/front-panel/VIP_Post-Install_Custom_Action.vi-002-artifacts/compare-report.html)') -or
    $indexMarkdown -notmatch [regex]::Escape('[![Block diagram head](targets/001-post/history/block-diagram/VIP_Post-Install_Custom_Action.vi-002-artifacts/compare-report_files/bd_2.png)](targets/001-post/history/block-diagram/VIP_Post-Install_Custom_Action.vi-002-artifacts/compare-report.html)')) {
    throw 'Index markdown should make preview images one-click links to exact visual report surfaces.'
  }
  if ([regex]::Matches($indexMarkdown, [regex]::Escape('#### Reviewer summary')).Count -ne 2 -or
    $indexMarkdown -notmatch [regex]::Escape('- Headline: `Material logic-affecting movement and structure resizing`') -or
    $indexMarkdown -notmatch [regex]::Escape('- Overall severity: `medium`') -or
    $indexMarkdown -notmatch [regex]::Escape('- [`Logic-affecting movement`](targets/001-post/history/attributes/VIP_Post-Install_Custom_Action.vi-001-artifacts/compare-report.reviewer-anchors.html#comparevi-change-001-block-diagram-objects): `medium` severity, `3` details across `1` sections') -or
    $indexMarkdown -notmatch [regex]::Escape('- [`Structure resizing`](targets/001-post/history/attributes/VIP_Post-Install_Custom_Action.vi-001-artifacts/compare-report.reviewer-anchors.html#comparevi-change-002-block-diagram-objects): `low` severity, `2` details across `1` sections') -or
    $indexMarkdown -notmatch [regex]::Escape('- Headline: `Material version or compatibility changes`') -or
    $indexMarkdown -notmatch [regex]::Escape('- [`Version or compatibility changes`](targets/001-post/history/attributes/VIP_Post-Install_Custom_Action.vi-002-artifacts/compare-report.reviewer-anchors.html#comparevi-change-001-vi-attribute-miscellaneous): `medium` severity, `1` details across `1` sections')) {
    throw 'Index markdown should render reviewer-summary headlines, severity, and exact linked signals.'
  }
  if ([regex]::Matches($indexMarkdown, [regex]::Escape('#### Change details')).Count -ne 2 -or
    $indexMarkdown -notmatch [regex]::Escape('[`Block diagram moves`](targets/001-post/history/attributes/VIP_Post-Install_Custom_Action.vi-001-artifacts/compare-report.reviewer-anchors.html#comparevi-change-001-block-diagram-objects): `3` details across `1` sections') -or
    $indexMarkdown -notmatch [regex]::Escape('[`Block diagram resizing`](targets/001-post/history/attributes/VIP_Post-Install_Custom_Action.vi-001-artifacts/compare-report.reviewer-anchors.html#comparevi-change-002-block-diagram-objects): `2` details across `1` sections') -or
    $indexMarkdown -notmatch [regex]::Escape('Exact sections: [section 1](targets/001-post/history/attributes/VIP_Post-Install_Custom_Action.vi-001-artifacts/compare-report.reviewer-anchors.html#comparevi-change-001-block-diagram-objects)') -or
    $indexMarkdown -notmatch [regex]::Escape('[`VI version changes`](targets/001-post/history/attributes/VIP_Post-Install_Custom_Action.vi-002-artifacts/compare-report.reviewer-anchors.html#comparevi-change-001-vi-attribute-miscellaneous): `1` details across `1` sections') -or
    $indexMarkdown -notmatch [regex]::Escape('Included categories: `Block Diagram Functional`, `VI Attribute`')) {
    throw 'Index markdown should render bounded change-detail summaries from the attributes compare report.'
  }

  $markdownPositions = Get-OrdinalPositions -Content $indexMarkdown -Needles @(
    'targets/001-post/history/front-panel/VIP_Post-Install_Custom_Action.vi-001-artifacts/compare-report_files/fp_1.png',
    'targets/001-post/history/block-diagram/VIP_Post-Install_Custom_Action.vi-001-artifacts/compare-report_files/bd_1.png',
    'targets/001-post/history/front-panel/VIP_Post-Install_Custom_Action.vi-002-artifacts/compare-report_files/fp_1.png',
    'targets/001-post/history/block-diagram/VIP_Post-Install_Custom_Action.vi-002-artifacts/compare-report_files/bd_1.png'
  )
  if (-not ($markdownPositions[0] -lt $markdownPositions[1] -and
      $markdownPositions[1] -lt $markdownPositions[2] -and
      $markdownPositions[2] -lt $markdownPositions[3])) {
    throw 'Index markdown should preserve history-pair ordering while surfacing both front-panel and block-diagram previews.'
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
  if ([regex]::Matches($indexHtml, [regex]::Escape('<h4>Front panel</h4>')).Count -ne 2 -or
    [regex]::Matches($indexHtml, [regex]::Escape('<h4>Block diagram</h4>')).Count -ne 2) {
    throw 'Index HTML should render both front-panel and block-diagram surfaces for each reviewer card.'
  }
  if ($indexHtml -notmatch [regex]::Escape('<a href="targets/001-post/history/front-panel/VIP_Post-Install_Custom_Action.vi-001-artifacts/compare-report.html"><img alt="Front panel base" src="targets/001-post/history/front-panel/VIP_Post-Install_Custom_Action.vi-001-artifacts/compare-report_files/fp_1.png"></a>') -or
    $indexHtml -notmatch [regex]::Escape('<a href="targets/001-post/history/block-diagram/VIP_Post-Install_Custom_Action.vi-001-artifacts/compare-report.html"><img alt="Block diagram base" src="targets/001-post/history/block-diagram/VIP_Post-Install_Custom_Action.vi-001-artifacts/compare-report_files/bd_1.png"></a>') -or
    $indexHtml -notmatch [regex]::Escape('<a href="targets/001-post/history/front-panel/VIP_Post-Install_Custom_Action.vi-002-artifacts/compare-report.html"><img alt="Front panel head" src="targets/001-post/history/front-panel/VIP_Post-Install_Custom_Action.vi-002-artifacts/compare-report_files/fp_2.png"></a>') -or
    $indexHtml -notmatch [regex]::Escape('<a href="targets/001-post/history/block-diagram/VIP_Post-Install_Custom_Action.vi-002-artifacts/compare-report.html"><img alt="Block diagram head" src="targets/001-post/history/block-diagram/VIP_Post-Install_Custom_Action.vi-002-artifacts/compare-report_files/bd_2.png"></a>')) {
    throw 'Index HTML should make preview images one-click links to exact visual report surfaces.'
  }
  if ([regex]::Matches($indexHtml, [regex]::Escape('<h4>Reviewer summary</h4>')).Count -ne 2 -or
    $indexHtml -notmatch [regex]::Escape('<strong>Headline:</strong> Material logic-affecting movement and structure resizing') -or
    $indexHtml -notmatch [regex]::Escape('<strong>Overall severity:</strong> medium') -or
    $indexHtml -notmatch [regex]::Escape('<a href="targets/001-post/history/attributes/VIP_Post-Install_Custom_Action.vi-001-artifacts/compare-report.reviewer-anchors.html#comparevi-change-001-block-diagram-objects">Logic-affecting movement</a>:</strong> medium severity, 3 details across 1 sections') -or
    $indexHtml -notmatch [regex]::Escape('<a href="targets/001-post/history/attributes/VIP_Post-Install_Custom_Action.vi-001-artifacts/compare-report.reviewer-anchors.html#comparevi-change-002-block-diagram-objects">Structure resizing</a>:</strong> low severity, 2 details across 1 sections') -or
    $indexHtml -notmatch [regex]::Escape('<strong>Headline:</strong> Material version or compatibility changes') -or
    $indexHtml -notmatch [regex]::Escape('<a href="targets/001-post/history/attributes/VIP_Post-Install_Custom_Action.vi-002-artifacts/compare-report.reviewer-anchors.html#comparevi-change-001-vi-attribute-miscellaneous">Version or compatibility changes</a>:</strong> medium severity, 1 details across 1 sections')) {
    throw 'Index HTML should render reviewer-summary headlines, severity, and exact linked signals.'
  }
  if ([regex]::Matches($indexHtml, [regex]::Escape('<h4>Change details</h4>')).Count -ne 2 -or
    $indexHtml -notmatch [regex]::Escape('<a href="targets/001-post/history/attributes/VIP_Post-Install_Custom_Action.vi-001-artifacts/compare-report.reviewer-anchors.html#comparevi-change-001-block-diagram-objects">Block diagram moves</a>') -or
    $indexHtml -notmatch [regex]::Escape('<a href="targets/001-post/history/attributes/VIP_Post-Install_Custom_Action.vi-001-artifacts/compare-report.reviewer-anchors.html#comparevi-change-002-block-diagram-objects">Block diagram resizing</a>') -or
    $indexHtml -notmatch [regex]::Escape('<strong>Exact sections:</strong> <a href="targets/001-post/history/attributes/VIP_Post-Install_Custom_Action.vi-001-artifacts/compare-report.reviewer-anchors.html#comparevi-change-001-block-diagram-objects">section 1</a>') -or
    $indexHtml -notmatch [regex]::Escape('<a href="targets/001-post/history/attributes/VIP_Post-Install_Custom_Action.vi-002-artifacts/compare-report.reviewer-anchors.html#comparevi-change-001-vi-attribute-miscellaneous">VI version changes</a>') -or
    $indexHtml -notmatch [regex]::Escape('open change details report')) {
    throw 'Index HTML should render bounded change-detail summaries from the attributes compare report.'
  }

  $htmlPositions = Get-OrdinalPositions -Content $indexHtml -Needles @(
    'targets/001-post/history/front-panel/VIP_Post-Install_Custom_Action.vi-001-artifacts/compare-report_files/fp_1.png',
    'targets/001-post/history/block-diagram/VIP_Post-Install_Custom_Action.vi-001-artifacts/compare-report_files/bd_1.png',
    'targets/001-post/history/front-panel/VIP_Post-Install_Custom_Action.vi-002-artifacts/compare-report_files/fp_1.png',
    'targets/001-post/history/block-diagram/VIP_Post-Install_Custom_Action.vi-002-artifacts/compare-report_files/bd_1.png'
  )
  if (-not ($htmlPositions[0] -lt $htmlPositions[1] -and
      $htmlPositions[1] -lt $htmlPositions[2] -and
      $htmlPositions[2] -lt $htmlPositions[3])) {
    throw 'Index HTML should preserve history-pair ordering while surfacing both front-panel and block-diagram previews.'
  }

  $previewManifest = Get-Content -LiteralPath $receipt.outputs.previewManifestPath -Raw | ConvertFrom-Json -Depth 64
  if ($previewManifest.summary.previewPairCount -ne 4 -or
    $previewManifest.summary.rawPreviewPairCount -ne 4 -or
    $previewManifest.summary.reviewerPreviewPairCount -ne 2 -or
    $previewManifest.summary.commentPreviewPairCount -ne 2 -or
    $previewManifest.summary.indexPreviewPairCount -ne 2 -or
    $previewManifest.summary.commentPreviewCardCount -ne 2 -or
    $previewManifest.summary.commentPreviewSurfaceCount -ne 4 -or
    $previewManifest.summary.indexPreviewCardCount -ne 2 -or
    $previewManifest.summary.indexPreviewSurfaceCount -ne 4) {
    throw 'Preview manifest summary mismatch.'
  }
  if ([string]$previewManifest.indexPreviewCards[0].reviewerSummary.label -ne 'Reviewer summary' -or
    [string]$previewManifest.indexPreviewCards[0].reviewerSummary.overallSeverity -ne 'medium' -or
    [string]$previewManifest.indexPreviewCards[0].reviewerSummary.headline -ne 'Material logic-affecting movement and structure resizing' -or
    [int]$previewManifest.indexPreviewCards[0].reviewerSummary.signalCount -ne 2 -or
    [string]$previewManifest.indexPreviewCards[0].reviewerSummary.signals[0].label -ne 'Logic-affecting movement' -or
    [string]$previewManifest.indexPreviewCards[0].reviewerSummary.signals[1].label -ne 'Structure resizing' -or
    [string]$previewManifest.indexPreviewCards[1].reviewerSummary.headline -ne 'Material version or compatibility changes' -or
    [string]$previewManifest.indexPreviewCards[1].reviewerSummary.signals[0].label -ne 'Version or compatibility changes') {
    throw 'Preview manifest should carry reviewer-summary headlines and signals into the aggregate PR run.'
  }
  if ([string]$previewManifest.indexPreviewCards[0].reviewerSummary.signals[0].primaryReportHtmlRelativePath -ne 'targets/001-post/history/attributes/VIP_Post-Install_Custom_Action.vi-001-artifacts/compare-report.reviewer-anchors.html#comparevi-change-001-block-diagram-objects' -or
    [string]$previewManifest.indexPreviewCards[1].reviewerSummary.signals[0].primaryReportHtmlRelativePath -ne 'targets/001-post/history/attributes/VIP_Post-Install_Custom_Action.vi-002-artifacts/compare-report.reviewer-anchors.html#comparevi-change-001-vi-attribute-miscellaneous') {
    throw 'Preview manifest should carry exact reviewer-summary links into the aggregate PR run.'
  }
  if ([string]$previewManifest.indexPreviewCards[0].changeDetails.label -ne 'Change details' -or
    [string]$previewManifest.indexPreviewCards[0].changeDetails.groups[0].heading -ne 'Block diagram moves' -or
    [string]$previewManifest.indexPreviewCards[0].changeDetails.groups[1].heading -ne 'Block diagram resizing' -or
    [string]$previewManifest.indexPreviewCards[1].changeDetails.groups[0].heading -ne 'VI version changes') {
    throw 'Preview manifest should carry reviewer-facing change-detail summaries into the aggregate PR run.'
  }
  if ([string]$previewManifest.indexPreviewCards[0].changeDetails.groups[0].sectionLinks[0].reportHtmlRelativePath -ne 'targets/001-post/history/attributes/VIP_Post-Install_Custom_Action.vi-001-artifacts/compare-report.reviewer-anchors.html#comparevi-change-001-block-diagram-objects' -or
    [string]$previewManifest.indexPreviewCards[1].changeDetails.groups[0].primaryReportHtmlRelativePath -ne 'targets/001-post/history/attributes/VIP_Post-Install_Custom_Action.vi-002-artifacts/compare-report.reviewer-anchors.html#comparevi-change-001-vi-attribute-miscellaneous') {
    throw 'Preview manifest should carry exact attribute-section links into the aggregate PR run.'
  }
  if ($previewManifest.indexPreviewCards.Count -ne 2 -or
    (@($previewManifest.indexPreviewCards[0].surfaces | ForEach-Object { [string]$_.surfaceKind }) -join ',') -ne 'front-panel,block-diagram') {
    throw 'Preview manifest should expose reviewer cards with both front-panel and block-diagram surfaces.'
  }

  $stepSummary = Get-Content -LiteralPath $receipt.outputs.publicStepSummaryPath -Raw
  if ($stepSummary -notmatch 'automatic pull request run' -or
    $stepSummary -notmatch 'Final status: `failed`' -or
    $stepSummary -notmatch 'Reviewer preview gallery: `2` history pairs shown, `0` omitted, cap `4`' -or
    $stepSummary -notmatch 'Raw preview surfaces collapsed for review: `4` raw -> `2` reviewer-canonical') {
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
