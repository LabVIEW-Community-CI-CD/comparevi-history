Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'Write-CompareVIHistoryAutomaticPullRequestRun.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('comparevi-history-auto-pr-run-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

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

  $indexMarkdown = Get-Content -LiteralPath $receipt.outputs.indexMarkdownPath -Raw
  foreach ($requiredText in @(
      '[changed-vi-discovery.json](changed-vi-discovery.json)',
      '[pr-run.json](pr-run.json)',
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

  $stepSummary = Get-Content -LiteralPath $receipt.outputs.publicStepSummaryPath -Raw
  if ($stepSummary -notmatch 'automatic pull request run' -or $stepSummary -notmatch 'Final status: `failed`') {
    throw 'Public step summary content mismatch.'
  }

  $outputText = Get-Content -LiteralPath $outputPath -Raw
  foreach ($requiredKey in @(
      'pr-run-path=',
      'public-comment-path=',
      'public-step-summary-path=',
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
