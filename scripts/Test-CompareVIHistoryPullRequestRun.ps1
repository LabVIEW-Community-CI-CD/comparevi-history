Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'Write-CompareVIHistoryPullRequestRun.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('comparevi-history-pr-run-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
  $resultsDir = Join-Path $tempRoot 'results'
  New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null

  $discoveryPath = Join-Path $resultsDir 'changed-vi-discovery.json'
  @'
{
  "schema": "comparevi-history/changed-vi-discovery@v1",
  "generatedAtUtc": "2026-03-17T00:00:00Z",
  "repository": "LabVIEW-Community-CI-CD/labview-icon-editor-demo",
  "eventName": "pull_request",
  "targetCatalog": {
    "schema": "comparevi-history/consumer-targets@v1",
    "path": "C:/repo/.github/comparevi-history-targets.json"
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
    }
  ],
  "matchedTargets": [
    {
      "targetId": "vip-post-install",
      "targetPath": "Tooling/deployment/VIP_Post-Install Custom Action.vi",
      "publicModes": ["attributes", "front-panel", "block-diagram"],
      "matchKind": "current-path",
      "currentPath": "Tooling/deployment/VIP_Post-Install Custom Action.vi",
      "previousPath": null,
      "changeStatus": "modified"
    }
  ],
  "summary": {
    "executionStatus": "ready",
    "executionReason": "matched-targets",
    "changedViCount": 1,
    "matchedTargetCount": 1
  }
}
'@ | Set-Content -LiteralPath $discoveryPath -Encoding utf8

  $manifestPath = Join-Path $resultsDir 'pr-target-runs-manifest.json'
  @'
{
  "schema": "comparevi-history/pr-target-runs-manifest@v1",
  "generatedAtUtc": "2026-03-17T00:01:00Z",
  "summary": {
    "matchedTargetCount": 1,
    "executedTargetCount": 1,
    "failedTargetCount": 0,
    "skippedTargetCount": 0,
    "executionStatus": "succeeded",
    "executionReason": "completed"
  },
  "targets": [
    {
      "targetId": "vip-post-install",
      "targetPath": "Tooling/deployment/VIP_Post-Install Custom Action.vi",
      "matchKind": "current-path",
      "finalStatus": "succeeded",
      "finalReason": "completed",
      "publicRunPath": "C:/results/targets/001-vip-post-install/history/public/public-run.json",
      "sharedEvidencePath": "C:/results/targets/001-vip-post-install/history/public/shared-evidence.json",
      "totalProcessed": 5,
      "totalDiffs": 2
    }
  ]
}
'@ | Set-Content -LiteralPath $manifestPath -Encoding utf8

  $outputPath = Join-Path $tempRoot 'pr-run.out'
  $receiptJson = & $scriptPath `
    -DiscoveryPath $discoveryPath `
    -ResultsDir $resultsDir `
    -TargetRunsManifestPath $manifestPath `
    -GitHubOutputPath $outputPath

  $receipt = $receiptJson | ConvertFrom-Json -Depth 64
  if ($receipt.schema -ne 'comparevi-history/pr-run@v1') {
    throw 'PR run schema mismatch.'
  }
  if ($receipt.summary.finalStatus -ne 'succeeded') {
    throw 'PR run final status mismatch.'
  }
  if ($receipt.summary.totalProcessed -ne 5) {
    throw 'PR run total processed mismatch.'
  }
  if (-not (Test-Path -LiteralPath $receipt.outputs.publicCommentPath -PathType Leaf)) {
    throw 'PR run comment body was not written.'
  }
  if (-not (Test-Path -LiteralPath $receipt.outputs.publicStepSummaryPath -PathType Leaf)) {
    throw 'PR run step summary was not written.'
  }

  $commentBody = Get-Content -LiteralPath $receipt.outputs.publicCommentPath -Raw
  if ($commentBody -notmatch 'comparevi-history PR diagnostics') {
    throw 'PR run comment body did not include the heading.'
  }

  $outputText = Get-Content -LiteralPath $outputPath -Raw
  foreach ($requiredKey in @('pr-run-path=', 'public-comment-path=', 'public-step-summary-path=', 'final-status=succeeded', 'final-reason=completed')) {
    if ($outputText -notmatch [regex]::Escape($requiredKey)) {
      throw "Expected GitHub output '$requiredKey'."
    }
  }

  $blockedDiscoveryPath = Join-Path $resultsDir 'blocked-discovery.json'
  @'
{
  "schema": "comparevi-history/changed-vi-discovery@v1",
  "generatedAtUtc": "2026-03-17T00:00:00Z",
  "repository": "LabVIEW-Community-CI-CD/labview-icon-editor-demo",
  "eventName": "pull_request",
  "targetCatalog": {
    "schema": "comparevi-history/consumer-targets@v1",
    "path": "C:/repo/.github/comparevi-history-targets.json"
  },
  "pullRequest": {
    "number": 23,
    "htmlUrl": null,
    "baseRepository": "LabVIEW-Community-CI-CD/labview-icon-editor-demo",
    "baseRef": "develop",
    "baseSha": "base-sha",
    "headRepository": "some-user/labview-icon-editor-demo",
    "headRef": "feature/from-fork",
    "headSha": "head-sha",
    "isFork": true,
    "changedFileCount": 1
  },
  "changedViFiles": [],
  "matchedTargets": [],
  "summary": {
    "executionStatus": "blocked",
    "executionReason": "untrusted-cross-repository-pull-request",
    "changedViCount": 0,
    "matchedTargetCount": 0
  }
}
'@ | Set-Content -LiteralPath $blockedDiscoveryPath -Encoding utf8

  $blockedReceiptJson = & $scriptPath `
    -DiscoveryPath $blockedDiscoveryPath `
    -ResultsDir (Join-Path $tempRoot 'blocked-results')
  $blockedReceipt = $blockedReceiptJson | ConvertFrom-Json -Depth 64
  if ($blockedReceipt.summary.finalStatus -ne 'blocked') {
    throw 'Blocked discovery should remain blocked in PR run receipt.'
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
