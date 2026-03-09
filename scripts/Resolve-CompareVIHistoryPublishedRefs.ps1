param(
  [string]$Repository = 'LabVIEW-Community-CI-CD/comparevi-history',
  [string]$MajorTag = 'v1',
  [string]$LatestImmutableTag,
  [string]$LatestReleaseApiUrl,
  [string]$GitHubToken,
  [string]$GitHubOutputPath,
  [string]$OutputPath,
  [string]$StepSummaryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-GitHubHeaders {
  param(
    [string]$Token
  )

  $headers = @{
    Accept = 'application/vnd.github+json'
    'User-Agent' = 'comparevi-history-published-refs'
    'X-GitHub-Api-Version' = '2022-11-28'
  }

  if (-not [string]::IsNullOrWhiteSpace($Token)) {
    $headers.Authorization = "Bearer $Token"
  }

  return $headers
}

function Assert-ReleaseTag {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Tag,
    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  if ($Tag -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$') {
    throw "$Name must be an immutable release tag. Actual: $Tag"
  }
}

function Resolve-LatestImmutableReleaseTag {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Repository,
    [string]$ProvidedTag,
    [string]$ApiUrl,
    [string]$Token
  )

  if (-not [string]::IsNullOrWhiteSpace($ProvidedTag)) {
    $trimmedTag = $ProvidedTag.Trim()
    Assert-ReleaseTag -Tag $trimmedTag -Name 'LatestImmutableTag'
    return $trimmedTag
  }

  $resolvedApiUrl = if ([string]::IsNullOrWhiteSpace($ApiUrl)) {
    "https://api.github.com/repos/$Repository/releases/latest"
  } else {
    $ApiUrl
  }

  $release = Invoke-RestMethod -Uri $resolvedApiUrl -Headers (Get-GitHubHeaders -Token $Token)
  $tagName = [string]$release.tag_name
  if ([string]::IsNullOrWhiteSpace($tagName)) {
    throw "Latest release lookup for '$Repository' returned an empty tag_name."
  }

  Assert-ReleaseTag -Tag $tagName -Name 'Latest release tag'
  return $tagName
}

function New-PublishedRefRecord {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Repository,
    [Parameter(Mandatory = $true)]
    [string]$Label,
    [Parameter(Mandatory = $true)]
    [string]$Ref,
    [Parameter(Mandatory = $true)]
    [string]$Kind
  )

  $artifactSuffix = ($Ref -replace '[^0-9A-Za-z]+', '-').Trim('-').ToLowerInvariant()

  return [ordered]@{
    label          = $Label
    ref            = $Ref
    kind           = $Kind
    actionRef      = "$Repository@$Ref"
    artifactSuffix = $artifactSuffix
  }
}

if ($MajorTag -notmatch '^v[0-9]+$') {
  throw "MajorTag must match v<major>. Actual: $MajorTag"
}

$resolvedLatestImmutableTag = Resolve-LatestImmutableReleaseTag `
  -Repository $Repository `
  -ProvidedTag $LatestImmutableTag `
  -ApiUrl $LatestReleaseApiUrl `
  -Token $GitHubToken

$publishedRefs = New-Object System.Collections.Generic.List[object]
$publishedRefs.Add((New-PublishedRefRecord -Repository $Repository -Label 'major' -Ref $MajorTag -Kind 'moving-major'))
$publishedRefs.Add((New-PublishedRefRecord -Repository $Repository -Label 'immutable' -Ref $resolvedLatestImmutableTag -Kind 'immutable-release'))

$plan = [ordered]@{
  schema             = 'comparevi-history/published-ref-plan@v1'
  generatedAtUtc     = [DateTime]::UtcNow.ToString('o')
  repository         = $Repository
  majorTag           = $MajorTag
  latestImmutableTag = $resolvedLatestImmutableTag
  refs               = @($publishedRefs.ToArray())
}

$publishedRefsJson = ConvertTo-Json @($publishedRefs.ToArray()) -Depth 5 -Compress
$planJson = ConvertTo-Json $plan -Depth 8

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
  $outputDirectory = Split-Path -Parent $OutputPath
  if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
  }
  $planJson | Set-Content -LiteralPath $OutputPath -Encoding utf8
}

if (-not [string]::IsNullOrWhiteSpace($GitHubOutputPath)) {
  @(
    "latest-immutable-tag=$resolvedLatestImmutableTag"
    "published-refs-json=$publishedRefsJson"
  ) | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append

  if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    "published-ref-plan-path=$OutputPath" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
  }
}

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  @(
    '## comparevi-history published refs'
    ''
    ('- Repository: `{0}`' -f $Repository)
    ('- Major tag: `{0}`' -f $MajorTag)
    ('- Latest immutable tag: `{0}`' -f $resolvedLatestImmutableTag)
    ('- Published refs: `{0}`' -f ((@($publishedRefs.ToArray()) | ForEach-Object { $_.actionRef }) -join ', '))
  ) | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
}

$planJson
