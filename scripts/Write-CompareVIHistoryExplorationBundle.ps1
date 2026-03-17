param(
  [Parameter(Mandatory = $true)]
  [string]$RevisionCatalogPath,
  [Parameter(Mandatory = $true)]
  [string]$ChunkPlanPath,
  [string]$ResultsDir,
  [string]$ExplorationRunPath,
  [string]$TimelineMd,
  [string]$TimelineHtml,
  [string]$BundlePath,
  [string]$BundleManifestPath,
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

function Resolve-ExistingPath {
  param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [string]$BasePath
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }

  $resolved = Resolve-AbsolutePath -Path $Path -BasePath $BasePath
  if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
    return $null
  }

  return $resolved
}

function Resolve-ChildRelativePath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath,
    [Parameter(Mandatory = $true)]
    [string]$ChildPath
  )

  $rootWithSeparator = $RootPath
  if (-not $rootWithSeparator.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
    $rootWithSeparator += [System.IO.Path]::DirectorySeparatorChar
  }

  if (-not $ChildPath.StartsWith($rootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Bundle entry path '$ChildPath' must stay under results root '$RootPath'."
  }

  return $ChildPath.Substring($rootWithSeparator.Length).Replace('\', '/')
}

function Add-BundleFile {
  param(
    [Parameter(Mandatory = $true)]
    [System.Collections.Generic.Dictionary[string, string]]$Map,
    [Parameter(Mandatory = $true)]
    [string]$RootPath,
    [AllowNull()]
    [string]$FilePath
  )

  if ([string]::IsNullOrWhiteSpace($FilePath)) {
    return
  }

  if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
    return
  }

  $resolved = [System.IO.Path]::GetFullPath($FilePath)
  $relative = Resolve-ChildRelativePath -RootPath $RootPath -ChildPath $resolved
  if (-not $Map.ContainsKey($relative)) {
    $Map[$relative] = $resolved
  }
}

function Add-BundleDirectory {
  param(
    [Parameter(Mandatory = $true)]
    [System.Collections.Generic.Dictionary[string, string]]$Map,
    [Parameter(Mandatory = $true)]
    [string]$RootPath,
    [AllowNull()]
    [string]$DirectoryPath
  )

  if ([string]::IsNullOrWhiteSpace($DirectoryPath)) {
    return
  }

  if (-not (Test-Path -LiteralPath $DirectoryPath -PathType Container)) {
    return
  }

  Get-ChildItem -LiteralPath $DirectoryPath -Recurse -File | Sort-Object FullName | ForEach-Object {
    Add-BundleFile -Map $Map -RootPath $RootPath -FilePath $_.FullName
  }
}

function New-BundleManifest {
  param(
    [Parameter(Mandatory = $true)]
    $Catalog,
    [Parameter(Mandatory = $true)]
    $ChunkPlan,
    [Parameter(Mandatory = $true)]
    [string]$ResultsRoot,
    [AllowNull()]
    [string]$BundlePathResolved,
    [Parameter(Mandatory = $true)]
    [string[]]$EntryNames,
    [Parameter(Mandatory = $true)]
    [string]$Status,
    [Parameter(Mandatory = $true)]
    [string]$Reason,
    [AllowNull()]
    [string]$FailureMessage
  )

  return [ordered]@{
    schema = 'comparevi-history/exploration-bundle@v1'
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    consumer = [ordered]@{
      repository = [string]$Catalog.consumer.repository
      ref = [string]$Catalog.consumer.ref
    }
    target = [ordered]@{
      path = [string]$Catalog.target.path
      selectedRef = [string]$Catalog.target.selectedRef
    }
    outputs = [ordered]@{
      resultsRoot = $ResultsRoot
      bundlePath = $BundlePathResolved
      entryCount = $EntryNames.Count
    }
    planning = [ordered]@{
      revisionCount = [int]$Catalog.summary.revisionCount
      chunkCount = [int]$ChunkPlan.summary.chunkCount
      pairCount = [int]$ChunkPlan.summary.pairCount
    }
    bundle = [ordered]@{
      status = $Status
      reason = $Reason
      entryNames = @($EntryNames)
    }
    failure = if ([string]::IsNullOrWhiteSpace($FailureMessage)) { $null } else { [ordered]@{ message = $FailureMessage } }
  }
}

$revisionCatalogPathResolved = Resolve-AbsolutePath -Path $RevisionCatalogPath -BasePath (Get-Location).Path
$chunkPlanPathResolved = Resolve-AbsolutePath -Path $ChunkPlanPath -BasePath (Get-Location).Path
if (-not (Test-Path -LiteralPath $revisionCatalogPathResolved -PathType Leaf)) {
  throw "Revision catalog not found: $revisionCatalogPathResolved"
}
if (-not (Test-Path -LiteralPath $chunkPlanPathResolved -PathType Leaf)) {
  throw "Chunk plan not found: $chunkPlanPathResolved"
}

$catalog = Get-Content -LiteralPath $revisionCatalogPathResolved -Raw | ConvertFrom-Json -Depth 64
$chunkPlan = Get-Content -LiteralPath $chunkPlanPathResolved -Raw | ConvertFrom-Json -Depth 64
if ([string]$catalog.schema -ne 'comparevi-history/revision-catalog@v1') {
  throw "Unsupported revision catalog schema in '$revisionCatalogPathResolved': $($catalog.schema)"
}
if ([string]$chunkPlan.schema -ne 'comparevi-history/chunk-plan@v1') {
  throw "Unsupported chunk plan schema in '$chunkPlanPathResolved': $($chunkPlan.schema)"
}

$resultsDirResolved = if ([string]::IsNullOrWhiteSpace($ResultsDir)) {
  Split-Path -Parent $revisionCatalogPathResolved
} else {
  Resolve-AbsolutePath -Path $ResultsDir -BasePath (Split-Path -Parent $revisionCatalogPathResolved)
}
New-Item -ItemType Directory -Path $resultsDirResolved -Force | Out-Null

$bundlePathResolved = if ([string]::IsNullOrWhiteSpace($BundlePath)) {
  Join-Path $resultsDirResolved 'manual-vi-exploration-bundle.zip'
} else {
  Resolve-AbsolutePath -Path $BundlePath -BasePath $resultsDirResolved
}
$bundleManifestPathResolved = if ([string]::IsNullOrWhiteSpace($BundleManifestPath)) {
  Join-Path $resultsDirResolved 'bundle-manifest.json'
} else {
  Resolve-AbsolutePath -Path $BundleManifestPath -BasePath $resultsDirResolved
}

$chunkReceiptsRoot = if ([int]$chunkPlan.summary.chunkCount -eq 0) {
  Join-Path $resultsDirResolved 'chunk-receipts'
} else {
  Split-Path -Parent ([string]$chunkPlan.chunks[0].outputs.chunkRoot)
}
$explorationRunPathResolved = Resolve-ExistingPath -Path $ExplorationRunPath -BasePath $resultsDirResolved
$timelineMdResolved = Resolve-ExistingPath -Path $TimelineMd -BasePath $resultsDirResolved
$timelineHtmlResolved = Resolve-ExistingPath -Path $TimelineHtml -BasePath $resultsDirResolved

$bundleStatus = 'succeeded'
$bundleReason = 'bundle-created'
$bundleFailureMessage = $null
$bundleEntryMap = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)

Add-BundleFile -Map $bundleEntryMap -RootPath $resultsDirResolved -FilePath $revisionCatalogPathResolved
Add-BundleFile -Map $bundleEntryMap -RootPath $resultsDirResolved -FilePath $chunkPlanPathResolved
Add-BundleFile -Map $bundleEntryMap -RootPath $resultsDirResolved -FilePath $explorationRunPathResolved
Add-BundleFile -Map $bundleEntryMap -RootPath $resultsDirResolved -FilePath $timelineMdResolved
Add-BundleFile -Map $bundleEntryMap -RootPath $resultsDirResolved -FilePath $timelineHtmlResolved
Add-BundleDirectory -Map $bundleEntryMap -RootPath $resultsDirResolved -DirectoryPath $chunkReceiptsRoot

$entryNames = @($bundleEntryMap.Keys | Sort-Object)
if ($entryNames.Count -eq 0) {
  $bundleStatus = 'not-required'
  $bundleReason = 'no-bundle-entries'
}

$manifest = $null
try {
  if ($bundleStatus -eq 'succeeded') {
    if (-not [string]::IsNullOrWhiteSpace($env:COMPAREVI_HISTORY_TEST_BUNDLE_FAIL)) {
      throw $env:COMPAREVI_HISTORY_TEST_BUNDLE_FAIL
    }

    $bundleParent = Split-Path -Parent $bundlePathResolved
    if (-not [string]::IsNullOrWhiteSpace($bundleParent)) {
      New-Item -ItemType Directory -Path $bundleParent -Force | Out-Null
    }

    Remove-Item -LiteralPath $bundlePathResolved -Force -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::Open($bundlePathResolved, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
      foreach ($entryName in $entryNames) {
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $bundleEntryMap[$entryName], $entryName, [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
      }
    } finally {
      $zip.Dispose()
    }
  }
} catch {
  $bundleStatus = 'failed'
  $bundleReason = 'bundle-packaging-failed'
  $bundleFailureMessage = $_.Exception.Message
  Remove-Item -LiteralPath $bundlePathResolved -Force -ErrorAction SilentlyContinue
}

$manifest = New-BundleManifest `
  -Catalog $catalog `
  -ChunkPlan $chunkPlan `
  -ResultsRoot $resultsDirResolved `
  -BundlePathResolved $(if ($bundleStatus -eq 'succeeded') { $bundlePathResolved } else { $null }) `
  -EntryNames $entryNames `
  -Status $bundleStatus `
  -Reason $bundleReason `
  -FailureMessage $bundleFailureMessage
$manifest | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $bundleManifestPathResolved -Encoding utf8

Write-ActionOutput -Key 'bundle-path' -Value $(if ($bundleStatus -eq 'succeeded') { $bundlePathResolved } else { '' })
Write-ActionOutput -Key 'bundle-status' -Value $bundleStatus
Write-ActionOutput -Key 'bundle-reason' -Value $bundleReason
Write-ActionOutput -Key 'bundle-manifest-path' -Value $bundleManifestPathResolved

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  @(
    ''
    '## comparevi-history exploration bundle'
    ''
    ('- Bundle status: `{0}`' -f $bundleStatus)
    ('- Bundle reason: `{0}`' -f $bundleReason)
    ('- Bundle path: `{0}`' -f $(if ($bundleStatus -eq 'succeeded') { $bundlePathResolved } else { '' }))
    ('- Bundle manifest: `{0}`' -f $bundleManifestPathResolved)
    ('- Entry count: `{0}`' -f $entryNames.Count)
  ) | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
  if (-not [string]::IsNullOrWhiteSpace($bundleFailureMessage)) {
    ('- Failure: `{0}`' -f $bundleFailureMessage) | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
  }
}

$manifest | ConvertTo-Json -Depth 64
