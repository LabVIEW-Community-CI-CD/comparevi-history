param(
  [Parameter(Mandatory = $true)]
  [string]$ConsumerRepositoryRoot,
  [Parameter(Mandatory = $true)]
  [string]$ViPath,
  [string]$ConsumerRef = 'HEAD',
  [string]$ConsumerRepository,
  [string]$ResultsDir = 'tests/results/ref-compare/history-exploration/local-fast-loop',
  [string]$Mode = 'full',
  [ValidateSet('include', 'collapse', 'skip')]
  [string]$NoisePolicy = 'include',
  [switch]$IncludeMergeParents,
  [Nullable[int]]$MaxPairs,
  [Nullable[int]]$MaxSignalPairs,
  [Nullable[int]]$CompareTimeoutSeconds,
  [string]$InvokeScriptPath,
  [string]$ToolingRoot,
  [string]$CompareviRepository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
  [string]$CompareviRef,
  [string]$GitHubToken,
  [switch]$SkipImagePull
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Resolve-DefaultInvokeScriptPath {
  param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

  $candidate = Join-Path $RepositoryRoot 'Tooling' 'Invoke-CompareVIHistoryHostedNILinux.ps1'
  if (Test-Path -LiteralPath $candidate -PathType Leaf) {
    return $candidate
  }

  return $null
}

function Resolve-ToolingMetadata {
  param([Parameter(Mandatory = $true)][string]$ToolingRootPath)

  $metadataPath = Join-Path $ToolingRootPath 'comparevi-tools-release.json'
  if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
    return $null
  }

  return Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json -Depth 32
}

function Invoke-DockerPull {
  param([Parameter(Mandatory = $true)][string]$Image)

  $dockerCommand = Get-Command docker -ErrorAction SilentlyContinue
  if ($null -eq $dockerCommand) {
    throw "docker was not found on PATH, but the local fast loop requires it to pre-pull '$Image'."
  }

  & $dockerCommand.Source pull $Image
  if ($LASTEXITCODE -ne 0) {
    throw "docker pull failed for image '$Image'."
  }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$consumerRootResolved = Resolve-AbsolutePath -Path $ConsumerRepositoryRoot -BasePath (Get-Location).Path
if (-not (Test-Path -LiteralPath $consumerRootResolved -PathType Container)) {
  throw "Consumer repository root not found: $consumerRootResolved"
}

[void](Invoke-GitCapture -RepositoryRoot $consumerRootResolved -Arguments @('rev-parse', '--show-toplevel'))
$selectedConsumerSha = (Invoke-GitCapture -RepositoryRoot $consumerRootResolved -Arguments @('rev-parse', '--verify', "$ConsumerRef^{commit}")).Trim()
$consumerRepositorySlug = Resolve-ConsumerRepositorySlug -RepositoryRoot $consumerRootResolved -Override $ConsumerRepository
$resultsDirResolved = Resolve-AbsolutePath -Path $ResultsDir -BasePath $consumerRootResolved
$historyResultsDir = Join-Path $resultsDirResolved 'history'
$revisionCatalogSummaryPath = Join-Path $resultsDirResolved 'revision-catalog-summary.md'
$modeSummaryPath = Join-Path $resultsDirResolved 'mode-summary.md'
$modeSummaryJsonPath = Join-Path $resultsDirResolved 'mode-summary.json'
$localSummaryPath = Join-Path $resultsDirResolved 'local-fast-loop-summary.md'
$localReceiptPath = Join-Path $resultsDirResolved 'local-fast-loop.json'
New-Item -ItemType Directory -Path $resultsDirResolved -Force | Out-Null

$effectiveInvokeScriptPath = if (-not [string]::IsNullOrWhiteSpace($InvokeScriptPath)) {
  Resolve-AbsolutePath -Path $InvokeScriptPath -BasePath $consumerRootResolved
} else {
  Resolve-DefaultInvokeScriptPath -RepositoryRoot $consumerRootResolved
}
if ([string]::IsNullOrWhiteSpace($effectiveInvokeScriptPath) -or -not (Test-Path -LiteralPath $effectiveInvokeScriptPath -PathType Leaf)) {
  throw 'Local manual exploration fast loop requires invoke_script_path or a consumer-local Tooling/Invoke-CompareVIHistoryHostedNILinux.ps1 adapter.'
}

$toolingRootResolved = $null
$toolingSource = $null
$effectiveCompareviRef = $null
$hostedRunnerDefaultImage = $null
$resolvedGitHubToken = Resolve-GitHubToken

if (-not [string]::IsNullOrWhiteSpace($ToolingRoot)) {
  $toolingRootResolved = Resolve-AbsolutePath -Path $ToolingRoot -BasePath (Get-Location).Path
  if (-not (Test-Path -LiteralPath $toolingRootResolved -PathType Container)) {
    throw "Tooling root not found: $toolingRootResolved"
  }
  $toolingSource = 'provided-tooling-root'
  $effectiveCompareviRef = if ([string]::IsNullOrWhiteSpace($CompareviRef)) { 'provided-tooling-root' } else { $CompareviRef.Trim() }
} else {
  $resolveOutputPath = Join-Path $resultsDirResolved 'resolve-backend.out'
  & (Join-Path $repoRoot 'scripts' 'Resolve-CompareVIHistoryBackend.ps1') `
    -Repository $CompareviRepository `
    -RequestedRef $CompareviRef `
    -DefaultRefPath (Join-Path $repoRoot 'comparevi-backend-ref.txt') `
    -ActionRef 'local-fast-loop' `
    -ToolingPath (Join-Path $resultsDirResolved '.comparevi-history-tools') `
    -AllowSourceFallback `
    -GitHubToken $resolvedGitHubToken `
    -GitHubOutputPath $resolveOutputPath | Out-Null

  $backendValues = Read-KeyValueFile -Path $resolveOutputPath
  $toolingSource = [string]$backendValues['tooling-source']
  $effectiveCompareviRef = [string]$backendValues['comparevi-ref']
  if ([string]::IsNullOrWhiteSpace($toolingSource)) {
    throw 'Failed to resolve comparevi-history backend tooling source for local fast loop.'
  }

  if ($toolingSource -eq 'bundle') {
    $acquireOutputPath = Join-Path $resultsDirResolved 'acquire-backend.out'
    & (Join-Path $repoRoot 'scripts' 'Acquire-CompareVIToolsBundle.ps1') `
      -Repository $CompareviRepository `
      -ReleaseTag ([string]$backendValues['release-tag']) `
      -BundleAssetName ([string]$backendValues['bundle-asset-name']) `
      -BundleAssetUrl ([string]$backendValues['bundle-asset-url']) `
      -BundleAssetDigest ([string]$backendValues['bundle-asset-digest']) `
      -DestinationPath ([string]$backendValues['tooling-path']) `
      -GitHubToken $resolvedGitHubToken `
      -GitHubOutputPath $acquireOutputPath | Out-Null

    $acquireValues = Read-KeyValueFile -Path $acquireOutputPath
    $toolingRootResolved = Resolve-AbsolutePath -Path ([string]$acquireValues['tooling-path']) -BasePath (Get-Location).Path
    $hostedRunnerDefaultImage = [string]$acquireValues['hosted-runner-default-image']
  } else {
    throw 'Local manual exploration fast loop supports released backend bundles only. For unreleased backend work, supply -ToolingRoot explicitly.'
  }
}

if (-not (Test-Path -LiteralPath $toolingRootResolved -PathType Container)) {
  throw "Resolved tooling root not found: $toolingRootResolved"
}

$toolingMetadata = Resolve-ToolingMetadata -ToolingRootPath $toolingRootResolved
if ([string]::IsNullOrWhiteSpace($hostedRunnerDefaultImage) -and $null -ne $toolingMetadata) {
  if ($toolingMetadata.PSObject.Properties['consumerContract'] -and $toolingMetadata.consumerContract.PSObject.Properties['hostedNiLinuxRunner']) {
    $hostedRunnerDefaultImage = [string]$toolingMetadata.consumerContract.hostedNiLinuxRunner.defaultImage
  }
}
if ([string]::IsNullOrWhiteSpace($hostedRunnerDefaultImage)) {
  $hostedRunnerDefaultImage = if ([string]::IsNullOrWhiteSpace($env:COMPAREVI_NI_LINUX_IMAGE)) {
    'nationalinstruments/labview:2026q1-linux'
  } else {
    $env:COMPAREVI_NI_LINUX_IMAGE.Trim()
  }
}

if (-not $SkipImagePull.IsPresent) {
  Invoke-DockerPull -Image $hostedRunnerDefaultImage
}

$catalogOutputPath = Join-Path $resultsDirResolved 'revision-catalog.out'
& (Join-Path $repoRoot 'scripts' 'Write-CompareVIHistoryRevisionCatalog.ps1') `
  -RepositoryRoot $consumerRootResolved `
  -TargetPath $ViPath `
  -SelectedRef $selectedConsumerSha `
  -ConsumerRepository $consumerRepositorySlug `
  -ConsumerRef $ConsumerRef `
  -ResultsDir $resultsDirResolved `
  -IncludeMergeParents:$IncludeMergeParents.IsPresent `
  -GitHubOutputPath $catalogOutputPath `
  -StepSummaryPath $revisionCatalogSummaryPath | Out-Null
$catalogValues = Read-KeyValueFile -Path $catalogOutputPath

$requestOutputPath = Join-Path $resultsDirResolved 'request.out'
& (Join-Path $repoRoot 'scripts' 'Resolve-CompareVIHistoryRequest.ps1') `
  -RepositoryRoot $consumerRootResolved `
  -TargetPath $ViPath `
  -StartRef $selectedConsumerSha `
  -NoisePolicy $NoisePolicy `
  -Mode $Mode `
  -ResultsDir $historyResultsDir `
  -ReportFormat 'html' `
  -RenderReport `
  -IncludeMergeParents:$IncludeMergeParents.IsPresent `
  -ConsumerRepository $consumerRepositorySlug `
  -ConsumerRef $ConsumerRef `
  -GitHubOutputPath $requestOutputPath | Out-Null
$requestValues = Read-KeyValueFile -Path $requestOutputPath

$runOutputPath = Join-Path $resultsDirResolved 'run.out'
$runOutcome = 'success'
$runConclusion = 'success'
$runException = $null
try {
  $invokeArgs = @{
    RepositoryRoot = $consumerRootResolved
    ToolingRoot = $toolingRootResolved
    TargetPath = [string]$requestValues['target-path']
    StartRef = $selectedConsumerSha
    NoisePolicy = $NoisePolicy
    Mode = [string]$requestValues['requested-mode-list']
    ResultsDir = [string]$requestValues['results-dir']
    ReportFormat = 'html'
    RenderReport = $true
    Detailed = $true
    IncludeMergeParents = $IncludeMergeParents.IsPresent
    InvokeScriptPath = $effectiveInvokeScriptPath
    GitHubOutputPath = $runOutputPath
  }
  if ($null -ne $MaxPairs) {
    $invokeArgs.MaxPairs = [int]$MaxPairs
  }
  if ($null -ne $MaxSignalPairs) {
    $invokeArgs.MaxSignalPairs = [int]$MaxSignalPairs
  }
  if ($null -ne $CompareTimeoutSeconds) {
    $invokeArgs.CompareTimeoutSeconds = [int]$CompareTimeoutSeconds
  }

  & (Join-Path $repoRoot 'scripts' 'Invoke-CompareVIHistoryFacade.ps1') @invokeArgs | Out-Null
} catch {
  $runOutcome = 'failure'
  $runConclusion = 'failure'
  $runException = $_
}
$runValues = Read-KeyValueFile -Path $runOutputPath

& (Join-Path $repoRoot 'scripts' 'Format-CompareVIHistoryModeSummary.ps1') `
  -RequestedModeList ([string]$runValues['requested-mode-list']) `
  -ExecutedModeList ([string]$runValues['executed-mode-list']) `
  -ModeManifestsJson ([string]$runValues['mode-manifests-json']) `
  -TotalProcessed ([string]$runValues['total-processed']) `
  -TotalDiffs ([string]$runValues['total-diffs']) `
  -StopReason ([string]$runValues['stop-reason']) `
  -NoisePolicy $NoisePolicy `
  -JsonOutputPath $modeSummaryJsonPath `
  -OutputPath $modeSummaryPath | Out-Null
$modeSummaryMarkdown = if (Test-Path -LiteralPath $modeSummaryPath -PathType Leaf) {
  Get-Content -LiteralPath $modeSummaryPath -Raw
} else {
  ''
}

$publicRunOutputPath = Join-Path $resultsDirResolved 'public-run.out'
& (Join-Path $repoRoot 'scripts' 'Write-CompareVIHistoryPublicRun.ps1') `
  -RequestPath ([string]$requestValues['request-path']) `
  -ToolingRoot $toolingRootResolved `
  -CompareviRepository $CompareviRepository `
  -CompareviRef $effectiveCompareviRef `
  -ToolingSource $toolingSource `
  -ActionRef 'comparevi-history/local-fast-loop' `
  -HistorySummaryJson ([string]$runValues['history-summary-json']) `
  -ManifestPath ([string]$runValues['manifest-path']) `
  -ResultsDir ([string]$runValues['results-dir']) `
  -HistoryReportMd ([string]$runValues['history-report-md']) `
  -HistoryReportHtml ([string]$runValues['history-report-html']) `
  -ModeSummaryJsonPath $modeSummaryJsonPath `
  -ModeSummaryPath $modeSummaryPath `
  -RequestedModeList ([string]$runValues['requested-mode-list']) `
  -ExecutedModeList ([string]$runValues['executed-mode-list']) `
  -ModeSummaryMarkdown $modeSummaryMarkdown `
  -ModeCount ([string]$runValues['mode-count']) `
  -TotalProcessed ([string]$runValues['total-processed']) `
  -TotalDiffs ([string]$runValues['total-diffs']) `
  -StopReason ([string]$runValues['stop-reason']) `
  -RunOutcome $runOutcome `
  -RunConclusion $runConclusion `
  -GitHubOutputPath $publicRunOutputPath | Out-Null
$publicRunValues = Read-KeyValueFile -Path $publicRunOutputPath

$localReceipt = [ordered]@{
  schema = 'comparevi-history/local-fast-loop@v1'
  generatedAtUtc = [DateTime]::UtcNow.ToString('o')
  consumer = [ordered]@{
    repositoryRoot = $consumerRootResolved
    repository = $consumerRepositorySlug
    requestedRef = $ConsumerRef
    selectedSha = $selectedConsumerSha
  }
  target = [ordered]@{
    path = $ViPath
    normalizedPath = [string]$catalogValues['normalized-target-path']
    includeMergeParents = [bool]$IncludeMergeParents.IsPresent
  }
  tooling = [ordered]@{
    source = $toolingSource
    repository = $CompareviRepository
    ref = $effectiveCompareviRef
    root = $toolingRootResolved
    hostedImage = $hostedRunnerDefaultImage
    imagePulled = -not $SkipImagePull.IsPresent
    invokeScriptPath = $effectiveInvokeScriptPath
  }
  outputs = [ordered]@{
    resultsRoot = $resultsDirResolved
    revisionCatalogPath = [string]$catalogValues['revision-catalog-path']
    requestPath = [string]$requestValues['request-path']
    publicRunPath = [string]$publicRunValues['public-run-path']
    sharedEvidencePath = [string]$publicRunValues['shared-evidence-path']
    publicStepSummaryPath = [string]$publicRunValues['public-step-summary-path']
    historySummaryJson = [string]$publicRunValues['history-summary-json']
    historyReportMd = [string]$runValues['history-report-md']
    historyReportHtml = [string]$runValues['history-report-html']
    modeSummaryPath = $modeSummaryPath
    modeSummaryJsonPath = $modeSummaryJsonPath
    localSummaryPath = $localSummaryPath
  }
  summary = [ordered]@{
    revisionCount = if ([string]::IsNullOrWhiteSpace([string]$catalogValues['revision-count'])) { $null } else { [int][string]$catalogValues['revision-count'] }
    catalogComplete = [string]$catalogValues['catalog-complete']
    finalStatus = [string]$publicRunValues['final-status']
    finalReason = [string]$publicRunValues['final-reason']
  }
}
$localReceipt | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $localReceiptPath -Encoding utf8

@(
  '## comparevi-history local manual exploration fast loop'
  ''
  ('- Consumer repository: `{0}`' -f $consumerRepositorySlug)
  ('- Consumer ref: `{0}`' -f $ConsumerRef)
  ('- Selected SHA: `{0}`' -f $selectedConsumerSha)
  ('- Target path: `{0}`' -f $ViPath)
  ('- Requested modes: `{0}`' -f $Mode)
  ('- Noise policy: `{0}`' -f $NoisePolicy)
  ('- Tooling source: `{0}`' -f $toolingSource)
  ('- Tooling ref: `{0}`' -f $effectiveCompareviRef)
  ('- Tooling root: `{0}`' -f $toolingRootResolved)
  ('- Invoke script: `{0}`' -f $effectiveInvokeScriptPath)
  ('- Hosted image: `{0}`' -f $hostedRunnerDefaultImage)
  ('- Revision catalog: `{0}`' -f [string]$catalogValues['revision-catalog-path'])
  ('- Public run receipt: `{0}`' -f [string]$publicRunValues['public-run-path'])
  ('- History summary: `{0}`' -f [string]$publicRunValues['history-summary-json'])
  ('- History report (md): `{0}`' -f [string]$runValues['history-report-md'])
  ('- History report (html): `{0}`' -f [string]$runValues['history-report-html'])
  ('- Local receipt: `{0}`' -f $localReceiptPath)
) | Set-Content -LiteralPath $localSummaryPath -Encoding utf8

$localReceipt | ConvertTo-Json -Depth 20

if ($null -ne $runException) {
  throw $runException
}
