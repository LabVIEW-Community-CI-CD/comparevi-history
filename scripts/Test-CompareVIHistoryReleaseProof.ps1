$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptPath = Join-Path $PSScriptRoot 'Invoke-CompareVIHistoryReleaseProof.ps1'
$artifactScriptPath = Join-Path $PSScriptRoot 'Publish-CompareVIHistoryReviewCompilerArtifact.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('comparevi-history-release-proof-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
  $scriptContent = Get-Content -LiteralPath $scriptPath -Raw
  foreach ($requiredText in @(
      'set -eu',
      'cp -R /compiler/. /tmp/comparevi-history-review-compiler/',
      'chmod +x /tmp/comparevi-history-review-compiler/'
    )) {
    if ($scriptContent -notmatch [regex]::Escape($requiredText)) {
      throw "Release-proof docker shim is missing '$requiredText'."
    }
  }

  $runtimeIdentifier = if ($IsWindows) {
    'win-x64'
  } elseif ($IsLinux) {
    'linux-x64'
  } else {
    throw 'Release-proof test currently supports Windows and Linux only.'
  }

  $releaseAssetsDir = Join-Path $tempRoot 'release-assets'
  $null = & $artifactScriptPath -Version 'v9.9.9' -OutputDir $releaseAssetsDir -RuntimeIdentifiers @($runtimeIdentifier)

  $invokerStubPath = Join-Path $tempRoot 'Invoke-ReleaseProofContainer.stub.ps1'
@'
param(
  [string]$ContainerImage,
  [string]$CompilerExecutablePath,
  [string]$TargetRunsManifestPath,
  [string]$ResultsDir,
  [string]$OutputPath,
  [string]$RuntimeIdentifier,
  [string]$LogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($RuntimeIdentifier -ne 'win-x64' -and $RuntimeIdentifier -ne 'linux-x64') {
  throw "Unexpected runtime identifier in stub: $RuntimeIdentifier"
}

if ([string]::IsNullOrWhiteSpace($env:COMPAREVI_HISTORY_RELEASE_PROOF_EXPECTED_BUNDLE_PATH)) {
  throw 'COMPAREVI_HISTORY_RELEASE_PROOF_EXPECTED_BUNDLE_PATH must be set for the release-proof stub.'
}

if (-not (Test-Path -LiteralPath $env:COMPAREVI_HISTORY_RELEASE_PROOF_EXPECTED_BUNDLE_PATH -PathType Leaf)) {
  throw "Expected bundle fixture was not found: $env:COMPAREVI_HISTORY_RELEASE_PROOF_EXPECTED_BUNDLE_PATH"
}

@(
  "container-image=$ContainerImage"
  "compiler-executable-path=$CompilerExecutablePath"
  "target-runs-manifest-path=$TargetRunsManifestPath"
  "output-path=$OutputPath"
) | Set-Content -LiteralPath $LogPath -Encoding utf8

Copy-Item -LiteralPath $env:COMPAREVI_HISTORY_RELEASE_PROOF_EXPECTED_BUNDLE_PATH -Destination $OutputPath -Force
'@ | Set-Content -LiteralPath $invokerStubPath -Encoding utf8

  $resultsDir = Join-Path $tempRoot 'results-success'
  $expectedBundlePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'tests' 'fixtures' 'review-bundle-v1' 'review-bundle.json'
  $previousExpectedBundlePath = $env:COMPAREVI_HISTORY_RELEASE_PROOF_EXPECTED_BUNDLE_PATH
  $env:COMPAREVI_HISTORY_RELEASE_PROOF_EXPECTED_BUNDLE_PATH = $expectedBundlePath
  try {
    $receipt = (& $scriptPath `
        -Version 'v9.9.9' `
        -ReleaseAssetsDir $releaseAssetsDir `
        -RuntimeIdentifier $runtimeIdentifier `
        -ContainerImage 'fake/runtime:latest' `
        -ContainerInvokerScriptPath $invokerStubPath `
        -SkipImagePull `
        -ResultsDir $resultsDir) | ConvertFrom-Json -Depth 64
  } finally {
    if ($null -eq $previousExpectedBundlePath) {
      Remove-Item Env:COMPAREVI_HISTORY_RELEASE_PROOF_EXPECTED_BUNDLE_PATH -ErrorAction SilentlyContinue
    } else {
      $env:COMPAREVI_HISTORY_RELEASE_PROOF_EXPECTED_BUNDLE_PATH = $previousExpectedBundlePath
    }
  }

  if ([string]$receipt.schema -ne 'comparevi-history/release-proof@v1') {
    throw 'Release-proof receipt schema mismatch.'
  }
  if ([string]$receipt.summary.finalStatus -ne 'succeeded' -or
    [string]$receipt.summary.finalReason -ne 'release-proof-succeeded' -or
    [bool]$receipt.summary.goldenBaselineMatched -ne $true) {
    throw 'Release-proof success summary mismatch.'
  }
  if ([string]$receipt.runtime.containerExecutionKind -ne 'script-override' -or
    [string]$receipt.runtime.containerImage -ne 'fake/runtime:latest' -or
    [string]$receipt.runtime.runtimeIdentifier -ne $runtimeIdentifier) {
    throw 'Release-proof runtime receipt mismatch.'
  }
  if ([string]$receipt.releaseAssets.selectedAsset.runtimeIdentifier -ne $runtimeIdentifier -or
    [string]$receipt.releaseAssets.selectedAsset.fileName -notmatch 'comparevi-history-review-compiler-v9\.9\.9-') {
    throw 'Release-proof selected asset mismatch.'
  }

  foreach ($path in @(
      [string]$receipt.outputs.receiptPath,
      [string]$receipt.outputs.summaryPath,
      [string]$receipt.outputs.logPath,
      [string]$receipt.fixture.outputBundlePath
    )) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "Expected release-proof output path: $path"
    }
  }

  $summary = Get-Content -LiteralPath $receipt.outputs.summaryPath -Raw
  foreach ($requiredText in @(
      '# comparevi-history release proof',
      'Final status: `succeeded`',
      'Final reason: `release-proof-succeeded`',
      'fake/runtime:latest'
    )) {
    if ($summary -notmatch [regex]::Escape($requiredText)) {
      throw "Release-proof summary is missing '$requiredText'."
    }
  }

  $failed = $false
  $failureResultsDir = Join-Path $tempRoot 'results-failure'
  try {
    $previousExpectedBundlePath = $env:COMPAREVI_HISTORY_RELEASE_PROOF_EXPECTED_BUNDLE_PATH
    $env:COMPAREVI_HISTORY_RELEASE_PROOF_EXPECTED_BUNDLE_PATH = $expectedBundlePath
    try {
      & $scriptPath `
        -Version 'v9.9.9' `
        -ReleaseAssetsDir $releaseAssetsDir `
        -RuntimeIdentifier 'linux-arm64' `
        -ContainerImage 'fake/runtime:latest' `
        -ContainerInvokerScriptPath $invokerStubPath `
        -SkipImagePull `
        -ResultsDir $failureResultsDir | Out-Null
    } finally {
      if ($null -eq $previousExpectedBundlePath) {
        Remove-Item Env:COMPAREVI_HISTORY_RELEASE_PROOF_EXPECTED_BUNDLE_PATH -ErrorAction SilentlyContinue
      } else {
        $env:COMPAREVI_HISTORY_RELEASE_PROOF_EXPECTED_BUNDLE_PATH = $previousExpectedBundlePath
      }
    }
  } catch {
    $failed = $_.Exception.Message -match 'release-proof failed'
  }

  if (-not $failed) {
    throw 'Release-proof should fail closed when the requested runtime asset is missing.'
  }

  $failedReceiptPath = Join-Path $failureResultsDir 'release-proof.json'
  if (-not (Test-Path -LiteralPath $failedReceiptPath -PathType Leaf)) {
    throw 'Failed release-proof run should still write a receipt.'
  }
  $failedReceipt = Get-Content -LiteralPath $failedReceiptPath -Raw | ConvertFrom-Json -Depth 64
  if ([string]$failedReceipt.summary.finalStatus -ne 'failed' -or
    [string]$failedReceipt.summary.finalReason -ne 'release-proof-failed' -or
    [string]$failedReceipt.summary.errorMessage -notmatch 'do not contain runtime') {
    throw 'Release-proof failure receipt mismatch.'
  }
}
finally {
  if ([string]::IsNullOrWhiteSpace($env:COMPAREVI_HISTORY_TEST_KEEP_TEMP) -and (Test-Path -LiteralPath $tempRoot)) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
  }
}
