param(
  [Parameter(Mandatory = $true)]
  [string]$ConsumerRepositoryRoot,
  [Parameter(Mandatory = $true, ParameterSetName = 'explicit')]
  [string[]]$ViPath,
  [Parameter(ParameterSetName = 'explicit')]
  [Parameter(Mandatory = $true, ParameterSetName = 'changed')]
  [string]$BaseRef,
  [string]$HeadRef = 'HEAD',
  [ValidateSet('proof', 'dev-fast', 'warm-dev')]
  [string]$Profile = 'dev-fast',
  [string]$ConsumerRepository,
  [string]$ResultsDir = 'tests/results/local-review',
  [string]$Mode = 'attributes,front-panel,block-diagram',
  [ValidateSet('include', 'collapse', 'skip')]
  [string]$NoisePolicy = 'include',
  [switch]$IncludeMergeParents,
  [Nullable[int]]$CompareTimeoutSeconds,
  [string]$InvokeScriptPath,
  [string]$ToolingRoot,
  [string]$CompareviRepository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
  [string]$CompareviRef,
  [string]$WarmRuntimeDir,
  [string]$ContainerImage,
  [string]$CompilerPath,
  [string]$CompilerRepository = 'LabVIEW-Community-CI-CD/comparevi-history',
  [string]$CompilerRef,
  [string]$CompilerRuntimeIdentifier,
  [string]$GitHubToken,
  [switch]$SkipImagePull,
  [switch]$SkipDevImageBuild,
  [string]$GitHubOutputPath,
  [string]$StepSummaryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$localReviewTimer = [System.Diagnostics.Stopwatch]::StartNew()

$publicModesAllowed = @('attributes', 'front-panel', 'block-diagram')
$publicModeSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($modeName in $publicModesAllowed) {
  [void]$publicModeSet.Add($modeName)
}

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

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][string]$Path)

  $raw = Get-Content -LiteralPath $Path -Raw
  if ([string]::IsNullOrWhiteSpace($raw)) {
    throw "JSON file was empty: $Path"
  }

  return $raw | ConvertFrom-Json -Depth 100
}

function Read-KeyValueFile {
  param([Parameter(Mandatory = $true)][string]$Path)

  $values = @{}
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $values
  }

  foreach ($line in Get-Content -LiteralPath $Path) {
    if ($line -match '^(?<key>[^=]+)=(?<value>.*)$') {
      $values[$Matches['key']] = $Matches['value']
    }
  }

  return $values
}

function Get-OptionalString {
  param([AllowNull()]$Value)

  if ($null -eq $Value) {
    return $null
  }

  $stringValue = [string]$Value
  if ([string]::IsNullOrWhiteSpace($stringValue)) {
    return $null
  }

  return $stringValue.Trim()
}

function ConvertTo-ObjectArray {
  param([AllowNull()]$Value)

  if ($null -eq $Value) {
    return @()
  }

  if ($Value -is [string] -or $Value -isnot [System.Collections.IEnumerable]) {
    return @($Value)
  }

  $items = New-Object System.Collections.Generic.List[object]
  foreach ($item in ([System.Collections.IEnumerable]$Value)) {
    $items.Add($item) | Out-Null
  }

  return @($items | ForEach-Object { $_ })
}

function Get-OptionalPropertyValue {
  param(
    [AllowNull()]$InputObject,
    [Parameter(Mandatory = $true)][string]$PropertyName,
    $Default = $null
  )

  if ($null -eq $InputObject) {
    return $Default
  }

  $property = $InputObject.PSObject.Properties[$PropertyName]
  if ($null -eq $property) {
    return $Default
  }

  return $property.Value
}

function Invoke-GitCapture {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryRoot,
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  $output = & git -C $RepositoryRoot @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) {
    $rendered = if ($output) { ($output -join [Environment]::NewLine) } else { 'git command failed.' }
    throw $rendered
  }

  return [string]::Join([Environment]::NewLine, @($output))
}

function Resolve-GitHubToken {
  if (-not [string]::IsNullOrWhiteSpace($GitHubToken)) {
    return $GitHubToken.Trim()
  }

  foreach ($candidate in @($env:GITHUB_TOKEN, $env:GH_TOKEN)) {
    if (-not [string]::IsNullOrWhiteSpace($candidate)) {
      return $candidate.Trim()
    }
  }

  return $null
}

function Get-GitHubHeaders {
  param([string]$Token)

  $headers = @{
    Accept = 'application/vnd.github+json'
    'User-Agent' = 'comparevi-history-local-review'
    'X-GitHub-Api-Version' = '2022-11-28'
  }

  if (-not [string]::IsNullOrWhiteSpace($Token)) {
    $headers.Authorization = "Bearer $Token"
  }

  return $headers
}

function Resolve-ConsumerRepositorySlug {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryRoot,
    [string]$Override
  )

  if (-not [string]::IsNullOrWhiteSpace($Override)) {
    return $Override.Trim()
  }

  $originUrl = $null
  try {
    $originUrl = (Invoke-GitCapture -RepositoryRoot $RepositoryRoot -Arguments @('config', '--get', 'remote.origin.url')).Trim()
  } catch {
    $originUrl = $null
  }

  if (-not [string]::IsNullOrWhiteSpace($originUrl) -and $originUrl -match 'github\.com[:/](?<owner>[^/]+)/(?<repo>[^/]+?)(?:\.git)?$') {
    return ('{0}/{1}' -f $Matches['owner'], $Matches['repo'])
  }

  return ('local/{0}' -f (Split-Path -Leaf $RepositoryRoot))
}

function Normalize-RepositoryPath {
  param([AllowNull()][string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }

  $normalized = $Path.Trim() -replace '\\', '/'
  while ($normalized.Contains('//')) {
    $normalized = $normalized.Replace('//', '/')
  }

  return $normalized.TrimStart([char[]]@('.', '/')).Trim([char[]]@('/'))
}

function ConvertTo-SafeSlug {
  param(
    [AllowNull()]
    [string]$Value,
    [string]$Fallback = 'vi'
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $Fallback
  }

  $slug = $Value.ToLowerInvariant() -replace '[^a-z0-9]+', '-'
  $slug = $slug.Trim('-')
  if ([string]::IsNullOrWhiteSpace($slug)) {
    return $Fallback
  }

  return $slug
}

function New-SyntheticTargetId {
  param([Parameter(Mandatory = $true)][string]$TargetPath)

  $normalized = Normalize-RepositoryPath -Path $TargetPath
  $leafName = [System.IO.Path]::GetFileNameWithoutExtension($normalized)
  $slug = ConvertTo-SafeSlug -Value $(if ([string]::IsNullOrWhiteSpace($leafName)) { $normalized } else { $leafName })

  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized.ToLowerInvariant())
    $hashBytes = $sha.ComputeHash($bytes)
    $hash = ([System.BitConverter]::ToString($hashBytes) -replace '-', '').ToLowerInvariant().Substring(0, 12)
  } finally {
    $sha.Dispose()
  }

  return "dynamic-$slug-$hash"
}

function ConvertTo-PublicModeList {
  param([AllowNull()]$Value)

  $modes = New-Object System.Collections.Generic.List[string]
  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($entry in @($Value -split '[,;]')) {
    $normalized = Get-OptionalString -Value $entry
    if ([string]::IsNullOrWhiteSpace($normalized)) {
      continue
    }

    $normalized = $normalized.ToLowerInvariant()
    if (-not $publicModeSet.Contains($normalized)) {
      throw "Local review mode list included unsupported public mode '$normalized'. Allowed values: $($publicModesAllowed -join ', ')."
    }

    if ($seen.Add($normalized)) {
      $modes.Add($normalized) | Out-Null
    }
  }

  if ($modes.Count -eq 0) {
    throw 'Local review requires at least one explicit public mode.'
  }

  return @($modes | ForEach-Object { $_ })
}

function Resolve-CommitSha {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryRoot,
    [Parameter(Mandatory = $true)]
    [string]$Ref
  )

  return (Invoke-GitCapture -RepositoryRoot $RepositoryRoot -Arguments @('rev-parse', '--verify', "$Ref`^{commit}")).Trim()
}

function Resolve-DisplayRef {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryRoot,
    [string]$InputRef,
    [Parameter(Mandatory = $true)]
    [string]$ResolvedSha
  )

  $trimmed = Get-OptionalString -Value $InputRef
  if (-not [string]::IsNullOrWhiteSpace($trimmed) -and $trimmed -ne 'HEAD') {
    return $trimmed
  }

  try {
    $symbolic = (Invoke-GitCapture -RepositoryRoot $RepositoryRoot -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')).Trim()
    if (-not [string]::IsNullOrWhiteSpace($symbolic) -and $symbolic -ne 'HEAD') {
      return $symbolic
    }
  } catch {
  }

  return $ResolvedSha
}

function Test-PathExistsAtCommit {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryRoot,
    [Parameter(Mandatory = $true)]
    [string]$Commit,
    [Parameter(Mandatory = $true)]
    [string]$RepositoryPath
  )

  & git -C $RepositoryRoot cat-file -e "$Commit`:$RepositoryPath" 2>$null
  return ($LASTEXITCODE -eq 0)
}

function Resolve-CurrentRuntimeIdentifier {
  param([string]$Requested)

  if (-not [string]::IsNullOrWhiteSpace($Requested)) {
    return $Requested.Trim()
  }

  if ($IsWindows) {
    return 'win-x64'
  }
  if ($IsLinux) {
    return 'linux-x64'
  }

  throw 'Local review currently supports only win-x64 and linux-x64 compiler assets.'
}

function Resolve-CompilerExecutablePath {
  param(
    [AllowNull()]
    [string]$RequestedPath,
    [Parameter(Mandatory = $true)]
    [string]$BasePath
  )

  $effectivePath = if ([string]::IsNullOrWhiteSpace($RequestedPath)) {
    $env:COMPAREVI_HISTORY_REVIEW_COMPILER_PATH
  } else {
    $RequestedPath
  }
  if ([string]::IsNullOrWhiteSpace($effectivePath)) {
    return $null
  }

  $resolvedPath = Resolve-AbsolutePath -Path $effectivePath -BasePath $BasePath
  if (Test-Path -LiteralPath $resolvedPath -PathType Leaf) {
    return $resolvedPath
  }

  if (Test-Path -LiteralPath $resolvedPath -PathType Container) {
    $candidateName = if ($IsWindows) { 'comparevi-history-review-compiler.exe' } else { 'comparevi-history-review-compiler' }
    $candidatePath = Join-Path $resolvedPath $candidateName
    if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
      return $candidatePath
    }
  }

  throw "Review compiler path did not resolve to an executable or extracted CLI root: $resolvedPath"
}

function Assert-ImmutableReleaseTag {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Value,
    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  if ($Value -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$') {
    throw "$Name must be an immutable release tag. Actual: $Value"
  }
}

function Invoke-DownloadFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Uri,
    [Parameter(Mandatory = $true)]
    [string]$DestinationPath,
    [Parameter(Mandatory = $true)]
    [hashtable]$Headers
  )

  $destinationDir = Split-Path -Parent $DestinationPath
  if (-not [string]::IsNullOrWhiteSpace($destinationDir)) {
    New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
  }

  $tempPath = $DestinationPath + '.tmp'
  if (Test-Path -LiteralPath $tempPath) {
    Remove-Item -LiteralPath $tempPath -Force
  }

  try {
    Invoke-WebRequest -Uri $Uri -Headers $Headers -OutFile $tempPath | Out-Null
    Move-Item -LiteralPath $tempPath -Destination $DestinationPath -Force
  } finally {
    if (Test-Path -LiteralPath $tempPath) {
      Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
  }
}

function Resolve-PublishedCompiler {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Repository,
    [string]$RequestedRef,
    [Parameter(Mandatory = $true)]
    [string]$RuntimeIdentifier,
    [Parameter(Mandatory = $true)]
    [string]$CacheRoot,
    [string]$Token
  )

  $publishedRefsOutputPath = Join-Path $CacheRoot 'published-refs.out'
  & (Join-Path $repoRoot 'scripts' 'Resolve-CompareVIHistoryPublishedRefs.ps1') `
    -Repository $Repository `
    -LatestImmutableTag $RequestedRef `
    -GitHubToken $Token `
    -GitHubOutputPath $publishedRefsOutputPath | Out-Null

  $publishedRefValues = Read-KeyValueFile -Path $publishedRefsOutputPath
  $resolvedRef = [string]$publishedRefValues['latest-immutable-tag']
  if ([string]::IsNullOrWhiteSpace($resolvedRef)) {
    throw 'Failed to resolve the immutable review compiler release tag.'
  }
  Assert-ImmutableReleaseTag -Value $resolvedRef -Name 'Resolved compiler release tag'

  $headers = Get-GitHubHeaders -Token $Token
  $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/tags/$resolvedRef" -Headers $headers
  $releaseAssets = @(ConvertTo-ObjectArray -Value $release.assets)
  if ($releaseAssets.Count -eq 0) {
    throw "Compiler release '$resolvedRef' did not expose any assets."
  }

  $manifestAsset = @($releaseAssets | Where-Object { [string]$_.name -eq 'comparevi-history-review-compiler-release.json' } | Select-Object -First 1)
  if (-not $manifestAsset) {
    throw "Compiler release '$resolvedRef' did not publish comparevi-history-review-compiler-release.json."
  }

  $downloadsRoot = Join-Path $CacheRoot 'downloads'
  $manifestPath = Join-Path $downloadsRoot 'comparevi-history-review-compiler-release.json'
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    Invoke-DownloadFile -Uri ([string]$manifestAsset.browser_download_url) -DestinationPath $manifestPath -Headers $headers
  }

  $releaseManifest = Read-JsonFile -Path $manifestPath
  if ([string]$releaseManifest.schema -ne 'comparevi-history/review-compiler-release@v1') {
    throw "Unsupported review compiler release manifest schema in '$manifestPath': $($releaseManifest.schema)"
  }

  $runtimeAsset = @($releaseManifest.assets | Where-Object { [string]$_.runtimeIdentifier -eq $RuntimeIdentifier } | Select-Object -First 1)
  if (-not $runtimeAsset) {
    throw "Compiler release '$resolvedRef' did not publish a '$RuntimeIdentifier' runtime asset."
  }

  $archiveName = [string]$runtimeAsset.fileName
  $releaseArchive = @($releaseAssets | Where-Object { [string]$_.name -eq $archiveName } | Select-Object -First 1)
  if (-not $releaseArchive) {
    throw "Compiler release '$resolvedRef' is missing runtime asset '$archiveName'."
  }

  $archivePath = Join-Path $downloadsRoot $archiveName
  $expectedSha256 = ([string]$runtimeAsset.sha256).ToLowerInvariant()
  $needsDownload = $true
  if (Test-Path -LiteralPath $archivePath -PathType Leaf) {
    $actualSha256 = ((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash).ToLowerInvariant()
    if ($actualSha256 -eq $expectedSha256) {
      $needsDownload = $false
    } else {
      Remove-Item -LiteralPath $archivePath -Force
    }
  }

  if ($needsDownload) {
    Invoke-DownloadFile -Uri ([string]$releaseArchive.browser_download_url) -DestinationPath $archivePath -Headers $headers
    $actualSha256 = ((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash).ToLowerInvariant()
    if ($actualSha256 -ne $expectedSha256) {
      throw "Compiler runtime asset checksum mismatch for '$archivePath'. Expected '$expectedSha256', actual '$actualSha256'."
    }
  }

  $extractRoot = Join-Path $CacheRoot 'extracted'
  $packageDirectory = Join-Path $extractRoot ([string]$runtimeAsset.packageDirectory)
  $executablePath = Join-Path $packageDirectory ([string]$runtimeAsset.entryExecutable)
  if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
    if (Test-Path -LiteralPath $extractRoot) {
      Remove-Item -LiteralPath $extractRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
    Expand-Archive -LiteralPath $archivePath -DestinationPath $extractRoot -Force
  }

  if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
    throw "Extracted compiler executable was not found: $executablePath"
  }

  if (-not $IsWindows) {
    & chmod +x $executablePath
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to mark compiler executable as runnable: $executablePath"
    }
  }

  return [ordered]@{
    source = 'published-release'
    repository = $Repository
    ref = $resolvedRef
    runtimeIdentifier = $RuntimeIdentifier
    executablePath = $executablePath
    cacheRoot = $CacheRoot
    archivePath = $archivePath
    releaseManifestPath = $manifestPath
  }
}

function Resolve-ExplicitChanges {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Paths
  )

  $changes = New-Object System.Collections.Generic.List[object]
  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($entry in @($Paths | ForEach-Object { $_ })) {
    $normalized = Normalize-RepositoryPath -Path (Get-OptionalString -Value $entry)
    if ([string]::IsNullOrWhiteSpace($normalized)) {
      continue
    }
    if (-not $normalized.EndsWith('.vi', [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Local review explicit paths must point to '.vi' files. Actual: $normalized"
    }
    if ($seen.Add($normalized)) {
      $changes.Add([ordered]@{
          status = 'modified'
          currentPath = $normalized
          previousPath = $null
        }) | Out-Null
    }
  }

  return @($changes | ForEach-Object { $_ })
}

function Resolve-GitDiffChanges {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryRoot,
    [Parameter(Mandatory = $true)]
    [string]$BaseSha,
    [Parameter(Mandatory = $true)]
    [string]$HeadSha
  )

  $output = Invoke-GitCapture -RepositoryRoot $RepositoryRoot -Arguments @(
    'diff',
    '--name-status',
    '--find-renames=90%',
    '--no-ext-diff',
    $BaseSha,
    $HeadSha,
    '--',
    '*.vi'
  )

  $changes = New-Object System.Collections.Generic.List[object]
  foreach ($line in @($output -split "`r?`n")) {
    if ([string]::IsNullOrWhiteSpace($line)) {
      continue
    }

    $parts = @($line -split "`t")
    if ($parts.Count -lt 2) {
      throw "Unable to parse git diff line: $line"
    }

    $statusToken = [string]$parts[0]
    $statusCode = $statusToken.Substring(0, 1).ToUpperInvariant()
    switch ($statusCode) {
      'A' { $changes.Add([ordered]@{ status = 'added'; currentPath = Normalize-RepositoryPath -Path $parts[1]; previousPath = $null }) | Out-Null }
      'C' { $changes.Add([ordered]@{ status = 'copied'; currentPath = Normalize-RepositoryPath -Path $parts[$parts.Count - 1]; previousPath = Normalize-RepositoryPath -Path $parts[1] }) | Out-Null }
      'D' { $changes.Add([ordered]@{ status = 'deleted'; currentPath = Normalize-RepositoryPath -Path $parts[1]; previousPath = $null }) | Out-Null }
      'M' { $changes.Add([ordered]@{ status = 'modified'; currentPath = Normalize-RepositoryPath -Path $parts[1]; previousPath = $null }) | Out-Null }
      'R' { $changes.Add([ordered]@{ status = 'renamed'; currentPath = Normalize-RepositoryPath -Path $parts[$parts.Count - 1]; previousPath = Normalize-RepositoryPath -Path $parts[1] }) | Out-Null }
      'T' { $changes.Add([ordered]@{ status = 'type-changed'; currentPath = Normalize-RepositoryPath -Path $parts[1]; previousPath = $null }) | Out-Null }
      default {
        $changes.Add([ordered]@{
            status = $statusToken.ToLowerInvariant()
            currentPath = Normalize-RepositoryPath -Path $parts[$parts.Count - 1]
            previousPath = if ($parts.Count -gt 2) { Normalize-RepositoryPath -Path $parts[1] } else { $null }
          }) | Out-Null
      }
    }
  }

  return @($changes | ForEach-Object { $_ })
}

function New-SyntheticPolicyProjection {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$RequestedModes,
    [Parameter(Mandatory = $true)]
    [string]$NoisePolicyValue,
    [Parameter(Mandatory = $true)]
    [string]$PolicyPath
  )

  return [ordered]@{
    schema = 'comparevi-history/pr-policy@v2'
    path = $PolicyPath
    applied = $true
    discovery = [ordered]@{
      selectionMode = 'dynamic-paths'
      includePaths = @('**/*.vi')
      excludePaths = @()
      maxChangedViCount = 10
      overflowBehavior = 'block'
    }
    execution = [ordered]@{
      publicModes = @($RequestedModes)
      noisePolicy = $NoisePolicyValue
      history = [ordered]@{
        sourceBranchRefStrategy = 'pull-request-base'
        keepArtifactsOnNoDiff = $true
      }
    }
    reviewerSurface = [ordered]@{
      emitCommentBody = $true
      emitStepSummary = $true
      fullSurface = 'artifact-index'
    }
    trust = [ordered]@{
      forkBehavior = 'hosted-auto'
    }
  }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$resolvedGitHubToken = Resolve-GitHubToken
$consumerRootResolved = Resolve-AbsolutePath -Path $ConsumerRepositoryRoot -BasePath (Get-Location).Path
if (-not (Test-Path -LiteralPath $consumerRootResolved -PathType Container)) {
  throw "Consumer repository root not found: $consumerRootResolved"
}
[void](Invoke-GitCapture -RepositoryRoot $consumerRootResolved -Arguments @('rev-parse', '--show-toplevel'))

$resultsDirResolved = Resolve-AbsolutePath -Path $ResultsDir -BasePath $consumerRootResolved
if (Test-Path -LiteralPath $resultsDirResolved) {
  Remove-Item -LiteralPath $resultsDirResolved -Recurse -Force
}
New-Item -ItemType Directory -Path $resultsDirResolved -Force | Out-Null

$requestedModes = ConvertTo-PublicModeList -Value $Mode
$headSha = Resolve-CommitSha -RepositoryRoot $consumerRootResolved -Ref $HeadRef
$headRefDisplay = Resolve-DisplayRef -RepositoryRoot $consumerRootResolved -InputRef $HeadRef -ResolvedSha $headSha

$baseRefInput = Get-OptionalString -Value $BaseRef
$baseSha = if ([string]::IsNullOrWhiteSpace($baseRefInput)) { $headSha } else { Resolve-CommitSha -RepositoryRoot $consumerRootResolved -Ref $baseRefInput }
$baseRefDisplay = if ([string]::IsNullOrWhiteSpace($baseRefInput)) {
  $headRefDisplay
} else {
  Resolve-DisplayRef -RepositoryRoot $consumerRootResolved -InputRef $baseRefInput -ResolvedSha $baseSha
}
$sourceBranchRef = if ([string]::IsNullOrWhiteSpace($baseRefInput)) { $null } else { $baseRefDisplay }
$consumerRepositorySlug = Resolve-ConsumerRepositorySlug -RepositoryRoot $consumerRootResolved -Override $ConsumerRepository

$selectionMode = if ($PSCmdlet.ParameterSetName -eq 'changed') { 'git-diff' } else { 'explicit-paths' }
$changedViFiles = @(
  if ($PSCmdlet.ParameterSetName -eq 'changed') {
    Resolve-GitDiffChanges -RepositoryRoot $consumerRootResolved -BaseSha $baseSha -HeadSha $headSha
  } else {
    Resolve-ExplicitChanges -Paths $ViPath
  }
)

$selectedTargets = New-Object System.Collections.Generic.List[object]
$excludedViFiles = New-Object System.Collections.Generic.List[object]
$maxChangedViCount = 10
$overflowed = $changedViFiles.Count -gt $maxChangedViCount
$overflowChangedViCount = if ($overflowed) { $changedViFiles.Count - $maxChangedViCount } else { 0 }

if (-not $overflowed) {
  foreach ($change in $changedViFiles) {
    $currentPath = Normalize-RepositoryPath -Path ([string]$change.currentPath)
    if ([string]::IsNullOrWhiteSpace($currentPath)) {
      continue
    }

    if ([string]$change.status -eq 'deleted') {
      $excludedViFiles.Add([ordered]@{
          status = [string]$change.status
          currentPath = $currentPath
          previousPath = Get-OptionalString -Value $change.previousPath
          exclusionReason = 'deleted-vi-not-executable'
        }) | Out-Null
      continue
    }

    if (-not (Test-PathExistsAtCommit -RepositoryRoot $consumerRootResolved -Commit $headSha -RepositoryPath $currentPath)) {
      $excludedViFiles.Add([ordered]@{
          status = [string]$change.status
          currentPath = $currentPath
          previousPath = Get-OptionalString -Value $change.previousPath
          exclusionReason = 'missing-current-target-path'
        }) | Out-Null
      continue
    }

    $selectedTargets.Add([ordered]@{
        targetId = New-SyntheticTargetId -TargetPath $currentPath
        targetSource = 'dynamic-path'
        targetPath = $currentPath
        requestedModes = @($requestedModes)
        requestedModeSource = 'pr-policy'
        history = [ordered]@{
          branchBudget = [ordered]@{
            sourceBranchRef = $sourceBranchRef
            maxCommitCount = $null
            source = 'pull-request-base'
          }
        }
        keepArtifactsOnNoDiff = $true
        currentPath = $currentPath
        previousPath = Get-OptionalString -Value $change.previousPath
        changeStatus = [string]$change.status
      }) | Out-Null
  }
}

$discoveryStatus = 'ready'
$discoveryReason = 'selected-targets'
if ($overflowed) {
  $discoveryStatus = 'blocked'
  $discoveryReason = 'max-changed-vi-count-exceeded'
} elseif ($changedViFiles.Count -eq 0) {
  $discoveryStatus = 'skipped'
  $discoveryReason = 'no-vi-files-changed'
} elseif ($selectedTargets.Count -eq 0) {
  $discoveryStatus = 'skipped'
  $discoveryReason = 'no-executable-vi-targets'
}

$policyProjectionPath = Join-Path $resultsDirResolved 'local-review-pr-policy.json'
$policyProjection = New-SyntheticPolicyProjection -RequestedModes $requestedModes -NoisePolicyValue $NoisePolicy -PolicyPath $policyProjectionPath
($policyProjection | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $policyProjectionPath -Encoding utf8

$discoveryPath = Join-Path $resultsDirResolved 'changed-vi-discovery.json'
$discoveryReceipt = [ordered]@{
  schema = 'comparevi-history/changed-vi-discovery@v2'
  generatedAtUtc = [DateTime]::UtcNow.ToString('o')
  repository = $consumerRepositorySlug
  eventName = 'pull_request'
  prPolicy = $policyProjection
  executionContext = [ordered]@{
    selectionMode = 'dynamic-paths'
    forkBehavior = 'hosted-auto'
    fullSurface = 'artifact-index'
  }
  pullRequest = [ordered]@{
    number = 1
    htmlUrl = $null
    baseRepository = $consumerRepositorySlug
    baseRef = $baseRefDisplay
    baseSha = $baseSha
    headRepository = $consumerRepositorySlug
    headRef = $headRefDisplay
    headSha = $headSha
    isFork = $false
    changedFileCount = $changedViFiles.Count
  }
  changedViFiles = @($changedViFiles | ForEach-Object { $_ })
  excludedViFiles = @($excludedViFiles | ForEach-Object { $_ })
  selectedTargets = @($selectedTargets | ForEach-Object { $_ })
  summary = [ordered]@{
    selectionMode = 'dynamic-paths'
    executionStatus = $discoveryStatus
    executionReason = $discoveryReason
    changedViCount = $changedViFiles.Count
    eligibleChangedViCount = $changedViFiles.Count
    excludedViCount = $excludedViFiles.Count
    selectedTargetCount = $selectedTargets.Count
    overflowBehavior = 'block'
    overflowed = $overflowed
    overflowChangedViCount = $overflowChangedViCount
  }
}
($discoveryReceipt | ConvertTo-Json -Depth 64) | Set-Content -LiteralPath $discoveryPath -Encoding utf8

$compilerBasePath = (Get-Location).Path
$resolvedCompilerExecutable = Resolve-CompilerExecutablePath -RequestedPath $CompilerPath -BasePath $compilerBasePath
$compilerInfo = if ($null -ne $resolvedCompilerExecutable) {
  [ordered]@{
    source = 'provided-path'
    repository = $CompilerRepository
    ref = if ([string]::IsNullOrWhiteSpace($CompilerRef)) { 'provided-path' } else { $CompilerRef.Trim() }
    runtimeIdentifier = Resolve-CurrentRuntimeIdentifier -Requested $CompilerRuntimeIdentifier
    executablePath = $resolvedCompilerExecutable
    cacheRoot = $null
    archivePath = $null
    releaseManifestPath = $null
  }
} else {
  Resolve-PublishedCompiler `
    -Repository $CompilerRepository `
    -RequestedRef $CompilerRef `
    -RuntimeIdentifier (Resolve-CurrentRuntimeIdentifier -Requested $CompilerRuntimeIdentifier) `
    -CacheRoot (Join-Path $resultsDirResolved '.compiler-cache') `
    -Token $resolvedGitHubToken
}

$targetManifestPath = $null
$manifestTargets = New-Object System.Collections.Generic.List[object]
$runtimeReceipts = New-Object System.Collections.Generic.List[object]
$effectiveToolingRoot = if ([string]::IsNullOrWhiteSpace($ToolingRoot)) { $null } else { (Resolve-AbsolutePath -Path $ToolingRoot -BasePath (Get-Location).Path) }
$invocationScriptPath = if ([string]::IsNullOrWhiteSpace($InvokeScriptPath)) { $null } else { (Resolve-AbsolutePath -Path $InvokeScriptPath -BasePath $consumerRootResolved) }

if ($discoveryStatus -eq 'ready') {
  $targetOrdinal = 0
  foreach ($selectedTarget in @($selectedTargets | ForEach-Object { $_ })) {
    $targetOrdinal += 1
    $targetResultsDir = Join-Path $resultsDirResolved ('targets/{0:D3}-{1}' -f $targetOrdinal, [string]$selectedTarget.targetId)
    $localFastLoopPath = Join-Path $targetResultsDir 'local-fast-loop.json'
    $localFastLoopReceipt = $null
    $caughtException = $null
    try {
      $fastLoopArgs = @{
        ConsumerRepositoryRoot = $consumerRootResolved
        ViPath = [string]$selectedTarget.targetPath
        RuntimeProfile = $Profile
        ConsumerRef = $headSha
        SourceBranchRef = $sourceBranchRef
        ConsumerRepository = $consumerRepositorySlug
        ResultsDir = $targetResultsDir
        Mode = ($requestedModes -join ',')
        NoisePolicy = $NoisePolicy
        IncludeMergeParents = $IncludeMergeParents.IsPresent
        CompareviRepository = $CompareviRepository
        GitHubToken = $resolvedGitHubToken
      }
      if ($null -ne $CompareTimeoutSeconds) {
        $fastLoopArgs.CompareTimeoutSeconds = [int]$CompareTimeoutSeconds
      }
      if (-not [string]::IsNullOrWhiteSpace($WarmRuntimeDir)) {
        $fastLoopArgs.WarmRuntimeDir = $WarmRuntimeDir
      }
      if ($null -ne $effectiveToolingRoot) {
        $fastLoopArgs.ToolingRoot = $effectiveToolingRoot
      }
      if (-not [string]::IsNullOrWhiteSpace($CompareviRef)) {
        $fastLoopArgs.CompareviRef = $CompareviRef
      }
      if (-not [string]::IsNullOrWhiteSpace($ContainerImage)) {
        $fastLoopArgs.ContainerImage = $ContainerImage
      }
      if ($targetOrdinal -gt 1 -or $SkipImagePull.IsPresent) {
        $fastLoopArgs.SkipImagePull = $true
      }
      if ($SkipDevImageBuild.IsPresent) {
        $fastLoopArgs.SkipDevImageBuild = $true
      }
      if (-not [string]::IsNullOrWhiteSpace($invocationScriptPath)) {
        $fastLoopArgs.InvokeScriptPath = $invocationScriptPath
      }

      & (Join-Path $repoRoot 'scripts' 'Invoke-CompareVIHistoryManualExplorationFastLoop.ps1') @fastLoopArgs | Out-Null
      if (-not (Test-Path -LiteralPath $localFastLoopPath -PathType Leaf)) {
        throw "Local fast-loop receipt was not written: $localFastLoopPath"
      }
      $localFastLoopReceipt = Read-JsonFile -Path $localFastLoopPath
    } catch {
      $caughtException = $_
      if (Test-Path -LiteralPath $localFastLoopPath -PathType Leaf) {
        $localFastLoopReceipt = Read-JsonFile -Path $localFastLoopPath
      }
    }

    if ($null -ne $localFastLoopReceipt -and -not [string]::IsNullOrWhiteSpace([string]$localFastLoopReceipt.tooling.root)) {
      $effectiveToolingRoot = [string]$localFastLoopReceipt.tooling.root
    }
    if ($null -ne $localFastLoopReceipt) {
      $runtimeReceipts.Add($localFastLoopReceipt) | Out-Null
    }

    $publicRunReceipt = $null
    $publicRunPath = Get-OptionalString -Value $(if ($null -eq $localFastLoopReceipt) { $null } else { $localFastLoopReceipt.outputs.publicRunPath })
    if (-not [string]::IsNullOrWhiteSpace($publicRunPath) -and (Test-Path -LiteralPath $publicRunPath -PathType Leaf)) {
      $publicRunReceipt = Read-JsonFile -Path $publicRunPath
    }

    $targetFinalStatus = if ($null -ne $localFastLoopReceipt) { Get-OptionalString -Value $localFastLoopReceipt.summary.finalStatus } else { 'failed' }
    if ([string]::IsNullOrWhiteSpace($targetFinalStatus)) {
      $targetFinalStatus = if ($null -ne $publicRunReceipt) { [string]$publicRunReceipt.summary.finalStatus } else { 'failed' }
    }
    $targetFinalReason = if ($null -ne $localFastLoopReceipt) { Get-OptionalString -Value $localFastLoopReceipt.summary.finalReason } else { 'local-fast-loop-failed' }
    if ([string]::IsNullOrWhiteSpace($targetFinalReason)) {
      $targetFinalReason = if ($null -ne $publicRunReceipt) { [string]$publicRunReceipt.summary.finalReason } else { 'local-fast-loop-failed' }
    }
    if ($null -ne $caughtException -and [string]::IsNullOrWhiteSpace($targetFinalReason)) {
      $targetFinalReason = 'local-fast-loop-failed'
    }

    $manifestTargets.Add([ordered]@{
        targetId = [string]$selectedTarget.targetId
        targetSource = [string]$selectedTarget.targetSource
        targetPath = [string]$selectedTarget.targetPath
        requestedModes = @($selectedTarget.requestedModes | ForEach-Object { [string]$_ })
        requestedModeSource = [string]$selectedTarget.requestedModeSource
        sourceBranchRef = $sourceBranchRef
        keepArtifactsOnNoDiff = [bool]$selectedTarget.keepArtifactsOnNoDiff
        currentPath = [string]$selectedTarget.currentPath
        previousPath = Get-OptionalString -Value $selectedTarget.previousPath
        changeStatus = [string]$selectedTarget.changeStatus
        finalStatus = $targetFinalStatus
        finalReason = $targetFinalReason
        requestPath = Get-OptionalString -Value $(if ($null -eq $localFastLoopReceipt) { $null } else { $localFastLoopReceipt.outputs.requestPath })
        publicRunPath = $publicRunPath
        sharedEvidencePath = Get-OptionalString -Value $(if ($null -eq $localFastLoopReceipt) { $null } else { $localFastLoopReceipt.outputs.sharedEvidencePath })
        historySummaryJsonPath = Get-OptionalString -Value $(if ($null -eq $localFastLoopReceipt) { $null } else { $localFastLoopReceipt.outputs.historySummaryJson })
        manifestPath = Get-OptionalString -Value $(if ($null -eq $publicRunReceipt) { $null } else { $publicRunReceipt.outputs.manifestPath })
        historyReportMdPath = Get-OptionalString -Value $(if ($null -eq $localFastLoopReceipt) { $null } else { $localFastLoopReceipt.outputs.historyReportMd })
        historyReportHtmlPath = Get-OptionalString -Value $(if ($null -eq $localFastLoopReceipt) { $null } else { $localFastLoopReceipt.outputs.historyReportHtml })
        modeSummaryJsonPath = Get-OptionalString -Value $(if ($null -eq $localFastLoopReceipt) { $null } else { $localFastLoopReceipt.outputs.modeSummaryJsonPath })
        modeSummaryPath = Get-OptionalString -Value $(if ($null -eq $localFastLoopReceipt) { $null } else { $localFastLoopReceipt.outputs.modeSummaryPath })
        totalProcessed = if ($null -eq $publicRunReceipt -or $null -eq $publicRunReceipt.summary.totalProcessed) { $null } else { [int]$publicRunReceipt.summary.totalProcessed }
        totalDiffs = if ($null -eq $publicRunReceipt -or $null -eq $publicRunReceipt.summary.totalDiffs) { $null } else { [int]$publicRunReceipt.summary.totalDiffs }
      }) | Out-Null
  }

  $targetManifestPath = Join-Path $resultsDirResolved 'pr-target-runs-manifest.json'
  $failedTargetCount = @($manifestTargets | Where-Object { [string]$_.finalStatus -ne 'succeeded' }).Count
  ([ordered]@{
      schema = 'comparevi-history/pr-target-runs-manifest@v2'
      generatedAtUtc = [DateTime]::UtcNow.ToString('o')
      summary = [ordered]@{
        selectedTargetCount = $selectedTargets.Count
        executedTargetCount = $manifestTargets.Count
        failedTargetCount = $failedTargetCount
        skippedTargetCount = 0
        executionStatus = if ($failedTargetCount -gt 0) { 'failed' } else { 'succeeded' }
        executionReason = if ($failedTargetCount -gt 0) { 'one-or-more-targets-failed' } else { 'completed' }
      }
      targets = @($manifestTargets | ForEach-Object { $_ })
    } | ConvertTo-Json -Depth 64) | Set-Content -LiteralPath $targetManifestPath -Encoding utf8
}

$originalCompilerEnv = $env:COMPAREVI_HISTORY_REVIEW_COMPILER_PATH
try {
  $env:COMPAREVI_HISTORY_REVIEW_COMPILER_PATH = [string]$compilerInfo.executablePath
  $aggregateArgs = @{
    DiscoveryPath = $discoveryPath
    ResultsDir = $resultsDirResolved
    ArtifactName = 'comparevi-history-local-review'
  }
  if (-not [string]::IsNullOrWhiteSpace($targetManifestPath)) {
    $aggregateArgs.TargetRunsManifestPath = $targetManifestPath
  }
  $prRunJson = & (Join-Path $repoRoot 'scripts' 'Write-CompareVIHistoryAutomaticPullRequestRun.ps1') @aggregateArgs
} finally {
  if ($null -eq $originalCompilerEnv) {
    Remove-Item Env:COMPAREVI_HISTORY_REVIEW_COMPILER_PATH -ErrorAction SilentlyContinue
  } else {
    $env:COMPAREVI_HISTORY_REVIEW_COMPILER_PATH = $originalCompilerEnv
  }
}

$prRunReceipt = $prRunJson | ConvertFrom-Json -Depth 64
$localSummaryPath = Join-Path $resultsDirResolved 'local-review-summary.md'
$localReceiptPath = Join-Path $resultsDirResolved 'local-review.json'
$executedTargetCount = 0
$failedTargetCount = 0
$compareTimeoutValue = if ($null -eq $CompareTimeoutSeconds) { $null } else { [int]$CompareTimeoutSeconds }
$containerImageValue = if ([string]::IsNullOrWhiteSpace($ContainerImage)) { $null } else { $ContainerImage.Trim() }
if ($null -ne $targetManifestPath) {
  $executedTargetCount = $manifestTargets.Count
  $failedTargetCount = @($manifestTargets | Where-Object { [string]$_.finalStatus -ne 'succeeded' }).Count
}

$requestedViPaths = @($changedViFiles | ForEach-Object { [string]$_.currentPath })
$previewManifestPathValue = Get-OptionalString -Value $prRunReceipt.outputs.previewManifestPath
$prRunPathValue = Get-OptionalString -Value $prRunReceipt.outputs.prRunPath
$publicCommentPathValue = Get-OptionalString -Value $prRunReceipt.outputs.publicCommentPath
$publicStepSummaryPathValue = Get-OptionalString -Value $prRunReceipt.outputs.publicStepSummaryPath
$indexMarkdownPathValue = Get-OptionalString -Value $prRunReceipt.outputs.indexMarkdownPath
$indexHtmlPathValue = Get-OptionalString -Value $prRunReceipt.outputs.indexHtmlPath
$reviewBundlePathValue = Join-Path $resultsDirResolved 'review-bundle.json'
$normalizedRuntimeReceipts = @(
  $runtimeReceipts |
    ForEach-Object { ConvertTo-ObjectArray -Value $_ } |
    ForEach-Object { $_ }
)
$runtimeImages = @($normalizedRuntimeReceipts | ForEach-Object { Get-OptionalString -Value (Get-OptionalPropertyValue -InputObject (Get-OptionalPropertyValue -InputObject $_ -PropertyName 'runtime') -PropertyName 'image') } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
$runtimeToolSources = @($normalizedRuntimeReceipts | ForEach-Object { Get-OptionalString -Value (Get-OptionalPropertyValue -InputObject (Get-OptionalPropertyValue -InputObject $_ -PropertyName 'runtime') -PropertyName 'toolSource') } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
$runtimeReuseStates = @($normalizedRuntimeReceipts | ForEach-Object { Get-OptionalString -Value (Get-OptionalPropertyValue -InputObject (Get-OptionalPropertyValue -InputObject $_ -PropertyName 'runtime') -PropertyName 'cacheReuseState') } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
$runtimeTemperatureClasses = @($normalizedRuntimeReceipts | ForEach-Object { Get-OptionalString -Value (Get-OptionalPropertyValue -InputObject (Get-OptionalPropertyValue -InputObject $_ -PropertyName 'runtime') -PropertyName 'coldWarmClass') } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
$runtimeWarmDirs = @($normalizedRuntimeReceipts | ForEach-Object { Get-OptionalString -Value (Get-OptionalPropertyValue -InputObject (Get-OptionalPropertyValue -InputObject $_ -PropertyName 'runtime') -PropertyName 'warmRuntimeDir') } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)

$consumerReceipt = [ordered]@{
  repositoryRoot = $consumerRootResolved
  repository = $consumerRepositorySlug
  selectionMode = $selectionMode
  baseRef = $baseRefDisplay
  baseSha = $baseSha
  headRef = $headRefDisplay
  headSha = $headSha
}

$invocationReceipt = [ordered]@{
  runtimeProfile = $Profile
  requestedViPaths = $requestedViPaths
  requestedModes = @($requestedModes)
  noisePolicy = $NoisePolicy
  includeMergeParents = [bool]$IncludeMergeParents.IsPresent
  compareTimeoutSeconds = $compareTimeoutValue
  skipImagePull = [bool]$SkipImagePull.IsPresent
  skipDevImageBuild = [bool]$SkipDevImageBuild.IsPresent
  containerImage = $containerImageValue
  warmRuntimeDir = Get-OptionalString -Value $WarmRuntimeDir
}

$projectionReceipt = [ordered]@{
  prPolicyPath = $policyProjectionPath
  changedViDiscoveryPath = $discoveryPath
  targetRunsManifestPath = $targetManifestPath
  previewManifestPath = $previewManifestPathValue
  prRunPath = $prRunPathValue
  publicCommentPath = $publicCommentPathValue
  publicStepSummaryPath = $publicStepSummaryPathValue
}

$outputReceipt = [ordered]@{
  resultsDir = $resultsDirResolved
  localSummaryPath = $localSummaryPath
  reviewBundlePath = $reviewBundlePathValue
  indexMarkdownPath = $indexMarkdownPathValue
  indexHtmlPath = $indexHtmlPathValue
}

$summaryReceipt = [ordered]@{
  changedViCount = $changedViFiles.Count
  selectedTargetCount = $selectedTargets.Count
  executedTargetCount = $executedTargetCount
  failedTargetCount = $failedTargetCount
  finalStatus = [string]$prRunReceipt.summary.finalStatus
  finalReason = [string]$prRunReceipt.summary.finalReason
}

$runtimeReceipt = [ordered]@{
  profile = $Profile
  image = if ($runtimeImages.Count -eq 1) { $runtimeImages[0] } elseif ($runtimeImages.Count -gt 1) { $runtimeImages -join ', ' } else { $containerImageValue }
  toolSource = if ($runtimeToolSources.Count -eq 1) { $runtimeToolSources[0] } elseif ($runtimeToolSources.Count -gt 1) { 'mixed' } else { $null }
  cacheReuseState = if ($runtimeReuseStates.Count -eq 1) { $runtimeReuseStates[0] } elseif ($runtimeReuseStates.Count -gt 1) { 'mixed' } else { $null }
  coldWarmClass = if ($runtimeTemperatureClasses.Count -eq 1) { $runtimeTemperatureClasses[0] } elseif ($runtimeTemperatureClasses.Count -gt 1) { 'mixed' } else { $null }
  warmRuntimeDir = if ($runtimeWarmDirs.Count -eq 1) { $runtimeWarmDirs[0] } elseif ($runtimeWarmDirs.Count -gt 1) { $runtimeWarmDirs -join ', ' } else { Get-OptionalString -Value $WarmRuntimeDir }
}
$localReviewTimer.Stop()
$timingsReceipt = [ordered]@{
  elapsedMilliseconds = [int]$localReviewTimer.ElapsedMilliseconds
  elapsedSeconds = [math]::Round($localReviewTimer.Elapsed.TotalSeconds, 3)
}

$localReceipt = [ordered]@{
  schema = 'comparevi-history/local-review@v1'
  generatedAtUtc = [DateTime]::UtcNow.ToString('o')
  consumer = $consumerReceipt
  invocation = $invocationReceipt
  runtime = $runtimeReceipt
  timings = $timingsReceipt
  compiler = $compilerInfo
  projections = $projectionReceipt
  outputs = $outputReceipt
  summary = $summaryReceipt
}
($localReceipt | ConvertTo-Json -Depth 64) | Set-Content -LiteralPath $localReceiptPath -Encoding utf8

@(
  '# comparevi-history local review'
  ''
  ('- Primary workspace: `{0}`' -f [string]$prRunReceipt.outputs.indexHtmlPath)
  ('- Markdown workspace: `{0}`' -f [string]$prRunReceipt.outputs.indexMarkdownPath)
  ('- Local receipt: `{0}`' -f $localReceiptPath)
  ('- Discovery projection: `{0}`' -f $discoveryPath)
  ('- Target-runs projection: `{0}`' -f $(if ([string]::IsNullOrWhiteSpace($targetManifestPath)) { 'n/a' } else { $targetManifestPath }))
  ('- PR-run compatibility projection: `{0}`' -f [string]$prRunReceipt.outputs.prRunPath)
  ('- PR-comment compatibility projection: `{0}`' -f $(if ([string]::IsNullOrWhiteSpace([string]$prRunReceipt.outputs.publicCommentPath)) { 'n/a' } else { [string]$prRunReceipt.outputs.publicCommentPath }))
  ('- Runtime profile: `{0}`' -f $Profile)
  ('- Runtime image: `{0}`' -f $(if ([string]::IsNullOrWhiteSpace([string]$runtimeReceipt.image)) { 'n/a' } else { [string]$runtimeReceipt.image }))
  ('- Runtime cache reuse: `{0}`' -f $(if ([string]::IsNullOrWhiteSpace([string]$runtimeReceipt.cacheReuseState)) { 'n/a' } else { [string]$runtimeReceipt.cacheReuseState }))
  ('- Runtime cold/warm class: `{0}`' -f $(if ([string]::IsNullOrWhiteSpace([string]$runtimeReceipt.coldWarmClass)) { 'n/a' } else { [string]$runtimeReceipt.coldWarmClass }))
  ('- Elapsed seconds: `{0}`' -f [string]$timingsReceipt.elapsedSeconds)
  ('- Compiler source: `{0}`' -f [string]$compilerInfo.source)
  ('- Compiler executable: `{0}`' -f [string]$compilerInfo.executablePath)
  ('- Final status: `{0}`' -f [string]$prRunReceipt.summary.finalStatus)
  ('- Final reason: `{0}`' -f [string]$prRunReceipt.summary.finalReason)
  ''
  'The `index.html` workspace is the primary local review surface. The PR-oriented receipts are compatibility projections so local runs and workflow runs share one bundle shape.'
) | Set-Content -LiteralPath $localSummaryPath -Encoding utf8

Write-ActionOutput -Key 'local-review-path' -Value $localReceiptPath
Write-ActionOutput -Key 'local-summary-path' -Value $localSummaryPath
Write-ActionOutput -Key 'changed-vi-discovery-path' -Value $discoveryPath
Write-ActionOutput -Key 'pr-target-runs-manifest-path' -Value $(if ([string]::IsNullOrWhiteSpace($targetManifestPath)) { '' } else { $targetManifestPath })
Write-ActionOutput -Key 'pr-run-path' -Value ([string]$prRunReceipt.outputs.prRunPath)
Write-ActionOutput -Key 'preview-manifest-path' -Value ([string]$prRunReceipt.outputs.previewManifestPath)
Write-ActionOutput -Key 'review-bundle-path' -Value (Join-Path $resultsDirResolved 'review-bundle.json')
Write-ActionOutput -Key 'index-markdown-path' -Value ([string]$prRunReceipt.outputs.indexMarkdownPath)
Write-ActionOutput -Key 'index-html-path' -Value ([string]$prRunReceipt.outputs.indexHtmlPath)
Write-ActionOutput -Key 'compiler-executable-path' -Value ([string]$compilerInfo.executablePath)
Write-ActionOutput -Key 'compiler-source' -Value ([string]$compilerInfo.source)
Write-ActionOutput -Key 'final-status' -Value ([string]$prRunReceipt.summary.finalStatus)
Write-ActionOutput -Key 'final-reason' -Value ([string]$prRunReceipt.summary.finalReason)

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  @(
    '## comparevi-history local review'
    ''
    ('- Selection mode: `{0}`' -f $selectionMode)
    ('- Changed VI files: `{0}`' -f $changedViFiles.Count)
    ('- Selected targets: `{0}`' -f $selectedTargets.Count)
    ('- Compiler source: `{0}`' -f [string]$compilerInfo.source)
    ('- Compiler executable: `{0}`' -f [string]$compilerInfo.executablePath)
    ('- Workspace: `{0}`' -f [string]$prRunReceipt.outputs.indexHtmlPath)
    ('- Final status: `{0}`' -f [string]$prRunReceipt.summary.finalStatus)
    ('- Final reason: `{0}`' -f [string]$prRunReceipt.summary.finalReason)
  ) | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
}

$localReceipt | ConvertTo-Json -Depth 64
