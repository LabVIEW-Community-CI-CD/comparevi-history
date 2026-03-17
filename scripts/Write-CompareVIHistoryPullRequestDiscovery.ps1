param(
  [Parameter(Mandatory = $true)]
  [string]$EventName,
  [Parameter(Mandatory = $true)]
  [string]$EventPath,
  [Parameter(Mandatory = $true)]
  [string]$TargetSpecPath,
  [string]$PrPolicyPath,
  [bool]$AllowTrustedForkExecution = $false,
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

function Resolve-RequestedModes {
  param(
    [string[]]$TargetPublicModes,
    [string[]]$PolicyPublicModes
  )

  if ($PolicyPublicModes.Count -eq 0) {
    return [ordered]@{
      requestedModes = @($TargetPublicModes)
      source = 'target-public-modes'
    }
  }

  $targetModeSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($targetMode in $TargetPublicModes) {
    [void]$targetModeSet.Add($targetMode)
  }

  $requestedModes = New-Object System.Collections.Generic.List[string]
  foreach ($policyMode in $PolicyPublicModes) {
    if ($targetModeSet.Contains($policyMode)) {
      $requestedModes.Add($policyMode) | Out-Null
    }
  }

  return [ordered]@{
    requestedModes = @($requestedModes | ForEach-Object { $_ })
    source = 'pr-policy'
  }
}

function Resolve-PrPolicy {
  param(
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$BasePath
  )

  $resolvedPath = $null
  $applied = $false
  $rawPolicy = $null
  if (-not [string]::IsNullOrWhiteSpace($Path)) {
    $resolvedPath = Resolve-AbsolutePath -Path $Path -BasePath $BasePath
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
      throw "PR policy not found: $resolvedPath"
    }

    $rawPolicy = Read-JsonFile -Path $resolvedPath
    if ([string]$rawPolicy.schema -ne 'comparevi-history/pr-policy@v1') {
      throw "Unsupported PR policy schema in '$resolvedPath': $($rawPolicy.schema)"
    }

    $applied = $true
  }

  $discovery = Get-NestedValue -Object $rawPolicy -Path @('discovery')
  $execution = Get-NestedValue -Object $rawPolicy -Path @('execution')
  $history = Get-NestedValue -Object $execution -Path @('history')
  $branchBudget = Get-NestedValue -Object $history -Path @('branchBudget')
  $reviewerSurface = Get-NestedValue -Object $rawPolicy -Path @('reviewerSurface')
  $trust = Get-NestedValue -Object $rawPolicy -Path @('trust')
  $forkBehavior = if ([string]::IsNullOrWhiteSpace([string](Get-NestedValue -Object $trust -Path @('forkBehavior')))) {
    'block'
  } else {
    [string](Get-NestedValue -Object $trust -Path @('forkBehavior'))
  }
  if ($forkBehavior -notin @('block', 'maintainer-dispatch')) {
    throw "PR policy trust.forkBehavior must be 'block' or 'maintainer-dispatch'. Actual: $forkBehavior"
  }

  return [ordered]@{
    schema = 'comparevi-history/pr-policy@v1'
    path = $resolvedPath
    applied = $applied
    discovery = [ordered]@{
      includePaths = @(ConvertTo-NormalizedStringArray -Value (Get-NestedValue -Object $discovery -Path @('includePaths')))
      excludePaths = @(ConvertTo-NormalizedStringArray -Value (Get-NestedValue -Object $discovery -Path @('excludePaths')))
      allowedTargetIds = @(
        @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $discovery -Path @('allowedTargetIds'))) |
          ForEach-Object { Get-OptionalString -Value $_ } |
          Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
      )
      maxChangedViCount = Get-OptionalInt -Value (Get-NestedValue -Object $discovery -Path @('maxChangedViCount'))
      unmatchedChangedViBehavior = if ([string]::IsNullOrWhiteSpace([string](Get-NestedValue -Object $discovery -Path @('unmatchedChangedViBehavior')))) {
        'ignore'
      } else {
        [string](Get-NestedValue -Object $discovery -Path @('unmatchedChangedViBehavior'))
      }
    }
    execution = [ordered]@{
      publicModes = @(ConvertTo-NormalizedModeList -Value (Get-NestedValue -Object $execution -Path @('publicModes')) -ContextLabel 'PR policy execution.publicModes')
      history = [ordered]@{
        branchBudget = [ordered]@{
          sourceBranchRef = Get-OptionalString -Value (Get-NestedValue -Object $branchBudget -Path @('sourceBranchRef'))
          maxCommitCount = Get-OptionalInt -Value (Get-NestedValue -Object $branchBudget -Path @('maxCommitCount'))
        }
        keepArtifactsOnNoDiff = [bool](Get-NestedValue -Object $history -Path @('keepArtifactsOnNoDiff') -Default $false)
      }
    }
    reviewerSurface = [ordered]@{
      emitCommentBody = [bool](Get-NestedValue -Object $reviewerSurface -Path @('emitCommentBody') -Default $true)
      emitStepSummary = [bool](Get-NestedValue -Object $reviewerSurface -Path @('emitStepSummary') -Default $true)
    }
    trust = [ordered]@{
      forkBehavior = $forkBehavior
    }
  }
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

$prPolicy = Resolve-PrPolicy -Path $PrPolicyPath -BasePath $basePath
$allowedTargetIdSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($allowedTargetId in @($prPolicy.discovery.allowedTargetIds)) {
  [void]$allowedTargetIdSet.Add([string]$allowedTargetId)
}

$catalogTargets = New-Object System.Collections.Generic.List[object]
foreach ($target in @($targetCatalog.targets)) {
  $targetId = Get-OptionalString -Value $target.id
  $targetPath = Normalize-RepositoryPath -Path (Get-OptionalString -Value $target.path)
  if ([string]::IsNullOrWhiteSpace($targetId) -or [string]::IsNullOrWhiteSpace($targetPath)) {
    continue
  }

  $targetPublicModes = @(ConvertTo-NormalizedModeList -Value $target.publicModes -ContextLabel "Target '$targetId' publicModes")
  if ($targetPublicModes.Count -eq 0) {
    throw "Target '$targetId' in '$targetSpecPathResolved' must declare at least one explicit public mode."
  }

  $catalogTargets.Add([pscustomobject][ordered]@{
      targetId = $targetId
      targetPath = $targetPath
      publicModes = @($targetPublicModes)
      history = [ordered]@{
        branchBudget = [ordered]@{
          sourceBranchRef = Get-OptionalString -Value (Get-NestedValue -Object $target -Path @('history', 'branchBudget', 'sourceBranchRef'))
          maxCommitCount = Get-OptionalInt -Value (Get-NestedValue -Object $target -Path @('history', 'branchBudget', 'maxCommitCount'))
        }
      }
    }) | Out-Null
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
$trustedForkExecutionEligible = $isFork -and $prPolicy.trust.forkBehavior -eq 'maintainer-dispatch'
$trustedForkExecutionApplied = $trustedForkExecutionEligible -and $AllowTrustedForkExecution
if ($isFork) {
  if ($trustedForkExecutionApplied) {
    $executionStatus = 'ready'
    $executionReason = 'matched-targets'
  } elseif ($trustedForkExecutionEligible) {
    $executionStatus = 'blocked'
    $executionReason = 'trusted-fork-fallback-required'
  } else {
    $executionStatus = 'blocked'
    $executionReason = 'untrusted-cross-repository-pull-request'
  }
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

$matchedTargets = New-Object System.Collections.Generic.List[object]
$matchedTargetSignatures = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$excludedViFiles = New-Object System.Collections.Generic.List[object]
$policyEligibleChangedViCount = 0
$unmatchedViCount = 0

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

  $policyEligibleChangedViCount += 1

  $candidateTargets = New-Object System.Collections.Generic.List[object]
  foreach ($target in $catalogTargets) {
    if ([string]$change.currentPath -eq [string]$target.targetPath) {
      $candidateTargets.Add([pscustomobject][ordered]@{
          target = $target
          matchKind = 'current-path'
        }) | Out-Null
      continue
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$change.previousPath) -and [string]$change.previousPath -eq [string]$target.targetPath) {
      $candidateTargets.Add([pscustomobject][ordered]@{
          target = $target
          matchKind = 'previous-path'
        }) | Out-Null
    }
  }

  if ($candidateTargets.Count -eq 0) {
    $excludedViFiles.Add([pscustomobject][ordered]@{
        status = [string]$change.status
        currentPath = [string]$change.currentPath
        previousPath = if ([string]::IsNullOrWhiteSpace([string]$change.previousPath)) { $null } else { [string]$change.previousPath }
        exclusionReason = 'no-target-catalog-match'
      }) | Out-Null
    $unmatchedViCount += 1
    continue
  }

  $effectiveTargets = New-Object System.Collections.Generic.List[object]
  foreach ($candidateTarget in $candidateTargets) {
    $target = $candidateTarget.target
    if ($allowedTargetIdSet.Count -gt 0 -and -not $allowedTargetIdSet.Contains([string]$target.targetId)) {
      continue
    }

    $modeResolution = Resolve-RequestedModes -TargetPublicModes @($target.publicModes) -PolicyPublicModes @($prPolicy.execution.publicModes)
    if (@($modeResolution.requestedModes).Count -eq 0) {
      continue
    }

    $branchBudgetSourceBranchRef = if (-not [string]::IsNullOrWhiteSpace([string]$prPolicy.execution.history.branchBudget.sourceBranchRef)) {
      [string]$prPolicy.execution.history.branchBudget.sourceBranchRef
    } else {
      Get-OptionalString -Value $target.history.branchBudget.sourceBranchRef
    }
    $branchBudgetMaxCommitCount = if ($null -ne $prPolicy.execution.history.branchBudget.maxCommitCount) {
      [int]$prPolicy.execution.history.branchBudget.maxCommitCount
    } else {
      Get-OptionalInt -Value $target.history.branchBudget.maxCommitCount
    }
    $branchBudgetSource = if (-not [string]::IsNullOrWhiteSpace([string]$prPolicy.execution.history.branchBudget.sourceBranchRef) -or $null -ne $prPolicy.execution.history.branchBudget.maxCommitCount) {
      'pr-policy'
    } elseif (-not [string]::IsNullOrWhiteSpace([string]$target.history.branchBudget.sourceBranchRef) -or $null -ne $target.history.branchBudget.maxCommitCount) {
      'target-catalog'
    } else {
      'none'
    }

    $entrySignature = '{0}|{1}|{2}|{3}' -f [string]$target.targetId, [string]$change.currentPath, [string]$change.previousPath, [string]$candidateTarget.matchKind
    if (-not $matchedTargetSignatures.Add($entrySignature)) {
      continue
    }

    $effectiveTargets.Add([pscustomobject][ordered]@{
        targetId = [string]$target.targetId
        targetPath = [string]$target.targetPath
        publicModes = @($target.publicModes)
        requestedModes = @($modeResolution.requestedModes)
        requestedModeSource = [string]$modeResolution.source
        history = [ordered]@{
          branchBudget = [ordered]@{
            sourceBranchRef = if ([string]::IsNullOrWhiteSpace($branchBudgetSourceBranchRef)) { $null } else { $branchBudgetSourceBranchRef }
            maxCommitCount = if ($null -eq $branchBudgetMaxCommitCount) { $null } else { [int]$branchBudgetMaxCommitCount }
            source = $branchBudgetSource
          }
        }
        keepArtifactsOnNoDiff = [bool]$prPolicy.execution.history.keepArtifactsOnNoDiff
        matchKind = [string]$candidateTarget.matchKind
        currentPath = [string]$change.currentPath
        previousPath = if ([string]::IsNullOrWhiteSpace([string]$change.previousPath)) { $null } else { [string]$change.previousPath }
        changeStatus = [string]$change.status
      }) | Out-Null
  }

  if ($effectiveTargets.Count -eq 0) {
    $exclusionReason = if ($allowedTargetIdSet.Count -gt 0) {
      'target-id-not-allowed'
    } elseif ($prPolicy.execution.publicModes.Count -gt 0) {
      'no-policy-allowed-public-modes'
    } else {
      'no-target-catalog-match'
    }

    $excludedViFiles.Add([pscustomobject][ordered]@{
        status = [string]$change.status
        currentPath = [string]$change.currentPath
        previousPath = if ([string]::IsNullOrWhiteSpace([string]$change.previousPath)) { $null } else { [string]$change.previousPath }
        exclusionReason = $exclusionReason
      }) | Out-Null
    $unmatchedViCount += 1
    continue
  }

  foreach ($effectiveTarget in $effectiveTargets) {
    $matchedTargets.Add($effectiveTarget) | Out-Null
  }
}

$changedViArray = @(
  $changedViFiles |
    Sort-Object { [string]$_.currentPath }, { [string]$_.previousPath }, { [string]$_.status } |
    ForEach-Object { $_ }
)
$matchedTargetArray = @(
  $matchedTargets |
    Sort-Object { [string]$_.targetPath }, { [string]$_.targetId }, { [string]$_.currentPath }, { [string]$_.previousPath } |
    ForEach-Object { $_ }
)
$excludedViArray = @(
  $excludedViFiles |
    Sort-Object { [string]$_.currentPath }, { [string]$_.previousPath }, { [string]$_.exclusionReason }, { [string]$_.status } |
    ForEach-Object { $_ }
)

if ($executionStatus -eq 'ready' -and $null -ne $prPolicy.discovery.maxChangedViCount -and $policyEligibleChangedViCount -gt [int]$prPolicy.discovery.maxChangedViCount) {
  $executionStatus = 'blocked'
  $executionReason = 'max-changed-vi-count-exceeded'
}
if ($executionStatus -eq 'ready' -and $prPolicy.discovery.unmatchedChangedViBehavior -eq 'block' -and $unmatchedViCount -gt 0) {
  $executionStatus = 'blocked'
  $executionReason = 'unmatched-changed-vi-detected'
}

if ($executionStatus -eq 'ready') {
  if ($changedViArray.Count -eq 0) {
    $executionStatus = 'skipped'
    $executionReason = 'no-vi-files-changed'
  } elseif ($matchedTargetArray.Count -eq 0) {
    if ($policyEligibleChangedViCount -eq 0) {
      $executionStatus = 'skipped'
      $executionReason = 'no-policy-eligible-vi-files'
    } else {
      $executionStatus = 'skipped'
      $executionReason = 'no-target-catalog-matches'
    }
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
  prPolicy = $prPolicy
  executionContext = [ordered]@{
    trustedForkExecutionRequested = [bool]$AllowTrustedForkExecution
    trustedForkExecutionEligible = [bool]$trustedForkExecutionEligible
    trustedForkExecutionApplied = [bool]$trustedForkExecutionApplied
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
  matchedTargets = @($matchedTargetArray)
  summary = [ordered]@{
    executionStatus = $executionStatus
    executionReason = $executionReason
    changedViCount = $changedViArray.Count
    eligibleChangedViCount = $policyEligibleChangedViCount
    excludedViCount = $excludedViArray.Count
    unmatchedViCount = $unmatchedViCount
    matchedTargetCount = $matchedTargetArray.Count
  }
}

$receipt | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $receiptPath -Encoding utf8

Write-ActionOutput -Key 'changed-vi-discovery-path' -Value $receiptPath
Write-ActionOutput -Key 'pr-policy-path' -Value $(if ([string]::IsNullOrWhiteSpace([string]$prPolicy.path)) { '' } else { [string]$prPolicy.path })
Write-ActionOutput -Key 'pr-policy-applied' -Value ($prPolicy.applied.ToString().ToLowerInvariant())
Write-ActionOutput -Key 'trusted-fork-execution-requested' -Value ($AllowTrustedForkExecution.ToString().ToLowerInvariant())
Write-ActionOutput -Key 'trusted-fork-execution-eligible' -Value ($trustedForkExecutionEligible.ToString().ToLowerInvariant())
Write-ActionOutput -Key 'trusted-fork-execution-applied' -Value ($trustedForkExecutionApplied.ToString().ToLowerInvariant())
Write-ActionOutput -Key 'changed-vi-count' -Value ([string]$changedViArray.Count)
Write-ActionOutput -Key 'eligible-changed-vi-count' -Value ([string]$policyEligibleChangedViCount)
Write-ActionOutput -Key 'excluded-vi-count' -Value ([string]$excludedViArray.Count)
Write-ActionOutput -Key 'unmatched-vi-count' -Value ([string]$unmatchedViCount)
Write-ActionOutput -Key 'matched-target-count' -Value ([string]$matchedTargetArray.Count)
Write-ActionOutput -Key 'execution-status' -Value $executionStatus
Write-ActionOutput -Key 'execution-reason' -Value $executionReason
Write-ActionOutput -Key 'matched-targets-json' -Value (($matchedTargetArray | ConvertTo-Json -Depth 32 -Compress))
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
    ('- PR policy: `{0}`' -f $(if ([string]::IsNullOrWhiteSpace([string]$prPolicy.path)) { 'platform defaults' } else { [string]$prPolicy.path }))
    ('- PR policy applied: `{0}`' -f $prPolicy.applied.ToString().ToLowerInvariant())
    ('- Fork PR: `{0}`' -f $isFork.ToString().ToLowerInvariant())
    ('- Trusted fork execution requested: `{0}`' -f $AllowTrustedForkExecution.ToString().ToLowerInvariant())
    ('- Trusted fork execution eligible: `{0}`' -f $trustedForkExecutionEligible.ToString().ToLowerInvariant())
    ('- Trusted fork execution applied: `{0}`' -f $trustedForkExecutionApplied.ToString().ToLowerInvariant())
    ('- Changed VI count: `{0}`' -f $changedViArray.Count)
    ('- Policy-eligible changed VI count: `{0}`' -f $policyEligibleChangedViCount)
    ('- Excluded VI count: `{0}`' -f $excludedViArray.Count)
    ('- Unmatched VI count: `{0}`' -f $unmatchedViCount)
    ('- Matched target count: `{0}`' -f $matchedTargetArray.Count)
    ('- Execution status: `{0}`' -f $executionStatus)
    ('- Execution reason: `{0}`' -f $executionReason)
    ('- Discovery receipt: `{0}`' -f $receiptPath)
  ) | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
}

$receipt | ConvertTo-Json -Depth 32
