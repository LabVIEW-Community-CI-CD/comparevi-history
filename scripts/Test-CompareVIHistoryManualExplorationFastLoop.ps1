Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'Invoke-CompareVIHistoryManualExplorationFastLoop.ps1'
$stubWriterPath = Join-Path $PSScriptRoot 'Write-CompareVIHistorySmokeStub.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("comparevi-history-fast-loop-" + [guid]::NewGuid().ToString('N'))
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

try {
  $consumerRoot = Join-Path $tempRoot 'consumer'
  New-Item -ItemType Directory -Path $consumerRoot -Force | Out-Null
  Invoke-Git -RepositoryRoot $consumerRoot -Arguments @('init', '--initial-branch=main') | Out-Null
  Invoke-Git -RepositoryRoot $consumerRoot -Arguments @('config', 'user.name', 'comparevi-history-test') | Out-Null
  Invoke-Git -RepositoryRoot $consumerRoot -Arguments @('config', 'user.email', 'comparevi-history-test@example.com') | Out-Null
  Invoke-Git -RepositoryRoot $consumerRoot -Arguments @('remote', 'add', 'origin', 'https://github.com/LabVIEW-Community-CI-CD/labview-icon-editor-demo.git') | Out-Null

  $deploymentDir = Join-Path $consumerRoot 'Tooling' 'deployment'
  $toolingDir = Join-Path $consumerRoot 'Tooling'
  New-Item -ItemType Directory -Path $deploymentDir -Force | Out-Null

  'v1' | Set-Content -LiteralPath (Join-Path $deploymentDir 'VIP_Pre-Install Custom Action.vi') -Encoding utf8
  Invoke-Git -RepositoryRoot $consumerRoot -Arguments @('add', '.') | Out-Null
  Invoke-Git -RepositoryRoot $consumerRoot -Arguments @('commit', '-m', 'Add pre-install VI') | Out-Null

  'v2' | Set-Content -LiteralPath (Join-Path $deploymentDir 'VIP_Pre-Install Custom Action.vi') -Encoding utf8
  Invoke-Git -RepositoryRoot $consumerRoot -Arguments @('add', '.') | Out-Null
  Invoke-Git -RepositoryRoot $consumerRoot -Arguments @('commit', '-m', 'Update pre-install VI') | Out-Null

  $consumerAdapterPath = Join-Path $toolingDir 'Invoke-CompareVIHistoryHostedNILinux.ps1'
  & $stubWriterPath -DestinationPath $consumerAdapterPath

  $toolingRoot = Join-Path $tempRoot 'tooling'
  $toolingToolsDir = Join-Path $toolingRoot 'tools'
  New-Item -ItemType Directory -Path $toolingToolsDir -Force | Out-Null
  @'
param(
  [string]$TargetPath,
  [string]$StartRef,
  [string]$ResultsDir,
  [string]$Mode,
  [string]$InvokeScriptPath,
  [string]$GitHubOutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($InvokeScriptPath) -or -not (Test-Path -LiteralPath $InvokeScriptPath -PathType Leaf)) {
  throw 'InvokeScriptPath must point to an existing adapter script.'
}

New-Item -ItemType Directory -Path $ResultsDir -Force | Out-Null
$manifestPath = Join-Path $ResultsDir 'manifest.json'
$historySummaryPath = Join-Path $ResultsDir 'history-summary.json'
$historyReportMd = Join-Path $ResultsDir 'history-report.md'
$historyReportHtml = Join-Path $ResultsDir 'history-report.html'

$modeEntries = New-Object System.Collections.Generic.List[object]
$modes = @(
  $Mode -split '[,;]' |
    ForEach-Object { $_.Trim() } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)
foreach ($entry in $modes) {
  $slug = $entry.ToLowerInvariant()
  $modeDir = Join-Path $ResultsDir $slug
  New-Item -ItemType Directory -Path $modeDir -Force | Out-Null
  $modeManifestPath = Join-Path $modeDir 'manifest.json'
  $artifactDir = Join-Path $modeDir 'pair-001-artifacts'
  $imagesDir = Join-Path $artifactDir 'cli-images'
  New-Item -ItemType Directory -Path $imagesDir -Force | Out-Null
  [System.IO.File]::WriteAllBytes((Join-Path $imagesDir 'cli-image-00.png'), @(0xCA,0xFE,0xBA,0xBE))
  @(
    '{'
    '  "schema": "lvcompare-capture-v1",'
    '  "environment": {'
    '    "cli": {'
    '      "artifacts": {'
    '        "images": ['
    '          {'
    '            "index": 0,'
    '            "mimeType": "image/png",'
    '            "byteLength": 4,'
    ('            "savedPath": "{0}"' -f ((Join-Path $imagesDir 'cli-image-00.png') -replace '\\','\\\\'))
    '          }'
    '        ]'
    '      }'
    '    }'
    '  }'
    '}'
  ) | Set-Content -LiteralPath (Join-Path $artifactDir 'lvcompare-capture.json') -Encoding utf8
  @(
    '{'
    '  "schema": "vi-compare/history@v1",'
    '  "comparisons": ['
    '    {'
    '      "result": {'
    ('        "artifactDir": "{0}"' -f ($artifactDir -replace '\\','\\\\'))
    '      }'
    '    }'
    '  ],'
    '  "stats": {'
    '    "categoryCounts": { "attributes": 1 },'
    '    "bucketCounts": { "metadata-rich": 1 }'
    '  }'
    '}'
  ) | Set-Content -LiteralPath $modeManifestPath -Encoding utf8
  [void]$modeEntries.Add([ordered]@{
      mode = $entry
      slug = $slug
      manifest = $modeManifestPath
      resultsDir = $modeDir
      processed = 1
      diffs = 1
      signalDiffs = 1
      noiseCollapsed = 0
      errors = 0
      status = 'ok'
      stopReason = 'completed'
      flags = @()
      categoryCounts = [ordered]@{ attributes = 1 }
      bucketCounts = [ordered]@{ 'metadata-rich' = 1 }
    })
}

'{}' | Set-Content -LiteralPath $manifestPath -Encoding utf8
@{
  schema = 'comparevi-tools/history-facade@v1'
  targetPath = $TargetPath
  startRef = $StartRef
  invokeScriptPath = $InvokeScriptPath
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $historySummaryPath -Encoding utf8
'# history report' | Set-Content -LiteralPath $historyReportMd -Encoding utf8
'<html><body>history report</body></html>' | Set-Content -LiteralPath $historyReportHtml -Encoding utf8

$outputs = @(
  "target-path=$TargetPath"
  "manifest-path=$manifestPath"
  "results-dir=$ResultsDir"
  "history-summary-json=$historySummaryPath"
  "history-report-md=$historyReportMd"
  "history-report-html=$historyReportHtml"
  "mode-count=$($modes.Count)"
  "total-processed=1"
  "total-diffs=1"
  "stop-reason=completed"
  'category-counts-json={}'
  'bucket-counts-json={}'
  ("mode-manifests-json={0}" -f (($modeEntries.ToArray() | ConvertTo-Json -Depth 8 -Compress)))
  ("requested-mode-list={0}" -f ($modes -join ','))
  ("executed-mode-list={0}" -f ($modes -join ','))
  ("mode-list={0}" -f ($modes -join ','))
  'flag-list='
)
$outputs | Set-Content -LiteralPath $GitHubOutputPath -Encoding utf8
'@ | Set-Content -LiteralPath (Join-Path $toolingToolsDir 'Compare-VIHistory.ps1') -Encoding utf8

  @'
param([string]$Tag = 'comparevi-vi-history-dev:local')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
@{
  tag = $Tag
  status = 'built'
} | ConvertTo-Json -Depth 8
'@ | Set-Content -LiteralPath (Join-Path $toolingToolsDir 'Build-VIHistoryDevImage.ps1') -Encoding utf8

  @'
param(
  [string]$Action = 'status',
  [string]$RepoRoot,
  [string]$ResultsRoot,
  [string]$RuntimeDir,
  [string]$Image = 'comparevi-vi-history-dev:local'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
@{
  schema = 'comparevi/local-runtime-state@v1'
  action = $Action
  outcome = 'reused'
  image = $Image
  container = @{
    name = 'comparevi-history-runtime'
  }
  mounts = @{
    repoHostPath = $RepoRoot
    repoContainerPath = '/opt/comparevi/source'
    resultsHostPath = $ResultsRoot
    resultsContainerPath = '/opt/comparevi/vi-history/results'
  }
  runtimeDir = $RuntimeDir
} | ConvertTo-Json -Depth 8
'@ | Set-Content -LiteralPath (Join-Path $toolingToolsDir 'Manage-VIHistoryRuntimeInDocker.ps1') -Encoding utf8

  $resultsDir = Join-Path $tempRoot 'results'
  $receiptJson = & $scriptPath `
    -ConsumerRepositoryRoot $consumerRoot `
    -ViPath 'Tooling/deployment/VIP_Pre-Install Custom Action.vi' `
    -ConsumerRef 'HEAD' `
    -ResultsDir $resultsDir `
    -ToolingRoot $toolingRoot `
    -SkipImagePull

  $receipt = $receiptJson | ConvertFrom-Json -Depth 20
  if ($receipt.schema -ne 'comparevi-history/local-fast-loop@v1') {
    throw 'Local fast-loop receipt schema mismatch.'
  }
  if ($receipt.consumer.repository -ne 'LabVIEW-Community-CI-CD/labview-icon-editor-demo') {
    throw 'Consumer repository slug mismatch.'
  }
  if ($receipt.target.normalizedPath -ne 'Tooling/deployment/VIP_Pre-Install Custom Action.vi') {
    throw 'Normalized path mismatch.'
  }
  if ($receipt.summary.revisionCount -ne 2) {
    throw 'Revision count mismatch.'
  }
  if ($receipt.summary.finalStatus -ne 'succeeded') {
    throw 'Final status mismatch.'
  }
  if (-not (Test-Path -LiteralPath $receipt.outputs.revisionCatalogPath -PathType Leaf)) {
    throw 'Revision catalog was not written.'
  }
  if (-not (Test-Path -LiteralPath $receipt.outputs.publicRunPath -PathType Leaf)) {
    throw 'Public run receipt was not written.'
  }
  if (-not (Test-Path -LiteralPath $receipt.outputs.sharedEvidencePath -PathType Leaf)) {
    throw 'Shared evidence receipt was not written.'
  }
  if (-not (Test-Path -LiteralPath $receipt.outputs.historySummaryJson -PathType Leaf)) {
    throw 'History summary JSON was not written.'
  }
  if (-not (Test-Path -LiteralPath $receipt.outputs.historyReportMd -PathType Leaf)) {
    throw 'History report markdown was not written.'
  }
  if (-not (Test-Path -LiteralPath $receipt.outputs.historyReportHtml -PathType Leaf)) {
    throw 'History report HTML was not written.'
  }
  if (-not (Test-Path -LiteralPath $receipt.outputs.localSummaryPath -PathType Leaf)) {
    throw 'Local summary markdown was not written.'
  }
  if (-not (Test-Path -LiteralPath $receipt.outputs.modeSummaryJsonPath -PathType Leaf)) {
    throw 'Mode summary JSON was not written.'
  }

  $historySummary = Get-Content -LiteralPath $receipt.outputs.historySummaryJson -Raw | ConvertFrom-Json -Depth 8
  $normalizedInvokeScriptPath = ([string]$historySummary.invokeScriptPath) -replace '\\', '/'
  if (-not $normalizedInvokeScriptPath.EndsWith('Tooling/Invoke-CompareVIHistoryHostedNILinux.ps1')) {
    throw 'Default consumer adapter path was not forwarded to the backend.'
  }

  $request = Get-Content -LiteralPath $receipt.outputs.requestPath -Raw | ConvertFrom-Json -Depth 20
  if (($request.target.requestedModes -join ',') -ne 'full') {
    throw 'Local fast loop must default to the unsuppressed full mode.'
  }
  if ($request.history.noisePolicy -ne 'include') {
    throw 'Local fast loop must default to in-band noise handling.'
  }

  $modeSummary = Get-Content -LiteralPath $receipt.outputs.modeSummaryJsonPath -Raw | ConvertFrom-Json -Depth 64
  if ($modeSummary.metadata.captureCount -ne 1 -or $modeSummary.metadata.imageArtifactCount -ne 1) {
    throw 'Local fast loop must surface capture/image metadata.'
  }

  $devFastResultsDir = Join-Path $tempRoot 'results-dev-fast'
  $devFastReceiptJson = & $scriptPath `
    -ConsumerRepositoryRoot $consumerRoot `
    -ViPath 'Tooling/deployment/VIP_Pre-Install Custom Action.vi' `
    -ConsumerRef 'HEAD' `
    -ResultsDir $devFastResultsDir `
    -ToolingRoot $toolingRoot `
    -RuntimeProfile 'dev-fast' `
    -ContainerImage 'comparevi-vi-history-dev:local' `
    -SkipImagePull

  $devFastReceipt = $devFastReceiptJson | ConvertFrom-Json -Depth 20
  if ($devFastReceipt.runtime.profile -ne 'dev-fast') {
    throw 'Dev-fast local fast loop profile mismatch.'
  }
  if ($devFastReceipt.runtime.image -ne 'comparevi-vi-history-dev:local') {
    throw 'Dev-fast local fast loop image mismatch.'
  }
  if (@('built-local-image', 'existing-local-image') -notcontains [string]$devFastReceipt.runtime.cacheReuseState) {
    throw 'Dev-fast local fast loop must surface image-build or local-image reuse state.'
  }
  if (@('cold', 'warm') -notcontains [string]$devFastReceipt.runtime.coldWarmClass) {
    throw 'Dev-fast local fast loop must classify the runtime temperature.'
  }

  $warmRuntimeDir = Join-Path $tempRoot 'runtime'
  $warmDevResultsDir = Join-Path $tempRoot 'results-warm-dev'
  $warmDevReceiptJson = & $scriptPath `
    -ConsumerRepositoryRoot $consumerRoot `
    -ViPath 'Tooling/deployment/VIP_Pre-Install Custom Action.vi' `
    -ConsumerRef 'HEAD' `
    -ResultsDir $warmDevResultsDir `
    -ToolingRoot $toolingRoot `
    -RuntimeProfile 'warm-dev' `
    -ContainerImage 'comparevi-vi-history-dev:local' `
    -WarmRuntimeDir $warmRuntimeDir `
    -SkipImagePull

  $warmDevReceipt = $warmDevReceiptJson | ConvertFrom-Json -Depth 20
  if ($warmDevReceipt.runtime.profile -ne 'warm-dev') {
    throw 'Warm-dev local fast loop profile mismatch.'
  }
  if ($warmDevReceipt.runtime.image -ne 'comparevi-vi-history-dev:local') {
    throw 'Warm-dev local fast loop image mismatch.'
  }
  if ([string]$warmDevReceipt.runtime.cacheReuseState -ne 'warm-runtime-reused') {
    throw 'Warm-dev local fast loop must surface warm-runtime reuse.'
  }
  if ([string]$warmDevReceipt.runtime.coldWarmClass -ne 'warm') {
    throw 'Warm-dev local fast loop must classify the runtime as warm.'
  }
  if ([string]$warmDevReceipt.runtime.warmRuntimeDir -ne $warmRuntimeDir) {
    throw 'Warm-dev local fast loop warm-runtime directory mismatch.'
  }
  if ([string]$warmDevReceipt.runtime.warmRuntime.container.name -ne 'comparevi-history-runtime') {
    throw 'Warm-dev local fast loop runtime receipt must preserve the reused container name.'
  }

  $failedMissingAdapter = $false
  try {
    Remove-Item -LiteralPath $consumerAdapterPath -Force
    & $scriptPath `
      -ConsumerRepositoryRoot $consumerRoot `
      -ViPath 'Tooling/deployment/VIP_Pre-Install Custom Action.vi' `
      -ConsumerRef 'HEAD' `
      -ResultsDir (Join-Path $tempRoot 'results-no-adapter') `
      -ToolingRoot $toolingRoot `
      -SkipImagePull | Out-Null
  } catch {
    $failedMissingAdapter = $_.Exception.Message -match 'requires invoke_script_path or a consumer-local'
  }
  if (-not $failedMissingAdapter) {
    throw 'Expected missing adapter validation failure.'
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
