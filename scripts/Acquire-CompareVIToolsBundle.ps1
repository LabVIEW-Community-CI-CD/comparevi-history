param(
  [Parameter(Mandatory = $true)]
  [string]$Repository,
  [Parameter(Mandatory = $true)]
  [string]$ReleaseTag,
  [Parameter(Mandatory = $true)]
  [string]$BundleAssetName,
  [Parameter(Mandatory = $true)]
  [string]$BundleAssetUrl,
  [string]$BundleAssetDigest,
  [string]$DestinationPath = '.comparevi-history-tools',
  [string]$GitHubToken,
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

  $safeValue = if ($null -eq $Value) { '' } else { $Value }
  "$Key=$safeValue" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
}

function Resolve-FullPath {
  param([Parameter(Mandatory = $true)][string]$Path)

  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }

  return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
}

function Get-DownloadHeaders {
  $headers = @{
    'User-Agent' = 'comparevi-history'
  }

  if (-not [string]::IsNullOrWhiteSpace($GitHubToken)) {
    $headers.Authorization = "Bearer $GitHubToken"
  }

  return $headers
}

$destinationResolved = Resolve-FullPath -Path $DestinationPath
if (Test-Path -LiteralPath $destinationResolved) {
  Remove-Item -LiteralPath $destinationResolved -Recurse -Force
}
New-Item -ItemType Directory -Path $destinationResolved -Force | Out-Null

$downloadPath = Join-Path ([System.IO.Path]::GetTempPath()) ("comparevi-tools-" + [guid]::NewGuid().ToString('N') + '.zip')

try {
  Invoke-WebRequest -Uri $BundleAssetUrl -OutFile $downloadPath -Headers (Get-DownloadHeaders)

  if (-not [string]::IsNullOrWhiteSpace($BundleAssetDigest) -and $BundleAssetDigest.StartsWith('sha256:', [System.StringComparison]::OrdinalIgnoreCase)) {
    $expectedHash = $BundleAssetDigest.Substring(7).ToLowerInvariant()
    $actualHash = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
      throw "Downloaded CompareVI.Tools bundle hash mismatch for $BundleAssetName. expected=$expectedHash actual=$actualHash"
    }
  }

  Expand-Archive -Path $downloadPath -DestinationPath $destinationResolved

  $bundleDir = Get-ChildItem -LiteralPath $destinationResolved -Directory | Select-Object -First 1
  if ($null -eq $bundleDir) {
    throw "CompareVI.Tools archive '$BundleAssetName' did not contain a top-level bundle directory."
  }

  $metadataPath = Join-Path $bundleDir.FullName 'comparevi-tools-release.json'
  if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
    throw "CompareVI.Tools archive '$BundleAssetName' is missing comparevi-tools-release.json."
  }

  $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json -Depth 32
  if ([string]$metadata.schema -ne 'comparevi-tools-release-manifest@v1') {
    throw "Unsupported CompareVI.Tools metadata schema in '$metadataPath': $($metadata.schema)"
  }

  if ($metadata.PSObject.Properties['bundle'] -and $metadata.bundle.PSObject.Properties['archiveName']) {
    if ([string]$metadata.bundle.archiveName -ne $BundleAssetName) {
      throw "Bundle metadata archiveName '$($metadata.bundle.archiveName)' did not match downloaded asset '$BundleAssetName'."
    }
  }

  if ($metadata.PSObject.Properties['source'] -and $metadata.source.PSObject.Properties['releaseTag']) {
    $sourceReleaseTag = [string]$metadata.source.releaseTag
    if (-not [string]::IsNullOrWhiteSpace($sourceReleaseTag) -and $sourceReleaseTag -ne $ReleaseTag) {
      throw "Bundle metadata releaseTag '$sourceReleaseTag' did not match requested release tag '$ReleaseTag'."
    }
  }

  if (-not ($metadata.PSObject.Properties['consumerContract'] -and $metadata.consumerContract.PSObject.Properties['hostedNiLinuxRunner'])) {
    throw "CompareVI.Tools bundle '$BundleAssetName' does not publish consumerContract.hostedNiLinuxRunner."
  }

  $hostedRunnerContract = $metadata.consumerContract.hostedNiLinuxRunner
  $hostedRunnerScriptPath = [string]$hostedRunnerContract.entryScriptPath
  if ([string]::IsNullOrWhiteSpace($hostedRunnerScriptPath)) {
    throw "CompareVI.Tools bundle '$BundleAssetName' published an empty hostedNiLinuxRunner.entryScriptPath."
  }

  $hostedRunnerSupportPaths = @(
    @($hostedRunnerContract.supportScriptPaths) |
      ForEach-Object { [string]$_ } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  )
  if ($hostedRunnerSupportPaths.Count -eq 0) {
    throw "CompareVI.Tools bundle '$BundleAssetName' published no hostedNiLinuxRunner.supportScriptPaths."
  }

  $hostedRunnerDefaultImage = [string]$hostedRunnerContract.defaultImage
  if ([string]::IsNullOrWhiteSpace($hostedRunnerDefaultImage)) {
    throw "CompareVI.Tools bundle '$BundleAssetName' published an empty hostedNiLinuxRunner.defaultImage."
  }

  $requiredRelativePaths = New-Object System.Collections.Generic.List[string]
  foreach ($relativePath in @(
    'README.md',
    'tools/CompareVI.Tools/CompareVI.Tools.psd1',
    'tools/Compare-VIHistory.ps1',
    'tools/Compare-RefsToTemp.ps1',
    'tools/Invoke-LVCompare.ps1',
    'tools/Render-VIHistoryReport.ps1',
    'scripts/CompareVI.psm1'
  )) {
    if (-not $requiredRelativePaths.Contains($relativePath)) {
      $requiredRelativePaths.Add($relativePath) | Out-Null
    }
  }

  foreach ($relativePath in @($hostedRunnerScriptPath) + @($hostedRunnerSupportPaths)) {
    if (-not $requiredRelativePaths.Contains($relativePath)) {
      $requiredRelativePaths.Add($relativePath) | Out-Null
    }
  }

  foreach ($relativePath in @($requiredRelativePaths.ToArray())) {
    $candidate = Join-Path $bundleDir.FullName $relativePath
    if (-not (Test-Path -LiteralPath $candidate)) {
      throw "CompareVI.Tools bundle '$BundleAssetName' is missing required file '$relativePath'."
    }
  }

  $relativeToolingPath = if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_WORKSPACE)) {
    $workspaceResolved = [System.IO.Path]::GetFullPath($env:GITHUB_WORKSPACE)
    if ($bundleDir.FullName.StartsWith($workspaceResolved, [System.StringComparison]::OrdinalIgnoreCase)) {
      $trimmed = $bundleDir.FullName.Substring($workspaceResolved.Length).TrimStart('\', '/')
      $trimmed.Replace('\', '/')
    } else {
      $bundleDir.FullName
    }
  } else {
    $bundleDir.FullName
  }

  Write-ActionOutput -Key 'tooling-path' -Value $relativeToolingPath
  Write-ActionOutput -Key 'bundle-release-version' -Value ([string]$metadata.module.releaseVersion)
  Write-ActionOutput -Key 'bundle-source-sha' -Value ([string]$metadata.source.sha)
  Write-ActionOutput -Key 'hosted-runner-script-path' -Value $hostedRunnerScriptPath
  Write-ActionOutput -Key 'hosted-runner-default-image' -Value $hostedRunnerDefaultImage

  if ($StepSummaryPath) {
    @(
      '## comparevi-history bundle acquisition'
      ''
      ('- Backend release: `{0}`' -f $ReleaseTag)
      ('- Asset: `{0}`' -f $BundleAssetName)
      ('- Extracted tooling path: `{0}`' -f $relativeToolingPath)
      ('- Bundle release version: `{0}`' -f $metadata.module.releaseVersion)
      ('- Bundle source SHA: `{0}`' -f $metadata.source.sha)
      ('- Hosted runner script: `{0}`' -f $hostedRunnerScriptPath)
      ('- Hosted runner image: `{0}`' -f $hostedRunnerDefaultImage)
    ) | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
  }
} finally {
  Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
}
