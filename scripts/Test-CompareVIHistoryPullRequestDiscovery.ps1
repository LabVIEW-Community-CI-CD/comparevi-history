Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'Write-CompareVIHistoryPullRequestDiscovery.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('comparevi-history-pr-discovery-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
  $targetSpecPath = Join-Path $tempRoot 'comparevi-history-targets.json'
  @"
{
  "schema": "comparevi-history/consumer-targets@v1",
  "targets": [
    {
      "id": "vip-post-install",
      "path": "Tooling/deployment/VIP_Post-Install Custom Action.vi",
      "publicModes": ["attributes", "front-panel", "block-diagram"],
      "history": {
        "branchBudget": {
          "sourceBranchRef": "release/2026-q1",
          "maxCommitCount": 15
        }
      }
    },
    {
      "id": "vip-pre-install",
      "path": "Tooling/deployment/VIP_Pre-Install Custom Action.vi",
      "publicModes": ["attributes", "front-panel", "block-diagram"]
    }
  ]
}
"@ | Set-Content -LiteralPath $targetSpecPath -Encoding utf8

  $prPolicyPath = Join-Path $tempRoot 'comparevi-history-pr-policy.json'
  @"
{
  "schema": "comparevi-history/pr-policy@v1",
  "discovery": {
    "includePaths": [
      "Tooling/deployment/**/*.vi"
    ],
    "excludePaths": [
      "Tooling/deployment/archive/**/*.vi"
    ],
    "allowedTargetIds": [
      "vip-post-install"
    ],
    "maxChangedViCount": 2,
    "unmatchedChangedViBehavior": "ignore"
  },
  "execution": {
    "publicModes": [
      "attributes",
      "front-panel"
    ],
    "history": {
      "branchBudget": {
        "sourceBranchRef": "develop",
        "maxCommitCount": 50
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
}
"@ | Set-Content -LiteralPath $prPolicyPath -Encoding utf8

  $eventPath = Join-Path $tempRoot 'event.json'
  @"
{
  "pull_request": {
    "number": 42,
    "html_url": "https://github.com/example/repo/pull/42",
    "changed_files": 4,
    "base": {
      "ref": "develop",
      "sha": "base-sha",
      "repo": {
        "full_name": "LabVIEW-Community-CI-CD/labview-icon-editor-demo"
      }
    },
    "head": {
      "ref": "feature/history",
      "sha": "head-sha",
      "repo": {
        "full_name": "LabVIEW-Community-CI-CD/labview-icon-editor-demo",
        "fork": false
      }
    }
  }
}
"@ | Set-Content -LiteralPath $eventPath -Encoding utf8

  $filesPayloadPath = Join-Path $tempRoot 'files.json'
  @"
[
  {
    "filename": "Tooling/deployment/VIP_Post-Install Custom Action.vi",
    "status": "modified"
  },
  {
    "filename": "Tooling/deployment/VIP_Pre-Install Custom Action.vi",
    "status": "modified"
  },
  {
    "filename": "Tooling/deployment/archive/Legacy.vi",
    "status": "modified"
  },
  {
    "filename": "README.md",
    "status": "modified"
  }
]
"@ | Set-Content -LiteralPath $filesPayloadPath -Encoding utf8

  $outputPath = Join-Path $tempRoot 'discovery.out'
  $resultsDir = Join-Path $tempRoot 'results'
  $receiptJson = & $scriptPath `
    -EventName 'pull_request' `
    -EventPath $eventPath `
    -TargetSpecPath $targetSpecPath `
    -PrPolicyPath $prPolicyPath `
    -ResultsDir $resultsDir `
    -Repository 'LabVIEW-Community-CI-CD/labview-icon-editor-demo' `
    -FilesPayloadPath $filesPayloadPath `
    -GitHubOutputPath $outputPath

  $receipt = $receiptJson | ConvertFrom-Json -Depth 64
  if ($receipt.schema -ne 'comparevi-history/changed-vi-discovery@v1') {
    throw 'Discovery schema mismatch.'
  }
  if (-not $receipt.prPolicy.applied) {
    throw 'Discovery should record the applied PR policy.'
  }
  if ($receipt.summary.executionStatus -ne 'ready') {
    throw 'Discovery should stay ready for same-repo VI changes within policy limits.'
  }
  if ($receipt.summary.changedViCount -ne 3) {
    throw 'Changed VI count mismatch.'
  }
  if ($receipt.summary.eligibleChangedViCount -ne 2) {
    throw 'Policy-eligible changed VI count mismatch.'
  }
  if ($receipt.summary.excludedViCount -ne 2) {
    throw 'Excluded VI count mismatch.'
  }
  if ($receipt.summary.unmatchedViCount -ne 1) {
    throw 'Unmatched VI count mismatch.'
  }
  if ($receipt.summary.matchedTargetCount -ne 1) {
    throw 'Matched target count mismatch.'
  }
  if ($receipt.matchedTargets[0].requestedModes.Count -ne 2) {
    throw 'Discovery should narrow requested modes through PR policy.'
  }
  if ($receipt.matchedTargets[0].requestedModes[0] -ne 'attributes' -or $receipt.matchedTargets[0].requestedModes[1] -ne 'front-panel') {
    throw 'Requested modes order mismatch.'
  }
  if ($receipt.matchedTargets[0].history.branchBudget.source -ne 'pr-policy') {
    throw 'Branch budget source mismatch.'
  }
  if ($receipt.matchedTargets[0].history.branchBudget.sourceBranchRef -ne 'develop') {
    throw 'Policy branch-budget source branch mismatch.'
  }
  if ($receipt.matchedTargets[0].keepArtifactsOnNoDiff -ne $true) {
    throw 'PR policy keepArtifactsOnNoDiff was not surfaced.'
  }
  if ($receipt.executionContext.trustedForkExecutionRequested -ne $false -or
    $receipt.executionContext.trustedForkExecutionEligible -ne $false -or
    $receipt.executionContext.trustedForkExecutionApplied -ne $false) {
    throw 'Same-repo discovery should not mark trusted fork execution state.'
  }
  if (-not ($receipt.excludedViFiles | Where-Object { $_.currentPath -eq 'Tooling/deployment/VIP_Pre-Install Custom Action.vi' -and $_.exclusionReason -eq 'target-id-not-allowed' })) {
    throw 'Expected target-id exclusion for the pre-install VI.'
  }
  if (-not ($receipt.excludedViFiles | Where-Object { $_.currentPath -eq 'Tooling/deployment/archive/Legacy.vi' -and $_.exclusionReason -eq 'excluded-by-pr-policy' })) {
    throw 'Expected archive exclusion from the PR policy.'
  }

  $outputText = Get-Content -LiteralPath $outputPath -Raw
  foreach ($requiredKey in @('pr-policy-applied=true', 'eligible-changed-vi-count=2', 'excluded-vi-count=2', 'matched-target-count=1', 'pull-request-number=42')) {
    if ($outputText -notmatch [regex]::Escape($requiredKey)) {
      throw "Expected GitHub output '$requiredKey'."
    }
  }

  $strictPolicyPath = Join-Path $tempRoot 'strict-pr-policy.json'
  @"
{
  "schema": "comparevi-history/pr-policy@v1",
  "discovery": {
    "includePaths": [
      "Tooling/deployment/**/*.vi"
    ],
    "maxChangedViCount": 1,
    "unmatchedChangedViBehavior": "block"
  },
  "trust": {
    "forkBehavior": "block"
  }
}
"@ | Set-Content -LiteralPath $strictPolicyPath -Encoding utf8

  $strictReceiptJson = & $scriptPath `
    -EventName 'pull_request' `
    -EventPath $eventPath `
    -TargetSpecPath $targetSpecPath `
    -PrPolicyPath $strictPolicyPath `
    -ResultsDir (Join-Path $tempRoot 'strict-results') `
    -Repository 'LabVIEW-Community-CI-CD/labview-icon-editor-demo' `
    -FilesPayloadPath $filesPayloadPath
  $strictReceipt = $strictReceiptJson | ConvertFrom-Json -Depth 64
  if ($strictReceipt.summary.executionStatus -ne 'blocked') {
    throw 'Strict PR policy should block oversized changed-VI sets.'
  }
  if ($strictReceipt.summary.executionReason -ne 'max-changed-vi-count-exceeded') {
    throw 'Strict PR policy block reason mismatch.'
  }

  $forkEventPath = Join-Path $tempRoot 'fork-event.json'
  @"
{
  "pull_request": {
    "number": 7,
    "changed_files": 1,
    "base": {
      "ref": "develop",
      "sha": "base-sha",
      "repo": {
        "full_name": "LabVIEW-Community-CI-CD/labview-icon-editor-demo"
      }
    },
    "head": {
      "ref": "feature/from-fork",
      "sha": "fork-sha",
      "repo": {
        "full_name": "some-user/labview-icon-editor-demo",
        "fork": true
      }
    }
  }
}
"@ | Set-Content -LiteralPath $forkEventPath -Encoding utf8

  $forkReceiptJson = & $scriptPath `
    -EventName 'pull_request' `
    -EventPath $forkEventPath `
    -TargetSpecPath $targetSpecPath `
    -PrPolicyPath $prPolicyPath `
    -ResultsDir (Join-Path $tempRoot 'fork-results') `
    -Repository 'LabVIEW-Community-CI-CD/labview-icon-editor-demo' `
    -FilesPayloadPath $filesPayloadPath
  $forkReceipt = $forkReceiptJson | ConvertFrom-Json -Depth 64
  if ($forkReceipt.summary.executionStatus -ne 'blocked') {
    throw 'Fork pull request must be blocked.'
  }
  if ($forkReceipt.summary.executionReason -ne 'untrusted-cross-repository-pull-request') {
    throw 'Fork pull request block reason mismatch.'
  }

  $maintainerForkPolicyPath = Join-Path $tempRoot 'maintainer-fork-pr-policy.json'
  @"
{
  "schema": "comparevi-history/pr-policy@v1",
  "discovery": {
    "includePaths": [
      "Tooling/deployment/**/*.vi"
    ]
  },
  "trust": {
    "forkBehavior": "maintainer-dispatch"
  }
}
"@ | Set-Content -LiteralPath $maintainerForkPolicyPath -Encoding utf8

  $fallbackRequiredJson = & $scriptPath `
    -EventName 'pull_request_target' `
    -EventPath $forkEventPath `
    -TargetSpecPath $targetSpecPath `
    -PrPolicyPath $maintainerForkPolicyPath `
    -ResultsDir (Join-Path $tempRoot 'fallback-required-results') `
    -Repository 'LabVIEW-Community-CI-CD/labview-icon-editor-demo' `
    -FilesPayloadPath $filesPayloadPath
  $fallbackRequiredReceipt = $fallbackRequiredJson | ConvertFrom-Json -Depth 64
  if ($fallbackRequiredReceipt.summary.executionStatus -ne 'blocked') {
    throw 'Fork PR should stay blocked until trusted fallback is explicitly requested.'
  }
  if ($fallbackRequiredReceipt.summary.executionReason -ne 'trusted-fork-fallback-required') {
    throw 'Trusted fork fallback block reason mismatch.'
  }
  if ($fallbackRequiredReceipt.executionContext.trustedForkExecutionEligible -ne $true -or
    $fallbackRequiredReceipt.executionContext.trustedForkExecutionRequested -ne $false -or
    $fallbackRequiredReceipt.executionContext.trustedForkExecutionApplied -ne $false) {
    throw 'Fallback-required discovery execution context mismatch.'
  }

  $fallbackAppliedJson = & $scriptPath `
    -EventName 'pull_request_target' `
    -EventPath $forkEventPath `
    -TargetSpecPath $targetSpecPath `
    -PrPolicyPath $maintainerForkPolicyPath `
    -AllowTrustedForkExecution $true `
    -ResultsDir (Join-Path $tempRoot 'fallback-applied-results') `
    -Repository 'LabVIEW-Community-CI-CD/labview-icon-editor-demo' `
    -FilesPayloadPath $filesPayloadPath
  $fallbackAppliedReceipt = $fallbackAppliedJson | ConvertFrom-Json -Depth 64
  if ($fallbackAppliedReceipt.summary.executionStatus -ne 'ready') {
    throw 'Trusted fallback should allow the fork PR discovery to proceed.'
  }
  if ($fallbackAppliedReceipt.executionContext.trustedForkExecutionEligible -ne $true -or
    $fallbackAppliedReceipt.executionContext.trustedForkExecutionRequested -ne $true -or
    $fallbackAppliedReceipt.executionContext.trustedForkExecutionApplied -ne $true) {
    throw 'Trusted fallback applied execution context mismatch.'
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
