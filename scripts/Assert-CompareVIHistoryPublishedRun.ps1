param(
  [Parameter(Mandatory = $true)]
  [string]$ActionRef,
  [Parameter(Mandatory = $true)]
  [string]$ConsumerRepository,
  [Parameter(Mandatory = $true)]
  [string]$ConsumerRef,
  [Parameter(Mandatory = $true)]
  [string]$TargetPath,
  [Parameter(Mandatory = $true)]
  [string]$ExpectedModeList,
  [Parameter(Mandatory = $true)]
  [string]$ManifestPath,
  [Parameter(Mandatory = $true)]
  [string]$ResultsDir,
  [Parameter(Mandatory = $true)]
  [string]$ModeCount,
  [Parameter(Mandatory = $true)]
  [string]$ModeList,
  [Parameter(Mandatory = $true)]
  [string]$ModeManifestsJson,
  [Parameter(Mandatory = $true)]
  [string]$HistoryReportMd,
  [Parameter(Mandatory = $true)]
  [string]$HistoryReportHtml,
  [Parameter(Mandatory = $true)]
  [string]$TotalProcessed,
  [string]$TotalDiffs,
  [string]$StopReason,
  [string]$RequestedModeList,
  [string]$ExecutedModeList,
  [string]$ArtifactName,
  [string]$EvidencePath,
  [string]$StepSummaryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-NormalizedModeList {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Value
  )

  return @(
    $Value -split '[,;]'
    | ForEach-Object { $_.Trim() }
    | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    | Sort-Object -Unique
  )
}

function Assert-ExistingPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$PathType,
    [Parameter(Mandatory = $true)]
    [string]$Label
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    throw "$Label was empty."
  }

  if (-not (Test-Path -LiteralPath $Path -PathType $PathType)) {
    throw "$Label not found: $Path"
  }
}

$expectedModes = ConvertTo-NormalizedModeList -Value $ExpectedModeList
if ($expectedModes.Count -eq 0) {
  throw 'ExpectedModeList must resolve to at least one mode.'
}

$reportedModes = ConvertTo-NormalizedModeList -Value $ModeList
$requestedModes = if ([string]::IsNullOrWhiteSpace($RequestedModeList)) {
  $expectedModes
} else {
  ConvertTo-NormalizedModeList -Value $RequestedModeList
}
$executedModes = if ([string]::IsNullOrWhiteSpace($ExecutedModeList)) {
  $reportedModes
} else {
  ConvertTo-NormalizedModeList -Value $ExecutedModeList
}

if ([int]$ModeCount -ne $expectedModes.Count) {
  throw "ModeCount mismatch. Expected $($expectedModes.Count), actual $ModeCount."
}

if (@(Compare-Object -ReferenceObject $expectedModes -DifferenceObject $reportedModes).Count -gt 0) {
  throw "ModeList mismatch. Expected '$($expectedModes -join ', ')', actual '$($reportedModes -join ', ')'."
}

if (@(Compare-Object -ReferenceObject $expectedModes -DifferenceObject $executedModes).Count -gt 0) {
  throw "Executed modes mismatch. Expected '$($expectedModes -join ', ')', actual '$($executedModes -join ', ')'."
}

Assert-ExistingPath -Path $ManifestPath -PathType Leaf -Label 'Manifest'
Assert-ExistingPath -Path $ResultsDir -PathType Container -Label 'Results directory'
Assert-ExistingPath -Path $HistoryReportMd -PathType Leaf -Label 'Markdown report'
Assert-ExistingPath -Path $HistoryReportHtml -PathType Leaf -Label 'HTML report'

if ([string]::IsNullOrWhiteSpace($TotalProcessed) -or [int]$TotalProcessed -lt 1) {
  throw "Expected TotalProcessed >= 1. Actual: $TotalProcessed"
}

$modeEntries = @($ModeManifestsJson | ConvertFrom-Json)
if ($modeEntries.Count -ne $expectedModes.Count) {
  throw "ModeManifestsJson count mismatch. Expected $($expectedModes.Count), actual $($modeEntries.Count)."
}

$modeSummaryPath = $null
if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
  $modeSummaryPath = Join-Path (Split-Path -Parent $EvidencePath) 'mode-summary.md'
}

$modeSummary = & (Join-Path $PSScriptRoot 'Format-CompareVIHistoryModeSummary.ps1') `
  -RequestedModeList ($requestedModes -join ', ') `
  -ExecutedModeList ($executedModes -join ', ') `
  -ModeManifestsJson $ModeManifestsJson `
  -TotalProcessed $TotalProcessed `
  -TotalDiffs $TotalDiffs `
  -StopReason $StopReason `
  -OutputPath $modeSummaryPath

$artifactFiles = @(Get-ChildItem -LiteralPath $ResultsDir -Recurse -File)
if ($artifactFiles.Count -lt 1) {
  throw "Results directory '$ResultsDir' did not contain any files to upload."
}

foreach ($entry in $modeEntries) {
  if ($null -eq $entry.mode -or [string]::IsNullOrWhiteSpace([string]$entry.mode)) {
    throw 'Mode manifest entry contained an empty mode value.'
  }

  Assert-ExistingPath -Path ([string]$entry.manifest) -PathType Leaf -Label "Mode manifest for $($entry.mode)"
  Assert-ExistingPath -Path ([string]$entry.resultsDir) -PathType Container -Label "Mode results directory for $($entry.mode)"
}

$evidence = [ordered]@{
  schema            = 'comparevi-history/published-consumer-evidence@v1'
  generatedAtUtc    = [DateTime]::UtcNow.ToString('o')
  actionRef         = $ActionRef
  consumerRepository= $ConsumerRepository
  consumerRef       = $ConsumerRef
  targetPath        = $TargetPath
  expectedModes     = $expectedModes
  requestedModes    = $requestedModes
  executedModes     = $executedModes
  modeCount         = [int]$ModeCount
  totalProcessed    = [int]$TotalProcessed
  totalDiffs        = if ([string]::IsNullOrWhiteSpace($TotalDiffs)) { $null } else { [int]$TotalDiffs }
  stopReason        = $StopReason
  manifestPath      = $ManifestPath
  resultsDir        = $ResultsDir
  historyReportMd   = $HistoryReportMd
  historyReportHtml = $HistoryReportHtml
  artifactName      = $ArtifactName
  artifactFileCount = $artifactFiles.Count
  modeSummaryMarkdown = $modeSummary
  modes             = @(
    foreach ($entry in $modeEntries) {
      [ordered]@{
        mode           = [string]$entry.mode
        slug           = [string]$entry.slug
        manifest       = [string]$entry.manifest
        resultsDir     = [string]$entry.resultsDir
        processed      = $entry.processed
        diffs          = $entry.diffs
        signalDiffs    = $entry.signalDiffs
        noiseCollapsed = $entry.noiseCollapsed
        errors         = $entry.errors
        status         = [string]$entry.status
        stopReason     = [string]$entry.stopReason
      }
    }
  )
}

if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
  $evidenceDirectory = Split-Path -Parent $EvidencePath
  if (-not [string]::IsNullOrWhiteSpace($evidenceDirectory)) {
    New-Item -ItemType Directory -Path $evidenceDirectory -Force | Out-Null
  }
  $evidence | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $EvidencePath -Encoding utf8
}

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  @(
    '## comparevi-history published consumer validation'
    ''
    ('- Action ref: `{0}`' -f $ActionRef)
    ('- Consumer repo: `{0}@{1}`' -f $ConsumerRepository, $ConsumerRef)
    ('- Target path: `{0}`' -f $TargetPath)
    ('- Artifact name: `{0}`' -f $(if ([string]::IsNullOrWhiteSpace($ArtifactName)) { 'n/a' } else { $ArtifactName }))
    ''
    '### Reviewer summary'
    ''
    $modeSummary
  ) | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
}

$evidence | ConvertTo-Json -Depth 10
