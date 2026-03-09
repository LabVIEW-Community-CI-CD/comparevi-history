param(
  [string]$RequestedModeList,
  [string]$ExecutedModeList,
  [string]$ModeManifestsJson,
  [string]$TotalProcessed,
  [string]$TotalDiffs,
  [string]$StopReason,
  [string]$GitHubOutputPath,
  [string]$OutputPath,
  [string]$StepSummaryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-NormalizedModeList {
  param(
    [string]$Value
  )

  return @(
    $Value -split '[,;]'
    | ForEach-Object { $_.Trim() }
    | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    | Sort-Object -Unique
  )
}

function Write-MultilineGitHubOutput {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Key,
    [Parameter(Mandatory = $true)]
    [string]$Value,
    [string]$Path
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return
  }

  $delimiter = "EOF_{0}" -f ([guid]::NewGuid().ToString('N'))
  @(
    "$Key<<$delimiter"
    $Value
    $delimiter
  ) | Out-File -FilePath $Path -Encoding utf8 -Append
}

function Get-EntryValue {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Entry,
    [Parameter(Mandatory = $true)]
    [string]$Name,
    $DefaultValue = $null
  )

  $property = $Entry.PSObject.Properties[$Name]
  if ($null -eq $property) {
    return $DefaultValue
  }

  return $property.Value
}

$requestedModes = @(ConvertTo-NormalizedModeList -Value $RequestedModeList)
$executedModes = @(ConvertTo-NormalizedModeList -Value $ExecutedModeList)

$modeEntries = @()
if (-not [string]::IsNullOrWhiteSpace($ModeManifestsJson)) {
  $modeEntries = @($ModeManifestsJson | ConvertFrom-Json)
}

if ($requestedModes.Count -eq 0 -and $modeEntries.Count -gt 0) {
  $requestedModes = @(
    $modeEntries
    | ForEach-Object { [string](Get-EntryValue -Entry $_ -Name 'mode' -DefaultValue '') }
    | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    | Sort-Object -Unique
  )
}

if ($executedModes.Count -eq 0 -and $modeEntries.Count -gt 0) {
  $executedModes = $requestedModes
}

$summaryLines = New-Object System.Collections.Generic.List[string]
$summaryLines.Add(('Requested modes: `{0}`' -f $(if ($requestedModes.Count -gt 0) { $requestedModes -join ', ' } else { 'n/a' })))
$summaryLines.Add(('Executed modes: `{0}`' -f $(if ($executedModes.Count -gt 0) { $executedModes -join ', ' } else { 'n/a' })))
$summaryLines.Add(('Total processed: `{0}`' -f $(if ([string]::IsNullOrWhiteSpace($TotalProcessed)) { 'n/a' } else { $TotalProcessed })))
$summaryLines.Add(('Total diffs: `{0}`' -f $(if ([string]::IsNullOrWhiteSpace($TotalDiffs)) { 'n/a' } else { $TotalDiffs })))
if (-not [string]::IsNullOrWhiteSpace($StopReason)) {
  $summaryLines.Add(('Stop reason: `{0}`' -f $StopReason))
}

if ($modeEntries.Count -gt 0) {
  $summaryLines.Add('')
  $summaryLines.Add('| Mode | Processed | Diffs | Signal | Noise | Errors | Status |')
  $summaryLines.Add('| --- | ---: | ---: | ---: | ---: | ---: | --- |')
  foreach ($entry in @($modeEntries | Sort-Object -Property @{ Expression = { $_.mode } })) {
    $summaryLines.Add((
      '| {0} | {1} | {2} | {3} | {4} | {5} | {6} |' -f `
      (Get-EntryValue -Entry $entry -Name 'mode' -DefaultValue 'unknown'), `
      (Get-EntryValue -Entry $entry -Name 'processed' -DefaultValue 0), `
      (Get-EntryValue -Entry $entry -Name 'diffs' -DefaultValue 0), `
      (Get-EntryValue -Entry $entry -Name 'signalDiffs' -DefaultValue 0), `
      (Get-EntryValue -Entry $entry -Name 'noiseCollapsed' -DefaultValue 0), `
      (Get-EntryValue -Entry $entry -Name 'errors' -DefaultValue 0), `
      (Get-EntryValue -Entry $entry -Name 'status' -DefaultValue 'unknown')
    ))
  }
}

$summary = $summaryLines -join [Environment]::NewLine

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
  $outputDirectory = Split-Path -Parent $OutputPath
  if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
  }
  $summary | Set-Content -LiteralPath $OutputPath -Encoding utf8
}

Write-MultilineGitHubOutput -Key 'mode-summary-markdown' -Value $summary -Path $GitHubOutputPath

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  @(
    '### comparevi-history mode summary'
    ''
    $summary
  ) | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
}

$summary
