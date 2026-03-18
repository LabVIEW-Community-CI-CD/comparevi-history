param(
  [Parameter(Mandatory = $true)]
  [string]$TargetRunsManifestPath,
  [Parameter(Mandatory = $true)]
  [string]$ResultsDir,
  [string]$OutputPath,
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

$basePath = (Get-Location).Path
$manifestPathResolved = Resolve-AbsolutePath -Path $TargetRunsManifestPath -BasePath $basePath
$resultsDirResolved = Resolve-AbsolutePath -Path $ResultsDir -BasePath $basePath
$outputPathResolved = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
  Join-Path $resultsDirResolved 'review-bundle.json'
} else {
  Resolve-AbsolutePath -Path $OutputPath -BasePath $basePath
}

if (-not (Test-Path -LiteralPath $manifestPathResolved -PathType Leaf)) {
  throw "Target-runs manifest not found: $manifestPathResolved"
}
if (-not (Test-Path -LiteralPath $resultsDirResolved -PathType Container)) {
  throw "Results directory not found: $resultsDirResolved"
}

$projectPathResolved = Resolve-AbsolutePath -Path '..\src\CompareVIHistory.ReviewCompiler\CompareVIHistory.ReviewCompiler.csproj' -BasePath $PSScriptRoot
if (-not (Test-Path -LiteralPath $projectPathResolved -PathType Leaf)) {
  throw "Review bundle compiler project not found: $projectPathResolved"
}

& dotnet run --project $projectPathResolved -- `
  --target-runs-manifest-path $manifestPathResolved `
  --results-dir $resultsDirResolved `
  --output-path $outputPathResolved | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "Review bundle compiler failed with exit code $LASTEXITCODE."
}

if (-not (Test-Path -LiteralPath $outputPathResolved -PathType Leaf)) {
  throw "Review bundle compiler did not emit expected output: $outputPathResolved"
}

Write-ActionOutput -Key 'review-bundle-path' -Value $outputPathResolved

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  @(
    '## comparevi-history review bundle compiler'
    ''
    ('- Review bundle: `{0}`' -f $outputPathResolved)
    ('- Target-runs manifest: `{0}`' -f $manifestPathResolved)
    ('- Results directory: `{0}`' -f $resultsDirResolved)
  ) | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
}

Get-Content -LiteralPath $outputPathResolved -Raw
