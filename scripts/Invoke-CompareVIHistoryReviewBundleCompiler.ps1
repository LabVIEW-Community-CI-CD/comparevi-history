param(
  [Parameter(Mandatory = $true)]
  [string]$TargetRunsManifestPath,
  [Parameter(Mandatory = $true)]
  [string]$ResultsDir,
  [string]$OutputPath,
  [string]$CompilerPath,
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

function Resolve-CompilerExecutablePath {
  param(
    [AllowNull()]
    [string]$RequestedPath,
    [Parameter(Mandatory = $true)]
    [string]$BasePath
  )

  $effectivePath = if ([string]::IsNullOrWhiteSpace($RequestedPath)) {
    $env:COMPAREVI_HISTORY_REVIEW_COMPILER_PATH
  } else {
    $RequestedPath
  }
  if ([string]::IsNullOrWhiteSpace($effectivePath)) {
    return $null
  }

  $resolvedPath = Resolve-AbsolutePath -Path $effectivePath -BasePath $BasePath
  if (Test-Path -LiteralPath $resolvedPath -PathType Leaf) {
    return $resolvedPath
  }

  if (Test-Path -LiteralPath $resolvedPath -PathType Container) {
    $candidateName = if ($IsWindows) { 'comparevi-history-review-compiler.exe' } else { 'comparevi-history-review-compiler' }
    $candidatePath = Join-Path $resolvedPath $candidateName
    if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
      return $candidatePath
    }
  }

  throw "Review bundle compiler path did not resolve to an executable or extracted CLI root: $resolvedPath"
}

$basePath = (Get-Location).Path
$manifestPathResolved = Resolve-AbsolutePath -Path $TargetRunsManifestPath -BasePath $basePath
$resultsDirResolved = Resolve-AbsolutePath -Path $ResultsDir -BasePath $basePath
$compilerExecutablePath = Resolve-CompilerExecutablePath -RequestedPath $CompilerPath -BasePath $basePath
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
if ($null -eq $compilerExecutablePath -and -not (Test-Path -LiteralPath $projectPathResolved -PathType Leaf)) {
  throw "Review bundle compiler project not found: $projectPathResolved"
}

$invocationKind = 'source-dotnet-run'
if ($null -ne $compilerExecutablePath) {
  $invocationKind = 'self-contained-cli'
  & $compilerExecutablePath `
    --target-runs-manifest-path $manifestPathResolved `
    --results-dir $resultsDirResolved `
    --output-path $outputPathResolved | Out-Null
} else {
  & dotnet run --project $projectPathResolved -- `
    --target-runs-manifest-path $manifestPathResolved `
    --results-dir $resultsDirResolved `
    --output-path $outputPathResolved | Out-Null
}
if ($LASTEXITCODE -ne 0) {
  throw "Review bundle compiler failed with exit code $LASTEXITCODE."
}

if (-not (Test-Path -LiteralPath $outputPathResolved -PathType Leaf)) {
  throw "Review bundle compiler did not emit expected output: $outputPathResolved"
}

Write-ActionOutput -Key 'review-bundle-path' -Value $outputPathResolved
Write-ActionOutput -Key 'compiler-invocation-kind' -Value $invocationKind
Write-ActionOutput -Key 'compiler-executable-path' -Value $(if ($null -eq $compilerExecutablePath) { '' } else { $compilerExecutablePath })

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  @(
    '## comparevi-history review bundle compiler'
    ''
    ('- Review bundle: `{0}`' -f $outputPathResolved)
    ('- Target-runs manifest: `{0}`' -f $manifestPathResolved)
    ('- Results directory: `{0}`' -f $resultsDirResolved)
    ('- Invocation kind: `{0}`' -f $invocationKind)
    $(if ($null -ne $compilerExecutablePath) { '- Compiler executable: `{0}`' -f $compilerExecutablePath } else { '- Compiler executable: `source project via dotnet run`' })
  ) | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
}

Get-Content -LiteralPath $outputPathResolved -Raw
