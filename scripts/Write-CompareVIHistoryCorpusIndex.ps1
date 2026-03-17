param(
  [Parameter(Mandatory = $true)]
  [string[]]$SharedEvidencePaths,
  [string[]]$EvidenceGraphPaths = @(),
  [Parameter(Mandatory = $true)]
  [string]$OutputDir,
  [ValidateRange(1, 500)]
  [int]$PageSize = 25,
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

function ConvertTo-ForwardSlashPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  return $Path.Replace('\', '/')
}

function ConvertTo-RelativePath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$BasePath,
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $normalizedBase = ([System.IO.Path]::GetFullPath($BasePath)).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
  $normalizedPath = [System.IO.Path]::GetFullPath($Path)
  return [System.IO.Path]::GetRelativePath($normalizedBase, $normalizedPath)
}

function Get-OptionalPropertyValue {
  param(
    [AllowNull()]$InputObject,
    [Parameter(Mandatory = $true)][string]$PropertyName,
    [AllowNull()]$Default = $null
  )

  if ($null -eq $InputObject) {
    return $Default
  }

  if ($InputObject -is [System.Collections.IDictionary]) {
    if ($InputObject.Contains($PropertyName)) {
      return $InputObject[$PropertyName]
    }
    return $Default
  }

  $property = $InputObject.PSObject.Properties[$PropertyName]
  if ($null -eq $property) {
    return $Default
  }

  return $property.Value
}

function ConvertTo-ObjectArray {
  param([AllowNull()]$Value)

  if ($null -eq $Value) {
    return @()
  }

  if ($Value -is [string] -or $Value -isnot [System.Collections.IEnumerable]) {
    return @($Value)
  }

  $items = New-Object System.Collections.Generic.List[object]
  foreach ($item in ([System.Collections.IEnumerable]$Value)) {
    $items.Add($item) | Out-Null
  }

  return @($items | ForEach-Object { $_ })
}

function ConvertTo-OrderedCountMap {
  param([AllowNull()]$Value)

  $map = [ordered]@{}
  if ($null -eq $Value) {
    return $map
  }

  if ($Value -is [System.Collections.IDictionary]) {
    foreach ($key in @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object)) {
      $map[$key] = [int]$Value[$key]
    }
    return $map
  }

  foreach ($property in @($Value.PSObject.Properties | Sort-Object Name)) {
    $map[[string]$property.Name] = [int]$property.Value
  }

  return $map
}

function Read-JsonReceipt {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$ExpectedSchema
  )

  $resolved = Resolve-AbsolutePath -Path $Path -BasePath (Get-Location).Path
  if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
    throw "Receipt not found: $resolved"
  }

  $receipt = Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json -Depth 100
  if ([string](Get-OptionalPropertyValue -InputObject $receipt -PropertyName 'schema' -Default '') -ne $ExpectedSchema) {
    throw "Unsupported schema in '$resolved'. Expected '$ExpectedSchema', actual '$($receipt.schema)'"
  }

  return [pscustomobject]@{ Path = $resolved; Json = $receipt }
}

function Get-TargetKey {
  param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$Ref,
    [Parameter(Mandatory = $true)][string]$TargetPath,
    [Parameter(Mandatory = $true)][string]$SelectedRef
  )

  return ('{0}|{1}|{2}|{3}' -f $Repository.Trim(), $Ref.Trim(), $SelectedRef.Trim(), $TargetPath.Trim())
}

function Get-EntrypointKind {
  param([Parameter(Mandatory = $true)][string]$SourceSchema)

  switch ($SourceSchema) {
    'comparevi-history/evidence-graph@v1' { return 'manual-exploration' }
    'comparevi-history/public-run@v1' { return 'curated-public-run' }
    default { return 'unknown' }
  }
}

function Get-GraphContext {
  param([AllowNull()]$GraphJson)

  if ($null -eq $GraphJson) {
    return [ordered]@{
      graphStatus = $null
      graphReason = $null
      catalogComplete = $null
      catalogCompletenessReason = $null
      continuityStatus = $null
      continuityBreakCount = $null
      segmentCount = $null
    }
  }

  $continuity = Get-OptionalPropertyValue -InputObject $GraphJson -PropertyName 'continuity'
  $discovery = Get-OptionalPropertyValue -InputObject $GraphJson -PropertyName 'discovery'
  $completeness = Get-OptionalPropertyValue -InputObject $GraphJson -PropertyName 'completeness'
  return [ordered]@{
    graphStatus = [string](Get-OptionalPropertyValue -InputObject $completeness -PropertyName 'status' -Default '')
    graphReason = [string](Get-OptionalPropertyValue -InputObject $completeness -PropertyName 'reason' -Default '')
    catalogComplete = [bool](Get-OptionalPropertyValue -InputObject $discovery -PropertyName 'catalogComplete' -Default $false)
    catalogCompletenessReason = [string](Get-OptionalPropertyValue -InputObject $discovery -PropertyName 'catalogCompletenessReason' -Default '')
    continuityStatus = [string](Get-OptionalPropertyValue -InputObject $continuity -PropertyName 'status' -Default '')
    continuityBreakCount = [int](Get-OptionalPropertyValue -InputObject $continuity -PropertyName 'breakCount' -Default 0)
    segmentCount = [int](Get-OptionalPropertyValue -InputObject $continuity -PropertyName 'segmentCount' -Default 0)
  }
}

function Get-IsTargetComplete {
  param(
    [Parameter(Mandatory = $true)][string]$FinalStatus,
    [AllowNull()][string]$GraphStatus
  )

  if ($FinalStatus -ne 'succeeded') {
    return $false
  }

  if (-not [string]::IsNullOrWhiteSpace($GraphStatus) -and $GraphStatus -ne 'complete') {
    return $false
  }

  return $true
}

$outputDirResolved = Resolve-AbsolutePath -Path $OutputDir -BasePath (Get-Location).Path
New-Item -ItemType Directory -Path $outputDirResolved -Force | Out-Null
$pagesRoot = Join-Path $outputDirResolved 'pages'
New-Item -ItemType Directory -Path $pagesRoot -Force | Out-Null
$corpusIndexPath = Join-Path $outputDirResolved 'corpus-index.json'
$downstreamManifestPath = Join-Path $outputDirResolved 'downstream-processing-manifest.json'

$graphByKey = @{}
foreach ($graphPath in @(ConvertTo-ObjectArray -Value $EvidenceGraphPaths)) {
  $graphReceipt = Read-JsonReceipt -Path ([string]$graphPath) -ExpectedSchema 'comparevi-history/evidence-graph@v1'
  $graph = $graphReceipt.Json
  $graphKey = Get-TargetKey -Repository ([string]$graph.consumer.repository) -Ref ([string]$graph.consumer.ref) -TargetPath ([string]$graph.target.path) -SelectedRef ([string]$graph.target.selectedRef)
  $graphByKey[$graphKey] = $graphReceipt
}

$entries = New-Object System.Collections.Generic.List[object]
$seenKeys = @{}
foreach ($sharedPath in @(ConvertTo-ObjectArray -Value $SharedEvidencePaths)) {
  $sharedReceipt = Read-JsonReceipt -Path ([string]$sharedPath) -ExpectedSchema 'comparevi-history/shared-evidence@v1'
  $shared = $sharedReceipt.Json
  $targetKey = Get-TargetKey -Repository ([string]$shared.consumer.repository) -Ref ([string]$shared.consumer.ref) -TargetPath ([string]$shared.target.path) -SelectedRef ([string]$shared.target.selectedRef)
  if ($seenKeys.ContainsKey($targetKey)) {
    throw "Duplicate target key in corpus input: $targetKey"
  }
  $seenKeys[$targetKey] = $true

  $graphReceipt = $null
  if ($graphByKey.ContainsKey($targetKey)) {
    $graphReceipt = $graphByKey[$targetKey]
  } elseif ([string]$shared.source.schema -eq 'comparevi-history/evidence-graph@v1' -and -not [string]::IsNullOrWhiteSpace([string]$shared.source.path)) {
    $derivedGraphPath = Resolve-AbsolutePath -Path ([string]$shared.source.path) -BasePath (Split-Path -Parent $sharedReceipt.Path)
    if (Test-Path -LiteralPath $derivedGraphPath -PathType Leaf) {
      $graphReceipt = Read-JsonReceipt -Path $derivedGraphPath -ExpectedSchema 'comparevi-history/evidence-graph@v1'
      $graphByKey[$targetKey] = $graphReceipt
    }
  }

  $graphContext = Get-GraphContext -GraphJson $(if ($null -eq $graphReceipt) { $null } else { $graphReceipt.Json })
  $surfaces = Get-OptionalPropertyValue -InputObject $shared -PropertyName 'surfaces'
  $entries.Add([pscustomobject]@{
      targetKey = $targetKey
      repository = [string]$shared.consumer.repository
      consumerRef = [string]$shared.consumer.ref
      target = [ordered]@{
        path = [string]$shared.target.path
        selectedRef = [string]$shared.target.selectedRef
        extension = [string]$shared.target.extension
        targetId = $(Get-OptionalPropertyValue -InputObject $shared.target -PropertyName 'targetId')
      }
      entrypoint = $(Get-EntrypointKind -SourceSchema ([string]$shared.source.schema))
      sources = [ordered]@{
        sharedEvidenceSchema = [string]$shared.schema
        sharedEvidencePath = $sharedReceipt.Path
        sourceSchema = [string]$shared.source.schema
        sourcePath = [string]$shared.source.path
        evidenceGraphSchema = $(if ($null -eq $graphReceipt) { $null } else { [string]$graphReceipt.Json.schema })
        evidenceGraphPath = $(if ($null -eq $graphReceipt) { $null } else { [string]$graphReceipt.Path })
      }
      summary = [ordered]@{
        modeCount = $(Get-OptionalPropertyValue -InputObject $shared.summary -PropertyName 'modeCount')
        totalProcessed = $(Get-OptionalPropertyValue -InputObject $shared.summary -PropertyName 'totalProcessed')
        totalDiffs = $(Get-OptionalPropertyValue -InputObject $shared.summary -PropertyName 'totalDiffs')
        stopReason = $(Get-OptionalPropertyValue -InputObject $shared.summary -PropertyName 'stopReason')
        suppressionProfile = [string]$surfaces.suppressionProfile
        comparisonArtifactCount = [int](Get-OptionalPropertyValue -InputObject $surfaces -PropertyName 'comparisonArtifactCount' -Default 0)
        captureCount = [int](Get-OptionalPropertyValue -InputObject $surfaces -PropertyName 'captureCount' -Default 0)
        imageArtifactCount = [int](Get-OptionalPropertyValue -InputObject $surfaces -PropertyName 'imageArtifactCount' -Default 0)
        previewImageCount = @((ConvertTo-ObjectArray -Value (Get-OptionalPropertyValue -InputObject $surfaces -PropertyName 'previewImages'))).Count
        comparisonPairCount = @((ConvertTo-ObjectArray -Value (Get-OptionalPropertyValue -InputObject $surfaces -PropertyName 'comparisonPairs'))).Count
      }
      completeness = [ordered]@{
        finalStatus = [string]$shared.completeness.finalStatus
        finalReason = [string]$shared.completeness.finalReason
        replayStatus = [string]$shared.completeness.replayStatus
        replayReason = [string]$shared.completeness.replayReason
        graphStatus = $(if ([string]::IsNullOrWhiteSpace([string]$graphContext.graphStatus)) { $null } else { [string]$graphContext.graphStatus })
        graphReason = $(if ([string]::IsNullOrWhiteSpace([string]$graphContext.graphReason)) { $null } else { [string]$graphContext.graphReason })
        catalogComplete = $(if ($null -eq $graphReceipt) { $null } else { [bool]$graphContext.catalogComplete })
        catalogCompletenessReason = $(if ($null -eq $graphReceipt) { $null } elseif ([string]::IsNullOrWhiteSpace([string]$graphContext.catalogCompletenessReason)) { $null } else { [string]$graphContext.catalogCompletenessReason })
        continuityStatus = $(if ($null -eq $graphReceipt) { $null } elseif ([string]::IsNullOrWhiteSpace([string]$graphContext.continuityStatus)) { $null } else { [string]$graphContext.continuityStatus })
        continuityBreakCount = $(if ($null -eq $graphReceipt) { $null } else { [int]$graphContext.continuityBreakCount })
        segmentCount = $(if ($null -eq $graphReceipt) { $null } else { [int]$graphContext.segmentCount })
      }
      surfaces = [ordered]@{
        categoryCounts = $(ConvertTo-OrderedCountMap -Value (Get-OptionalPropertyValue -InputObject $surfaces -PropertyName 'categoryCounts'))
        bucketCounts = $(ConvertTo-OrderedCountMap -Value (Get-OptionalPropertyValue -InputObject $surfaces -PropertyName 'bucketCounts'))
        renderSurfacesCount = @((ConvertTo-ObjectArray -Value (Get-OptionalPropertyValue -InputObject $surfaces -PropertyName 'renderSurfaces'))).Count
        artifactSurfacesCount = @((ConvertTo-ObjectArray -Value (Get-OptionalPropertyValue -InputObject $surfaces -PropertyName 'artifactSurfaces'))).Count
      }
    }) | Out-Null
}

if ($entries.Count -eq 0) {
  throw 'At least one shared-evidence receipt is required.'
}

$repositoryValues = @($entries | ForEach-Object { [string]$_.repository } | Select-Object -Unique)
$refValues = @($entries | ForEach-Object { [string]$_.consumerRef } | Select-Object -Unique)
if ($repositoryValues.Count -ne 1 -or $refValues.Count -ne 1) {
  throw 'Corpus indexing requires one consumer repository and one consumer ref per manifest.'
}

$sortedEntries = @($entries | Sort-Object { [string]$_.target.path }, { [string]$_.target.selectedRef }, { [string]$_.target.targetId } | ForEach-Object { $_ })
for ($i = 0; $i -lt $sortedEntries.Count; $i++) {
  Add-Member -InputObject $sortedEntries[$i] -NotePropertyName targetOrdinal -NotePropertyValue ($i + 1) -Force
}

$pageDescriptors = New-Object System.Collections.Generic.List[object]
$units = New-Object System.Collections.Generic.List[object]
$pageCount = [int][Math]::Ceiling($sortedEntries.Count / [double]$PageSize)
for ($pageIndex = 0; $pageIndex -lt $pageCount; $pageIndex++) {
  $pageOrdinal = $pageIndex + 1
  $startIndex = $pageIndex * $PageSize
  $endIndex = [Math]::Min($startIndex + $PageSize - 1, $sortedEntries.Count - 1)
  $pageEntries = @($sortedEntries[$startIndex..$endIndex])
  $pagePath = Join-Path $pagesRoot ('corpus-page-{0:d3}.json' -f $pageOrdinal)
  $continuationToken = ('page-{0:d3}' -f $pageOrdinal)
  $pageComplete = @($pageEntries | Where-Object { -not (Get-IsTargetComplete -FinalStatus ([string]$_.completeness.finalStatus) -GraphStatus ([string]$_.completeness.graphStatus)) }).Count -eq 0
  $pageReason = if ($pageComplete) { 'all-targets-complete' } else { 'target-degradation-present' }
  $pageIndexPath = ConvertTo-ForwardSlashPath -Path (ConvertTo-RelativePath -BasePath $pagesRoot -Path $corpusIndexPath)
  $pageRelativePath = ConvertTo-ForwardSlashPath -Path (ConvertTo-RelativePath -BasePath $outputDirResolved -Path $pagePath)

  $pageDocument = [ordered]@{
    schema = 'comparevi-history/corpus-page@v1'
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    corpus = [ordered]@{
      repository = [string]$repositoryValues[0]
      ref = [string]$refValues[0]
      indexPath = $pageIndexPath
    }
    page = [ordered]@{
      pageOrdinal = $pageOrdinal
      pageSize = $PageSize
      targetCount = $pageEntries.Count
      targetOrdinalStart = [int]$pageEntries[0].targetOrdinal
      targetOrdinalEnd = [int]$pageEntries[$pageEntries.Count - 1].targetOrdinal
    }
    targets = @($pageEntries | ForEach-Object {
        $sharedEvidenceRelative = ConvertTo-ForwardSlashPath -Path (ConvertTo-RelativePath -BasePath $pagesRoot -Path ([string]$_.sources.sharedEvidencePath))
        $sourcePathValue = ConvertTo-ForwardSlashPath -Path ([string]$_.sources.sourcePath)
        $evidenceGraphRelative = if ($null -eq $_.sources.evidenceGraphPath) { $null } else { ConvertTo-ForwardSlashPath -Path (ConvertTo-RelativePath -BasePath $pagesRoot -Path ([string]$_.sources.evidenceGraphPath)) }
        [ordered]@{
          targetOrdinal = [int]$_.targetOrdinal
          targetKey = [string]$_.targetKey
          entrypoint = [string]$_.entrypoint
          target = $_.target
          sources = [ordered]@{
            sharedEvidenceSchema = [string]$_.sources.sharedEvidenceSchema
            sharedEvidencePath = $sharedEvidenceRelative
            sourceSchema = [string]$_.sources.sourceSchema
            sourcePath = $sourcePathValue
            evidenceGraphSchema = $(if ($null -eq $_.sources.evidenceGraphSchema) { $null } else { [string]$_.sources.evidenceGraphSchema })
            evidenceGraphPath = $evidenceGraphRelative
          }
          summary = $_.summary
          completeness = $_.completeness
          surfaces = $_.surfaces
        }
      })
    completeness = [ordered]@{
      isComplete = $pageComplete
      reason = $pageReason
    }
  }
  $pageDocument | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $pagePath -Encoding utf8

  $pageDescriptors.Add([ordered]@{
      pageOrdinal = $pageOrdinal
      targetCount = $pageEntries.Count
      targetOrdinalStart = [int]$pageEntries[0].targetOrdinal
      targetOrdinalEnd = [int]$pageEntries[$pageEntries.Count - 1].targetOrdinal
      relativePath = $pageRelativePath
      continuationToken = $continuationToken
    }) | Out-Null

  $units.Add([ordered]@{
      unitId = $continuationToken
      pageOrdinal = $pageOrdinal
      pagePath = $pageRelativePath
      targetCount = $pageEntries.Count
      targetOrdinalStart = [int]$pageEntries[0].targetOrdinal
      targetOrdinalEnd = [int]$pageEntries[$pageEntries.Count - 1].targetOrdinal
      continuationToken = $continuationToken
      status = 'ready'
    }) | Out-Null
}

$completeTargetCount = 0
$incompleteTargetCount = 0
$degradedTargetCount = 0
$replayReadyTargetCount = 0
$unsuppressedTargetCount = 0
$totalComparisonArtifactCount = 0
$totalImageArtifactCount = 0
$totalPreviewImageCount = 0
foreach ($entry in $sortedEntries) {
  $isComplete = Get-IsTargetComplete -FinalStatus ([string]$entry.completeness.finalStatus) -GraphStatus ([string]$entry.completeness.graphStatus)
  if ($isComplete) { $completeTargetCount++ } else { $incompleteTargetCount++ }
  if ([string]$entry.completeness.finalStatus -ne 'succeeded') { $degradedTargetCount++ }
  if ([string]$entry.completeness.replayStatus -eq 'ready') { $replayReadyTargetCount++ }
  if ([string]$entry.summary.suppressionProfile -eq 'unsuppressed') { $unsuppressedTargetCount++ }
  $totalComparisonArtifactCount += [int]$entry.summary.comparisonArtifactCount
  $totalImageArtifactCount += [int]$entry.summary.imageArtifactCount
  $totalPreviewImageCount += [int]$entry.summary.previewImageCount
}

$corpusComplete = $incompleteTargetCount -eq 0
$corpusReason = if ($corpusComplete) { 'all-targets-complete' } else { 'target-degradation-present' }
$candidateTargetPaths = @($sortedEntries | Select-Object -First ([Math]::Min(3, $sortedEntries.Count)) | ForEach-Object { [string]$_.target.path })
$corpusIndexRelativePath = ConvertTo-ForwardSlashPath -Path (ConvertTo-RelativePath -BasePath $outputDirResolved -Path $corpusIndexPath)
$downstreamManifestRelativePath = ConvertTo-ForwardSlashPath -Path (ConvertTo-RelativePath -BasePath $outputDirResolved -Path $downstreamManifestPath)

$downstreamManifest = [ordered]@{}
$downstreamManifest['schema'] = 'comparevi-history/downstream-processing-manifest@v1'
$downstreamManifest['generatedAtUtc'] = [DateTime]::UtcNow.ToString('o')
$downstreamManifest['corpus'] = [ordered]@{
  repository = [string]$repositoryValues[0]
  ref = [string]$refValues[0]
  corpusIndexPath = $corpusIndexRelativePath
}
$downstreamManifest['acceptedSchemas'] = [ordered]@{
  sharedEvidence = 'comparevi-history/shared-evidence@v1'
  evidenceGraph = 'comparevi-history/evidence-graph@v1'
  corpusPage = 'comparevi-history/corpus-page@v1'
}
$downstreamManifest['processingModel'] = [ordered]@{
  unitKind = 'corpus-page'
  ordering = 'target-path-asc'
  continuationMode = 'page-ordinal'
  pageSize = $PageSize
  pageCount = $pageCount
  targetCount = $sortedEntries.Count
}
$downstreamManifest['units'] = @($units | ForEach-Object { $_ })
$downstreamManifest['completeness'] = [ordered]@{
  isComplete = $corpusComplete
  reason = $corpusReason
}
$downstreamManifest['pilotRecommendation'] = [ordered]@{
  name = 'manual-exploration-corpus-pilot@v1'
  selectionStrategy = 'explicit-evidence-list'
  minimumTargetCount = [Math]::Max(1, [Math]::Min(3, $sortedEntries.Count))
  candidateTargetPaths = $candidateTargetPaths
  requiredSchemas = @('comparevi-history/shared-evidence@v1', 'comparevi-history/evidence-graph@v1')
  continuationMode = 'page-ordinal'
  nextStep = 'Seed the pilot with an explicit list of long-lived VIs and let downstream processors resume by page ordinal instead of scraping timeline markdown or HTML.'
}
$downstreamManifest | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $downstreamManifestPath -Encoding utf8

$corpusIndex = [ordered]@{}
$corpusIndex['schema'] = 'comparevi-history/corpus-index@v1'
$corpusIndex['generatedAtUtc'] = [DateTime]::UtcNow.ToString('o')
$corpusIndex['corpus'] = [ordered]@{
  repository = [string]$repositoryValues[0]
  ref = [string]$refValues[0]
  selectionMode = 'explicit-evidence-list'
  pageSize = $PageSize
  targetCount = $sortedEntries.Count
  sharedEvidenceCount = $sortedEntries.Count
  evidenceGraphCount = @($sortedEntries | Where-Object { $null -ne $_.sources.evidenceGraphPath }).Count
}
$corpusIndex['summary'] = [ordered]@{
  completeTargetCount = $completeTargetCount
  incompleteTargetCount = $incompleteTargetCount
  degradedTargetCount = $degradedTargetCount
  replayReadyTargetCount = $replayReadyTargetCount
  unsuppressedTargetCount = $unsuppressedTargetCount
  totalComparisonArtifactCount = $totalComparisonArtifactCount
  totalImageArtifactCount = $totalImageArtifactCount
  totalPreviewImageCount = $totalPreviewImageCount
}
$corpusIndex['paging'] = [ordered]@{
  pageSize = $PageSize
  pageCount = $pageCount
  continuationMode = 'page-ordinal'
  continuationRequired = $false
  pages = @($pageDescriptors | ForEach-Object { $_ })
}
$corpusIndex['targetDigests'] = @($sortedEntries | ForEach-Object {
    $pageOrdinal = [int][Math]::Floor(([int]$_.targetOrdinal - 1) / $PageSize) + 1
    $sharedEvidenceRelative = ConvertTo-ForwardSlashPath -Path (ConvertTo-RelativePath -BasePath $outputDirResolved -Path ([string]$_.sources.sharedEvidencePath))
    $evidenceGraphRelative = if ($null -eq $_.sources.evidenceGraphPath) { $null } else { ConvertTo-ForwardSlashPath -Path (ConvertTo-RelativePath -BasePath $outputDirResolved -Path ([string]$_.sources.evidenceGraphPath)) }
    [ordered]@{
      targetOrdinal = [int]$_.targetOrdinal
      targetKey = [string]$_.targetKey
      pageOrdinal = $pageOrdinal
      path = [string]$_.target.path
      selectedRef = [string]$_.target.selectedRef
      targetId = $_.target.targetId
      sharedEvidencePath = $sharedEvidenceRelative
      evidenceGraphPath = $evidenceGraphRelative
      entrypoint = [string]$_.entrypoint
      finalStatus = [string]$_.completeness.finalStatus
      graphStatus = $(if ($null -eq $_.completeness.graphStatus) { $null } else { [string]$_.completeness.graphStatus })
      previewImageCount = [int]$_.summary.previewImageCount
    }
  })
$corpusIndex['completeness'] = [ordered]@{
  isComplete = $corpusComplete
  reason = $corpusReason
}
$corpusIndex['downstream'] = [ordered]@{
  schema = 'comparevi-history/downstream-processing-manifest@v1'
  path = $downstreamManifestRelativePath
}
$corpusIndex | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $corpusIndexPath -Encoding utf8

Write-ActionOutput -Key 'corpus-index-path' -Value $corpusIndexPath
Write-ActionOutput -Key 'corpus-pages-root' -Value $pagesRoot
Write-ActionOutput -Key 'downstream-processing-manifest-path' -Value $downstreamManifestPath
Write-ActionOutput -Key 'page-count' -Value ([string]$pageCount)
Write-ActionOutput -Key 'target-count' -Value ([string]$sortedEntries.Count)
Write-ActionOutput -Key 'continuation-mode' -Value 'page-ordinal'
Write-ActionOutput -Key 'corpus-complete' -Value ($corpusComplete.ToString().ToLowerInvariant())
Write-ActionOutput -Key 'corpus-reason' -Value $corpusReason

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  @(
    ''
    '## comparevi-history corpus index'
    ''
    ('- Consumer repository: `{0}`' -f [string]$repositoryValues[0])
    ('- Consumer ref: `{0}`' -f [string]$refValues[0])
    ('- Target count: `{0}`' -f $sortedEntries.Count)
    ('- Page size: `{0}`' -f $PageSize)
    ('- Page count: `{0}`' -f $pageCount)
    ('- Continuation mode: `page-ordinal`')
    ('- Corpus complete: `{0}`' -f $corpusComplete.ToString().ToLowerInvariant())
    ('- Corpus reason: `{0}`' -f $corpusReason)
    ('- Unsuppressed target count: `{0}`' -f $unsuppressedTargetCount)
    ('- Replay-ready target count: `{0}`' -f $replayReadyTargetCount)
    ('- Corpus index: `{0}`' -f $corpusIndexPath)
    ('- Downstream processing manifest: `{0}`' -f $downstreamManifestPath)
    ('- Pages root: `{0}`' -f $pagesRoot)
  ) | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
}

$corpusIndex | ConvertTo-Json -Depth 100
