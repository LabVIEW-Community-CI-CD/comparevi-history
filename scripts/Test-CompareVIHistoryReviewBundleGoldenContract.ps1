$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'CompareVIHistoryReviewBundleFixture.psm1') -Force

$repoRoot = Split-Path -Parent $PSScriptRoot
$fixtureRoot = Join-Path $repoRoot 'tests' 'fixtures' 'review-bundle-v1'
$fixtureReadmePath = Join-Path $fixtureRoot 'README.md'
$fixtureBundlePath = Join-Path $fixtureRoot 'review-bundle.json'
$scriptPath = Join-Path $PSScriptRoot 'Invoke-CompareVIHistoryReviewBundleCompiler.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('comparevi-history-review-bundle-golden-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

function ConvertTo-NormalizedReviewBundle {
  param(
    [Parameter(Mandatory = $true)]
    $Receipt
  )

  $normalized = $Receipt | ConvertTo-Json -Depth 100 | ConvertFrom-Json -Depth 100
  $normalized.generatedAtUtc = '__GENERATED_AT_UTC__'
  $normalized.targetRunsManifestPath = '__RESULTS_DIR__/pr-target-runs-manifest.json'
  $normalized.resultsDir = '__RESULTS_DIR__'
  return $normalized
}

try {
  if (-not (Test-Path -LiteralPath $fixtureReadmePath -PathType Leaf)) {
    throw 'Review bundle fixture README is missing.'
  }
  if (-not (Test-Path -LiteralPath $fixtureBundlePath -PathType Leaf)) {
    throw 'Review bundle fixture JSON is missing.'
  }

  $fixtureReadme = Get-Content -LiteralPath $fixtureReadmePath -Raw
  foreach ($requiredPattern in @(
      'canonical compiled review-bundle golden baseline',
      'pair-first instead of mode-first',
      'raw preview pairs remain available as debug evidence',
      'reviewer-canonical history pairs remain deterministic',
      'primary reviewer destinations remain pair-level'
    )) {
    if ($fixtureReadme -notmatch $requiredPattern) {
      throw "Review bundle fixture README is missing required contract text: $requiredPattern"
    }
  }

  $fixture = New-CompareVIHistorySyntheticReviewBundleFixture -RootPath $tempRoot
  $outputPath = Join-Path ([string]$fixture.resultsDir) 'review-bundle.json'
  $receiptJson = & $scriptPath `
    -TargetRunsManifestPath ([string]$fixture.targetRunsManifestPath) `
    -ResultsDir ([string]$fixture.resultsDir) `
    -OutputPath $outputPath
  $receipt = $receiptJson | ConvertFrom-Json -Depth 100

  $expectedBundle = Get-Content -LiteralPath $fixtureBundlePath -Raw | ConvertFrom-Json -Depth 100
  $actualBundle = ConvertTo-NormalizedReviewBundle -Receipt $receipt

  $expectedJson = $expectedBundle | ConvertTo-Json -Depth 100 -Compress
  $actualJson = $actualBundle | ConvertTo-Json -Depth 100 -Compress
  if ($actualJson -ne $expectedJson) {
    throw 'Compiled review bundle golden baseline drifted.'
  }
}
finally {
  if (Test-Path -LiteralPath $tempRoot) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
  }
}
