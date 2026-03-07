param(
  [string]$Repository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
  [string]$DefaultRepository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
  [string]$RequestedRef,
  [string]$DefaultRefPath,
  [string]$ActionRef,
  [string]$ToolingPath = '.comparevi-history-tools',
  [switch]$AllowSourceFallback,
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

function Add-Candidate {
  param(
    [Parameter(Mandatory = $true)]
    $List,
    [string]$Value,
    [Parameter(Mandatory = $true)]
    [string]$Origin
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return
  }

  $trimmed = $Value.Trim()
  if ($List | Where-Object { $_.value -eq $trimmed }) {
    return
  }

  $List.Add([pscustomobject]@{
      value = $trimmed
      origin = $Origin
    }) | Out-Null
}

function Get-GitHubHeaders {
  $headers = @{
    Accept = 'application/vnd.github+json'
    'User-Agent' = 'comparevi-history'
    'X-GitHub-Api-Version' = '2022-11-28'
  }

  if (-not [string]::IsNullOrWhiteSpace($GitHubToken)) {
    $headers.Authorization = "Bearer $GitHubToken"
  }

  return $headers
}

function Invoke-GitHubJson {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Uri
  )

  try {
    return Invoke-RestMethod -Uri $Uri -Headers (Get-GitHubHeaders)
  } catch {
    $response = $_.Exception.Response
    if ($null -ne $response -and [int]$response.StatusCode -eq 404) {
      return $null
    }

    throw
  }
}

function Get-ReleaseByTag {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepositorySlug,
    [Parameter(Mandatory = $true)]
    [string]$Tag
  )

  $encodedTag = [System.Uri]::EscapeDataString($Tag)
  $uri = "https://api.github.com/repos/$RepositorySlug/releases/tags/$encodedTag"
  return Invoke-GitHubJson -Uri $uri
}

function Resolve-GitRefSha {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepositorySlug,
    [Parameter(Mandatory = $true)]
    [string]$Ref
  )

  $encodedRef = [System.Uri]::EscapeDataString($Ref)
  $uri = "https://api.github.com/repos/$RepositorySlug/commits/$encodedRef"
  $commit = Invoke-GitHubJson -Uri $uri
  if ($null -eq $commit) {
    return $null
  }

  if ($commit.PSObject.Properties['sha']) {
    return [string]$commit.sha
  }

  return $null
}

function Get-BundleAsset {
  param([Parameter(Mandatory = $true)]$Release)

  $assets = @($Release.assets)
  if (-not $assets -or $assets.Count -eq 0) {
    return $null
  }

  return $assets |
    Where-Object { $_.name -like 'CompareVI.Tools-v*.zip' } |
    Select-Object -First 1
}

$defaultRef = $null
if (-not [string]::IsNullOrWhiteSpace($DefaultRefPath) -and (Test-Path -LiteralPath $DefaultRefPath -PathType Leaf)) {
  $defaultRef = (Get-Content -LiteralPath $DefaultRefPath -Raw).Trim()
}

if ($Repository -ne $DefaultRepository -and [string]::IsNullOrWhiteSpace($RequestedRef)) {
  throw "comparevi-history requires comparevi_ref when comparevi_repository overrides the default repository '$DefaultRepository'."
}

$candidateRefs = [System.Collections.Generic.List[object]]::new()
Add-Candidate -List $candidateRefs -Value $RequestedRef -Origin 'input'
Add-Candidate -List $candidateRefs -Value $defaultRef -Origin 'default'
if ([string]::IsNullOrWhiteSpace($RequestedRef)) {
  Add-Candidate -List $candidateRefs -Value $ActionRef -Origin 'action'
  Add-Candidate -List $candidateRefs -Value 'develop' -Origin 'fallback'
}

if ($candidateRefs.Count -eq 0) {
  throw 'Unable to resolve CompareVI backend because no candidate ref was available.'
}

$resolution = $null
$bundleFailures = [System.Collections.Generic.List[string]]::new()

foreach ($candidate in $candidateRefs) {
  $release = Get-ReleaseByTag -RepositorySlug $Repository -Tag $candidate.value
  if ($null -ne $release) {
    $bundleAsset = Get-BundleAsset -Release $release
    if ($null -ne $bundleAsset) {
      $resolvedSha = Resolve-GitRefSha -RepositorySlug $Repository -Ref $release.tag_name
      $resolution = [ordered]@{
        tooling_source = 'bundle'
        comparevi_ref = [string]$release.tag_name
        resolved_sha = if ([string]::IsNullOrWhiteSpace($resolvedSha)) { '' } else { $resolvedSha.Trim() }
        tooling_path = $ToolingPath
        release_tag = [string]$release.tag_name
        asset_name = [string]$bundleAsset.name
        asset_url = [string]$bundleAsset.browser_download_url
        asset_digest = if ($bundleAsset.PSObject.Properties['digest']) { [string]$bundleAsset.digest } else { '' }
        origin = [string]$candidate.origin
      }
      break
    }

    $bundleFailures.Add(("release tag '{0}' exists in {1} but does not publish a CompareVI.Tools zip asset" -f $candidate.value, $Repository)) | Out-Null
  }

  if ($candidate.origin -eq 'input' -and $AllowSourceFallback.IsPresent) {
    $resolvedSha = Resolve-GitRefSha -RepositorySlug $Repository -Ref $candidate.value
    if (-not [string]::IsNullOrWhiteSpace($resolvedSha)) {
      $resolution = [ordered]@{
        tooling_source = 'source-checkout'
        comparevi_ref = $candidate.value
        resolved_sha = $resolvedSha.Trim()
        tooling_path = $ToolingPath
        release_tag = ''
        asset_name = ''
        asset_url = ''
        asset_digest = ''
        origin = [string]$candidate.origin
      }
      break
    }
  }
}

if ($null -eq $resolution) {
  $requestedExplicitly = -not [string]::IsNullOrWhiteSpace($RequestedRef)
  $defaultLabel = if ([string]::IsNullOrWhiteSpace($defaultRef)) { 'none' } else { $defaultRef }
  $bundleNotes = if ($bundleFailures.Count -gt 0) { ' ' + ($bundleFailures -join '; ') + '.' } else { '' }

  if ($requestedExplicitly) {
    throw ("comparevi-history could not resolve '{0}' in {1} to either a CompareVI.Tools release bundle or a git ref for maintainer fallback.{2}" -f $RequestedRef.Trim(), $Repository, $bundleNotes)
  }

  throw ("comparevi-history requires comparevi-backend-ref.txt to pin an immutable backend release tag that publishes a CompareVI.Tools zip bundle. Current pin: '{0}'. Maintainers can temporarily override comparevi_ref in a trusted context to use source checkout for an unreleased backend ref.{1}" -f $defaultLabel, $bundleNotes)
}

Write-ActionOutput -Key 'tooling-source' -Value $resolution.tooling_source
Write-ActionOutput -Key 'comparevi-ref' -Value $resolution.comparevi_ref
Write-ActionOutput -Key 'resolved-sha' -Value $resolution.resolved_sha
Write-ActionOutput -Key 'tooling-path' -Value $resolution.tooling_path
Write-ActionOutput -Key 'release-tag' -Value $resolution.release_tag
Write-ActionOutput -Key 'bundle-asset-name' -Value $resolution.asset_name
Write-ActionOutput -Key 'bundle-asset-url' -Value $resolution.asset_url
Write-ActionOutput -Key 'bundle-asset-digest' -Value $resolution.asset_digest
Write-ActionOutput -Key 'resolution-origin' -Value $resolution.origin

if ($StepSummaryPath) {
  $summary = @(
    '## comparevi-history backend'
    ''
    ('- Repository: `{0}`' -f $Repository)
    ('- Requested ref: `{0}`' -f ($(if ([string]::IsNullOrWhiteSpace($RequestedRef)) { 'none' } else { $RequestedRef.Trim() })))
    ('- Default pin: `{0}`' -f ($(if ([string]::IsNullOrWhiteSpace($defaultRef)) { 'none' } else { $defaultRef })))
    ('- Resolution kind: `{0}`' -f $resolution.tooling_source)
    ('- Resolved ref: `{0}`' -f $resolution.comparevi_ref)
    ('- Resolved SHA: `{0}`' -f ($(if ([string]::IsNullOrWhiteSpace($resolution.resolved_sha)) { 'unknown' } else { $resolution.resolved_sha })))
    ('- Resolution origin: `{0}`' -f $resolution.origin)
  )

  if ($resolution.tooling_source -eq 'bundle') {
    $summary += ('- Bundle asset: `{0}`' -f $resolution.asset_name)
  } else {
    $summary += ('- Fallback tooling path: `{0}`' -f $resolution.tooling_path)
  }

  $summary | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
}
