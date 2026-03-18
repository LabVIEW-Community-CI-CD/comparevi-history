$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'CompareVIHistoryReviewBundleFixture.psm1') -Force

$repoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $PSScriptRoot 'Publish-CompareVIHistoryReviewCompilerArtifact.ps1'
$wrapperPath = Join-Path $PSScriptRoot 'Invoke-CompareVIHistoryReviewBundleCompiler.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('comparevi-history-review-compiler-artifact-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
  $runtimeIdentifier = if ($IsWindows) {
    'win-x64'
  } elseif ($IsLinux) {
    'linux-x64'
  } else {
    throw 'Review compiler artifact test currently supports Windows and Linux only.'
  }

  $githubOutputPath = Join-Path $tempRoot 'artifact.out'
  $releaseOutputDir = Join-Path $tempRoot 'release'
  $releaseJson = & $scriptPath `
    -Version 'v9.9.9' `
    -OutputDir $releaseOutputDir `
    -RuntimeIdentifiers @($runtimeIdentifier) `
    -GitHubOutputPath $githubOutputPath
  $releaseReceipt = $releaseJson | ConvertFrom-Json -Depth 32

  if ([string]$releaseReceipt.schema -ne 'comparevi-history/review-compiler-release@v1') {
    throw 'Review compiler release manifest schema mismatch.'
  }
  if ([string]$releaseReceipt.version -ne 'v9.9.9' -or [string]$releaseReceipt.semanticVersion -ne '9.9.9') {
    throw 'Review compiler release version mismatch.'
  }
  if ([string]$releaseReceipt.project -ne 'src/CompareVIHistory.ReviewCompiler/CompareVIHistory.ReviewCompiler.csproj') {
    throw 'Review compiler release manifest project path mismatch.'
  }
  if ($releaseReceipt.assets.Count -ne 1) {
    throw 'Review compiler release manifest should contain exactly one runtime asset in the focused test.'
  }

  $asset = $releaseReceipt.assets[0]
  $expectedExecutableName = if ($runtimeIdentifier -like 'win-*') {
    'comparevi-history-review-compiler.exe'
  } else {
    'comparevi-history-review-compiler'
  }
  $expectedArchiveName = 'comparevi-history-review-compiler-v9.9.9-{0}.zip' -f $runtimeIdentifier
  if ([string]$asset.runtimeIdentifier -ne $runtimeIdentifier -or
    [string]$asset.fileName -ne $expectedArchiveName -or
    [string]$asset.entryExecutable -ne $expectedExecutableName -or
    [string]$asset.invocation -ne ('./{0} --version' -f $expectedExecutableName) -or
    [string]$asset.sha256 -notmatch '^[a-f0-9]{64}$') {
    throw 'Review compiler runtime asset metadata mismatch.'
  }

  $checksumsPath = Join-Path $releaseOutputDir 'SHA256SUMS.txt'
  $manifestPath = Join-Path $releaseOutputDir 'comparevi-history-review-compiler-release.json'
  $archivePath = Join-Path $releaseOutputDir $expectedArchiveName
  foreach ($path in @($checksumsPath, $manifestPath, $archivePath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "Expected release artifact path is missing: $path"
    }
  }

  $checksums = @(Get-Content -LiteralPath $checksumsPath)
  $archiveChecksumMatches = @($checksums | Where-Object { $_ -match [regex]::Escape($expectedArchiveName) })
  $manifestChecksumMatches = @($checksums | Where-Object { $_ -match [regex]::Escape('comparevi-history-review-compiler-release.json') })
  if ($checksums.Count -ne 2 -or
    $archiveChecksumMatches.Count -ne 1 -or
    $manifestChecksumMatches.Count -ne 1) {
    throw 'Review compiler checksum manifest mismatch.'
  }

  $extractRoot = Join-Path $tempRoot 'extracted'
  Expand-Archive -LiteralPath $archivePath -DestinationPath $extractRoot -Force
  $packageDirectory = Join-Path $extractRoot ('comparevi-history-review-compiler-v9.9.9-{0}' -f $runtimeIdentifier)
  $executablePath = Join-Path $packageDirectory $expectedExecutableName
  if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
    throw 'Extracted review compiler executable is missing.'
  }
  if (-not $IsWindows) {
    & chmod +x $executablePath
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to mark extracted compiler executable as runnable: $executablePath"
    }
  }

  $versionOutput = (& $executablePath --version | Out-String).Trim()
  if ([string]::IsNullOrWhiteSpace($versionOutput) -or $versionOutput -notmatch 'v?9\.9\.9') {
    throw "Extracted review compiler --version output mismatch. Actual: $versionOutput"
  }

  $fixture = New-CompareVIHistorySyntheticReviewBundleFixture -RootPath (Join-Path $tempRoot 'fixture')
  $compilerOutputPath = Join-Path ([string]$fixture.resultsDir) 'review-bundle-from-cli.json'
  $wrapperOutputPath = Join-Path $tempRoot 'wrapper.out'
  $bundleJson = & $wrapperPath `
    -TargetRunsManifestPath ([string]$fixture.targetRunsManifestPath) `
    -ResultsDir ([string]$fixture.resultsDir) `
    -OutputPath $compilerOutputPath `
    -CompilerPath $packageDirectory `
    -GitHubOutputPath $wrapperOutputPath
  $bundleReceipt = $bundleJson | ConvertFrom-Json -Depth 100

  if ([string]$bundleReceipt.schema -ne 'comparevi-history/review-bundle@v1' -or
    [int]$bundleReceipt.summary.reviewPairCount -ne 2 -or
    [int]$bundleReceipt.summary.rawPreviewPairCount -ne 4) {
    throw 'Wrapper invocation through the self-contained compiler produced an unexpected review bundle.'
  }

  $wrapperOutputs = Get-Content -LiteralPath $wrapperOutputPath -Raw
  foreach ($requiredKey in @(
      'review-bundle-path=',
      'compiler-invocation-kind=self-contained-cli',
      'compiler-executable-path='
    )) {
    if ($wrapperOutputs -notmatch [regex]::Escape($requiredKey)) {
      throw "Expected wrapper output '$requiredKey'."
    }
  }
}
finally {
  if (Test-Path -LiteralPath $tempRoot) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
  }
}
