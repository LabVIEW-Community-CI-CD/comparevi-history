param(
  [Parameter(Mandatory = $true)]
  [string]$RepositoryRoot,
  [Parameter(Mandatory = $true)]
  [string]$ToolingRoot,
  [Parameter(Mandatory = $true)]
  [string]$TargetPath,
  [string]$StartRef = 'HEAD',
  [string]$SourceBranchRef,
  [Nullable[int]]$MaxBranchCommits,
  [string]$EndRef,
  [Nullable[int]]$MaxPairs,
  [Nullable[int]]$MaxSignalPairs,
  [ValidateSet('include','collapse','skip')]
  [string]$NoisePolicy = 'collapse',
  [string]$Mode = 'default',
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
  [string]$InvokeScriptPath,
  [string]$GitHubOutputPath,
  [string]$StepSummaryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-FacadeOutput {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Key,
    [string]$Value,
    [string]$Path
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return
  }

  $safeValue = if ($null -eq $Value) { '' } else { [string]$Value }
  "$Key=$safeValue" | Out-File -FilePath $Path -Encoding utf8 -Append
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

$repositoryRootResolved = Resolve-AbsolutePath -Path $RepositoryRoot -BasePath (Get-Location).Path
$toolingRootResolved = Resolve-AbsolutePath -Path $ToolingRoot -BasePath (Get-Location).Path
$compareScript = Join-Path $toolingRootResolved 'tools' 'Compare-VIHistory.ps1'

if (-not (Test-Path -LiteralPath $repositoryRootResolved -PathType Container)) {
  throw "Repository root not found: $repositoryRootResolved"
}
if (-not (Test-Path -LiteralPath $toolingRootResolved -PathType Container)) {
  throw "Tooling root not found: $toolingRootResolved"
}
if (-not (Test-Path -LiteralPath $compareScript -PathType Leaf)) {
  throw "Backend compare script not found: $compareScript"
}

Push-Location $repositoryRootResolved
try {
  $repoTop = (& git rev-parse --show-toplevel 2>$null)
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($repoTop)) {
    throw "Repository root '$repositoryRootResolved' is not a git checkout. Run actions/checkout before using comparevi-history."
  }

  $modeList = @($Mode -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if (-not $modeList -or $modeList.Count -eq 0) {
    $modeList = @('default')
  }

  Write-FacadeOutput -Key 'repository-root' -Value $repoTop.Trim() -Path $GitHubOutputPath

  if ($StepSummaryPath) {
    @(
      ''
      '## comparevi-history facade'
      ''
      ('- Repository root: `{0}`' -f $repoTop.Trim())
      ('- Tooling root: `{0}`' -f $toolingRootResolved)
      ('- Target path: `{0}`' -f $TargetPath)
      ('- Modes: `{0}`' -f ($modeList -join ', '))
    ) | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
  }

  $invokeArgs = @{
    TargetPath        = $TargetPath
    StartRef          = $StartRef
    NoisePolicy       = $NoisePolicy
    Mode              = $modeList
    ResultsDir        = $ResultsDir
    Detailed          = $Detailed.IsPresent
    RenderReport      = $RenderReport.IsPresent
    ReportFormat      = $ReportFormat
    FailFast          = $FailFast.IsPresent
    FailOnDiff        = $FailOnDiff.IsPresent
    Quiet             = $Quiet.IsPresent
    KeepArtifactsOnNoDiff = $KeepArtifactsOnNoDiff.IsPresent
    GitHubOutputPath  = $GitHubOutputPath
    StepSummaryPath   = $StepSummaryPath
  }

  if (-not [string]::IsNullOrWhiteSpace($EndRef)) {
    $invokeArgs.EndRef = $EndRef
  }
  if (-not [string]::IsNullOrWhiteSpace($SourceBranchRef)) {
    $invokeArgs.SourceBranchRef = $SourceBranchRef
  }
  if ($null -ne $MaxBranchCommits) {
    $invokeArgs.MaxBranchCommits = [int]$MaxBranchCommits
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
  if (-not [string]::IsNullOrWhiteSpace($InvokeScriptPath)) {
    $invokeArgs.InvokeScriptPath = $InvokeScriptPath
  }
  if ($IncludeMergeParents.IsPresent) {
    $invokeArgs.IncludeMergeParents = $true
  }

  $env:COMPAREVI_SCRIPTS_ROOT = $toolingRootResolved
  try {
    & $compareScript @invokeArgs
  } finally {
    Remove-Item Env:COMPAREVI_SCRIPTS_ROOT -ErrorAction SilentlyContinue
  }
} finally {
  Pop-Location
}
