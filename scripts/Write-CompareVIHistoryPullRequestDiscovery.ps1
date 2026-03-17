param(
  [Parameter(Mandatory = $true)]
  [string]$EventName,
  [Parameter(Mandatory = $true)]
  [string]$EventPath,
  [Parameter(Mandatory = $true)]
  [string]$TargetSpecPath,
  [Parameter(Mandatory = $true)]
  [string]$ResultsDir,
  [string]$Repository,
  [string]$GitHubToken,
  [string]$FilesPayloadPath,
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

function Get-NestedValue {
  param(
    [AllowNull()]
    [object]$Object,
    [Parameter(Mandatory = $true)]
    [string[]]$Path,
    [AllowNull()]
    $Default = $null
  )

  $current = $Object
  foreach ($segment in $Path) {
    if ($null -eq $current) {
      return $Default
    }

    $property = $current.PSObject.Properties[$segment]
    if ($null -eq $property) {
      return $Default
    }

    $current = $property.Value
  }

  if ($null -eq $current) {
    return $Default
  }

  return $current
}

function ConvertTo-ObjectArray {
  param(
    [AllowNull()]
    $Value
  )

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

function Get-OptionalString {
  param(
    [AllowNull()]
    $Value
  )

  if ($null -eq $Value) {
    return $null
  }

  $stringValue = [string]$Value
  if ([string]::IsNullOrWhiteSpace($stringValue)) {
    return $null
  }

  return $stringValue.Trim()
}

function Read-JsonFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $raw = Get-Content -LiteralPath $Path -Raw
  if ([string]::IsNullOrWhiteSpace($raw)) {
    throw "JSON file was empty: $Path"
  }

  return $raw | ConvertFrom-Json -Depth 100
}

function Invoke-PullRequestFilesApi {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepositorySlug,
    [Parameter(Mandatory = $true)]
    [int]$PullRequestNumber,
    [string]$Token
  )

  if ([string]::IsNullOrWhiteSpace($Token)) {
    throw 'GitHub token is required to discover changed pull-request files.'
  }

  $headers = @{
    Accept = 'application/vnd.github+json'
    Authorization = "Bearer $Token"
    'User-Agent' = 'comparevi-history-pr-discovery'
    'X-GitHub-Api-Version' = '2022-11-28'
  }

  $files = New-Object System.Collections.Generic.List[object]
  $page = 1
  while ($true) {
    $uri = "https://api.github.com/repos/$RepositorySlug/pulls/$PullRequestNumber/files?per_page=100&page=$page"
    $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
    $pageEntries = @(ConvertTo-ObjectArray -Value $response)
    foreach ($entry in $pageEntries) {
      $files.Add($entry) | Out-Null
    }

    if ($pageEntries.Count -lt 100) {
      break
    }

    $page += 1
  }

  return @($files | ForEach-Object { $_ })
}

if ($EventName -notin @('pull_request', 'pull_request_target')) {
  throw "comparevi-history pull-request discovery requires pull_request or pull_request_target events. Actual: $EventName"
}

$basePath = (Get-Location).Path
$eventPathResolved = Resolve-AbsolutePath -Path $EventPath -BasePath $basePath
$targetSpecPathResolved = Resolve-AbsolutePath -Path $TargetSpecPath -BasePath $basePath
$resultsDirResolved = Resolve-AbsolutePath -Path $ResultsDir -BasePath $basePath
$receiptPath = Join-Path $resultsDirResolved 'changed-vi-discovery.json'

if (-not (Test-Path -LiteralPath $eventPathResolved -PathType Leaf)) {
  throw "GitHub event payload not found: $eventPathResolved"
}
if (-not (Test-Path -LiteralPath $targetSpecPathResolved -PathType Leaf)) {
  throw "Target catalog not found: $targetSpecPathResolved"
}

New-Item -ItemType Directory -Path $resultsDirResolved -Force | Out-Null

$eventPayload = Read-JsonFile -Path $eventPathResolved
$pullRequest = Get-NestedValue -Object $eventPayload -Path @('pull_request')
if ($null -eq $pullRequest) {
  throw 'GitHub event payload did not contain pull_request context.'
}

$targetCatalog = Read-JsonFile -Path $targetSpecPathResolved
if ([string]$targetCatalog.schema -ne 'comparevi-history/consumer-targets@v1') {
  throw "Unsupported target catalog schema in '$targetSpecPathResolved': $($targetCatalog.schema)"
}

$pullRequestNumber = [int](Get-NestedValue -Object $pullRequest -Path @('number') -Default 0)
$baseRepository = [string](Get-NestedValue -Object $pullRequest -Path @('base', 'repo', 'full_name') -Default '')
$baseRef = [string](Get-NestedValue -Object $pullRequest -Path @('base', 'ref') -Default '')
$baseSha = [string](Get-NestedValue -Object $pullRequest -Path @('base', 'sha') -Default '')
$headRepository = [string](Get-NestedValue -Object $pullRequest -Path @('head', 'repo', 'full_name') -Default '')
$headRef = [string](Get-NestedValue -Object $pullRequest -Path @('head', 'ref') -Default '')
$headSha = [string](Get-NestedValue -Object $pullRequest -Path @('head', 'sha') -Default '')
$pullRequestUrl = Get-OptionalString -Value (Get-NestedValue -Object $pullRequest -Path @('html_url'))
$reportedChangedFileCount = [int](Get-NestedValue -Object $pullRequest -Path @('changed_files') -Default 0)
$headFork = [bool](Get-NestedValue -Object $pullRequest -Path @('head', 'repo', 'fork') -Default $false)
$isFork = $headFork
if (-not $isFork -and -not [string]::IsNullOrWhiteSpace($headRepository) -and -not [string]::IsNullOrWhiteSpace($baseRepository)) {
  $isFork = $headRepository -ne $baseRepository
}

$repositorySlug = if (-not [string]::IsNullOrWhiteSpace($Repository)) {
  $Repository.Trim()
} elseif (-not [string]::IsNullOrWhiteSpace($baseRepository)) {
  $baseRepository
} else {
  $env:GITHUB_REPOSITORY
}

$executionStatus = 'ready'
$executionReason = 'matched-targets'
if ($isFork) {
  $executionStatus = 'blocked'
  $executionReason = 'untrusted-cross-repository-pull-request'
} elseif ($reportedChangedFileCount -gt 3000) {
  $executionStatus = 'blocked'
  $executionReason = 'pr-files-api-limit-exceeded'
}

$rawFiles = @()
if (-not [string]::IsNullOrWhiteSpace($FilesPayloadPath)) {
  $filesPayloadResolved = Resolve-AbsolutePath -Path $FilesPayloadPath -BasePath $basePath
  if (-not (Test-Path -LiteralPath $filesPayloadResolved -PathType Leaf)) {
    throw "Files payload override not found: $filesPayloadResolved"
  }
  $rawFiles = @(ConvertTo-ObjectArray -Value (Read-JsonFile -Path $filesPayloadResolved))
} elseif ($executionStatus -ne 'blocked') {
  $rawFiles = @(Invoke-PullRequestFilesApi -RepositorySlug $repositorySlug -PullRequestNumber $pullRequestNumber -Token $GitHubToken)
}

$changedViFiles = New-Object System.Collections.Generic.List[object]
$seenChanges = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($file in $rawFiles) {
  $currentPath = Get-OptionalString -Value (Get-NestedValue -Object $file -Path @('filename'))
  $previousPath = Get-OptionalString -Value (Get-NestedValue -Object $file -Path @('previous_filename'))
  if ([string]::IsNullOrWhiteSpace($currentPath) -and [string]::IsNullOrWhiteSpace($previousPath)) {
    continue
  }

  $isCurrentVi = -not [string]::IsNullOrWhiteSpace($currentPath) -and $currentPath.EndsWith('.vi', [System.StringComparison]::OrdinalIgnoreCase)
  $isPreviousVi = -not [string]::IsNullOrWhiteSpace($previousPath) -and $previousPath.EndsWith('.vi', [System.StringComparison]::OrdinalIgnoreCase)
  if (-not $isCurrentVi -and -not $isPreviousVi) {
    continue
  }

  $changeStatus = Get-OptionalString -Value (Get-NestedValue -Object $file -Path @('status'))
  if ([string]::IsNullOrWhiteSpace($changeStatus)) {
    $changeStatus = 'unknown'
  }

  $signature = '{0}|{1}|{2}' -f $changeStatus, $currentPath, $previousPath
  if (-not $seenChanges.Add($signature)) {
    continue
  }

  $changedViFiles.Add([pscustomobject][ordered]@{
      status = $changeStatus
      currentPath = if ([string]::IsNullOrWhiteSpace($currentPath)) { $previousPath } else { $currentPath }
      previousPath = $previousPath
    }) | Out-Null
}

$matchedTargets = New-Object System.Collections.Generic.List[object]
foreach ($target in $targetCatalog.targets) {
  $targetId = Get-OptionalString -Value $target.id
  $targetPath = Get-OptionalString -Value $target.path
  if ([string]::IsNullOrWhiteSpace($targetId) -or [string]::IsNullOrWhiteSpace($targetPath)) {
    continue
  }

  $match = $null
  $matchKind = $null
  foreach ($change in $changedViFiles) {
    if ([string]$change.currentPath -eq $targetPath) {
      $match = $change
      $matchKind = 'current-path'
      break
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$change.previousPath) -and [string]$change.previousPath -eq $targetPath) {
      $match = $change
      $matchKind = 'previous-path'
      break
    }
  }

  if ($null -eq $match) {
    continue
  }

  $publicModes = @(
    @(ConvertTo-ObjectArray -Value $target.publicModes) |
      ForEach-Object { Get-OptionalString -Value $_ } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  )

  $matchedTargets.Add([pscustomobject][ordered]@{
      targetId = $targetId
      targetPath = $targetPath
      publicModes = @($publicModes)
      matchKind = $matchKind
      currentPath = [string]$match.currentPath
      previousPath = if ([string]::IsNullOrWhiteSpace([string]$match.previousPath)) { $null } else { [string]$match.previousPath }
      changeStatus = [string]$match.status
    }) | Out-Null
}

$changedViArray = @(
  $changedViFiles |
    Sort-Object { [string]$_.currentPath }, { [string]$_.previousPath }, { [string]$_.status } |
    ForEach-Object { $_ }
)
$matchedTargetArray = @(
  $matchedTargets |
    Sort-Object { [string]$_.targetPath }, { [string]$_.targetId } |
    ForEach-Object { $_ }
)

if ($executionStatus -eq 'ready') {
  if ($changedViArray.Count -eq 0) {
    $executionStatus = 'skipped'
    $executionReason = 'no-vi-files-changed'
  } elseif ($matchedTargetArray.Count -eq 0) {
    $executionStatus = 'skipped'
    $executionReason = 'no-target-catalog-matches'
  }
}

$receipt = [ordered]@{
  schema = 'comparevi-history/changed-vi-discovery@v1'
  generatedAtUtc = [DateTime]::UtcNow.ToString('o')
  repository = $repositorySlug
  eventName = $EventName
  targetCatalog = [ordered]@{
    schema = 'comparevi-history/consumer-targets@v1'
    path = $targetSpecPathResolved
  }
  pullRequest = [ordered]@{
    number = $pullRequestNumber
    htmlUrl = $pullRequestUrl
    baseRepository = $baseRepository
    baseRef = $baseRef
    baseSha = $baseSha
    headRepository = $headRepository
    headRef = $headRef
    headSha = $headSha
    isFork = $isFork
    changedFileCount = $reportedChangedFileCount
  }
  changedViFiles = @($changedViArray)
  matchedTargets = @($matchedTargetArray)
  summary = [ordered]@{
    executionStatus = $executionStatus
    executionReason = $executionReason
    changedViCount = $changedViArray.Count
    matchedTargetCount = $matchedTargetArray.Count
  }
}

$receipt | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $receiptPath -Encoding utf8

Write-ActionOutput -Key 'changed-vi-discovery-path' -Value $receiptPath
Write-ActionOutput -Key 'changed-vi-count' -Value ([string]$changedViArray.Count)
Write-ActionOutput -Key 'matched-target-count' -Value ([string]$matchedTargetArray.Count)
Write-ActionOutput -Key 'execution-status' -Value $executionStatus
Write-ActionOutput -Key 'execution-reason' -Value $executionReason
Write-ActionOutput -Key 'matched-targets-json' -Value (($matchedTargetArray | ConvertTo-Json -Depth 20 -Compress))
Write-ActionOutput -Key 'base-repo' -Value $baseRepository
Write-ActionOutput -Key 'base-ref' -Value $baseRef
Write-ActionOutput -Key 'base-sha' -Value $baseSha
Write-ActionOutput -Key 'head-repo' -Value $headRepository
Write-ActionOutput -Key 'head-ref' -Value $headRef
Write-ActionOutput -Key 'head-sha' -Value $headSha
Write-ActionOutput -Key 'pull-request-number' -Value ([string]$pullRequestNumber)
Write-ActionOutput -Key 'reviewer-is-fork' -Value ($isFork.ToString().ToLowerInvariant())

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  @(
    '## comparevi-history pull request discovery'
    ''
    ('- Pull request: `#{0}`' -f $pullRequestNumber)
    ('- Base repository: `{0}`' -f $baseRepository)
    ('- Head repository: `{0}`' -f $headRepository)
    ('- Fork PR: `{0}`' -f $isFork.ToString().ToLowerInvariant())
    ('- Changed VI count: `{0}`' -f $changedViArray.Count)
    ('- Matched target count: `{0}`' -f $matchedTargetArray.Count)
    ('- Execution status: `{0}`' -f $executionStatus)
    ('- Execution reason: `{0}`' -f $executionReason)
    ('- Discovery receipt: `{0}`' -f $receiptPath)
  ) | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
}

$receipt | ConvertTo-Json -Depth 20
