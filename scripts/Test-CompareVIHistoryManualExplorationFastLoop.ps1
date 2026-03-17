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
  '{}' | Set-Content -LiteralPath $modeManifestPath -Encoding utf8
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

  $historySummary = Get-Content -LiteralPath $receipt.outputs.historySummaryJson -Raw | ConvertFrom-Json -Depth 8
  $normalizedInvokeScriptPath = ([string]$historySummary.invokeScriptPath) -replace '\\', '/'
  if (-not $normalizedInvokeScriptPath.EndsWith('Tooling/Invoke-CompareVIHistoryHostedNILinux.ps1')) {
    throw 'Default consumer adapter path was not forwarded to the backend.'
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
