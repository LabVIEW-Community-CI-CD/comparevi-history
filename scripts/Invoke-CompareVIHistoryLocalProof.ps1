param(
  [string]$ResultsDir = 'tests/results/local-proof',
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

function Invoke-ProofGate {
  param(
    [Parameter(Mandatory = $true)]
    [hashtable]$GateDefinition,
    [Parameter(Mandatory = $true)]
    [string]$LogsDir,
    [Parameter(Mandatory = $true)]
    [string]$RepositoryRoot
  )

  $logPath = Join-Path $LogsDir ('{0}.log' -f [string]$GateDefinition.name)
  $startedAtUtc = [DateTime]::UtcNow
  $status = 'succeeded'
  $errorMessage = $null

  try {
    Push-Location $RepositoryRoot
    try {
      & ([string]$GateDefinition.scriptPath) *> $logPath
    } finally {
      Pop-Location
    }
  } catch {
    $status = 'failed'
    $errorMessage = $_.Exception.Message
    if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) {
      ($_ | Out-String) | Set-Content -LiteralPath $logPath -Encoding utf8
    }
  }

  $completedAtUtc = [DateTime]::UtcNow
  $durationSeconds = [math]::Round(($completedAtUtc - $startedAtUtc).TotalSeconds, 3)

  return [ordered]@{
    name = [string]$GateDefinition.name
    category = [string]$GateDefinition.category
    purpose = [string]$GateDefinition.purpose
    scriptPath = [string]$GateDefinition.scriptPath
    logPath = $logPath
    startedAtUtc = $startedAtUtc.ToString('o')
    completedAtUtc = $completedAtUtc.ToString('o')
    durationSeconds = $durationSeconds
    status = $status
    errorMessage = $errorMessage
  }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$resultsDirResolved = Resolve-AbsolutePath -Path $ResultsDir -BasePath $repoRoot
$gateLogsDir = Join-Path $resultsDirResolved 'gate-logs'
$summaryPath = Join-Path $resultsDirResolved 'local-proof-summary.md'
$receiptPath = Join-Path $resultsDirResolved 'local-proof.json'
New-Item -ItemType Directory -Path $gateLogsDir -Force | Out-Null

$gateDefinitions = @(
  @{
    name = 'local-review'
    category = 'local-review'
    purpose = 'Prove the local-review facade against the canonical synthetic fixture.'
    scriptPath = Join-Path $PSScriptRoot 'Test-CompareVIHistoryLocalReview.ps1'
  },
  @{
    name = 'review-bundle-golden'
    category = 'review-bundle-golden'
    purpose = 'Freeze the compiled review bundle against the canonical golden baseline.'
    scriptPath = Join-Path $PSScriptRoot 'Test-CompareVIHistoryReviewBundleGoldenContract.ps1'
  },
  @{
    name = 'reviewer-workspace-golden'
    category = 'reviewer-workspace-golden'
    purpose = 'Freeze reviewer workspace, preview selection, and pair-page rendering against the golden baseline.'
    scriptPath = Join-Path $PSScriptRoot 'Test-CompareVIHistoryAutomaticPullRequestRun.ps1'
  },
  @{
    name = 'corpus-pilot-golden'
    category = 'corpus-pilot-golden'
    purpose = 'Freeze the downstream corpus pilot contract against the canonical corpus fixture.'
    scriptPath = Join-Path $PSScriptRoot 'Test-CompareVIHistoryCorpusPilotGoldenContract.ps1'
  }
)

$gateReceipts = New-Object System.Collections.Generic.List[object]
foreach ($gateDefinition in $gateDefinitions) {
  $gateReceipts.Add((Invoke-ProofGate -GateDefinition $gateDefinition -LogsDir $gateLogsDir -RepositoryRoot $repoRoot)) | Out-Null
}

$gateArray = @($gateReceipts | ForEach-Object { $_ })
$failedGateCount = @($gateArray | Where-Object { [string]$_.status -ne 'succeeded' }).Count
$passedGateCount = $gateArray.Count - $failedGateCount
$finalStatus = if ($failedGateCount -gt 0) { 'failed' } else { 'succeeded' }
$finalReason = if ($failedGateCount -gt 0) { 'one-or-more-gates-failed' } else { 'all-gates-succeeded' }

$receipt = [ordered]@{
  schema = 'comparevi-history/local-proof@v1'
  generatedAtUtc = [DateTime]::UtcNow.ToString('o')
  repositoryRoot = $repoRoot
  resultsDir = $resultsDirResolved
  fixtures = [ordered]@{
    reviewBundleFixtureRoot = Join-Path $repoRoot 'tests' 'fixtures' 'review-bundle-v1'
    reviewerWorkspaceFixtureRoot = Join-Path $repoRoot 'tests' 'fixtures' 'reviewer-workspace-v1'
    corpusPilotFixtureRoot = Join-Path $repoRoot 'tests' 'fixtures' 'corpus-pilot-v1'
  }
  gates = $gateArray
  outputs = [ordered]@{
    receiptPath = $receiptPath
    summaryPath = $summaryPath
    gateLogsDir = $gateLogsDir
  }
  summary = [ordered]@{
    gateCount = $gateArray.Count
    passedGateCount = $passedGateCount
    failedGateCount = $failedGateCount
    finalStatus = $finalStatus
    finalReason = $finalReason
  }
}
($receipt | ConvertTo-Json -Depth 64) | Set-Content -LiteralPath $receiptPath -Encoding utf8

$summaryLines = New-Object System.Collections.Generic.List[string]
$summaryLines.Add('# comparevi-history local proof') | Out-Null
$summaryLines.Add('') | Out-Null
$summaryLines.Add('- This gate wraps the canonical local-review and golden/corpus regression seams into one local pre-PR proof surface.') | Out-Null
$summaryLines.Add(('- Results root: `{0}`' -f $resultsDirResolved)) | Out-Null
$summaryLines.Add(('- Local proof receipt: `{0}`' -f $receiptPath)) | Out-Null
$summaryLines.Add(('- Gate logs: `{0}`' -f $gateLogsDir)) | Out-Null
$summaryLines.Add(('- Final status: `{0}`' -f $finalStatus)) | Out-Null
$summaryLines.Add(('- Final reason: `{0}`' -f $finalReason)) | Out-Null
$summaryLines.Add('') | Out-Null
$summaryLines.Add('## Gates') | Out-Null
$summaryLines.Add('') | Out-Null

foreach ($gate in $gateArray) {
  $summaryLines.Add(('- `{0}`: `{1}`' -f [string]$gate.name, [string]$gate.status)) | Out-Null
  $summaryLines.Add(('  - Purpose: {0}' -f [string]$gate.purpose)) | Out-Null
  $summaryLines.Add(('  - Script: `{0}`' -f [string]$gate.scriptPath)) | Out-Null
  $summaryLines.Add(('  - Log: `{0}`' -f [string]$gate.logPath)) | Out-Null
  $summaryLines.Add(('  - Duration: `{0}` seconds' -f [string]$gate.durationSeconds)) | Out-Null
  if (-not [string]::IsNullOrWhiteSpace([string]$gate.errorMessage)) {
    $summaryLines.Add(('  - Error: `{0}`' -f [string]$gate.errorMessage)) | Out-Null
  }
}

$summaryLines | Set-Content -LiteralPath $summaryPath -Encoding utf8

Write-ActionOutput -Key 'local-proof-path' -Value $receiptPath
Write-ActionOutput -Key 'local-proof-summary-path' -Value $summaryPath
Write-ActionOutput -Key 'local-proof-logs-dir' -Value $gateLogsDir
Write-ActionOutput -Key 'final-status' -Value $finalStatus
Write-ActionOutput -Key 'final-reason' -Value $finalReason

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  @(
    '## comparevi-history local proof'
    ''
    ('- Results root: `{0}`' -f $resultsDirResolved)
    ('- Gate count: `{0}`' -f $gateArray.Count)
    ('- Passed gates: `{0}`' -f $passedGateCount)
    ('- Failed gates: `{0}`' -f $failedGateCount)
    ('- Final status: `{0}`' -f $finalStatus)
    ('- Final reason: `{0}`' -f $finalReason)
  ) | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
}

if ($failedGateCount -gt 0) {
  throw "comparevi-history local-proof failed. See '$receiptPath'."
}

$receipt | ConvertTo-Json -Depth 64
