param(
  [Parameter(Mandatory = $true)]
  [string]$RepositoryRoot,
  [string]$TargetPath,
  [string]$TargetSpecPath,
  [string]$TargetId,
  [string]$StartRef = 'HEAD',
  [string]$EndRef,
  [Nullable[int]]$MaxPairs,
  [Nullable[int]]$MaxSignalPairs,
  [ValidateSet('include','collapse','skip')]
  [string]$NoisePolicy = 'collapse',
  [string]$Mode,
  [string]$ResultsDir = 'tests/results/ref-compare/history',
  [ValidateSet('html','xml','text')]
  [string]$ReportFormat = 'html',
  [switch]$RenderReport,
  [switch]$FailFast,
  [switch]$FailOnDiff,
  [switch]$Quiet,
  [switch]$Detailed,
  [switch]$KeepArtifactsOnNoDiff,
  [switch]$IncludeMergeParents,
  [Nullable[int]]$CompareTimeoutSeconds,
  [string]$ConsumerRepository,
  [string]$ConsumerRef,
  [string]$SourceBranchRef,
  [Nullable[int]]$MaxBranchCommits,
  [ValidateSet('none','manual','comment-gated')]
  [string]$ReviewerSurface = 'none',
  [string]$ReviewerIssueNumber,
  [string]$ReviewerPullRequestNumber,
  [string]$ReviewerIsFork,
  [string]$ContainerImage,
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
$aggregateAliases = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($aggregate in @('default', 'full', 'all')) {
  [void]$aggregateAliases.Add($aggregate)
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

function ConvertTo-NormalizedModeList {
  param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$Value
  )

  $modes = New-Object System.Collections.Generic.List[string]
  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($segment in @($Value -split '[,;]')) {
    $trimmed = $segment.Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
      continue
    }
    if ($seen.Add($trimmed)) {
      $modes.Add($trimmed) | Out-Null
    }
  }

  return @($modes.ToArray())
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

function Get-PropertyValue {
  param(
    [AllowNull()]
    [object]$Object,
    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  if ($null -eq $Object) {
    return $null
  }

  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) {
    return $null
  }

  return $property.Value
}

function Assert-PublicModes {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Modes,
    [Parameter(Mandatory = $true)]
    [string]$ContextLabel
  )

  if ($Modes.Count -eq 0) {
    throw "$ContextLabel must resolve to at least one explicit public mode."
  }

  foreach ($modeName in $Modes) {
    if ($aggregateAliases.Contains($modeName)) {
      throw "$ContextLabel cannot use aggregate aliases such as 'default', 'full', or 'all'. Use only explicit public modes: $($publicModesAllowed -join ', ')."
    }
    if (-not $publicModeSet.Contains($modeName)) {
      throw "$ContextLabel included unsupported mode '$modeName'. Allowed public modes: $($publicModesAllowed -join ', ')."
    }
  }
}

$repositoryRootResolved = Resolve-AbsolutePath -Path $RepositoryRoot -BasePath (Get-Location).Path
if (-not (Test-Path -LiteralPath $repositoryRootResolved -PathType Container)) {
  throw "Repository root not found: $repositoryRootResolved"
}

$resolvedTargetSpecPath = $null
$resolvedTargetId = $null
$effectiveTargetPath = $null
$targetPublicModes = @()
$targetHistoryStartRef = $null
$targetHistorySourceBranchRef = $null
$targetHistoryMaxCommitCount = $null
$targetHistory = $null
$targetReviewerSurface = $null

if (-not [string]::IsNullOrWhiteSpace($TargetSpecPath)) {
  $resolvedTargetSpecPath = Resolve-AbsolutePath -Path $TargetSpecPath -BasePath $repositoryRootResolved
  if (-not (Test-Path -LiteralPath $resolvedTargetSpecPath -PathType Leaf)) {
    throw "Target spec not found: $resolvedTargetSpecPath"
  }

  $targetSpec = Get-Content -LiteralPath $resolvedTargetSpecPath -Raw | ConvertFrom-Json -Depth 32
  if ([string](Get-PropertyValue -Object $targetSpec -Name 'schema') -ne 'comparevi-history/consumer-targets@v1') {
    throw "Unsupported target spec schema in '$resolvedTargetSpecPath': $($targetSpec.schema)"
  }

  $targets = @($targetSpec.targets)
  if ($targets.Count -eq 0) {
    throw "Target spec '$resolvedTargetSpecPath' did not declare any targets."
  }

  $resolvedTargetId = Get-OptionalString -Value $TargetId
  if ([string]::IsNullOrWhiteSpace($resolvedTargetId)) {
    $pathMatch = Get-OptionalString -Value $TargetPath
    if (-not [string]::IsNullOrWhiteSpace($pathMatch)) {
      $matchingTarget = @($targets | Where-Object { [string](Get-PropertyValue -Object $_ -Name 'path') -eq $pathMatch }) | Select-Object -First 1
      if ($matchingTarget) {
        $resolvedTargetId = [string](Get-PropertyValue -Object $matchingTarget -Name 'id')
      }
    }
  }
  if ([string]::IsNullOrWhiteSpace($resolvedTargetId)) {
    $defaultTargetId = Get-OptionalString -Value (Get-PropertyValue -Object $targetSpec -Name 'defaultTargetId')
    if (-not [string]::IsNullOrWhiteSpace($defaultTargetId)) {
      $resolvedTargetId = $defaultTargetId
    }
  }
  if ([string]::IsNullOrWhiteSpace($resolvedTargetId) -and $targets.Count -eq 1) {
    $resolvedTargetId = [string](Get-PropertyValue -Object $targets[0] -Name 'id')
  }
  if ([string]::IsNullOrWhiteSpace($resolvedTargetId)) {
    throw "Target spec '$resolvedTargetSpecPath' requires target_id when more than one target is declared."
  }

  $selectedTarget = @($targets | Where-Object { [string](Get-PropertyValue -Object $_ -Name 'id') -eq $resolvedTargetId }) | Select-Object -First 1
  if ($null -eq $selectedTarget) {
    throw "Target id '$resolvedTargetId' was not found in '$resolvedTargetSpecPath'."
  }

  $effectiveTargetPath = Get-OptionalString -Value (Get-PropertyValue -Object $selectedTarget -Name 'path')
  if ([string]::IsNullOrWhiteSpace($effectiveTargetPath)) {
    throw "Target '$resolvedTargetId' in '$resolvedTargetSpecPath' did not declare a path."
  }

  $targetPublicModes = @(
    @(Get-PropertyValue -Object $selectedTarget -Name 'publicModes') |
      ForEach-Object { [string]$_ } |
      ForEach-Object { $_.Trim() } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      ForEach-Object { $_.ToLowerInvariant() }
  )
  Assert-PublicModes -Modes $targetPublicModes -ContextLabel "Target '$resolvedTargetId' publicModes"

  $targetHistory = Get-PropertyValue -Object $selectedTarget -Name 'history'
  $targetHistoryStartRef = Get-OptionalString -Value (Get-PropertyValue -Object $targetHistory -Name 'startRef')
  $targetBranchBudget = Get-PropertyValue -Object $targetHistory -Name 'branchBudget'
  $targetHistorySourceBranchRef = Get-OptionalString -Value (Get-PropertyValue -Object $targetBranchBudget -Name 'sourceBranchRef')
  $targetHistoryMaxCommitCount = Get-OptionalInt -Value (Get-PropertyValue -Object $targetBranchBudget -Name 'maxCommitCount')
  $targetReviewerSurface = Get-PropertyValue -Object $selectedTarget -Name 'reviewerSurface'
} else {
  $effectiveTargetPath = Get-OptionalString -Value $TargetPath
}

if ([string]::IsNullOrWhiteSpace($effectiveTargetPath)) {
  throw 'comparevi-history requires either target_path or target_spec_path plus target_id.'
}

$reviewerSurfaceActive = $ReviewerSurface -ne 'none'
$publicSurfaceActive = $reviewerSurfaceActive -or -not [string]::IsNullOrWhiteSpace($resolvedTargetSpecPath)

$modeList = @(ConvertTo-NormalizedModeList -Value $Mode)
if ($modeList.Count -eq 0) {
  if ($targetPublicModes.Count -gt 0) {
    $modeList = @($targetPublicModes)
  } elseif ($publicSurfaceActive) {
    $modeList = @($publicModesAllowed)
  } else {
    $modeList = @('default')
  }
}
if ($publicSurfaceActive) {
  Assert-PublicModes -Modes $modeList -ContextLabel 'comparevi-history public request modes'
}

$effectiveStartRef = if ($StartRef -eq 'HEAD' -and -not [string]::IsNullOrWhiteSpace($targetHistoryStartRef)) {
  $targetHistoryStartRef
} else {
  $StartRef
}
$effectiveConsumerRepository = Get-OptionalString -Value $ConsumerRepository
if ([string]::IsNullOrWhiteSpace($effectiveConsumerRepository)) {
  $effectiveConsumerRepository = if ([string]::IsNullOrWhiteSpace($env:GITHUB_REPOSITORY)) { 'unknown' } else { $env:GITHUB_REPOSITORY }
}
$effectiveConsumerRef = Get-OptionalString -Value $ConsumerRef
if ([string]::IsNullOrWhiteSpace($effectiveConsumerRef)) {
  if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_SHA)) {
    $effectiveConsumerRef = $env:GITHUB_SHA
  } elseif (-not [string]::IsNullOrWhiteSpace($env:GITHUB_REF_NAME)) {
    $effectiveConsumerRef = $env:GITHUB_REF_NAME
  } else {
    $effectiveConsumerRef = $effectiveStartRef
  }
}
$effectiveSourceBranchRef = Get-OptionalString -Value $SourceBranchRef
if ([string]::IsNullOrWhiteSpace($effectiveSourceBranchRef)) {
  $effectiveSourceBranchRef = $targetHistorySourceBranchRef
}
$effectiveMaxBranchCommits = if ($null -ne $MaxBranchCommits -and $MaxBranchCommits -gt 0) {
  [int]$MaxBranchCommits
} else {
  $targetHistoryMaxCommitCount
}

$resultsDirResolved = Resolve-AbsolutePath -Path $ResultsDir -BasePath $repositoryRootResolved
$publicRoot = Join-Path $resultsDirResolved 'public'
$requestPath = Join-Path $publicRoot 'request.json'
$publicRunPath = Join-Path $publicRoot 'public-run.json'
$publicCommentPath = Join-Path $publicRoot 'comment.md'
$publicStepSummaryPath = Join-Path $publicRoot 'step-summary.md'
New-Item -ItemType Directory -Path $publicRoot -Force | Out-Null

$request = [ordered]@{
  schema = 'comparevi-history/request@v1'
  generatedAtUtc = [DateTime]::UtcNow.ToString('o')
  consumer = [ordered]@{
    repository = $effectiveConsumerRepository
    ref = $effectiveConsumerRef
    repositoryRoot = $repositoryRootResolved
  }
  targetSpec = if ([string]::IsNullOrWhiteSpace($resolvedTargetSpecPath)) {
    $null
  } else {
    [ordered]@{
      path = $resolvedTargetSpecPath
      targetId = $resolvedTargetId
    }
  }
  target = [ordered]@{
    id = if ([string]::IsNullOrWhiteSpace($resolvedTargetId)) { $null } else { $resolvedTargetId }
    path = $effectiveTargetPath
    requestedModes = @($modeList)
    publicModes = if ($targetPublicModes.Count -gt 0) { @($targetPublicModes) } else { $null }
  }
  history = [ordered]@{
    startRef = $effectiveStartRef
    endRef = Get-OptionalString -Value $EndRef
    sourceBranchRef = if ([string]::IsNullOrWhiteSpace($effectiveSourceBranchRef)) { $null } else { $effectiveSourceBranchRef }
    maxBranchCommits = if ($null -eq $effectiveMaxBranchCommits) { $null } else { [int]$effectiveMaxBranchCommits }
    maxPairs = if ($null -eq $MaxPairs) { $null } else { [int]$MaxPairs }
    maxSignalPairs = if ($null -eq $MaxSignalPairs) { $null } else { [int]$MaxSignalPairs }
    noisePolicy = $NoisePolicy
    resultsDir = $resultsDirResolved
    renderReport = [bool]$RenderReport.IsPresent
    reportFormat = $ReportFormat
    failFast = [bool]$FailFast.IsPresent
    failOnDiff = [bool]$FailOnDiff.IsPresent
    quiet = [bool]$Quiet.IsPresent
    detailed = [bool]$Detailed.IsPresent
    keepArtifactsOnNoDiff = [bool]$KeepArtifactsOnNoDiff.IsPresent
    includeMergeParents = [bool]$IncludeMergeParents.IsPresent
    compareTimeoutSeconds = if ($null -eq $CompareTimeoutSeconds) { $null } else { [int]$CompareTimeoutSeconds }
  }
  reviewerSurface = [ordered]@{
    kind = $ReviewerSurface
    issueNumber = Get-OptionalString -Value $ReviewerIssueNumber
    pullRequestNumber = Get-OptionalString -Value $ReviewerPullRequestNumber
    isFork = Get-OptionalString -Value $ReviewerIsFork
    containerImage = Get-OptionalString -Value $ContainerImage
  }
  results = [ordered]@{
    resultsDir = $resultsDirResolved
    publicRoot = $publicRoot
    requestPath = $requestPath
    publicRunPath = $publicRunPath
    publicCommentPath = $publicCommentPath
    publicStepSummaryPath = $publicStepSummaryPath
  }
}
$request | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $requestPath -Encoding utf8

Write-ActionOutput -Key 'repository-root' -Value $repositoryRootResolved
Write-ActionOutput -Key 'consumer-repository' -Value $effectiveConsumerRepository
Write-ActionOutput -Key 'consumer-ref' -Value $effectiveConsumerRef
Write-ActionOutput -Key 'target-path' -Value $effectiveTargetPath
Write-ActionOutput -Key 'target-id' -Value $(if ([string]::IsNullOrWhiteSpace($resolvedTargetId)) { '' } else { $resolvedTargetId })
Write-ActionOutput -Key 'target-spec-path' -Value $(if ([string]::IsNullOrWhiteSpace($resolvedTargetSpecPath)) { '' } else { $resolvedTargetSpecPath })
Write-ActionOutput -Key 'requested-mode-list' -Value ($modeList -join ',')
Write-ActionOutput -Key 'results-dir' -Value $resultsDirResolved
Write-ActionOutput -Key 'request-path' -Value $requestPath
Write-ActionOutput -Key 'public-run-path' -Value $publicRunPath
Write-ActionOutput -Key 'public-comment-path' -Value $publicCommentPath
Write-ActionOutput -Key 'public-step-summary-path' -Value $publicStepSummaryPath
Write-ActionOutput -Key 'source-branch-ref' -Value $(if ([string]::IsNullOrWhiteSpace($effectiveSourceBranchRef)) { '' } else { $effectiveSourceBranchRef })
Write-ActionOutput -Key 'max-branch-commits' -Value $(if ($null -eq $effectiveMaxBranchCommits) { '' } else { [string][int]$effectiveMaxBranchCommits })
Write-ActionOutput -Key 'reviewer-surface' -Value $ReviewerSurface

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  $surfaceNote = if ($ReviewerSurface -eq 'none') { 'none' } else { $ReviewerSurface }
  @(
    '## comparevi-history request'
    ''
    ('- Consumer repository: `{0}`' -f $effectiveConsumerRepository)
    ('- Consumer ref: `{0}`' -f $effectiveConsumerRef)
    ('- Target path: `{0}`' -f $effectiveTargetPath)
    ('- Target id: `{0}`' -f $(if ([string]::IsNullOrWhiteSpace($resolvedTargetId)) { 'n/a' } else { $resolvedTargetId }))
    ('- Target spec: `{0}`' -f $(if ([string]::IsNullOrWhiteSpace($resolvedTargetSpecPath)) { 'legacy target_path input' } else { $resolvedTargetSpecPath }))
    ('- Requested modes: `{0}`' -f ($modeList -join ', '))
    ('- Reviewer surface: `{0}`' -f $surfaceNote)
    ('- Results dir: `{0}`' -f $resultsDirResolved)
    ('- Request receipt: `{0}`' -f $requestPath)
  ) | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
}

$request | ConvertTo-Json -Depth 20
