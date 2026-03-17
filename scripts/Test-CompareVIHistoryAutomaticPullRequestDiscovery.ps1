Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'Write-CompareVIHistoryAutomaticPullRequestDiscovery.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('comparevi-history-auto-pr-discovery-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
  $policyPath = Join-Path $tempRoot 'comparevi-history-pr-policy.json'
  @"
{
  "schema": "comparevi-history/pr-policy@v2",
  "discovery": {
    "selectionMode": "dynamic-paths",
    "includePaths": ["**/*.vi"],
    "excludePaths": ["Tooling/deployment/archive/**/*.vi"],
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
}
"@ | Set-Content -LiteralPath $policyPath -Encoding utf8

  $eventPath = Join-Path $tempRoot 'event.json'
  @"
{
  "pull_request": {
    "number": 42,
    "html_url": "https://github.com/LabVIEW-Community-CI-CD/labview-icon-editor-demo/pull/42",
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
    "previous_filename": "Tooling/deployment/VIP_Pre-Install Old.vi",
    "status": "renamed"
  },
  {
    "filename": "Tooling/deployment/Removed.vi",
    "status": "removed"
  },
  {
    "filename": "docs/README.md",
    "status": "modified"
  }
]
"@ | Set-Content -LiteralPath $filesPayloadPath -Encoding utf8

  $outputPath = Join-Path $tempRoot 'outputs.txt'
  $resultsDir = Join-Path $tempRoot 'results'
  $receiptJson = & $scriptPath `
    -EventName 'pull_request' `
    -EventPath $eventPath `
    -PrPolicyPath $policyPath `
    -ResultsDir $resultsDir `
    -Repository 'LabVIEW-Community-CI-CD/labview-icon-editor-demo' `
    -FilesPayloadPath $filesPayloadPath `
    -GitHubOutputPath $outputPath

  $receipt = $receiptJson | ConvertFrom-Json -Depth 64
  if ($receipt.schema -ne 'comparevi-history/changed-vi-discovery@v2') {
    throw 'Discovery schema mismatch.'
  }
  if ($receipt.summary.executionStatus -ne 'ready' -or $receipt.summary.executionReason -ne 'selected-targets') {
    throw 'Discovery should stay ready for dynamic-path targets within policy limits.'
  }
  if ($receipt.summary.changedViCount -ne 3) {
    throw 'Changed VI count mismatch.'
  }
  if ($receipt.summary.eligibleChangedViCount -ne 3) {
    throw 'Eligible changed VI count mismatch.'
  }
  if ($receipt.summary.selectedTargetCount -ne 2) {
    throw 'Selected target count mismatch.'
  }
  if ($receipt.summary.excludedViCount -ne 1) {
    throw 'Excluded VI count mismatch.'
  }
  if ($receipt.summary.overflowed -ne $false -or $receipt.summary.overflowChangedViCount -ne 0) {
    throw 'Unexpected overflow state for the happy-path discovery receipt.'
  }
  if ($receipt.executionContext.selectionMode -ne 'dynamic-paths' -or
    $receipt.executionContext.forkBehavior -ne 'hosted-auto' -or
    $receipt.executionContext.fullSurface -ne 'artifact-index') {
    throw 'Execution context mismatch.'
  }

  $selectedTargets = @($receipt.selectedTargets | Sort-Object { [string]$_.targetPath })
  if ((@($selectedTargets | Where-Object { [string]$_.targetSource -ne 'dynamic-path' })).Count -ne 0) {
    throw 'All selected targets should be tagged as dynamic-path targets.'
  }
  if ((@($selectedTargets | Where-Object { [string]$_.requestedModeSource -ne 'pr-policy' })).Count -ne 0) {
    throw 'All selected targets should record the PR policy as the requested mode source.'
  }
  if ((@($selectedTargets | Where-Object { [string]$_.history.branchBudget.source -ne 'pull-request-base' })).Count -ne 0) {
    throw 'Selected targets should resolve sourceBranchRef through the pull-request base strategy.'
  }
  if ((@($selectedTargets | Where-Object { [string]$_.history.branchBudget.sourceBranchRef -ne 'develop' })).Count -ne 0) {
    throw 'Selected targets should carry the pull-request base ref as sourceBranchRef.'
  }
  if ((@($selectedTargets | Where-Object { $_.keepArtifactsOnNoDiff -ne $true })).Count -ne 0) {
    throw 'Selected targets should preserve keepArtifactsOnNoDiff from the PR policy.'
  }

  $firstTargetId = [string]$selectedTargets[0].targetId
  if ($firstTargetId -notmatch '^dynamic-[a-z0-9-]+-[a-f0-9]{12}$') {
    throw 'Synthetic target id format mismatch.'
  }

  $secondResultsDir = Join-Path $tempRoot 'results-repeat'
  $repeatJson = & $scriptPath `
    -EventName 'pull_request' `
    -EventPath $eventPath `
    -PrPolicyPath $policyPath `
    -ResultsDir $secondResultsDir `
    -Repository 'LabVIEW-Community-CI-CD/labview-icon-editor-demo' `
    -FilesPayloadPath $filesPayloadPath
  $repeatReceipt = $repeatJson | ConvertFrom-Json -Depth 64
  $repeatTarget = @($repeatReceipt.selectedTargets | Where-Object { [string]$_.targetPath -eq [string]$selectedTargets[0].targetPath } | Select-Object -First 1)
  if ($null -eq $repeatTarget -or [string]$repeatTarget.targetId -ne $firstTargetId) {
    throw 'Synthetic target ids must stay deterministic for a normalized target path.'
  }

  $deletedEntry = @($receipt.excludedViFiles | Where-Object { [string]$_.currentPath -eq 'Tooling/deployment/Removed.vi' } | Select-Object -First 1)
  if ($null -eq $deletedEntry -or [string]$deletedEntry.exclusionReason -ne 'deleted-vi-not-executable') {
    throw 'Removed VI entries must be excluded with the deleted-vi-not-executable reason.'
  }

  $outputText = (Get-Content -LiteralPath $outputPath -Raw) -replace '^\uFEFF', ''
  foreach ($requiredKey in @(
      'changed-vi-count=3',
      'eligible-changed-vi-count=3',
      'selected-target-count=2',
      'execution-status=ready',
      'execution-reason=selected-targets',
      'base-ref=develop',
      'pull-request-number=42'
    )) {
    if ($outputText -notmatch [regex]::Escape($requiredKey)) {
      throw "Expected GitHub output '$requiredKey'."
    }
  }

  $overflowEventPath = Join-Path $tempRoot 'overflow-event.json'
  @"
{
  "pull_request": {
    "number": 77,
    "changed_files": 11,
    "base": {
      "ref": "release/2026-q1",
      "sha": "base-sha",
      "repo": {
        "full_name": "LabVIEW-Community-CI-CD/labview-icon-editor-demo"
      }
    },
    "head": {
      "ref": "feature/big-pr",
      "sha": "head-sha",
      "repo": {
        "full_name": "some-user/labview-icon-editor-demo",
        "fork": true
      }
    }
  }
}
"@ | Set-Content -LiteralPath $overflowEventPath -Encoding utf8

  $overflowFilesPath = Join-Path $tempRoot 'overflow-files.json'
  $overflowFiles = New-Object System.Collections.Generic.List[object]
  for ($index = 1; $index -le 11; $index++) {
    $overflowFiles.Add([ordered]@{
        filename = ('Tooling/deployment/Generated-{0:d2}.vi' -f $index)
        status = 'modified'
      }) | Out-Null
  }
  $overflowFiles | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $overflowFilesPath -Encoding utf8

  $overflowJson = & $scriptPath `
    -EventName 'pull_request' `
    -EventPath $overflowEventPath `
    -PrPolicyPath $policyPath `
    -ResultsDir (Join-Path $tempRoot 'overflow-results') `
    -Repository 'LabVIEW-Community-CI-CD/labview-icon-editor-demo' `
    -FilesPayloadPath $overflowFilesPath
  $overflowReceipt = $overflowJson | ConvertFrom-Json -Depth 64
  if ($overflowReceipt.summary.executionStatus -ne 'blocked' -or
    $overflowReceipt.summary.executionReason -ne 'max-changed-vi-count-exceeded') {
    throw 'Overflow discovery should fail closed when more than ten VI paths are selected.'
  }
  if ($overflowReceipt.summary.overflowed -ne $true -or $overflowReceipt.summary.overflowChangedViCount -ne 1) {
    throw 'Overflow discovery count mismatch.'
  }

  $forkFilesPath = Join-Path $tempRoot 'fork-files.json'
  @"
[
  {
    "filename": "Tooling/deployment/VIP_Post-Install Custom Action.vi",
    "status": "modified"
  }
]
"@ | Set-Content -LiteralPath $forkFilesPath -Encoding utf8

  $forkJson = & $scriptPath `
    -EventName 'pull_request' `
    -EventPath $overflowEventPath `
    -PrPolicyPath $policyPath `
    -ResultsDir (Join-Path $tempRoot 'fork-results') `
    -Repository 'LabVIEW-Community-CI-CD/labview-icon-editor-demo' `
    -FilesPayloadPath $forkFilesPath
  $forkReceipt = $forkJson | ConvertFrom-Json -Depth 64
  if ($forkReceipt.pullRequest.isFork -ne $true -or $forkReceipt.summary.executionStatus -ne 'ready') {
    throw 'Fork pull requests should stay eligible for hosted-auto execution in v2.'
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
