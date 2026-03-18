param(
  [Parameter(Mandatory = $true)]
  [string]$Version,
  [string]$ProjectPath = '..\src\CompareVIHistory.ReviewCompiler\CompareVIHistory.ReviewCompiler.csproj',
  [string]$OutputDir = 'tests/results/review-compiler-release',
  [string[]]$RuntimeIdentifiers = @('win-x64', 'linux-x64'),
  [string]$Configuration = 'Release',
  [string]$GitHubOutputPath,
  [string]$StepSummaryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Get-Sha256Hex {
  param([Parameter(Mandatory = $true)][string]$Path)

  $hash = Get-FileHash -LiteralPath $Path -Algorithm SHA256
  return ([string]$hash.Hash).ToLowerInvariant()
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

function Get-ExecutableNames {
  param([Parameter(Mandatory = $true)][string]$RuntimeIdentifier)

  $stableName = if ($RuntimeIdentifier.StartsWith('win-', [System.StringComparison]::OrdinalIgnoreCase)) {
    'comparevi-history-review-compiler.exe'
  } else {
    'comparevi-history-review-compiler'
  }
  $publishedName = if ($RuntimeIdentifier.StartsWith('win-', [System.StringComparison]::OrdinalIgnoreCase)) {
    'CompareVIHistory.ReviewCompiler.exe'
  } else {
    'CompareVIHistory.ReviewCompiler'
  }

  return [ordered]@{
    stable = $stableName
    published = $publishedName
  }
}

$basePath = (Get-Location).Path
$versionInfo = Normalize-VersionString -Value $Version
$projectPathResolved = Resolve-AbsolutePath -Path $ProjectPath -BasePath $PSScriptRoot
$outputDirResolved = Resolve-AbsolutePath -Path $OutputDir -BasePath $basePath

if (-not (Test-Path -LiteralPath $projectPathResolved -PathType Leaf)) {
  throw "Review compiler project not found: $projectPathResolved"
}

if (Test-Path -LiteralPath $outputDirResolved) {
  Remove-Item -LiteralPath $outputDirResolved -Recurse -Force
}
New-Item -ItemType Directory -Path $outputDirResolved -Force | Out-Null

$publishRoot = Join-Path $outputDirResolved 'publish'
$packageRoot = Join-Path $outputDirResolved 'packages'
New-Item -ItemType Directory -Path $publishRoot -Force | Out-Null
New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null

$assets = New-Object System.Collections.Generic.List[object]
$checksumLines = New-Object System.Collections.Generic.List[string]
$assetPaths = New-Object System.Collections.Generic.List[string]

foreach ($runtimeIdentifier in @($RuntimeIdentifiers | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })) {
  $rid = [string]$runtimeIdentifier
  $publishDir = Join-Path $publishRoot $rid
  $packageDirName = 'comparevi-history-review-compiler-{0}-{1}' -f $versionInfo.tag, $rid
  $packageDir = Join-Path $packageRoot $packageDirName
  New-Item -ItemType Directory -Path $publishDir -Force | Out-Null
  New-Item -ItemType Directory -Path $packageDir -Force | Out-Null

  & dotnet publish $projectPathResolved `
    -c $Configuration `
    -r $rid `
    --self-contained true `
    /p:PublishSingleFile=true `
    /p:IncludeNativeLibrariesForSelfExtract=true `
    /p:DebugType=None `
    /p:DebugSymbols=false `
    /p:Version=$($versionInfo.semanticVersion) `
    /p:InformationalVersion=$($versionInfo.tag) `
    -o $publishDir | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed for runtime '$rid' with exit code $LASTEXITCODE."
  }

  $executableNames = Get-ExecutableNames -RuntimeIdentifier $rid
  $publishedExecutablePath = Join-Path $publishDir $executableNames.published
  if (-not (Test-Path -LiteralPath $publishedExecutablePath -PathType Leaf)) {
    throw "Published executable not found for runtime '$rid': $publishedExecutablePath"
  }

  Copy-Item -Path (Join-Path $publishDir '*') -Destination $packageDir -Recurse -Force
  $stableExecutablePath = Join-Path $packageDir $executableNames.stable
  Move-Item -LiteralPath (Join-Path $packageDir $executableNames.published) -Destination $stableExecutablePath -Force

  $archivePath = Join-Path $outputDirResolved ('{0}.zip' -f $packageDirName)
  if (Test-Path -LiteralPath $archivePath) {
    Remove-Item -LiteralPath $archivePath -Force
  }
  Compress-Archive -Path $packageDir -DestinationPath $archivePath -Force

  $sha256 = Get-Sha256Hex -Path $archivePath
  $checksumLines.Add(('{0} *{1}' -f $sha256, [System.IO.Path]::GetFileName($archivePath))) | Out-Null
  $assetPaths.Add($archivePath) | Out-Null

  $assets.Add([ordered]@{
      runtimeIdentifier = $rid
      fileName = [System.IO.Path]::GetFileName($archivePath)
      sha256 = $sha256
      packageDirectory = $packageDirName
      entryExecutable = $executableNames.stable
      invocation = ('./{0} --version' -f $executableNames.stable)
    }) | Out-Null
}

$manifestPath = Join-Path $outputDirResolved 'comparevi-history-review-compiler-release.json'
$manifest = [ordered]@{
  schema = 'comparevi-history/review-compiler-release@v1'
  generatedAtUtc = [DateTime]::UtcNow.ToString('o')
  version = $versionInfo.tag
  semanticVersion = $versionInfo.semanticVersion
  project = 'src/CompareVIHistory.ReviewCompiler/CompareVIHistory.ReviewCompiler.csproj'
  assets = @($assets | ForEach-Object { $_ })
}
($manifest | ConvertTo-Json -Depth 32) | Set-Content -LiteralPath $manifestPath -Encoding utf8
$checksumLines.Add(('{0} *{1}' -f (Get-Sha256Hex -Path $manifestPath), [System.IO.Path]::GetFileName($manifestPath))) | Out-Null
$assetPaths.Add($manifestPath) | Out-Null

$checksumsPath = Join-Path $outputDirResolved 'SHA256SUMS.txt'
($checksumLines -join [Environment]::NewLine) | Set-Content -LiteralPath $checksumsPath -Encoding utf8
$assetPaths.Add($checksumsPath) | Out-Null

Write-ActionOutput -Key 'review-compiler-release-dir' -Value $outputDirResolved
Write-ActionOutput -Key 'review-compiler-release-manifest' -Value $manifestPath
Write-ActionOutput -Key 'review-compiler-release-checksums' -Value $checksumsPath
Write-ActionOutput -Key 'review-compiler-release-assets' -Value ($assetPaths -join [System.IO.Path]::PathSeparator)

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  @(
    '## comparevi-history review compiler release assets'
    ''
    ('- Version: `{0}`' -f $versionInfo.tag)
    ('- Output directory: `{0}`' -f $outputDirResolved)
    ('- Release manifest: `{0}`' -f $manifestPath)
    ('- Checksums: `{0}`' -f $checksumsPath)
    ('- Runtime assets: `{0}`' -f ((@($assets | ForEach-Object { '{0}:{1}' -f $_.runtimeIdentifier, $_.fileName }) -join ', ')))
  ) | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
}

$manifest | ConvertTo-Json -Depth 32
