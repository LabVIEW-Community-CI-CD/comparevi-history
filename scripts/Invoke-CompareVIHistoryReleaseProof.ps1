param(
  [Parameter(Mandatory = $true)]
  [string]$Version,
  [Parameter(Mandatory = $true)]
  [string]$ReleaseAssetsDir,
  [string]$RuntimeIdentifier = 'linux-x64',
  [string]$ContainerImage = 'nationalinstruments/labview:2026q1-linux',
  [string]$ContainerInvokerScriptPath,
  [string]$DockerExecutablePath,
  [switch]$SkipImagePull,
  [string]$ResultsDir = 'tests/results/release-proof',
  [string]$GitHubOutputPath,
  [string]$StepSummaryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'CompareVIHistoryReviewBundleFixture.psm1') -Force

function Write-ActionOutput {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Key,
    [AllowNull()]
    [string]$Value
  )

  if ([string]::IsNullOrWhiteSpace($GitHubOutputPath)) {
    return
  }

  $safeValue = if ($null -eq $Value) { '' } else { [string]$Value }
  "$Key=$safeValue" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
}

function Resolve-AbsolutePath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$BasePath
  )

  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }

  return [System.IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function Normalize-VersionString {
  param([Parameter(Mandatory = $true)][string]$Value)

  if ($Value -notmatch '^v?(?<version>[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?)$') {
    throw "Version must match v<major>.<minor>.<patch> with optional prerelease/build metadata. Actual: $Value"
  }

  return [ordered]@{
    tag = if ($Value.StartsWith('v', [System.StringComparison]::OrdinalIgnoreCase)) { $Value } else { 'v' + $Matches['version'] }
    semanticVersion = $Matches['version']
  }
}

function Get-Sha256Hex {
  param([Parameter(Mandatory = $true)][string]$Path)

  return ([string](Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash).ToLowerInvariant()
}

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][string]$Path)

  $raw = Get-Content -LiteralPath $Path -Raw
  if ([string]::IsNullOrWhiteSpace($raw)) {
    throw "JSON file was empty: $Path"
  }

  return $raw | ConvertFrom-Json -Depth 100
}

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

function Resolve-DockerExecutablePath {
  param([string]$RequestedPath)

  if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
    return $RequestedPath
  }

  $dockerCommand = Get-Command docker -ErrorAction SilentlyContinue
  if ($null -eq $dockerCommand) {
    throw 'docker was not found on PATH.'
  }

  return $dockerCommand.Source
}

function Convert-HostPathToContainerPath {
  param(
    [AllowNull()]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$HostRoot,
    [Parameter(Mandatory = $true)]
    [string]$ContainerRoot
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $Path
  }

  $hostRootResolved = [System.IO.Path]::GetFullPath($HostRoot).TrimEnd('\', '/')
  $candidatePath = [System.IO.Path]::GetFullPath($Path)
  if (-not $candidatePath.StartsWith($hostRootResolved, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Container path projection expected '$candidatePath' to live under '$hostRootResolved'."
  }

  $suffix = $candidatePath.Substring($hostRootResolved.Length).TrimStart('\', '/')
  if ([string]::IsNullOrWhiteSpace($suffix)) {
    return $ContainerRoot.TrimEnd('/')
  }

  return ('{0}/{1}' -f $ContainerRoot.TrimEnd('/'), ($suffix -replace '\\', '/'))
}

function Update-ReleaseProofFixtureForContainer {
  param(
    [Parameter(Mandatory = $true)]
    [string]$TargetRunsManifestPath,
    [Parameter(Mandatory = $true)]
    [string]$HostResultsRoot,
    [Parameter(Mandatory = $true)]
    [string]$ContainerResultsRoot
  )

  $targetRunsManifest = Read-JsonFile -Path $TargetRunsManifestPath
  foreach ($target in @($targetRunsManifest.targets)) {
    $suiteManifestHostPath = [string]$target.manifestPath
    if (-not [string]::IsNullOrWhiteSpace($suiteManifestHostPath)) {
      $suiteManifest = Read-JsonFile -Path $suiteManifestHostPath
      foreach ($mode in @($suiteManifest.modes)) {
        $modeManifestHostPath = [string]$mode.manifestPath
        if (-not [string]::IsNullOrWhiteSpace($modeManifestHostPath)) {
          $modeManifest = Read-JsonFile -Path $modeManifestHostPath
          foreach ($comparison in @($modeManifest.comparisons)) {
            if ($comparison.PSObject.Properties['result'] -and $null -ne $comparison.result) {
              if ($comparison.result.PSObject.Properties['reportHtml'] -and -not [string]::IsNullOrWhiteSpace([string]$comparison.result.reportHtml)) {
                $comparison.result.reportHtml = Convert-HostPathToContainerPath -Path ([string]$comparison.result.reportHtml) -HostRoot $HostResultsRoot -ContainerRoot $ContainerResultsRoot
              }
              if ($comparison.result.PSObject.Properties['reportPath'] -and -not [string]::IsNullOrWhiteSpace([string]$comparison.result.reportPath)) {
                $comparison.result.reportPath = Convert-HostPathToContainerPath -Path ([string]$comparison.result.reportPath) -HostRoot $HostResultsRoot -ContainerRoot $ContainerResultsRoot
              }
            }
          }
          ($modeManifest | ConvertTo-Json -Depth 100) | Set-Content -LiteralPath $modeManifestHostPath -Encoding utf8
          $mode.manifestPath = Convert-HostPathToContainerPath -Path $modeManifestHostPath -HostRoot $HostResultsRoot -ContainerRoot $ContainerResultsRoot
        }
      }
      ($suiteManifest | ConvertTo-Json -Depth 100) | Set-Content -LiteralPath $suiteManifestHostPath -Encoding utf8
      $target.manifestPath = Convert-HostPathToContainerPath -Path $suiteManifestHostPath -HostRoot $HostResultsRoot -ContainerRoot $ContainerResultsRoot
    }

    if ($target.PSObject.Properties['publicRunPath'] -and -not [string]::IsNullOrWhiteSpace([string]$target.publicRunPath)) {
      $target.publicRunPath = Convert-HostPathToContainerPath -Path ([string]$target.publicRunPath) -HostRoot $HostResultsRoot -ContainerRoot $ContainerResultsRoot
    }
  }

  ($targetRunsManifest | ConvertTo-Json -Depth 100) | Set-Content -LiteralPath $TargetRunsManifestPath -Encoding utf8
}

function Invoke-DockerReleaseProof {
  param(
    [Parameter(Mandatory = $true)]
    [string]$DockerPath,
    [Parameter(Mandatory = $true)]
    [string]$ContainerImageValue,
    [Parameter(Mandatory = $true)]
    [string]$CompilerRoot,
    [Parameter(Mandatory = $true)]
    [string]$EntryExecutable,
    [Parameter(Mandatory = $true)]
    [string]$ResultsRoot,
    [Parameter(Mandatory = $true)]
    [string]$LogPath,
    [switch]$SkipPull
  )

  if (-not $SkipPull.IsPresent) {
    & $DockerPath pull $ContainerImageValue 2>&1 | Tee-Object -FilePath $LogPath -Append | Out-Null
    if ($LASTEXITCODE -ne 0) {
      throw "docker pull failed for image '$ContainerImageValue'."
    }
  }

  $containerCommand = @(
    'set -eu'
    'rm -rf /tmp/comparevi-history-review-compiler'
    'mkdir -p /tmp/comparevi-history-review-compiler'
    'cp -R /compiler/. /tmp/comparevi-history-review-compiler/'
    ('chmod +x /tmp/comparevi-history-review-compiler/{0}' -f $EntryExecutable)
    ('/tmp/comparevi-history-review-compiler/{0} --target-runs-manifest-path /results/pr-target-runs-manifest.json --results-dir /results --output-path /results/review-bundle.from-release.json' -f $EntryExecutable)
  ) -join '; '

  $dockerArgs = @(
    'run',
    '--rm',
    '-v', ('{0}:/compiler:ro' -f $CompilerRoot),
    '-v', ('{0}:/results' -f $ResultsRoot),
    $ContainerImageValue,
    '/bin/sh',
    '-lc',
    $containerCommand
  )

  & $DockerPath @dockerArgs 2>&1 | Tee-Object -FilePath $LogPath -Append | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "docker run failed for image '$ContainerImageValue'."
  }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$basePath = (Get-Location).Path
$versionInfo = Normalize-VersionString -Value $Version
$releaseAssetsDirResolved = Resolve-AbsolutePath -Path $ReleaseAssetsDir -BasePath $basePath
$resultsDirResolved = Resolve-AbsolutePath -Path $ResultsDir -BasePath $repoRoot
$receiptPath = Join-Path $resultsDirResolved 'release-proof.json'
$summaryPath = Join-Path $resultsDirResolved 'release-proof-summary.md'
$logPath = Join-Path $resultsDirResolved 'release-proof.log'
$extractRoot = Join-Path $resultsDirResolved 'extracted'
New-Item -ItemType Directory -Path $resultsDirResolved -Force | Out-Null

$releaseManifestPath = Join-Path $releaseAssetsDirResolved 'comparevi-history-review-compiler-release.json'
$checksumsPath = Join-Path $releaseAssetsDirResolved 'SHA256SUMS.txt'
$fixtureBundlePath = Join-Path $repoRoot 'tests' 'fixtures' 'review-bundle-v1' 'review-bundle.json'
$fixture = $null
$containerExecutionKind = if ([string]::IsNullOrWhiteSpace($ContainerInvokerScriptPath)) { 'docker' } else { 'script-override' }
$selectedAssetReceipt = $null
$outputBundlePath = $null
$proofError = $null
$finalStatus = 'succeeded'
$finalReason = 'release-proof-succeeded'
$dockerPathResolved = $null
$containerInvokerScriptPathResolved = $null
$imagePulled = $false

try {
  if (-not (Test-Path -LiteralPath $releaseAssetsDirResolved -PathType Container)) {
    throw "Release assets directory not found: $releaseAssetsDirResolved"
  }
  foreach ($requiredPath in @($releaseManifestPath, $checksumsPath, $fixtureBundlePath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
      throw "Required release-proof input was not found: $requiredPath"
    }
  }

  $releaseManifest = Read-JsonFile -Path $releaseManifestPath
  if ([string]$releaseManifest.schema -ne 'comparevi-history/review-compiler-release@v1') {
    throw 'Review compiler release manifest schema mismatch.'
  }
  if ([string]$releaseManifest.version -ne [string]$versionInfo.tag) {
    throw "Review compiler release manifest version mismatch. Expected '$($versionInfo.tag)', actual '$($releaseManifest.version)'."
  }

  $selectedAsset = @($releaseManifest.assets | Where-Object { [string]$_.runtimeIdentifier -eq $RuntimeIdentifier } | Select-Object -First 1)
  if (-not $selectedAsset) {
    throw "Review compiler release assets do not contain runtime '$RuntimeIdentifier'."
  }

  $archivePath = Join-Path $releaseAssetsDirResolved ([string]$selectedAsset.fileName)
  if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
    throw "Selected review compiler archive not found: $archivePath"
  }

  $archiveSha = Get-Sha256Hex -Path $archivePath
  if ($archiveSha -ne [string]$selectedAsset.sha256) {
    throw "Review compiler archive checksum mismatch for '$archivePath'."
  }

  $checksumsContent = Get-Content -LiteralPath $checksumsPath -Raw
  $expectedChecksumLine = '{0} *{1}' -f $archiveSha, [System.IO.Path]::GetFileName($archivePath)
  if ($checksumsContent -notmatch [regex]::Escape($expectedChecksumLine)) {
    throw "SHA256SUMS.txt did not contain the selected review compiler archive checksum for '$archivePath'."
  }

  if (Test-Path -LiteralPath $extractRoot) {
    Remove-Item -LiteralPath $extractRoot -Recurse -Force
  }
  New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
  Expand-Archive -LiteralPath $archivePath -DestinationPath $extractRoot -Force

  $packageRoot = Join-Path $extractRoot ([string]$selectedAsset.packageDirectory)
  $entryExecutable = [string]$selectedAsset.entryExecutable
  $executablePath = Join-Path $packageRoot $entryExecutable
  if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
    throw "Extracted review compiler executable not found: $executablePath"
  }

  $selectedAssetReceipt = [ordered]@{
    runtimeIdentifier = [string]$selectedAsset.runtimeIdentifier
    fileName = [string]$selectedAsset.fileName
    sha256 = [string]$selectedAsset.sha256
    packageDirectory = [string]$selectedAsset.packageDirectory
    entryExecutable = $entryExecutable
    archivePath = $archivePath
    packageRoot = $packageRoot
    executablePath = $executablePath
  }

  $fixture = New-CompareVIHistorySyntheticReviewBundleFixture -RootPath (Join-Path $resultsDirResolved 'fixture')
  $outputBundlePath = Join-Path ([string]$fixture.resultsDir) 'review-bundle.from-release.json'

  if (-not [string]::IsNullOrWhiteSpace($ContainerInvokerScriptPath)) {
    $containerInvokerScriptPathResolved = Resolve-AbsolutePath -Path $ContainerInvokerScriptPath -BasePath $basePath
    if (-not (Test-Path -LiteralPath $containerInvokerScriptPathResolved -PathType Leaf)) {
      throw "Container invoker script was not found: $containerInvokerScriptPathResolved"
    }

    & $containerInvokerScriptPathResolved `
      -ContainerImage $ContainerImage `
      -CompilerExecutablePath $executablePath `
      -TargetRunsManifestPath ([string]$fixture.targetRunsManifestPath) `
      -ResultsDir ([string]$fixture.resultsDir) `
      -OutputPath $outputBundlePath `
      -RuntimeIdentifier $RuntimeIdentifier `
      -LogPath $logPath
  } else {
    $dockerPathResolved = Resolve-DockerExecutablePath -RequestedPath $DockerExecutablePath
    $imagePulled = -not $SkipImagePull.IsPresent
    Update-ReleaseProofFixtureForContainer `
      -TargetRunsManifestPath ([string]$fixture.targetRunsManifestPath) `
      -HostResultsRoot ([string]$fixture.resultsDir) `
      -ContainerResultsRoot '/results'
    Invoke-DockerReleaseProof `
      -DockerPath $dockerPathResolved `
      -ContainerImageValue $ContainerImage `
      -CompilerRoot $packageRoot `
      -EntryExecutable $entryExecutable `
      -ResultsRoot ([string]$fixture.resultsDir) `
      -LogPath $logPath `
      -SkipPull:$SkipImagePull.IsPresent
  }

  if (-not (Test-Path -LiteralPath $outputBundlePath -PathType Leaf)) {
    throw "Release-proof compiler execution did not emit the expected review bundle: $outputBundlePath"
  }

  $expectedBundle = Get-Content -LiteralPath $fixtureBundlePath -Raw | ConvertFrom-Json -Depth 100
  $actualBundle = Read-JsonFile -Path $outputBundlePath
  $normalizedExpected = $expectedBundle | ConvertTo-Json -Depth 100 -Compress
  $normalizedActual = (ConvertTo-NormalizedReviewBundle -Receipt $actualBundle) | ConvertTo-Json -Depth 100 -Compress
  if ($normalizedActual -ne $normalizedExpected) {
    throw 'Release-proof generated review bundle drifted from the canonical golden baseline.'
  }
}
catch {
  $finalStatus = 'failed'
  $finalReason = 'release-proof-failed'
  $proofError = $_.Exception.Message
}

$receipt = [ordered]@{
  schema = 'comparevi-history/release-proof@v1'
  generatedAtUtc = [DateTime]::UtcNow.ToString('o')
  version = [string]$versionInfo.tag
  releaseAssets = [ordered]@{
    releaseAssetsDir = $releaseAssetsDirResolved
    releaseManifestPath = $releaseManifestPath
    checksumsPath = $checksumsPath
    selectedAsset = $selectedAssetReceipt
  }
  runtime = [ordered]@{
    runtimeIdentifier = $RuntimeIdentifier
    containerImage = $ContainerImage
    containerExecutionKind = $containerExecutionKind
    dockerExecutablePath = $dockerPathResolved
    containerInvokerScriptPath = $containerInvokerScriptPathResolved
    imagePulled = $imagePulled
  }
  fixture = [ordered]@{
    targetRunsManifestPath = if ($null -eq $fixture) { $null } else { [string]$fixture.targetRunsManifestPath }
    expectedBundlePath = $fixtureBundlePath
    outputBundlePath = $outputBundlePath
  }
  outputs = [ordered]@{
    receiptPath = $receiptPath
    summaryPath = $summaryPath
    logPath = $logPath
  }
  summary = [ordered]@{
    finalStatus = $finalStatus
    finalReason = $finalReason
    goldenBaselineMatched = [bool]($finalStatus -eq 'succeeded')
    errorMessage = $proofError
  }
}
($receipt | ConvertTo-Json -Depth 64) | Set-Content -LiteralPath $receiptPath -Encoding utf8

@(
  '# comparevi-history release proof'
  ''
  ('- Version: `{0}`' -f [string]$versionInfo.tag)
  ('- Release assets directory: `{0}`' -f $releaseAssetsDirResolved)
  ('- Runtime identifier: `{0}`' -f $RuntimeIdentifier)
  ('- Container image: `{0}`' -f $ContainerImage)
  ('- Execution kind: `{0}`' -f $containerExecutionKind)
  ('- Release manifest: `{0}`' -f $releaseManifestPath)
  ('- Checksums: `{0}`' -f $checksumsPath)
  ('- Output review bundle: `{0}`' -f $(if ([string]::IsNullOrWhiteSpace($outputBundlePath)) { 'n/a' } else { $outputBundlePath }))
  ('- Receipt: `{0}`' -f $receiptPath)
  ('- Final status: `{0}`' -f $finalStatus)
  ('- Final reason: `{0}`' -f $finalReason)
  $(if ([string]::IsNullOrWhiteSpace($proofError)) { '' } else { '- Error: `{0}`' -f $proofError })
) | Set-Content -LiteralPath $summaryPath -Encoding utf8

Write-ActionOutput -Key 'release-proof-path' -Value $receiptPath
Write-ActionOutput -Key 'release-proof-summary-path' -Value $summaryPath
Write-ActionOutput -Key 'release-proof-log-path' -Value $logPath
Write-ActionOutput -Key 'release-proof-output-bundle-path' -Value $(if ([string]::IsNullOrWhiteSpace($outputBundlePath)) { '' } else { $outputBundlePath })
Write-ActionOutput -Key 'release-proof-final-status' -Value $finalStatus
Write-ActionOutput -Key 'release-proof-final-reason' -Value $finalReason

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  @(
    '## comparevi-history release proof'
    ''
    ('- Version: `{0}`' -f [string]$versionInfo.tag)
    ('- Runtime identifier: `{0}`' -f $RuntimeIdentifier)
    ('- Container image: `{0}`' -f $ContainerImage)
    ('- Execution kind: `{0}`' -f $containerExecutionKind)
    ('- Final status: `{0}`' -f $finalStatus)
    ('- Final reason: `{0}`' -f $finalReason)
  ) | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
}

if ($finalStatus -ne 'succeeded') {
  throw "comparevi-history release-proof failed. See '$receiptPath'."
}

$receipt | ConvertTo-Json -Depth 64
