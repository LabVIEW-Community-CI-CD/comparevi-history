param(
  [Parameter(Mandatory = $true)]
  [string]$EventName,
  [Parameter(Mandatory = $true)]
  [string]$EventPath,
  [Parameter(Mandatory = $true)]
  [string]$PrPolicyPath,
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

function Get-OptionalInt {
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

  return [int]$stringValue
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
    [Parameter(Mandatory = $true)]
    [string]$Token
  )

  if ([string]::IsNullOrWhiteSpace($Token)) {
    throw 'GitHub token is required to discover changed pull-request files.'
  }

  $headers = @{
    Accept = 'application/vnd.github+json'
    Authorization = "Bearer $Token"
    'User-Agent' = 'comparevi-history-pr-discovery-v2'
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

function Normalize-RepositoryPath {
  param(
    [AllowNull()]
    [string]$Path
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }

  $normalized = $Path.Trim() -replace '\\', '/'
  while ($normalized.Contains('//')) {
    $normalized = $normalized.Replace('//', '/')
  }

  return $normalized.TrimStart([char[]]@('.', '/')).Trim([char[]]@('/'))
}

function ConvertTo-NormalizedStringArray {
  param(
    [AllowNull()]
    $Value
  )

  $items = New-Object System.Collections.Generic.List[string]
  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($entry in @(ConvertTo-ObjectArray -Value $Value)) {
    $normalized = Normalize-RepositoryPath -Path (Get-OptionalString -Value $entry)
    if ([string]::IsNullOrWhiteSpace($normalized)) {
      continue
    }

    if ($seen.Add($normalized)) {
      $items.Add($normalized) | Out-Null
    }
  }

  return @($items | ForEach-Object { $_ })
}

function ConvertTo-NormalizedModeList {
  param(
    [AllowNull()]
    $Value,
    [Parameter(Mandatory = $true)]
    [string]$ContextLabel
  )

  $items = New-Object System.Collections.Generic.List[string]
  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($entry in @(ConvertTo-ObjectArray -Value $Value)) {
    $normalized = Get-OptionalString -Value $entry
    if ([string]::IsNullOrWhiteSpace($normalized)) {
      continue
    }

    $normalized = $normalized.ToLowerInvariant()
    if (-not $publicModeSet.Contains($normalized)) {
      throw "$ContextLabel included unsupported public mode '$normalized'. Allowed values: $($publicModesAllowed -join ', ')."
    }

    if ($seen.Add($normalized)) {
      $items.Add($normalized) | Out-Null
    }
  }

  return @($items | ForEach-Object { $_ })
}

function Convert-GlobToRegex {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Pattern
  )

  $normalized = Normalize-RepositoryPath -Path $Pattern
  if ([string]::IsNullOrWhiteSpace($normalized)) {
    return '^(?!)$'
  }

  $builder = New-Object System.Text.StringBuilder
  [void]$builder.Append('^')
  $index = 0
  while ($index -lt $normalized.Length) {
    $char = $normalized[$index]
    if ($char -eq '*') {
      if (($index + 1) -lt $normalized.Length -and $normalized[$index + 1] -eq '*') {
        if (($index + 2) -lt $normalized.Length -and $normalized[$index + 2] -eq '/') {
          [void]$builder.Append('(?:.*/)?')
          $index += 3
        } else {
          [void]$builder.Append('.*')
          $index += 2
        }
      } else {
        [void]$builder.Append('[^/]*')
        $index += 1
      }
      continue
    }

    if ($char -eq '?') {
      [void]$builder.Append('[^/]')
      $index += 1
      continue
    }

    [void]$builder.Append([regex]::Escape([string]$char))
    $index += 1
  }

  [void]$builder.Append('$')
  return $builder.ToString()
}

function Test-PathMatchesPatterns {
  param(
    [AllowNull()]
    [string]$Path,
    [string[]]$Patterns
  )

  if ([string]::IsNullOrWhiteSpace($Path) -or $Patterns.Count -eq 0) {
    return $false
  }

  $normalizedPath = Normalize-RepositoryPath -Path $Path
  foreach ($pattern in $Patterns) {
    if ($normalizedPath -match (Convert-GlobToRegex -Pattern $pattern)) {
      return $true
    }
  }

  return $false
}

function Test-ChangeMatchesPatterns {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Change,
    [string[]]$Patterns
  )

  if ($Patterns.Count -eq 0) {
    return $false
  }

  foreach ($candidatePath in @([string]$Change.currentPath, [string]$Change.previousPath)) {
    if (Test-PathMatchesPatterns -Path $candidatePath -Patterns $Patterns) {
      return $true
    }
  }

  return $false
}

function ConvertTo-SafeSlug {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Value
  )

  $safe = $Value.ToLowerInvariant() -replace '[^a-z0-9]+', '-'
  $safe = $safe.Trim('-')
  if ([string]::IsNullOrWhiteSpace($safe)) {
    return 'vi'
  }

  return $safe
}

function New-SyntheticTargetId {
  param(
    [Parameter(Mandatory = $true)]
    [string]$TargetPath
  )

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

function Resolve-PrPolicy {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$BasePath
  )

  $resolvedPath = Resolve-AbsolutePath -Path $Path -BasePath $BasePath
  if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
    return [ordered]@{
      schema = 'comparevi-history/pr-policy@v2'
      path = $resolvedPath
      applied = $false
      discovery = [ordered]@{
        selectionMode = 'dynamic-paths'
        includePaths = @()
        excludePaths = @()
        maxChangedViCount = $null
        overflowBehavior = 'block'
      }
      execution = [ordered]@{
        publicModes = @('attributes', 'front-panel', 'block-diagram')
        noisePolicy = 'include'
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

  $rawPolicy = Read-JsonFile -Path $resolvedPath
  if ([string]$rawPolicy.schema -ne 'comparevi-history/pr-policy@v2') {
    throw "Unsupported PR policy schema in '$resolvedPath': $($rawPolicy.schema)"
  }

  $discovery = Get-NestedValue -Object $rawPolicy -Path @('discovery')
  $execution = Get-NestedValue -Object $rawPolicy -Path @('execution')
  $history = Get-NestedValue -Object $execution -Path @('history')
  $reviewerSurface = Get-NestedValue -Object $rawPolicy -Path @('reviewerSurface')
  $trust = Get-NestedValue -Object $rawPolicy -Path @('trust')

  $selectionMode = Get-OptionalString -Value (Get-NestedValue -Object $discovery -Path @('selectionMode'))
  if ([string]::IsNullOrWhiteSpace($selectionMode)) {
    $selectionMode = 'dynamic-paths'
  }
  if ($selectionMode -ne 'dynamic-paths') {
    throw "PR policy discovery.selectionMode must be 'dynamic-paths'. Actual: $selectionMode"
  }

  $overflowBehavior = Get-OptionalString -Value (Get-NestedValue -Object $discovery -Path @('overflowBehavior'))
  if ([string]::IsNullOrWhiteSpace($overflowBehavior)) {
    $overflowBehavior = 'block'
  }
  if ($overflowBehavior -ne 'block') {
    throw "PR policy discovery.overflowBehavior must be 'block'. Actual: $overflowBehavior"
  }

  $sourceBranchRefStrategy = Get-OptionalString -Value (Get-NestedValue -Object $history -Path @('sourceBranchRefStrategy'))
  if ([string]::IsNullOrWhiteSpace($sourceBranchRefStrategy)) {
    $sourceBranchRefStrategy = 'pull-request-base'
  }
  if ($sourceBranchRefStrategy -ne 'pull-request-base') {
    throw "PR policy execution.history.sourceBranchRefStrategy must be 'pull-request-base'. Actual: $sourceBranchRefStrategy"
  }

  $noisePolicy = Get-OptionalString -Value (Get-NestedValue -Object $execution -Path @('noisePolicy'))
  if ([string]::IsNullOrWhiteSpace($noisePolicy)) {
    $noisePolicy = 'include'
  }
  if ($noisePolicy -notin @('include', 'collapse', 'skip')) {
    throw "PR policy execution.noisePolicy must be include, collapse, or skip. Actual: $noisePolicy"
  }

  $fullSurface = Get-OptionalString -Value (Get-NestedValue -Object $reviewerSurface -Path @('fullSurface'))
  if ([string]::IsNullOrWhiteSpace($fullSurface)) {
    $fullSurface = 'artifact-index'
  }
  if ($fullSurface -ne 'artifact-index') {
    throw "PR policy reviewerSurface.fullSurface must be 'artifact-index'. Actual: $fullSurface"
  }

  $forkBehavior = Get-OptionalString -Value (Get-NestedValue -Object $trust -Path @('forkBehavior'))
  if ([string]::IsNullOrWhiteSpace($forkBehavior)) {
    $forkBehavior = 'hosted-auto'
  }
  if ($forkBehavior -ne 'hosted-auto') {
    throw "PR policy trust.forkBehavior must be 'hosted-auto'. Actual: $forkBehavior"
  }

  return [ordered]@{
    schema = 'comparevi-history/pr-policy@v2'
    path = $resolvedPath
    applied = $true
    discovery = [ordered]@{
      selectionMode = $selectionMode
      includePaths = @(ConvertTo-NormalizedStringArray -Value (Get-NestedValue -Object $discovery -Path @('includePaths')))
      excludePaths = @(ConvertTo-NormalizedStringArray -Value (Get-NestedValue -Object $discovery -Path @('excludePaths')))
      maxChangedViCount = Get-OptionalInt -Value (Get-NestedValue -Object $discovery -Path @('maxChangedViCount'))
      overflowBehavior = $overflowBehavior
    }
    execution = [ordered]@{
      publicModes = @(ConvertTo-NormalizedModeList -Value (Get-NestedValue -Object $execution -Path @('publicModes')) -ContextLabel 'PR policy execution.publicModes')
      noisePolicy = $noisePolicy
      history = [ordered]@{
        sourceBranchRefStrategy = $sourceBranchRefStrategy
        keepArtifactsOnNoDiff = [bool](Get-NestedValue -Object $history -Path @('keepArtifactsOnNoDiff') -Default $false)
      }
    }
    reviewerSurface = [ordered]@{
      emitCommentBody = [bool](Get-NestedValue -Object $reviewerSurface -Path @('emitCommentBody') -Default $true)
      emitStepSummary = [bool](Get-NestedValue -Object $reviewerSurface -Path @('emitStepSummary') -Default $true)
      fullSurface = $fullSurface
    }
    trust = [ordered]@{
      forkBehavior = $forkBehavior
    }
  }
}

if ($EventName -ne 'pull_request') {
  throw "comparevi-history automatic pull-request discovery requires pull_request events. Actual: $EventName"
}

$basePath = (Get-Location).Path
$eventPathResolved = Resolve-AbsolutePath -Path $EventPath -BasePath $basePath
$resultsDirResolved = Resolve-AbsolutePath -Path $ResultsDir -BasePath $basePath
$receiptPath = Join-Path $resultsDirResolved 'changed-vi-discovery.json'

if (-not (Test-Path -LiteralPath $eventPathResolved -PathType Leaf)) {
  throw "GitHub event payload not found: $eventPathResolved"
}

New-Item -ItemType Directory -Path $resultsDirResolved -Force | Out-Null

$eventPayload = Read-JsonFile -Path $eventPathResolved
$pullRequest = Get-NestedValue -Object $eventPayload -Path @('pull_request')
if ($null -eq $pullRequest) {
  throw 'GitHub event payload did not contain pull_request context.'
}

$prPolicy = Resolve-PrPolicy -Path $PrPolicyPath -BasePath $basePath
if ($prPolicy.execution.publicModes.Count -eq 0) {
  throw 'PR policy execution.publicModes must declare at least one explicit public mode.'
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
$executionReason = 'selected-targets'
if (-not $prPolicy.applied) {
  $executionStatus = 'skipped'
  $executionReason = 'pr-policy-not-found'
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
} elseif ($executionStatus -eq 'ready') {
  $rawFiles = @(Invoke-PullRequestFilesApi -RepositorySlug $repositorySlug -PullRequestNumber $pullRequestNumber -Token $GitHubToken)
}

$changedViFiles = New-Object System.Collections.Generic.List[object]
$seenChanges = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($file in $rawFiles) {
  $currentPath = Normalize-RepositoryPath -Path (Get-OptionalString -Value (Get-NestedValue -Object $file -Path @('filename')))
  $previousPath = Normalize-RepositoryPath -Path (Get-OptionalString -Value (Get-NestedValue -Object $file -Path @('previous_filename')))
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

  $effectiveCurrentPath = if ([string]::IsNullOrWhiteSpace($currentPath)) { $previousPath } else { $currentPath }
  $signature = '{0}|{1}|{2}' -f $changeStatus, $effectiveCurrentPath, $previousPath
  if (-not $seenChanges.Add($signature)) {
    continue
  }

  $changedViFiles.Add([pscustomobject][ordered]@{
      status = $changeStatus
      currentPath = $effectiveCurrentPath
      previousPath = if ([string]::IsNullOrWhiteSpace($previousPath)) { $null } else { $previousPath }
    }) | Out-Null
}

$selectedTargets = New-Object System.Collections.Generic.List[object]
$selectedTargetSignatures = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$excludedViFiles = New-Object System.Collections.Generic.List[object]
$policyEligibleChanges = New-Object System.Collections.Generic.List[object]

foreach ($change in $changedViFiles) {
  $includeMatched = $true
  if ($prPolicy.discovery.includePaths.Count -gt 0) {
    $includeMatched = Test-ChangeMatchesPatterns -Change $change -Patterns $prPolicy.discovery.includePaths
  }
  if (-not $includeMatched) {
    $excludedViFiles.Add([pscustomobject][ordered]@{
        status = [string]$change.status
        currentPath = [string]$change.currentPath
        previousPath = if ([string]::IsNullOrWhiteSpace([string]$change.previousPath)) { $null } else { [string]$change.previousPath }
        exclusionReason = 'not-included-by-pr-policy'
      }) | Out-Null
    continue
  }

  if (Test-ChangeMatchesPatterns -Change $change -Patterns $prPolicy.discovery.excludePaths) {
    $excludedViFiles.Add([pscustomobject][ordered]@{
        status = [string]$change.status
        currentPath = [string]$change.currentPath
        previousPath = if ([string]::IsNullOrWhiteSpace([string]$change.previousPath)) { $null } else { [string]$change.previousPath }
        exclusionReason = 'excluded-by-pr-policy'
      }) | Out-Null
    continue
  }

  $policyEligibleChanges.Add($change) | Out-Null
}

$policyEligibleChangedViCount = $policyEligibleChanges.Count
$maxChangedViCount = $prPolicy.discovery.maxChangedViCount
$overflowChangedViCount = 0
if ($null -ne $maxChangedViCount -and $policyEligibleChangedViCount -gt [int]$maxChangedViCount) {
  $overflowChangedViCount = $policyEligibleChangedViCount - [int]$maxChangedViCount
  if ($prPolicy.discovery.overflowBehavior -eq 'block') {
    $executionStatus = 'blocked'
    $executionReason = 'max-changed-vi-count-exceeded'
  }
}

if ($executionStatus -eq 'ready') {
  foreach ($change in @($policyEligibleChanges | ForEach-Object { $_ })) {
    if ([string]$change.status -eq 'removed') {
      $excludedViFiles.Add([pscustomobject][ordered]@{
          status = [string]$change.status
          currentPath = [string]$change.currentPath
          previousPath = if ([string]::IsNullOrWhiteSpace([string]$change.previousPath)) { $null } else { [string]$change.previousPath }
          exclusionReason = 'deleted-vi-not-executable'
        }) | Out-Null
      continue
    }

    $targetPath = Normalize-RepositoryPath -Path ([string]$change.currentPath)
    if ([string]::IsNullOrWhiteSpace($targetPath)) {
      $excludedViFiles.Add([pscustomobject][ordered]@{
          status = [string]$change.status
          currentPath = [string]$change.currentPath
          previousPath = if ([string]::IsNullOrWhiteSpace([string]$change.previousPath)) { $null } else { [string]$change.previousPath }
          exclusionReason = 'missing-current-target-path'
        }) | Out-Null
      continue
    }

    $targetId = New-SyntheticTargetId -TargetPath $targetPath
    $signature = '{0}|{1}|{2}|{3}' -f $targetId, $targetPath, [string]$change.previousPath, [string]$change.status
    if (-not $selectedTargetSignatures.Add($signature)) {
      continue
    }

    $selectedTargets.Add([pscustomobject][ordered]@{
        targetId = $targetId
        targetSource = 'dynamic-path'
        targetPath = $targetPath
        requestedModes = @($prPolicy.execution.publicModes)
        requestedModeSource = 'pr-policy'
        history = [ordered]@{
          branchBudget = [ordered]@{
            sourceBranchRef = if ($prPolicy.execution.history.sourceBranchRefStrategy -eq 'pull-request-base' -and -not [string]::IsNullOrWhiteSpace($baseRef)) { $baseRef } else { $null }
            maxCommitCount = $null
            source = $prPolicy.execution.history.sourceBranchRefStrategy
          }
        }
        keepArtifactsOnNoDiff = [bool]$prPolicy.execution.history.keepArtifactsOnNoDiff
        currentPath = [string]$change.currentPath
        previousPath = if ([string]::IsNullOrWhiteSpace([string]$change.previousPath)) { $null } else { [string]$change.previousPath }
        changeStatus = [string]$change.status
      }) | Out-Null
  }
}

$changedViArray = @(
  $changedViFiles |
    Sort-Object { [string]$_.currentPath }, { [string]$_.previousPath }, { [string]$_.status } |
    ForEach-Object { $_ }
)
$selectedTargetArray = @(
  $selectedTargets |
    Sort-Object { [string]$_.targetPath }, { [string]$_.targetId }, { [string]$_.currentPath }, { [string]$_.previousPath } |
    ForEach-Object { $_ }
)
$excludedViArray = @(
  $excludedViFiles |
    Sort-Object { [string]$_.currentPath }, { [string]$_.previousPath }, { [string]$_.exclusionReason }, { [string]$_.status } |
    ForEach-Object { $_ }
)

if ($executionStatus -eq 'ready') {
  if ($changedViArray.Count -eq 0) {
    $executionStatus = 'skipped'
    $executionReason = 'no-vi-files-changed'
  } elseif ($policyEligibleChangedViCount -eq 0) {
    $executionStatus = 'skipped'
    $executionReason = 'no-policy-eligible-vi-files'
  } elseif ($selectedTargetArray.Count -eq 0) {
    $executionStatus = 'skipped'
    $executionReason = 'no-executable-vi-targets'
  }
}

$receipt = [ordered]@{
  schema = 'comparevi-history/changed-vi-discovery@v2'
  generatedAtUtc = [DateTime]::UtcNow.ToString('o')
  repository = $repositorySlug
  eventName = $EventName
  prPolicy = $prPolicy
  executionContext = [ordered]@{
    selectionMode = $prPolicy.discovery.selectionMode
    forkBehavior = $prPolicy.trust.forkBehavior
    fullSurface = $prPolicy.reviewerSurface.fullSurface
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
  excludedViFiles = @($excludedViArray)
  selectedTargets = @($selectedTargetArray)
  summary = [ordered]@{
    selectionMode = $prPolicy.discovery.selectionMode
    executionStatus = $executionStatus
    executionReason = $executionReason
    changedViCount = $changedViArray.Count
    eligibleChangedViCount = $policyEligibleChangedViCount
    excludedViCount = $excludedViArray.Count
    selectedTargetCount = $selectedTargetArray.Count
    overflowBehavior = $prPolicy.discovery.overflowBehavior
    overflowed = $overflowChangedViCount -gt 0
    overflowChangedViCount = $overflowChangedViCount
  }
}

$receipt | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $receiptPath -Encoding utf8

Write-ActionOutput -Key 'changed-vi-discovery-path' -Value $receiptPath
Write-ActionOutput -Key 'pr-policy-path' -Value [string]$prPolicy.path
Write-ActionOutput -Key 'pr-policy-applied' -Value ($prPolicy.applied.ToString().ToLowerInvariant())
Write-ActionOutput -Key 'selection-mode' -Value [string]$prPolicy.discovery.selectionMode
Write-ActionOutput -Key 'changed-vi-count' -Value ([string]$changedViArray.Count)
Write-ActionOutput -Key 'eligible-changed-vi-count' -Value ([string]$policyEligibleChangedViCount)
Write-ActionOutput -Key 'excluded-vi-count' -Value ([string]$excludedViArray.Count)
Write-ActionOutput -Key 'selected-target-count' -Value ([string]$selectedTargetArray.Count)
Write-ActionOutput -Key 'execution-status' -Value $executionStatus
Write-ActionOutput -Key 'execution-reason' -Value $executionReason
Write-ActionOutput -Key 'overflowed' -Value (($overflowChangedViCount -gt 0).ToString().ToLowerInvariant())
Write-ActionOutput -Key 'overflow-changed-vi-count' -Value ([string]$overflowChangedViCount)
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
    '## comparevi-history automatic pull request discovery'
    ''
    ('- Pull request: `#{0}`' -f $pullRequestNumber)
    ('- Base repository: `{0}`' -f $baseRepository)
    ('- Base ref: `{0}`' -f $baseRef)
    ('- Head repository: `{0}`' -f $headRepository)
    ('- Head ref: `{0}`' -f $headRef)
    ('- Fork PR: `{0}`' -f $isFork.ToString().ToLowerInvariant())
    ('- PR policy applied: `{0}`' -f $prPolicy.applied.ToString().ToLowerInvariant())
    ('- PR policy: `{0}`' -f [string]$prPolicy.path)
    ('- Selection mode: `{0}`' -f [string]$prPolicy.discovery.selectionMode)
    ('- Changed VI count: `{0}`' -f $changedViArray.Count)
    ('- Policy-eligible changed VI count: `{0}`' -f $policyEligibleChangedViCount)
    ('- Selected target count: `{0}`' -f $selectedTargetArray.Count)
    ('- Excluded VI count: `{0}`' -f $excludedViArray.Count)
    ('- Overflowed: `{0}`' -f (($overflowChangedViCount -gt 0).ToString().ToLowerInvariant()))
    ('- Execution status: `{0}`' -f $executionStatus)
    ('- Execution reason: `{0}`' -f $executionReason)
    ('- Discovery receipt: `{0}`' -f $receiptPath)
  ) | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
}

$receipt | ConvertTo-Json -Depth 32
