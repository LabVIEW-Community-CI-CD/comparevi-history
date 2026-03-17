Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'Write-CompareVIHistoryPullRequestRun.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('comparevi-history-pr-run-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
  $resultsDir = Join-Path $tempRoot 'results'
  New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null

  $discoveryPath = Join-Path $resultsDir 'changed-vi-discovery.json'
  @"
{
  "schema": "comparevi-history/changed-vi-discovery@v1",
  "generatedAtUtc": "2026-03-17T00:00:00Z",
  "repository": "LabVIEW-Community-CI-CD/labview-icon-editor-demo",
  "eventName": "pull_request",
  "targetCatalog": {
    "schema": "comparevi-history/consumer-targets@v1",
    "path": "C:/repo/.github/comparevi-history-targets.json"
  },
  "prPolicy": {
    "schema": "comparevi-history/pr-policy@v1",
    "path": "C:/repo/.github/comparevi-history-pr-policy.json",
    "applied": true,
    "discovery": {
      "includePaths": ["Tooling/deployment/**/*.vi"],
      "excludePaths": [],
      "allowedTargetIds": ["vip-post-install"],
      "maxChangedViCount": 4,
      "unmatchedChangedViBehavior": "ignore"
    },
    "execution": {
      "publicModes": ["attributes", "front-panel"],
      "history": {
        "branchBudget": {
          "sourceBranchRef": "develop",
          "maxCommitCount": 25
        },
        "keepArtifactsOnNoDiff": true
      }
    },
    "reviewerSurface": {
      "emitCommentBody": false,
      "emitStepSummary": true
    },
    "trust": {
      "forkBehavior": "block"
    }
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
  "excludedViFiles": [
    {
      "status": "modified",
      "currentPath": "Tooling/deployment/VIP_Pre-Install Custom Action.vi",
      "previousPath": null,
      "exclusionReason": "target-id-not-allowed"
    }
  ],
  "matchedTargets": [
    {
      "targetId": "vip-post-install",
      "targetPath": "Tooling/deployment/VIP_Post-Install Custom Action.vi",
      "publicModes": ["attributes", "front-panel", "block-diagram"],
      "requestedModes": ["attributes", "front-panel"],
      "requestedModeSource": "pr-policy",
      "history": {
        "branchBudget": {
          "sourceBranchRef": "develop",
          "maxCommitCount": 25,
          "source": "pr-policy"
        }
      },
      "keepArtifactsOnNoDiff": true,
      "matchKind": "current-path",
      "currentPath": "Tooling/deployment/VIP_Post-Install Custom Action.vi",
      "previousPath": null,
      "changeStatus": "modified"
    }
  ],
  "summary": {
    "executionStatus": "ready",
    "executionReason": "matched-targets",
    "changedViCount": 2,
    "eligibleChangedViCount": 2,
    "excludedViCount": 1,
    "unmatchedViCount": 1,
    "matchedTargetCount": 1
  }
}
"@ | Set-Content -LiteralPath $discoveryPath -Encoding utf8

  $manifestPath = Join-Path $resultsDir 'pr-target-runs-manifest.json'
  @"
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
      "requestedModes": ["attributes", "front-panel"],
      "requestedModeSource": "pr-policy",
      "sourceBranchRef": "develop",
      "maxBranchCommits": 25,
      "keepArtifactsOnNoDiff": true,
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
"@ | Set-Content -LiteralPath $manifestPath -Encoding utf8

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
  if ($receipt.summary.excludedViCount -ne 1 -or $receipt.summary.unmatchedViCount -ne 1) {
    throw 'PR run policy counts mismatch.'
  }
  if ($null -ne $receipt.outputs.publicCommentPath) {
    throw 'PR policy should disable the reviewer comment body output.'
  }
  if (-not (Test-Path -LiteralPath $receipt.outputs.publicStepSummaryPath -PathType Leaf)) {
    throw 'PR run step summary was not written.'
  }
  if ($receipt.targets[0].keepArtifactsOnNoDiff -ne $true) {
    throw 'PR run receipt did not retain keep-artifacts policy.'
  }
  if (($receipt.targets[0].requestedModes -join ',') -ne 'attributes,front-panel') {
    throw 'PR run receipt did not preserve requested modes.'
  }

  $stepSummary = Get-Content -LiteralPath $receipt.outputs.publicStepSummaryPath -Raw
  if ($stepSummary -notmatch 'Excluded VI files') {
    throw 'PR run step summary did not include the excluded VI section.'
  }

  $outputText = Get-Content -LiteralPath $outputPath -Raw
  foreach ($requiredKey in @('pr-run-path=', 'public-comment-path=', 'public-step-summary-path=', 'final-status=succeeded', 'final-reason=completed')) {
    if ($outputText -notmatch [regex]::Escape($requiredKey)) {
      throw "Expected GitHub output '$requiredKey'."
    }
  }

  $blockedDiscoveryPath = Join-Path $resultsDir 'blocked-discovery.json'
  @"
{
  "schema": "comparevi-history/changed-vi-discovery@v1",
  "generatedAtUtc": "2026-03-17T00:00:00Z",
  "repository": "LabVIEW-Community-CI-CD/labview-icon-editor-demo",
  "eventName": "pull_request",
  "targetCatalog": {
    "schema": "comparevi-history/consumer-targets@v1",
    "path": "C:/repo/.github/comparevi-history-targets.json"
  },
  "prPolicy": {
    "schema": "comparevi-history/pr-policy@v1",
    "path": null,
    "applied": false,
    "discovery": {
      "includePaths": [],
      "excludePaths": [],
      "allowedTargetIds": [],
      "maxChangedViCount": null,
      "unmatchedChangedViBehavior": "ignore"
    },
    "execution": {
      "publicModes": [],
      "history": {
        "branchBudget": {
          "sourceBranchRef": null,
          "maxCommitCount": null
        },
        "keepArtifactsOnNoDiff": false
      }
    },
    "reviewerSurface": {
      "emitCommentBody": true,
      "emitStepSummary": true
    },
    "trust": {
      "forkBehavior": "block"
    }
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
  "excludedViFiles": [],
  "matchedTargets": [],
  "summary": {
    "executionStatus": "blocked",
    "executionReason": "untrusted-cross-repository-pull-request",
    "changedViCount": 0,
    "eligibleChangedViCount": 0,
    "excludedViCount": 0,
    "unmatchedViCount": 0,
    "matchedTargetCount": 0
  }
}
"@ | Set-Content -LiteralPath $blockedDiscoveryPath -Encoding utf8

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
