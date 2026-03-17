Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'Write-CompareVIHistoryPullRequestDiscovery.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('comparevi-history-pr-discovery-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
  $targetSpecPath = Join-Path $tempRoot 'comparevi-history-targets.json'
  @'
{
  "schema": "comparevi-history/consumer-targets@v1",
  "targets": [
    {
      "id": "vip-post-install",
      "path": "Tooling/deployment/VIP_Post-Install Custom Action.vi",
      "publicModes": ["attributes", "front-panel", "block-diagram"]
    },
    {
      "id": "vip-pre-install",
      "path": "Tooling/deployment/VIP_Pre-Install Custom Action.vi",
      "publicModes": ["attributes", "front-panel", "block-diagram"]
    }
  ]
}
'@ | Set-Content -LiteralPath $targetSpecPath -Encoding utf8

  $eventPath = Join-Path $tempRoot 'event.json'
  @'
{
  "pull_request": {
    "number": 42,
    "html_url": "https://github.com/example/repo/pull/42",
    "changed_files": 3,
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
'@ | Set-Content -LiteralPath $eventPath -Encoding utf8

  $filesPayloadPath = Join-Path $tempRoot 'files.json'
  @'
[
  {
    "filename": "Tooling/deployment/VIP_Post-Install Custom Action.vi",
    "status": "modified"
  },
  {
    "filename": "Tooling/deployment/VIP_Pre-Install Custom Action.vi",
    "previous_filename": "Tooling/deployment/VIP_Pre-Install Legacy.vi",
    "status": "renamed"
  },
  {
    "filename": "README.md",
    "status": "modified"
  }
]
'@ | Set-Content -LiteralPath $filesPayloadPath -Encoding utf8

  $outputPath = Join-Path $tempRoot 'discovery.out'
  $resultsDir = Join-Path $tempRoot 'results'
  $receiptJson = & $scriptPath `
    -EventName 'pull_request' `
    -EventPath $eventPath `
    -TargetSpecPath $targetSpecPath `
    -ResultsDir $resultsDir `
    -Repository 'LabVIEW-Community-CI-CD/labview-icon-editor-demo' `
    -FilesPayloadPath $filesPayloadPath `
    -GitHubOutputPath $outputPath

  $receipt = $receiptJson | ConvertFrom-Json -Depth 50
  if ($receipt.schema -ne 'comparevi-history/changed-vi-discovery@v1') {
    throw 'Discovery schema mismatch.'
  }
  if ($receipt.summary.executionStatus -ne 'ready') {
    throw 'Discovery should be ready for same-repo VI changes.'
  }
  if ($receipt.summary.changedViCount -ne 2) {
    throw 'Changed VI count mismatch.'
  }
  if ($receipt.summary.matchedTargetCount -ne 2) {
    throw 'Matched target count mismatch.'
  }
  if ($receipt.matchedTargets[1].matchKind -ne 'current-path') {
    throw 'Expected current-path match for renamed current target path.'
  }

  $outputText = Get-Content -LiteralPath $outputPath -Raw
  foreach ($requiredKey in @('changed-vi-discovery-path=', 'execution-status=ready', 'matched-target-count=2', 'pull-request-number=42')) {
    if ($outputText -notmatch [regex]::Escape($requiredKey)) {
      throw "Expected GitHub output '$requiredKey'."
    }
  }

  $forkEventPath = Join-Path $tempRoot 'fork-event.json'
  @'
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
'@ | Set-Content -LiteralPath $forkEventPath -Encoding utf8

  $forkReceiptJson = & $scriptPath `
    -EventName 'pull_request' `
    -EventPath $forkEventPath `
    -TargetSpecPath $targetSpecPath `
    -ResultsDir (Join-Path $tempRoot 'fork-results') `
    -Repository 'LabVIEW-Community-CI-CD/labview-icon-editor-demo' `
    -FilesPayloadPath $filesPayloadPath
  $forkReceipt = $forkReceiptJson | ConvertFrom-Json -Depth 50
  if ($forkReceipt.summary.executionStatus -ne 'blocked') {
    throw 'Fork pull request must be blocked.'
  }
  if ($forkReceipt.summary.executionReason -ne 'untrusted-cross-repository-pull-request') {
    throw 'Fork pull request block reason mismatch.'
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
