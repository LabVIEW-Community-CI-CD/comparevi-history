param(
  [Parameter(Mandatory = $true)]
  [string]$CandidateRepositoryRoot,
  [Parameter(Mandatory = $true)]
  [string]$TrustedRepositoryRoot,
  [Parameter(Mandatory = $true)]
  [string]$DiscoveryPath,
  [Parameter(Mandatory = $true)]
  [string]$ResultsDir,
  [Parameter(Mandatory = $true)]
  [string]$HeadSha,
  [Parameter(Mandatory = $true)]
  [string]$HeadRef,
  [Parameter(Mandatory = $true)]
  [string]$HeadRepository,
  [Parameter(Mandatory = $true)]
  [string]$PullRequestNumber,
  [string]$ReviewerIsFork = 'false',
  [Nullable[int]]$CompareTimeoutSeconds,
  [string]$InvokeScriptPath,
  [string]$ToolingRoot,
  [string]$CompareviRepository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
  [string]$CompareviRef,
  [string]$ContainerImage = 'nationalinstruments/labview:2026q1-linux',
  [string]$PlatformRoot,
  [string]$RunUrl,
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

function Read-KeyValueFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

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

function ConvertTo-StringArray {
  param(
    [AllowNull()]
    $Value
  )

  $items = New-Object System.Collections.Generic.List[string]
  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($entry in @(ConvertTo-ObjectArray -Value $Value)) {
    $normalized = Get-OptionalString -Value $entry
    if ([string]::IsNullOrWhiteSpace($normalized)) {
      continue
    }

    if ($seen.Add($normalized)) {
      $items.Add($normalized) | Out-Null
    }
  }

  return @($items | ForEach-Object { $_ })
}

function Resolve-DefaultInvokeScriptPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryRoot
  )

  $candidate = Join-Path $RepositoryRoot 'Tooling' 'Invoke-CompareVIHistoryHostedNILinux.ps1'
  if (Test-Path -LiteralPath $candidate -PathType Leaf) {
    return $candidate
  }

  return $null
}

function ConvertTo-SafeName {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Value
  )

  $safe = $Value -replace '[^A-Za-z0-9._-]+', '-'
  $safe = $safe.Trim('-')
  if ([string]::IsNullOrWhiteSpace($safe)) {
    return 'target'
  }

  return $safe
}

$basePath = (Get-Location).Path
$candidateRepositoryRootResolved = Resolve-AbsolutePath -Path $CandidateRepositoryRoot -BasePath $basePath
$trustedRepositoryRootResolved = Resolve-AbsolutePath -Path $TrustedRepositoryRoot -BasePath $basePath
$discoveryPathResolved = Resolve-AbsolutePath -Path $DiscoveryPath -BasePath $basePath
$resultsDirResolved = Resolve-AbsolutePath -Path $ResultsDir -BasePath $basePath
$platformRootResolved = if ([string]::IsNullOrWhiteSpace($PlatformRoot)) {
  Split-Path -Parent $PSScriptRoot
} else {
  Resolve-AbsolutePath -Path $PlatformRoot -BasePath $basePath
}

foreach ($requiredDirectory in @($candidateRepositoryRootResolved, $trustedRepositoryRootResolved, $platformRootResolved)) {
  if (-not (Test-Path -LiteralPath $requiredDirectory -PathType Container)) {
    throw "Required directory was not found: $requiredDirectory"
  }
}
if (-not (Test-Path -LiteralPath $discoveryPathResolved -PathType Leaf)) {
  throw "Required file was not found: $discoveryPathResolved"
}

New-Item -ItemType Directory -Path $resultsDirResolved -Force | Out-Null

$discovery = Read-JsonFile -Path $discoveryPathResolved
if ([string]$discovery.schema -ne 'comparevi-history/changed-vi-discovery@v2') {
  throw "Unsupported discovery schema in '$discoveryPathResolved': $($discovery.schema)"
}
if ([string]$discovery.summary.executionStatus -ne 'ready') {
  throw "Automatic pull request diagnostics require a ready discovery receipt. Actual status: $($discovery.summary.executionStatus)"
}

$effectiveInvokeScriptPath = if (-not [string]::IsNullOrWhiteSpace($InvokeScriptPath)) {
  Resolve-AbsolutePath -Path $InvokeScriptPath -BasePath $trustedRepositoryRootResolved
} else {
  Resolve-DefaultInvokeScriptPath -RepositoryRoot $trustedRepositoryRootResolved
}
if ([string]::IsNullOrWhiteSpace($effectiveInvokeScriptPath) -or -not (Test-Path -LiteralPath $effectiveInvokeScriptPath -PathType Leaf)) {
  throw 'Automatic pull request diagnostics require a trusted consumer-local Tooling/Invoke-CompareVIHistoryHostedNILinux.ps1 adapter.'
}

$toolingRootResolved = $null
$toolingSource = $null
$effectiveCompareviRef = $null
if (-not [string]::IsNullOrWhiteSpace($ToolingRoot)) {
  $toolingRootResolved = Resolve-AbsolutePath -Path $ToolingRoot -BasePath $basePath
  if (-not (Test-Path -LiteralPath $toolingRootResolved -PathType Container)) {
    throw "Provided tooling root was not found: $toolingRootResolved"
  }

  $toolingSource = 'provided-tooling-root'
  $effectiveCompareviRef = if ([string]::IsNullOrWhiteSpace($CompareviRef)) { 'provided-tooling-root' } else { $CompareviRef.Trim() }
} else {
  $resolveOutputPath = Join-Path $resultsDirResolved 'resolve-backend.out'
  & (Join-Path $platformRootResolved 'scripts' 'Resolve-CompareVIHistoryBackend.ps1') `
    -Repository $CompareviRepository `
    -RequestedRef $CompareviRef `
    -DefaultRefPath (Join-Path $platformRootResolved 'comparevi-backend-ref.txt') `
    -ActionRef 'pull-request-diagnostics-auto' `
    -ToolingPath (Join-Path $resultsDirResolved '.comparevi-history-tools') `
    -AllowSourceFallback `
    -GitHubToken $GitHubToken `
    -GitHubOutputPath $resolveOutputPath | Out-Null

  $resolveValues = Read-KeyValueFile -Path $resolveOutputPath
  $toolingSource = [string]$resolveValues['tooling-source']
  $effectiveCompareviRef = [string]$resolveValues['comparevi-ref']
  if ([string]::IsNullOrWhiteSpace($toolingSource)) {
    throw 'Failed to resolve comparevi-history backend tooling source.'
  }

  if ($toolingSource -eq 'bundle') {
    $acquireOutputPath = Join-Path $resultsDirResolved 'acquire-backend.out'
    & (Join-Path $platformRootResolved 'scripts' 'Acquire-CompareVIToolsBundle.ps1') `
      -Repository $CompareviRepository `
      -ReleaseTag ([string]$resolveValues['release-tag']) `
      -BundleAssetName ([string]$resolveValues['bundle-asset-name']) `
      -BundleAssetUrl ([string]$resolveValues['bundle-asset-url']) `
      -BundleAssetDigest ([string]$resolveValues['bundle-asset-digest']) `
      -DestinationPath ([string]$resolveValues['tooling-path']) `
      -GitHubToken $GitHubToken `
      -GitHubOutputPath $acquireOutputPath | Out-Null

    $acquireValues = Read-KeyValueFile -Path $acquireOutputPath
    $toolingRootResolved = Resolve-AbsolutePath -Path ([string]$acquireValues['tooling-path']) -BasePath $basePath
  } else {
    $toolingRootResolved = Resolve-AbsolutePath -Path ([string]$resolveValues['tooling-path']) -BasePath $basePath
  }
}

if (-not (Test-Path -LiteralPath $toolingRootResolved -PathType Container)) {
  throw "Resolved tooling root was not found: $toolingRootResolved"
}

$targetsRoot = Join-Path $resultsDirResolved 'targets'
New-Item -ItemType Directory -Path $targetsRoot -Force | Out-Null
$manifestPath = Join-Path $resultsDirResolved 'pr-target-runs-manifest.json'
$noisePolicy = Get-OptionalString -Value (Get-NestedValue -Object $discovery -Path @('prPolicy', 'execution', 'noisePolicy'))
if ([string]::IsNullOrWhiteSpace($noisePolicy)) {
  $noisePolicy = 'include'
}

$targetRuns = New-Object System.Collections.Generic.List[object]
$executedTargetCount = 0
$failedTargetCount = 0
$skippedTargetCount = 0
$index = 0

foreach ($selectedTarget in @($discovery.selectedTargets)) {
  $targetId = [string]$selectedTarget.targetId
  $targetPath = [string]$selectedTarget.targetPath
  $targetSafeName = ConvertTo-SafeName -Value $(if ([string]::IsNullOrWhiteSpace($targetId)) { $targetPath } else { $targetId })
  $targetRoot = Join-Path $targetsRoot ('{0:d3}-{1}' -f ($index + 1), $targetSafeName)
  $historyResultsDir = Join-Path $targetRoot 'history'
  New-Item -ItemType Directory -Path $targetRoot -Force | Out-Null

  $requestOutputPath = Join-Path $targetRoot 'request.out'
  $runOutputPath = Join-Path $targetRoot 'run.out'
  $publicRunOutputPath = Join-Path $targetRoot 'public-run.out'
  $modeSummaryJsonPath = Join-Path $targetRoot 'mode-summary.json'
  $modeSummaryPath = Join-Path $targetRoot 'mode-summary.md'

  $requestOutcome = 'failure'
  $runOutcome = 'skipped'
  $runConclusion = 'skipped'
  $requestError = $null
  $runError = $null
  $publicRunError = $null
  $requestedModes = @(ConvertTo-StringArray -Value (Get-NestedValue -Object $selectedTarget -Path @('requestedModes')))
  $requestedModeList = if ($requestedModes.Count -eq 0) { $null } else { $requestedModes -join ',' }
  $effectiveSourceBranchRef = Get-OptionalString -Value (Get-NestedValue -Object $selectedTarget -Path @('history', 'branchBudget', 'sourceBranchRef'))
  $keepArtifactsOnNoDiff = [bool](Get-NestedValue -Object $selectedTarget -Path @('keepArtifactsOnNoDiff') -Default $false)

  try {
    $requestArgs = @{
      RepositoryRoot = $candidateRepositoryRootResolved
      TargetPath = $targetPath
      TargetId = $targetId
      StartRef = $HeadSha
      NoisePolicy = $noisePolicy
      ResultsDir = $historyResultsDir
      ReportFormat = 'html'
      RenderReport = $true
      Detailed = $true
      ConsumerRepository = $HeadRepository
      ConsumerRef = $HeadSha
      ReviewerSurface = 'manual'
      ReviewerPullRequestNumber = $PullRequestNumber
      ReviewerIsFork = $ReviewerIsFork
      ContainerImage = $ContainerImage
      GitHubOutputPath = $requestOutputPath
    }
    if (-not [string]::IsNullOrWhiteSpace($requestedModeList)) {
      $requestArgs.Mode = $requestedModeList
    }
    if (-not [string]::IsNullOrWhiteSpace($effectiveSourceBranchRef)) {
      $requestArgs.SourceBranchRef = $effectiveSourceBranchRef
    }
    if ($keepArtifactsOnNoDiff) {
      $requestArgs.KeepArtifactsOnNoDiff = $true
    }
    if ($null -ne $CompareTimeoutSeconds) {
      $requestArgs.CompareTimeoutSeconds = [int]$CompareTimeoutSeconds
    }

    & (Join-Path $platformRootResolved 'scripts' 'Resolve-CompareVIHistoryRequest.ps1') @requestArgs | Out-Null
    $requestOutcome = 'success'
  } catch {
    $requestError = $_
  }

  $requestValues = Read-KeyValueFile -Path $requestOutputPath
  $runValues = @{}
  $publicRunValues = @{}
  if ($requestOutcome -eq 'success') {
    $executedTargetCount += 1
    try {
      $invokeArgs = @{
        RepositoryRoot = $candidateRepositoryRootResolved
        ToolingRoot = $toolingRootResolved
        TargetPath = [string]$requestValues['target-path']
        StartRef = $HeadSha
        NoisePolicy = $noisePolicy
        Mode = [string]$requestValues['requested-mode-list']
        ResultsDir = [string]$requestValues['results-dir']
        ReportFormat = 'html'
        RenderReport = $true
        Detailed = $true
        InvokeScriptPath = $effectiveInvokeScriptPath
        GitHubOutputPath = $runOutputPath
      }
      if (-not [string]::IsNullOrWhiteSpace([string]$requestValues['source-branch-ref'])) {
        $invokeArgs.SourceBranchRef = [string]$requestValues['source-branch-ref']
      }
      if ($null -ne $CompareTimeoutSeconds) {
        $invokeArgs.CompareTimeoutSeconds = [int]$CompareTimeoutSeconds
      }

      & (Join-Path $platformRootResolved 'scripts' 'Invoke-CompareVIHistoryFacade.ps1') @invokeArgs | Out-Null
      $runOutcome = 'success'
      $runConclusion = 'success'
    } catch {
      $runOutcome = 'failure'
      $runConclusion = 'failure'
      $runError = $_
    }

    $runValues = Read-KeyValueFile -Path $runOutputPath

    & (Join-Path $platformRootResolved 'scripts' 'Format-CompareVIHistoryModeSummary.ps1') `
      -RequestedModeList $([string]$runValues['requested-mode-list']) `
      -ExecutedModeList $([string]$runValues['executed-mode-list']) `
      -ModeManifestsJson $([string]$runValues['mode-manifests-json']) `
      -TotalProcessed $([string]$runValues['total-processed']) `
      -TotalDiffs $([string]$runValues['total-diffs']) `
      -StopReason $([string]$runValues['stop-reason']) `
      -JsonOutputPath $modeSummaryJsonPath `
      -OutputPath $modeSummaryPath | Out-Null

    $modeSummaryMarkdown = if (Test-Path -LiteralPath $modeSummaryPath -PathType Leaf) {
      Get-Content -LiteralPath $modeSummaryPath -Raw
    } else {
      ''
    }

    try {
      & (Join-Path $platformRootResolved 'scripts' 'Write-CompareVIHistoryPublicRun.ps1') `
        -RequestPath ([string]$requestValues['request-path']) `
        -ToolingRoot $toolingRootResolved `
        -CompareviRepository $CompareviRepository `
        -CompareviRef $effectiveCompareviRef `
        -ToolingSource $toolingSource `
        -ActionRef 'comparevi-history/pull-request-diagnostics-auto' `
        -HistorySummaryJson $([string]$runValues['history-summary-json']) `
        -ManifestPath $([string]$runValues['manifest-path']) `
        -ResultsDir $([string]$runValues['results-dir']) `
        -HistoryReportMd $([string]$runValues['history-report-md']) `
        -HistoryReportHtml $([string]$runValues['history-report-html']) `
        -ModeSummaryJsonPath $modeSummaryJsonPath `
        -ModeSummaryPath $modeSummaryPath `
        -RequestedModeList $([string]$runValues['requested-mode-list']) `
        -ExecutedModeList $([string]$runValues['executed-mode-list']) `
        -ModeSummaryMarkdown $modeSummaryMarkdown `
        -ModeCount $([string]$runValues['mode-count']) `
        -TotalProcessed $([string]$runValues['total-processed']) `
        -TotalDiffs $([string]$runValues['total-diffs']) `
        -StopReason $([string]$runValues['stop-reason']) `
        -RunOutcome $runOutcome `
        -RunConclusion $runConclusion `
        -RunUrl $RunUrl `
        -GitHubOutputPath $publicRunOutputPath | Out-Null
    } catch {
      $publicRunError = $_
    }

    $publicRunValues = Read-KeyValueFile -Path $publicRunOutputPath
  }

  $finalStatus = if ($publicRunValues.ContainsKey('final-status')) {
    [string]$publicRunValues['final-status']
  } elseif ($requestOutcome -ne 'success') {
    'failed'
  } elseif ($runOutcome -eq 'failure') {
    'failed'
  } else {
    'unknown'
  }

  $finalReason = if ($publicRunValues.ContainsKey('final-reason')) {
    [string]$publicRunValues['final-reason']
  } elseif ($requestOutcome -ne 'success') {
    'request-normalization-failed'
  } elseif ($null -ne $publicRunError) {
    'public-run-write-failed'
  } elseif ($runOutcome -eq 'failure') {
    'facade-step-failed'
  } else {
    'unknown'
  }

  if ($finalStatus -ne 'succeeded') {
    $failedTargetCount += 1
  }

  $targetRuns.Add([ordered]@{
      targetId = $targetId
      targetSource = Get-OptionalString -Value $selectedTarget.targetSource
      targetPath = $targetPath
      requestedModes = @($requestedModes)
      requestedModeSource = Get-OptionalString -Value (Get-NestedValue -Object $selectedTarget -Path @('requestedModeSource'))
      sourceBranchRef = if ([string]::IsNullOrWhiteSpace($effectiveSourceBranchRef)) { $null } else { $effectiveSourceBranchRef }
      keepArtifactsOnNoDiff = $keepArtifactsOnNoDiff
      currentPath = Get-OptionalString -Value $selectedTarget.currentPath
      previousPath = Get-OptionalString -Value $selectedTarget.previousPath
      changeStatus = Get-OptionalString -Value $selectedTarget.changeStatus
      requestOutcome = $requestOutcome
      runOutcome = $runOutcome
      finalStatus = $finalStatus
      finalReason = $finalReason
      requestPath = Get-OptionalString -Value $requestValues['request-path']
      publicRunPath = Get-OptionalString -Value $publicRunValues['public-run-path']
      sharedEvidencePath = Get-OptionalString -Value $publicRunValues['shared-evidence-path']
      publicCommentPath = Get-OptionalString -Value $publicRunValues['public-comment-path']
      publicStepSummaryPath = Get-OptionalString -Value $publicRunValues['public-step-summary-path']
      historySummaryJsonPath = Get-OptionalString -Value $publicRunValues['history-summary-json']
      manifestPath = Get-OptionalString -Value $runValues['manifest-path']
      modeSummaryJsonPath = if (Test-Path -LiteralPath $modeSummaryJsonPath -PathType Leaf) { $modeSummaryJsonPath } else { $null }
      modeSummaryPath = if (Test-Path -LiteralPath $modeSummaryPath -PathType Leaf) { $modeSummaryPath } else { $null }
      historyReportMdPath = Get-OptionalString -Value $runValues['history-report-md']
      historyReportHtmlPath = Get-OptionalString -Value $runValues['history-report-html']
      totalProcessed = if ([string]::IsNullOrWhiteSpace([string]$runValues['total-processed'])) { $null } else { [int][string]$runValues['total-processed'] }
      totalDiffs = if ([string]::IsNullOrWhiteSpace([string]$runValues['total-diffs'])) { $null } else { [int][string]$runValues['total-diffs'] }
      resultsDir = Get-OptionalString -Value $requestValues['results-dir']
      requestError = if ($null -eq $requestError) { $null } else { [string]$requestError.Exception.Message }
      runError = if ($null -eq $runError) { $null } else { [string]$runError.Exception.Message }
      publicRunError = if ($null -eq $publicRunError) { $null } else { [string]$publicRunError.Exception.Message }
    }) | Out-Null

  $index += 1
}

$executionStatus = if ($failedTargetCount -gt 0) {
  'failed'
} elseif ($executedTargetCount -eq 0) {
  'skipped'
} else {
  'succeeded'
}
$executionReason = switch ($executionStatus) {
  'failed' { 'one-or-more-targets-failed' }
  'skipped' { 'no-targets-executed' }
  default { 'completed' }
}

$manifest = [ordered]@{
  schema = 'comparevi-history/pr-target-runs-manifest@v2'
  generatedAtUtc = [DateTime]::UtcNow.ToString('o')
  pullRequest = [ordered]@{
    number = [int]$PullRequestNumber
    headRepository = $HeadRepository
    headRef = $HeadRef
    headSha = $HeadSha
    isFork = [string]$ReviewerIsFork
  }
  discovery = [ordered]@{
    schema = 'comparevi-history/changed-vi-discovery@v2'
    path = $discoveryPathResolved
    selectedTargetCount = @($discovery.selectedTargets).Count
  }
  tooling = [ordered]@{
    source = $toolingSource
    repository = $CompareviRepository
    ref = $effectiveCompareviRef
    root = $toolingRootResolved
    invokeScriptPath = $effectiveInvokeScriptPath
    containerImage = $ContainerImage
  }
  summary = [ordered]@{
    selectedTargetCount = @($discovery.selectedTargets).Count
    executedTargetCount = $executedTargetCount
    failedTargetCount = $failedTargetCount
    skippedTargetCount = $skippedTargetCount
    executionStatus = $executionStatus
    executionReason = $executionReason
  }
  targets = @($targetRuns | ForEach-Object { $_ })
}

$manifest | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $manifestPath -Encoding utf8

Write-ActionOutput -Key 'target-runs-manifest-path' -Value $manifestPath
Write-ActionOutput -Key 'tooling-path' -Value $toolingRootResolved
Write-ActionOutput -Key 'tooling-source' -Value $toolingSource
Write-ActionOutput -Key 'comparevi-ref' -Value $effectiveCompareviRef
Write-ActionOutput -Key 'executed-target-count' -Value ([string]$executedTargetCount)
Write-ActionOutput -Key 'failed-target-count' -Value ([string]$failedTargetCount)
Write-ActionOutput -Key 'skipped-target-count' -Value ([string]$skippedTargetCount)
Write-ActionOutput -Key 'execution-status' -Value $executionStatus
Write-ActionOutput -Key 'execution-reason' -Value $executionReason

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  @(
    '## comparevi-history automatic pull request diagnostics'
    ''
    ('- Head repository: `{0}`' -f $HeadRepository)
    ('- Head ref: `{0}`' -f $HeadRef)
    ('- Head SHA: `{0}`' -f $HeadSha)
    ('- Tooling source: `{0}`' -f $toolingSource)
    ('- Tooling ref: `{0}`' -f $effectiveCompareviRef)
    ('- Executed target count: `{0}`' -f $executedTargetCount)
    ('- Failed target count: `{0}`' -f $failedTargetCount)
    ('- Execution status: `{0}`' -f $executionStatus)
    ('- Execution reason: `{0}`' -f $executionReason)
    ('- Target runs manifest: `{0}`' -f $manifestPath)
  ) | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
}

$manifest | ConvertTo-Json -Depth 32
