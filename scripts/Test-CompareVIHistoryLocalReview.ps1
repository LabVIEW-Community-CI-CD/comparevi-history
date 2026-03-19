$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptPath = Join-Path $PSScriptRoot 'Invoke-CompareVIHistoryLocalReview.ps1'
$compilerArtifactScriptPath = Join-Path $PSScriptRoot 'Publish-CompareVIHistoryReviewCompilerArtifact.ps1'
$stubWriterPath = Join-Path $PSScriptRoot 'Write-CompareVIHistorySmokeStub.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('comparevi-history-local-review-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

function Invoke-Git {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryRoot,
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  $output = & git -C $RepositoryRoot @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw ([string]::Join([Environment]::NewLine, @($output)))
  }

  return [string]::Join([Environment]::NewLine, @($output))
}

function Write-FakeCompareHistoryTooling {
  param([Parameter(Mandatory = $true)][string]$DestinationRoot)

  $toolsDir = Join-Path $DestinationRoot 'tools'
  $moduleDir = Join-Path $toolsDir 'CompareVI.Tools'
  New-Item -ItemType Directory -Path $moduleDir -Force | Out-Null

  @'
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

function New-ReportFixture {
  param(
    [string]$ModeRoot,
    [string]$ModeName,
    [int]$ComparisonIndex
  )

  $artifactDir = Join-Path $ModeRoot ('Demo.vi-{0:D3}-artifacts' -f $ComparisonIndex)
  $reportFilesDir = Join-Path $artifactDir 'compare-report_files'
  New-Item -ItemType Directory -Path $reportFilesDir -Force | Out-Null
  [System.IO.File]::WriteAllBytes((Join-Path $reportFilesDir 'fp_1.png'), @(0xCA,0xFE,0xBA,0xBE))
  [System.IO.File]::WriteAllBytes((Join-Path $reportFilesDir 'fp_2.png'), @(0xBE,0xBA,0xFE,0xCA))
  [System.IO.File]::WriteAllBytes((Join-Path $reportFilesDir 'bd_1.png'), @(0x0B,0xD1,0xA6,0x01))
  [System.IO.File]::WriteAllBytes((Join-Path $reportFilesDir 'bd_2.png'), @(0x10,0x0C,0xD1,0xA6))

  $reportHtmlPath = Join-Path $artifactDir 'compare-report.html'
  $attributeDetails = if ($ComparisonIndex -eq 1) {
@"
<details open>
<summary class="difference-heading">1. Block Diagram objects</summary>
<ol class="detailed-description-list" type="A">
<li class="diff-detail">Property Node - moved : changed from "(-35,102)" to "(-55,77)"</li>
<li class="diff-detail">Case Structure - resized : changed from "702*298" to "702*370"</li>
</ol>
</details>
"@
  } else {
@"
<details open>
<summary class="difference-heading">1. VI Attribute - Miscellaneous</summary>
<ol class="detailed-description-list" type="A">
<li class="diff-detail">VI Version : changed from "21.0" to "20.0"</li>
</ol>
</details>
"@
  }

  $reportHtml = if ($ModeName -eq 'attributes') {
@"
<!DOCTYPE html>
<html><body>
<div class="compared-VIs">
<details><summary class="difference-heading"><div class="dropdown-left">First VI: /compare/base/Base.vi</div><div class="dropdown-right">Second VI: /compare/head/Head.vi</div></summary>
<table class="difference">
<tr class="compared-vi-image-captions"><td class="compared-vi-image-caption">Front Panel Overview</td></tr>
<tr class="compared-images"><td class="diff-image"><img class="difference-image" src="compare-report_files/fp_1.png"/></td><td class="difference-divider"></td><td class="diff-image"><img class="difference-image" src="compare-report_files/fp_2.png"/></td></tr>
<tr class="compared-vi-image-captions"><td class="compared-vi-image-caption">Block Diagram Overview</td></tr>
<tr class="compared-images"><td class="diff-image"><img class="difference-image" src="compare-report_files/bd_1.png"/></td><td class="difference-divider"></td><td class="diff-image"><img class="difference-image" src="compare-report_files/bd_2.png"/></td></tr>
</table></details>
</div>
<div class="included-attributes"><ul class="inclusion-list"><li class="checked">Block Diagram Functional</li><li class="checked">VI Attribute</li></ul></div>
<h2 class="section-header">Detailed Information</h2>
$attributeDetails
</body></html>
"@
  } else {
@"
<!DOCTYPE html>
<html><body>
<div class="compared-VIs">
<details><summary class="difference-heading"><div class="dropdown-left">First VI: /compare/base/Base.vi</div><div class="dropdown-right">Second VI: /compare/head/Head.vi</div></summary>
<table class="difference">
<tr class="compared-vi-image-captions"><td class="compared-vi-image-caption">Front Panel Overview</td></tr>
<tr class="compared-images"><td class="diff-image"><img class="difference-image" src="compare-report_files/fp_1.png"/></td><td class="difference-divider"></td><td class="diff-image"><img class="difference-image" src="compare-report_files/fp_2.png"/></td></tr>
<tr class="compared-vi-image-captions"><td class="compared-vi-image-caption">Block Diagram Overview</td></tr>
<tr class="compared-images"><td class="diff-image"><img class="difference-image" src="compare-report_files/bd_1.png"/></td><td class="difference-divider"></td><td class="diff-image"><img class="difference-image" src="compare-report_files/bd_2.png"/></td></tr>
</table></details>
</div>
</body></html>
"@
  }
  $reportHtml | Set-Content -LiteralPath $reportHtmlPath -Encoding utf8

  return [ordered]@{
    index = $ComparisonIndex
    base = [ordered]@{
      ref = ('local-base-{0}' -f $ComparisonIndex)
      short = ('local-base-{0:D2}' -f $ComparisonIndex)
    }
    head = [ordered]@{
      ref = ('local-head-{0}' -f $ComparisonIndex)
      short = ('local-head-{0:D2}' -f $ComparisonIndex)
    }
    result = [ordered]@{
      reportHtml = $reportHtmlPath
    }
  }
}

function Write-HistoryFixture {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ResultsRoot,
    [Parameter(Mandatory = $true)]
    [string[]]$RequestedModes,
    [Parameter(Mandatory = $true)]
    [string]$TargetPath,
    [Parameter(Mandatory = $true)]
    [string]$StartRef
  )

  $historyResultsRoot = Join-Path $ResultsRoot 'vi-history-report' 'results'
  New-Item -ItemType Directory -Path $historyResultsRoot -Force | Out-Null
  $suiteManifestPath = Join-Path $historyResultsRoot 'suite-manifest.json'
  $historySummaryPath = Join-Path $historyResultsRoot 'history-summary.json'
  $historyReportMd = Join-Path $historyResultsRoot 'history-report.md'
  $historyReportHtml = Join-Path $historyResultsRoot 'history-report.html'

  $modeEntries = New-Object System.Collections.Generic.List[object]
  foreach ($modeName in $RequestedModes) {
    $modeRoot = Join-Path $historyResultsRoot $modeName
    New-Item -ItemType Directory -Path $modeRoot -Force | Out-Null
    $modeManifestPath = Join-Path $modeRoot 'manifest.json'
    $comparisons = @(
      (New-ReportFixture -ModeRoot $modeRoot -ModeName $modeName -ComparisonIndex 1),
      (New-ReportFixture -ModeRoot $modeRoot -ModeName $modeName -ComparisonIndex 2)
    )

    ([ordered]@{
        schema = 'vi-compare/history@v1'
        generatedAt = '2026-03-18T00:00:00Z'
        mode = $modeName
        comparisons = $comparisons
        stats = [ordered]@{
          categoryCounts = [ordered]@{ attributes = 2 }
          bucketCounts = [ordered]@{ 'metadata-rich' = 1; 'logic-motion' = 1 }
        }
      } | ConvertTo-Json -Depth 64) | Set-Content -LiteralPath $modeManifestPath -Encoding utf8

    $modeEntries.Add([ordered]@{
        name = $modeName
        manifestPath = $modeManifestPath
      }) | Out-Null
  }

  ([ordered]@{
      schema = 'vi-compare/history-suite@v1'
      generatedAt = '2026-03-18T00:00:00Z'
      modes = @($modeEntries | ForEach-Object {
          [ordered]@{
            name = $_.name
            manifestPath = $_.manifestPath
          }
        })
    } | ConvertTo-Json -Depth 64) | Set-Content -LiteralPath $suiteManifestPath -Encoding utf8

  ([ordered]@{
      schema = 'comparevi-tools/history-facade@v1'
      targetPath = $TargetPath
      startRef = $StartRef
      summary = [ordered]@{
        totalProcessed = 2
        totalDiffs = 2
      }
    } | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $historySummaryPath -Encoding utf8
  '# local history report' | Set-Content -LiteralPath $historyReportMd -Encoding utf8
  '<html><body>local history report</body></html>' | Set-Content -LiteralPath $historyReportHtml -Encoding utf8

  return [ordered]@{
    resultsRoot = $historyResultsRoot
    manifestPath = $suiteManifestPath
    historySummaryJsonPath = $historySummaryPath
    historyReportMdPath = $historyReportMd
    historyReportHtmlPath = $historyReportHtml
  }
}

function Invoke-CompareVIHistoryLocalOperatorSessionFacade {
  [CmdletBinding()]
  param(
    [ValidateSet('proof', 'dev-fast', 'warm-dev')]
    [string]$Profile = 'dev-fast',
    [string]$RepoRoot = '',
    [string]$HistoryTargetPath = 'fixtures/vi-attr/Head.vi',
    [string]$HistoryBranchRef = 'HEAD',
    [string]$HistoryBaselineRef = '',
    [string]$ResultsRoot = '',
    [string]$WarmRuntimeDir = '',
    [string]$ProofImage = 'nationalinstruments/labview:2026q1-linux',
    [string]$DevImage = 'comparevi-vi-history-dev:local',
    [string]$ReviewCommandPath = '',
    [string[]]$ReviewCommandArguments = @(),
    [string]$ReviewWorkingDirectory = '',
    [string]$ReviewReceiptPath = '',
    [string]$SessionManifestPath = '',
    [switch]$SkipDevImageBuild
  )

  $resolvedRepoRoot = if ([string]::IsNullOrWhiteSpace($RepoRoot)) { (Get-Location).Path } else { $RepoRoot }
  $resolvedResultsRoot = if ([string]::IsNullOrWhiteSpace($ResultsRoot)) {
    Join-Path $resolvedRepoRoot ('tests/results/local-vi-history/{0}' -f $Profile)
  } else {
    $ResultsRoot
  }
  New-Item -ItemType Directory -Path $resolvedResultsRoot -Force | Out-Null

  $requestedModeLine = $ReviewCommandArguments | Where-Object { $_ -like 'attributes*' -or $_ -like 'front-panel*' -or $_ -like 'block-diagram*' } | Select-Object -First 1
  $requestedModes = if ([string]::IsNullOrWhiteSpace($requestedModeLine)) {
    @('attributes', 'front-panel', 'block-diagram')
  } else {
    @($requestedModeLine -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  }

  $historyFixture = Write-HistoryFixture -ResultsRoot $resolvedResultsRoot -RequestedModes $requestedModes -TargetPath $HistoryTargetPath -StartRef $HistoryBranchRef
  [ordered]@{
    schema = 'comparevi-review-suite-summary@v1'
    generatedAt = '2026-03-19T00:00:00Z'
    image = $(if ($Profile -eq 'proof') { $ProofImage } else { $DevImage })
    scenarios = @(
      [ordered]@{
        name = 'vi-history-report'
        historySummaryPath = $historyFixture.historySummaryJsonPath
      }
    )
  } | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath (Join-Path $resolvedResultsRoot 'review-suite-summary.json') -Encoding utf8

  $cacheReuseState = switch ($Profile) {
    'proof' { 'canonical-proof-image' }
    'warm-dev' { 'warm-runtime-reused' }
    default { 'existing-local-image' }
  }
  $coldWarmClass = switch ($Profile) {
    'proof' { 'cold' }
    'warm-dev' { 'warm' }
    default { 'warm' }
  }
  $imageUsed = if ($Profile -eq 'proof') { $ProofImage } else { $DevImage }
  $toolSource = if ($Profile -eq 'proof') { 'canonical-proof-image' } else { 'local-dev-image' }
  $localRefinementReceiptPath = Join-Path $resolvedResultsRoot 'local-refinement.json'
  $benchmarkPath = Join-Path $resolvedResultsRoot 'local-refinement-benchmark.json'
  $sessionPath = if ([string]::IsNullOrWhiteSpace($SessionManifestPath)) {
    Join-Path $resolvedResultsRoot 'local-operator-session.json'
  } else {
    $SessionManifestPath
  }
  $reviewReceiptResolved = if ([string]::IsNullOrWhiteSpace($ReviewReceiptPath)) {
    Join-Path $resolvedResultsRoot 'local-target-review.json'
  } else {
    $ReviewReceiptPath
  }

  ([ordered]@{
      schema = 'comparevi/local-refinement@v1'
      generatedAt = '2026-03-19T00:00:00Z'
      runtimeProfile = $Profile
      image = $imageUsed
      toolSource = $toolSource
      cacheReuseState = $cacheReuseState
      coldWarmClass = $coldWarmClass
      benchmarkSampleKind = if ($Profile -eq 'warm-dev') { 'warm-dev-repeat' } elseif ($Profile -eq 'proof') { 'proof-cold' } else { 'dev-fast-repeat' }
      repoRoot = $resolvedRepoRoot
      resultsRoot = $resolvedResultsRoot
      timings = [ordered]@{
        elapsedMilliseconds = 1200
        elapsedSeconds = 1.2
      }
      finalStatus = 'succeeded'
    } | ConvertTo-Json -Depth 16) | Set-Content -LiteralPath $localRefinementReceiptPath -Encoding utf8

  ([ordered]@{
      schema = 'comparevi/local-refinement-benchmark@v1'
      generatedAt = '2026-03-19T00:00:01Z'
      latest = [ordered]@{}
      selectedSamples = [ordered]@{}
      comparisons = [ordered]@{}
    } | ConvertTo-Json -Depth 16) | Set-Content -LiteralPath $benchmarkPath -Encoding utf8

  $reviewStatus = 'not-requested'
  if (-not [string]::IsNullOrWhiteSpace($ReviewCommandPath)) {
    $reviewWorkingDirectoryResolved = if ([string]::IsNullOrWhiteSpace($ReviewWorkingDirectory)) { $resolvedRepoRoot } else { $ReviewWorkingDirectory }
    $envState = @{}
    foreach ($name in @(
        'COMPAREVI_RUNTIME_PROFILE',
        'COMPAREVI_LOCAL_REFINEMENT_RECEIPT_PATH',
        'COMPAREVI_LOCAL_REFINEMENT_BENCHMARK_PATH',
        'COMPAREVI_LOCAL_REFINEMENT_RESULTS_ROOT',
        'COMPAREVI_LOCAL_OPERATOR_SESSION_PATH',
        'COMPAREVI_LOCAL_REFINEMENT_IMAGE',
        'COMPAREVI_LOCAL_REFINEMENT_TOOL_SOURCE',
        'COMPAREVI_REVIEW_RECEIPT_PATH'
      )) {
      $existingItem = Get-Item ("Env:{0}" -f $name) -ErrorAction SilentlyContinue
      $envState[$name] = if ($null -eq $existingItem) { $null } else { $existingItem.Value }
    }

    try {
      $env:COMPAREVI_RUNTIME_PROFILE = $Profile
      $env:COMPAREVI_LOCAL_REFINEMENT_RECEIPT_PATH = $localRefinementReceiptPath
      $env:COMPAREVI_LOCAL_REFINEMENT_BENCHMARK_PATH = $benchmarkPath
      $env:COMPAREVI_LOCAL_REFINEMENT_RESULTS_ROOT = $resolvedResultsRoot
      $env:COMPAREVI_LOCAL_OPERATOR_SESSION_PATH = $sessionPath
      $env:COMPAREVI_LOCAL_REFINEMENT_IMAGE = $imageUsed
      $env:COMPAREVI_LOCAL_REFINEMENT_TOOL_SOURCE = $toolSource
      $env:COMPAREVI_REVIEW_RECEIPT_PATH = $reviewReceiptResolved
      Push-Location $reviewWorkingDirectoryResolved
      try {
        & $ReviewCommandPath @ReviewCommandArguments
        if ($LASTEXITCODE -ne 0) {
          throw ("Review hook failed with exit code {0}." -f $LASTEXITCODE)
        }
      } finally {
        Pop-Location | Out-Null
      }
      $reviewStatus = 'succeeded'
    } finally {
      foreach ($entry in $envState.GetEnumerator()) {
        if ($null -eq $entry.Value) {
          Remove-Item ("Env:{0}" -f $entry.Key) -ErrorAction SilentlyContinue
        } else {
          Set-Item ("Env:{0}" -f $entry.Key) -Value $entry.Value
        }
      }
    }
  }

  $receipt = [ordered]@{
    schema = 'comparevi-tools/local-operator-session-facade@v1'
    generatedAtUtc = '2026-03-19T00:00:02Z'
    backendReceiptSchema = 'comparevi/local-operator-session@v1'
    runtimeProfile = $Profile
    repoRoot = $resolvedRepoRoot
    resultsRoot = $resolvedResultsRoot
    localRefinement = [ordered]@{
      schema = 'comparevi/local-refinement@v1'
      receiptPath = $localRefinementReceiptPath
      benchmarkPath = $benchmarkPath
      image = $imageUsed
      toolSource = $toolSource
      cacheReuseState = $cacheReuseState
      coldWarmClass = $coldWarmClass
      finalStatus = 'succeeded'
    }
    review = [ordered]@{
      status = $reviewStatus
      commandPath = $ReviewCommandPath
      workingDirectory = if ([string]::IsNullOrWhiteSpace($ReviewWorkingDirectory)) { $resolvedRepoRoot } else { $ReviewWorkingDirectory }
      outputs = [ordered]@{
        receiptPath = $reviewReceiptResolved
        reviewBundlePath = $null
        workspaceHtmlPath = $null
        workspaceMarkdownPath = $null
        previewManifestPath = $null
        runPath = $null
      }
    }
    artifacts = [ordered]@{
      sessionPath = $sessionPath
      localRefinementPath = $localRefinementReceiptPath
      benchmarkPath = $benchmarkPath
      reviewReceiptPath = $reviewReceiptResolved
    }
    finalStatus = 'succeeded'
  }

  $receipt | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $sessionPath -Encoding utf8
  return [pscustomobject]$receipt
}

Export-ModuleMember -Function Invoke-CompareVIHistoryLocalOperatorSessionFacade
'@ | Set-Content -LiteralPath (Join-Path $moduleDir 'CompareVI.Tools.psm1') -Encoding utf8

  @'
@{
  RootModule = 'CompareVI.Tools.psm1'
  ModuleVersion = '9.9.9'
  GUID = '9e64db64-9484-4b9d-96df-3aa1b44d90d0'
  PowerShellVersion = '7.0'
  FunctionsToExport = @('Invoke-CompareVIHistoryLocalOperatorSessionFacade')
}
'@ | Set-Content -LiteralPath (Join-Path $moduleDir 'CompareVI.Tools.psd1') -Encoding utf8

  ([ordered]@{
      schema = 'comparevi-tools-release-manifest@v1'
      generatedAt = '2026-03-19T00:00:00Z'
      consumerContract = [ordered]@{
        hostedNiLinuxRunner = [ordered]@{
          defaultImage = 'nationalinstruments/labview:2026q1-linux'
        }
      }
    } | ConvertTo-Json -Depth 16) | Set-Content -LiteralPath (Join-Path $DestinationRoot 'comparevi-tools-release.json') -Encoding utf8
}

try {
  $consumerRoot = Join-Path $tempRoot 'consumer'
  New-Item -ItemType Directory -Path $consumerRoot -Force | Out-Null
  Invoke-Git -RepositoryRoot $consumerRoot -Arguments @('init', '--initial-branch=main') | Out-Null
  Invoke-Git -RepositoryRoot $consumerRoot -Arguments @('config', 'user.name', 'comparevi-history-test') | Out-Null
  Invoke-Git -RepositoryRoot $consumerRoot -Arguments @('config', 'user.email', 'comparevi-history-test@example.com') | Out-Null
  Invoke-Git -RepositoryRoot $consumerRoot -Arguments @('remote', 'add', 'origin', 'https://github.com/LabVIEW-Community-CI-CD/labview-icon-editor-demo.git') | Out-Null

  $deploymentDir = Join-Path $consumerRoot 'Tooling' 'deployment'
  New-Item -ItemType Directory -Path $deploymentDir -Force | Out-Null
  'v1' | Set-Content -LiteralPath (Join-Path $deploymentDir 'Demo.vi') -Encoding utf8
  Invoke-Git -RepositoryRoot $consumerRoot -Arguments @('add', '.') | Out-Null
  Invoke-Git -RepositoryRoot $consumerRoot -Arguments @('commit', '-m', 'Add demo VI') | Out-Null
  $baseCommit = (Invoke-Git -RepositoryRoot $consumerRoot -Arguments @('rev-parse', 'HEAD')).Trim()

  'v2' | Set-Content -LiteralPath (Join-Path $deploymentDir 'Demo.vi') -Encoding utf8
  Invoke-Git -RepositoryRoot $consumerRoot -Arguments @('add', '.') | Out-Null
  Invoke-Git -RepositoryRoot $consumerRoot -Arguments @('commit', '-m', 'Update demo VI') | Out-Null
  $headCommit = (Invoke-Git -RepositoryRoot $consumerRoot -Arguments @('rev-parse', 'HEAD')).Trim()

  & $stubWriterPath -DestinationPath (Join-Path $consumerRoot 'Tooling' 'Invoke-CompareVIHistoryHostedNILinux.ps1')

  $toolingRoot = Join-Path $tempRoot 'tooling'
  Write-FakeCompareHistoryTooling -DestinationRoot $toolingRoot

  $runtimeIdentifier = if ($IsWindows) { 'win-x64' } elseif ($IsLinux) { 'linux-x64' } else { throw 'Unsupported RID for local-review test.' }
  $releaseDir = Join-Path $tempRoot 'compiler-release'
  $null = & $compilerArtifactScriptPath -Version 'v9.9.9' -OutputDir $releaseDir -RuntimeIdentifiers @($runtimeIdentifier)
  $archivePath = Join-Path $releaseDir ('comparevi-history-review-compiler-v9.9.9-{0}.zip' -f $runtimeIdentifier)
  $extractRoot = Join-Path $tempRoot 'compiler-extracted'
  Expand-Archive -LiteralPath $archivePath -DestinationPath $extractRoot -Force
  $compilerPath = Join-Path $extractRoot ('comparevi-history-review-compiler-v9.9.9-{0}' -f $runtimeIdentifier)
  if (-not $IsWindows) {
    & chmod +x (Join-Path $compilerPath 'comparevi-history-review-compiler')
    if ($LASTEXITCODE -ne 0) {
      throw 'Failed to mark extracted compiler executable as runnable.'
    }
  }

  $explicitResults = Join-Path $tempRoot 'results-explicit'
  $explicitReceipt = (& $scriptPath `
      -ConsumerRepositoryRoot $consumerRoot `
      -ViPath 'Tooling/deployment/Demo.vi' `
      -ResultsDir $explicitResults `
      -ToolingRoot $toolingRoot `
      -CompilerPath $compilerPath `
      -ContainerImage 'comparevi-vi-history-dev:local' `
      -SkipImagePull) | ConvertFrom-Json -Depth 64

  if ([string]$explicitReceipt.schema -ne 'comparevi-history/local-review@v1') {
    throw 'Explicit local-review receipt schema mismatch.'
  }
  if ([string]$explicitReceipt.consumer.selectionMode -ne 'explicit-paths') {
    throw 'Explicit local-review selection mode mismatch.'
  }
  if ([string]$explicitReceipt.compiler.source -ne 'provided-path') {
    throw 'Explicit local-review should use the provided compiler path.'
  }
  if ([string]$explicitReceipt.invocation.runtimeProfile -ne 'dev-fast' -or
    [string]$explicitReceipt.runtime.profile -ne 'dev-fast') {
    throw 'Explicit local-review runtime profile mismatch.'
  }
  if ([string]$explicitReceipt.invocation.containerImage -ne 'comparevi-vi-history-dev:local') {
    throw 'Explicit local-review should preserve the selected accelerated container image.'
  }
  if ([string]$explicitReceipt.operatorSession.facadeSchema -ne 'comparevi-tools/local-operator-session-facade@v1') {
    throw 'Explicit local-review should record the operator-session facade schema.'
  }
  if ([string]$explicitReceipt.operatorSession.toolingSource -ne 'provided-tooling-root') {
    throw 'Explicit local-review should record the provided tooling root source.'
  }
  if ([string]$explicitReceipt.operatorSession.toolingRoot -ne $toolingRoot) {
    throw 'Explicit local-review should record the resolved tooling root.'
  }
  if (@($explicitReceipt.operatorSession.sessionPaths).Count -ne 1 -or @($explicitReceipt.operatorSession.reviewReceiptPaths).Count -ne 1) {
    throw 'Explicit local-review should record one operator-session receipt and one review-hook receipt.'
  }
  if ([string]$explicitReceipt.runtime.image -ne 'comparevi-vi-history-dev:local') {
    throw 'Explicit local-review should use the selected accelerated dev image.'
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$explicitReceipt.runtime.cacheReuseState) -and
    @('built-local-image', 'existing-local-image') -notcontains [string]$explicitReceipt.runtime.cacheReuseState) {
    throw 'Explicit local-review should only surface dev-fast cache states when they are projected.'
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$explicitReceipt.runtime.coldWarmClass) -and
    @('cold', 'warm') -notcontains [string]$explicitReceipt.runtime.coldWarmClass) {
    throw 'Explicit local-review should only surface cold/warm runtime classes when they are projected.'
  }
  if ([int]$explicitReceipt.timings.elapsedMilliseconds -lt 0 -or [double]$explicitReceipt.timings.elapsedSeconds -lt 0) {
    throw 'Explicit local-review timings should be recorded.'
  }
  foreach ($path in @(
      [string]$explicitReceipt.projections.changedViDiscoveryPath,
      [string]$explicitReceipt.projections.targetRunsManifestPath,
      [string]$explicitReceipt.projections.previewManifestPath,
      [string]$explicitReceipt.projections.prRunPath,
      [string]$explicitReceipt.outputs.reviewBundlePath,
      [string]$explicitReceipt.outputs.indexMarkdownPath,
      [string]$explicitReceipt.outputs.indexHtmlPath,
      [string]$explicitReceipt.outputs.localSummaryPath
    )) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "Expected explicit local-review output path: $path"
    }
  }

  $explicitReviewBundle = Get-Content -LiteralPath $explicitReceipt.outputs.reviewBundlePath -Raw | ConvertFrom-Json -Depth 64
  if ([string]$explicitReviewBundle.schema -ne 'comparevi-history/review-bundle@v1' -or
    [int]$explicitReviewBundle.summary.reviewPairCount -ne 2) {
    throw 'Explicit local-review review bundle mismatch.'
  }
  $explicitPreviewManifest = Get-Content -LiteralPath $explicitReceipt.projections.previewManifestPath -Raw | ConvertFrom-Json -Depth 64
  if ([int]$explicitPreviewManifest.summary.reviewerPreviewCardCount -ne 2) {
    throw 'Explicit local-review preview manifest mismatch.'
  }
  $explicitPrRun = Get-Content -LiteralPath $explicitReceipt.projections.prRunPath -Raw | ConvertFrom-Json -Depth 64
  if ([string]$explicitPrRun.summary.finalStatus -ne 'succeeded') {
    throw 'Explicit local-review aggregate run should succeed.'
  }
  if ((Get-ChildItem -LiteralPath (Join-Path $explicitResults 'history-pairs') -Directory).Count -ne 2) {
    throw 'Explicit local-review should emit two history-pair pages.'
  }

  $changedResults = Join-Path $tempRoot 'results-changed'
  $warmRuntimeDir = Join-Path $tempRoot 'warm-runtime'
  $changedReceipt = (& $scriptPath `
      -ConsumerRepositoryRoot $consumerRoot `
      -BaseRef $baseCommit `
      -HeadRef 'HEAD' `
      -Profile 'warm-dev' `
      -WarmRuntimeDir $warmRuntimeDir `
      -ResultsDir $changedResults `
      -ToolingRoot $toolingRoot `
      -CompilerPath $compilerPath) | ConvertFrom-Json -Depth 64

  if ([string]$changedReceipt.consumer.selectionMode -ne 'git-diff') {
    throw 'Changed local-review selection mode mismatch.'
  }
  if ([string]$changedReceipt.operatorSession.facadeSchema -ne 'comparevi-tools/local-operator-session-facade@v1') {
    throw 'Changed local-review should record the operator-session facade schema.'
  }
  if ([string]$changedReceipt.invocation.runtimeProfile -ne 'warm-dev' -or
    [string]$changedReceipt.runtime.profile -ne 'warm-dev') {
    throw 'Changed local-review runtime profile mismatch.'
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$changedReceipt.runtime.cacheReuseState) -and
    [string]$changedReceipt.runtime.cacheReuseState -ne 'warm-runtime-reused') {
    throw 'Changed local-review should only surface the warm-runtime reuse state when it is projected.'
  }
  if ([string]$changedReceipt.runtime.warmRuntimeDir -ne $warmRuntimeDir) {
    throw 'Changed local-review warm runtime directory mismatch.'
  }
  if ([int]$changedReceipt.timings.elapsedMilliseconds -lt 0 -or [double]$changedReceipt.timings.elapsedSeconds -lt 0) {
    throw 'Changed local-review timings should be recorded.'
  }
  if ([int]$changedReceipt.summary.changedViCount -ne 1 -or [int]$changedReceipt.summary.selectedTargetCount -ne 1) {
    throw 'Changed local-review change-count mismatch.'
  }

  $changedDiscovery = Get-Content -LiteralPath $changedReceipt.projections.changedViDiscoveryPath -Raw | ConvertFrom-Json -Depth 64
  if ([string]$changedDiscovery.summary.executionStatus -ne 'ready' -or
    [string]$changedDiscovery.pullRequest.baseSha -ne $baseCommit -or
    [string]$changedDiscovery.pullRequest.headSha -ne $headCommit) {
    throw 'Changed local-review discovery projection mismatch.'
  }

  $changedManifest = Get-Content -LiteralPath $changedReceipt.projections.targetRunsManifestPath -Raw | ConvertFrom-Json -Depth 64
  $requestPath = [string]$changedManifest.targets[0].requestPath
  $request = Get-Content -LiteralPath $requestPath -Raw | ConvertFrom-Json -Depth 64
  if ([string]$request.history.sourceBranchRef -ne $baseCommit) {
    throw 'Changed local-review must forward the base ref into request.history.sourceBranchRef.'
  }
}
finally {
  if ([string]::IsNullOrWhiteSpace($env:COMPAREVI_HISTORY_TEST_KEEP_TEMP) -and (Test-Path -LiteralPath $tempRoot)) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force
  }
}
