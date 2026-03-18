$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptPath = Join-Path $PSScriptRoot 'Invoke-CompareVIHistoryLocalProof.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('comparevi-history-local-proof-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
  $resultsDir = Join-Path $tempRoot 'results'
  $receipt = (& $scriptPath -ResultsDir $resultsDir) | ConvertFrom-Json -Depth 64

  if ([string]$receipt.schema -ne 'comparevi-history/local-proof@v1') {
    throw 'Local-proof receipt schema mismatch.'
  }
  if ([int]$receipt.summary.gateCount -ne 4 -or
    [int]$receipt.summary.passedGateCount -ne 4 -or
    [int]$receipt.summary.failedGateCount -ne 0 -or
    [string]$receipt.summary.finalStatus -ne 'succeeded' -or
    [string]$receipt.summary.finalReason -ne 'all-gates-succeeded') {
    throw 'Local-proof summary mismatch.'
  }

  foreach ($path in @(
      [string]$receipt.outputs.receiptPath,
      [string]$receipt.outputs.summaryPath,
      [string]$receipt.outputs.gateLogsDir
    )) {
    if (-not (Test-Path -LiteralPath $path)) {
      throw "Expected local-proof output path: $path"
    }
  }

  $expectedGateNames = @(
    'local-review',
    'review-bundle-golden',
    'reviewer-workspace-golden',
    'corpus-pilot-golden'
  )
  $actualGateNames = @($receipt.gates | ForEach-Object { [string]$_.name })
  if (($actualGateNames -join ',') -ne ($expectedGateNames -join ',')) {
    throw 'Local-proof gate ordering mismatch.'
  }

  foreach ($gate in @($receipt.gates)) {
    if ([string]$gate.status -ne 'succeeded') {
      throw "Local-proof gate should succeed: $($gate.name)"
    }
    if (-not (Test-Path -LiteralPath ([string]$gate.scriptPath) -PathType Leaf)) {
      throw "Local-proof gate script path is missing: $($gate.scriptPath)"
    }
    if (-not (Test-Path -LiteralPath ([string]$gate.logPath) -PathType Leaf)) {
      throw "Local-proof gate log path is missing: $($gate.logPath)"
    }
    if ([double]$gate.durationSeconds -lt 0) {
      throw "Local-proof gate duration must be non-negative: $($gate.name)"
    }
  }

  $summary = Get-Content -LiteralPath $receipt.outputs.summaryPath -Raw
  foreach ($requiredText in @(
      '# comparevi-history local proof',
      'local-review',
      'review-bundle-golden',
      'reviewer-workspace-golden',
      'corpus-pilot-golden',
      'Final status: `succeeded`',
      'Final reason: `all-gates-succeeded`'
    )) {
    if ($summary -notmatch [regex]::Escape($requiredText)) {
      throw "Local-proof summary is missing '$requiredText'."
    }
  }

  foreach ($fixturePath in @(
      [string]$receipt.fixtures.reviewBundleFixtureRoot,
      [string]$receipt.fixtures.reviewerWorkspaceFixtureRoot,
      [string]$receipt.fixtures.corpusPilotFixtureRoot
    )) {
    if (-not (Test-Path -LiteralPath $fixturePath -PathType Container)) {
      throw "Expected local-proof fixture root: $fixturePath"
    }
  }
}
finally {
  if ([string]::IsNullOrWhiteSpace($env:COMPAREVI_HISTORY_TEST_KEEP_TEMP) -and (Test-Path -LiteralPath $tempRoot)) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
  }
}
