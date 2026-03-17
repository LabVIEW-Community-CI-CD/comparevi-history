param(
  [Parameter(ParameterSetName = 'public-run', Mandatory = $true)]
  [string]$PublicRunPath,
  [Parameter(ParameterSetName = 'public-run', Mandatory = $true)]
  [string]$ModeSummaryJsonPath,
  [Parameter(ParameterSetName = 'public-run')]
  [string]$ModeSummaryPath,
  [Parameter(ParameterSetName = 'graph', Mandatory = $true)]
  [string]$EvidenceGraphPath,
  [Parameter(Mandatory = $true)]
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
    [AllowEmptyString()]
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
    [string]$BasePath,
    [Parameter(Mandatory = $true)]
    [string]$PathType
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }

  $resolved = Resolve-AbsolutePath -Path $Path -BasePath $BasePath
  if (-not (Test-Path -LiteralPath $resolved -PathType $PathType)) {
    return $null
  }

  return $resolved
}

function Get-OptionalPropertyValue {
  param(
    [AllowNull()]
    $InputObject,
    [Parameter(Mandatory = $true)]
    [string]$PropertyName,
    [AllowNull()]
    $Default = $null
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
  param(
    [AllowNull()]
    $Value
  )

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
  param(
    [AllowNull()]
    $Value
  )

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

function ConvertTo-ComparisonPairArray {
  param(
    [AllowNull()]
    $Value
  )

  $pairs = New-Object System.Collections.Generic.List[object]
  foreach ($pair in @(ConvertTo-ObjectArray -Value $Value)) {
    $firstPath = [string](Get-OptionalPropertyValue -InputObject $pair -PropertyName 'firstPath' -Default '')
    $secondPath = [string](Get-OptionalPropertyValue -InputObject $pair -PropertyName 'secondPath' -Default '')
    if ([string]::IsNullOrWhiteSpace($firstPath) -or [string]::IsNullOrWhiteSpace($secondPath)) {
      continue
    }

    $pairs.Add([ordered]@{
        firstPath = $firstPath.Trim()
        secondPath = $secondPath.Trim()
        count = [int](Get-OptionalPropertyValue -InputObject $pair -PropertyName 'count' -Default 0)
      }) | Out-Null
  }

  return @(
    $pairs |
      Sort-Object { [string]$_.firstPath }, { [string]$_.secondPath } |
      ForEach-Object { $_ }
  )
}

function ConvertTo-PreviewImageArray {
  param(
    [AllowNull()]
    $Value,
    [Parameter(Mandatory = $true)]
    [string]$Scope,
    [Parameter(Mandatory = $true)]
    [string]$ResultsRoot,
    [AllowNull()]
    [string]$DefaultChunkId
  )

  $images = New-Object System.Collections.Generic.List[object]
  foreach ($preview in @(ConvertTo-ObjectArray -Value $Value)) {
    $relativePath = [string](Get-OptionalPropertyValue -InputObject $preview -PropertyName 'relativePath' -Default '')
    if ([string]::IsNullOrWhiteSpace($relativePath)) {
      $relativePath = [string](Get-OptionalPropertyValue -InputObject $preview -PropertyName 'artifactRelativePath' -Default '')
    }
    if ([string]::IsNullOrWhiteSpace($relativePath)) {
      $savedPath = Resolve-ExistingPath -Path ([string](Get-OptionalPropertyValue -InputObject $preview -PropertyName 'savedPath' -Default '')) -BasePath $ResultsRoot -PathType Leaf
      if ($null -ne $savedPath) {
        $resultsRootResolved = [System.IO.Path]::GetFullPath($ResultsRoot)
        $resultsRootWithSeparator = if ($resultsRootResolved.EndsWith([System.IO.Path]::DirectorySeparatorChar)) { $resultsRootResolved } else { $resultsRootResolved + [System.IO.Path]::DirectorySeparatorChar }
        if ($savedPath.StartsWith($resultsRootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) {
          $relativePath = $savedPath.Substring($resultsRootWithSeparator.Length).Replace('\', '/')
        }
      }
    }
    if ([string]::IsNullOrWhiteSpace($relativePath)) {
      continue
    }

    $pairNode = Get-OptionalPropertyValue -InputObject $preview -PropertyName 'comparisonPair'
    $comparisonPair = if ($null -eq $pairNode) {
      $null
    } else {
      $firstPath = [string](Get-OptionalPropertyValue -InputObject $pairNode -PropertyName 'firstPath' -Default '')
      $secondPath = [string](Get-OptionalPropertyValue -InputObject $pairNode -PropertyName 'secondPath' -Default '')
      if ([string]::IsNullOrWhiteSpace($firstPath) -or [string]::IsNullOrWhiteSpace($secondPath)) {
        $null
      } else {
        [ordered]@{
          firstPath = $firstPath.Trim()
          secondPath = $secondPath.Trim()
        }
      }
    }

    $images.Add([ordered]@{
        scope = $Scope
        chunkId = $(if ([string]::IsNullOrWhiteSpace([string](Get-OptionalPropertyValue -InputObject $preview -PropertyName 'chunkId' -Default $DefaultChunkId))) { $null } else { [string](Get-OptionalPropertyValue -InputObject $preview -PropertyName 'chunkId' -Default $DefaultChunkId) })
        mode = [string](Get-OptionalPropertyValue -InputObject $preview -PropertyName 'mode' -Default 'unknown')
        category = [string](Get-OptionalPropertyValue -InputObject $preview -PropertyName 'category' -Default 'uncategorized')
        comparisonPair = $comparisonPair
        mimeType = [string](Get-OptionalPropertyValue -InputObject $preview -PropertyName 'mimeType' -Default '')
        byteLength = [int](Get-OptionalPropertyValue -InputObject $preview -PropertyName 'byteLength' -Default 0)
        relativePath = $relativePath.Replace('\', '/')
        sortKey = [string](Get-OptionalPropertyValue -InputObject $preview -PropertyName 'sortKey' -Default $relativePath)
      }) | Out-Null
  }

  return @(
    $images |
      Sort-Object { [string]$_.sortKey }, { [string]$_.relativePath } |
      ForEach-Object { $_ }
  )
}

function ConvertTo-SurfaceReferenceArray {
  param(
    [AllowNull()]
    $Value
  )

  $references = New-Object System.Collections.Generic.List[object]
  foreach ($entry in @(ConvertTo-ObjectArray -Value $Value)) {
    $relativePath = [string](Get-OptionalPropertyValue -InputObject $entry -PropertyName 'relativePath' -Default '')
    if ([string]::IsNullOrWhiteSpace($relativePath)) {
      continue
    }

    $references.Add([ordered]@{
        scope = [string](Get-OptionalPropertyValue -InputObject $entry -PropertyName 'scope' -Default 'run')
        kind = [string](Get-OptionalPropertyValue -InputObject $entry -PropertyName 'kind' -Default 'unknown')
        chunkId = $(if ([string]::IsNullOrWhiteSpace([string](Get-OptionalPropertyValue -InputObject $entry -PropertyName 'chunkId' -Default ''))) { $null } else { [string](Get-OptionalPropertyValue -InputObject $entry -PropertyName 'chunkId' -Default '') })
        relativePath = $relativePath.Replace('\', '/')
        pathType = [string](Get-OptionalPropertyValue -InputObject $entry -PropertyName 'pathType' -Default 'file')
        contentType = $(if ([string]::IsNullOrWhiteSpace([string](Get-OptionalPropertyValue -InputObject $entry -PropertyName 'contentType' -Default ''))) { $null } else { [string](Get-OptionalPropertyValue -InputObject $entry -PropertyName 'contentType' -Default '') })
      }) | Out-Null
  }

  return @($references | ForEach-Object { $_ })
}

function New-SurfaceReference {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ResultsRoot,
    [Parameter(Mandatory = $true)]
    [string]$Kind,
    [AllowNull()]
    [AllowEmptyString()]
    [string]$Path,
    [ValidateSet('file','directory')]
    [string]$PathType = 'file',
    [AllowNull()]
    [AllowEmptyString()]
    [string]$ContentType = $null,
    [ValidateSet('run','chunk')]
    [string]$Scope = 'run',
    [AllowNull()]
    [string]$ChunkId = $null,
    [switch]$AllowMissing
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return $null
  }

  $resolvedPath = Resolve-AbsolutePath -Path $Path -BasePath $ResultsRoot
  if (-not $AllowMissing.IsPresent) {
    $expectedPathType = if ($PathType -eq 'directory') { 'Container' } else { 'Leaf' }
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType $expectedPathType)) {
      return $null
    }
  }

  $resultsRootResolved = [System.IO.Path]::GetFullPath($ResultsRoot)
  $resultsRootWithSeparator = if ($resultsRootResolved.EndsWith([System.IO.Path]::DirectorySeparatorChar)) { $resultsRootResolved } else { $resultsRootResolved + [System.IO.Path]::DirectorySeparatorChar }
  if (-not $resolvedPath.StartsWith($resultsRootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $null
  }

  return [ordered]@{
    scope = $Scope
    kind = $Kind
    chunkId = $ChunkId
    relativePath = $resolvedPath.Substring($resultsRootWithSeparator.Length).Replace('\', '/')
    pathType = $PathType
    contentType = $(if ([string]::IsNullOrWhiteSpace($ContentType)) { $null } else { $ContentType })
  }
}

function Add-SurfaceReference {
  param(
    [Parameter(Mandatory = $true)]
    [System.Collections.IList]$Target,
    [AllowNull()]
    $Entry
  )

  if ($null -eq $Entry) {
    return
  }

  $Target.Add($Entry) | Out-Null
}

function New-SharedEvidenceFromPublicRun {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ResolvedPublicRunPath,
    [Parameter(Mandatory = $true)]
    [string]$ResolvedModeSummaryJsonPath,
    [AllowNull()]
    [string]$ResolvedModeSummaryPath,
    [Parameter(Mandatory = $true)]
    [string]$ResolvedOutputPath
  )

  $publicRun = Get-Content -LiteralPath $ResolvedPublicRunPath -Raw | ConvertFrom-Json -Depth 64
  if ([string]$publicRun.schema -ne 'comparevi-history/public-run@v1') {
    throw "Unsupported public run schema in '$ResolvedPublicRunPath': $($publicRun.schema)"
  }

  $modeSummary = Get-Content -LiteralPath $ResolvedModeSummaryJsonPath -Raw | ConvertFrom-Json -Depth 64
  if ([string]$modeSummary.schema -ne 'comparevi-history/mode-summary@v1') {
    throw "Unsupported mode summary schema in '$ResolvedModeSummaryJsonPath': $($modeSummary.schema)"
  }

  $resultsRoot = [string]$publicRun.outputs.resultsDir
  if ([string]::IsNullOrWhiteSpace($resultsRoot)) {
    throw 'Public run resultsDir was empty.'
  }

  $renderSurfaces = New-Object 'System.Collections.Generic.List[object]'
  $artifactSurfaces = New-Object 'System.Collections.Generic.List[object]'

  Add-SurfaceReference -Target $renderSurfaces -Entry (New-SurfaceReference -ResultsRoot $resultsRoot -Kind 'history-report-md' -Path ([string]$publicRun.outputs.historyReportMd) -ContentType 'text/markdown')
  Add-SurfaceReference -Target $renderSurfaces -Entry (New-SurfaceReference -ResultsRoot $resultsRoot -Kind 'history-report-html' -Path ([string]$publicRun.outputs.historyReportHtml) -ContentType 'text/html')
  Add-SurfaceReference -Target $renderSurfaces -Entry (New-SurfaceReference -ResultsRoot $resultsRoot -Kind 'public-comment-md' -Path ([string]$publicRun.outputs.publicCommentPath) -ContentType 'text/markdown')
  Add-SurfaceReference -Target $renderSurfaces -Entry (New-SurfaceReference -ResultsRoot $resultsRoot -Kind 'public-step-summary-md' -Path ([string]$publicRun.outputs.publicStepSummaryPath) -ContentType 'text/markdown')
  Add-SurfaceReference -Target $renderSurfaces -Entry (New-SurfaceReference -ResultsRoot $resultsRoot -Kind 'mode-summary-md' -Path $ResolvedModeSummaryPath -ContentType 'text/markdown')

  Add-SurfaceReference -Target $artifactSurfaces -Entry (New-SurfaceReference -ResultsRoot $resultsRoot -Kind 'request-json' -Path ([string]$publicRun.requestPath) -ContentType 'application/json')
  Add-SurfaceReference -Target $artifactSurfaces -Entry (New-SurfaceReference -ResultsRoot $resultsRoot -Kind 'public-run-json' -Path $ResolvedPublicRunPath -ContentType 'application/json')
  Add-SurfaceReference -Target $artifactSurfaces -Entry (New-SurfaceReference -ResultsRoot $resultsRoot -Kind 'shared-evidence-json' -Path $ResolvedOutputPath -ContentType 'application/json' -AllowMissing)
  Add-SurfaceReference -Target $artifactSurfaces -Entry (New-SurfaceReference -ResultsRoot $resultsRoot -Kind 'mode-summary-json' -Path $ResolvedModeSummaryJsonPath -ContentType 'application/json')
  Add-SurfaceReference -Target $artifactSurfaces -Entry (New-SurfaceReference -ResultsRoot $resultsRoot -Kind 'manifest-json' -Path ([string]$publicRun.outputs.manifestPath) -ContentType 'application/json')
  Add-SurfaceReference -Target $artifactSurfaces -Entry (New-SurfaceReference -ResultsRoot $resultsRoot -Kind 'history-summary-json' -Path ([string]$publicRun.outputs.historySummaryJson) -ContentType 'application/json')

  return [ordered]@{
    schema = 'comparevi-history/shared-evidence@v1'
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    source = [ordered]@{
      schema = 'comparevi-history/public-run@v1'
      path = $ResolvedPublicRunPath
    }
    consumer = [ordered]@{
      repository = [string]$publicRun.request.consumer.repository
      ref = [string]$publicRun.request.consumer.ref
    }
    target = [ordered]@{
      path = [string]$publicRun.request.target.path
      selectedRef = [string]$publicRun.request.history.startRef
      extension = [System.IO.Path]::GetExtension([string]$publicRun.request.target.path).ToLowerInvariant()
      targetId = $(if ([string]::IsNullOrWhiteSpace([string]$publicRun.request.target.id)) { $null } else { [string]$publicRun.request.target.id })
    }
    configuration = [ordered]@{
      requestedModes = @($publicRun.summary.requestedModes | ForEach-Object { [string]$_ })
      noisePolicy = [string]$publicRun.request.history.noisePolicy
      includeMergeParents = [bool]$publicRun.request.history.includeMergeParents
    }
    summary = [ordered]@{
      modeCount = $(if ($null -eq $publicRun.summary.modeCount) { $null } else { [int]$publicRun.summary.modeCount })
      totalProcessed = $(if ($null -eq $publicRun.summary.totalProcessed) { $null } else { [int]$publicRun.summary.totalProcessed })
      totalDiffs = $(if ($null -eq $publicRun.summary.totalDiffs) { $null } else { [int]$publicRun.summary.totalDiffs })
      stopReason = $(if ([string]::IsNullOrWhiteSpace([string]$publicRun.summary.stopReason)) { $null } else { [string]$publicRun.summary.stopReason })
    }
    surfaces = [ordered]@{
      suppressionProfile = [string]$modeSummary.suppressionProfile
      comparisonArtifactCount = [int]$modeSummary.metadata.comparisonArtifactCount
      captureCount = [int]$modeSummary.metadata.captureCount
      imageArtifactCount = [int]$modeSummary.metadata.imageArtifactCount
      imageMimeTypes = @($modeSummary.metadata.imageMimeTypes | ForEach-Object { [string]$_ })
      categoryCounts = ConvertTo-OrderedCountMap -Value $modeSummary.categoryCounts
      comparisonPairs = @(ConvertTo-ComparisonPairArray -Value $modeSummary.comparisonPairs)
      bucketCounts = ConvertTo-OrderedCountMap -Value $modeSummary.bucketCounts
      previewImages = @(ConvertTo-PreviewImageArray -Value $modeSummary.previewImages -Scope 'run' -ResultsRoot $resultsRoot)
      renderSurfaces = @($renderSurfaces | ForEach-Object { $_ })
      artifactSurfaces = @($artifactSurfaces | ForEach-Object { $_ })
    }
    completeness = [ordered]@{
      finalStatus = [string]$publicRun.summary.finalStatus
      finalReason = [string]$publicRun.summary.finalReason
      replayStatus = [string]$publicRun.replay.status
      replayReason = [string]$publicRun.replay.reason
    }
  }
}

function New-SharedEvidenceFromGraph {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ResolvedEvidenceGraphPath,
    [Parameter(Mandatory = $true)]
    [string]$ResolvedOutputPath
  )

  $graph = Get-Content -LiteralPath $ResolvedEvidenceGraphPath -Raw | ConvertFrom-Json -Depth 64
  if ([string]$graph.schema -ne 'comparevi-history/evidence-graph@v1') {
    throw "Unsupported evidence graph schema in '$ResolvedEvidenceGraphPath': $($graph.schema)"
  }

  $chunkStopReasons = New-Object System.Collections.Generic.List[string]
  $totalProcessed = 0
  $totalDiffs = 0
  foreach ($chunk in @(ConvertTo-ObjectArray -Value $graph.execution.chunks)) {
    $summaryNode = Get-OptionalPropertyValue -InputObject $chunk -PropertyName 'summary'
    $processedValue = Get-OptionalPropertyValue -InputObject $summaryNode -PropertyName 'totalProcessed'
    if ($null -ne $processedValue) {
      $totalProcessed += [int]$processedValue
    }
    $diffValue = Get-OptionalPropertyValue -InputObject $summaryNode -PropertyName 'totalDiffs'
    if ($null -ne $diffValue) {
      $totalDiffs += [int]$diffValue
    }
    $stopReason = [string](Get-OptionalPropertyValue -InputObject $summaryNode -PropertyName 'stopReason' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($stopReason)) {
      $chunkStopReasons.Add($stopReason.Trim()) | Out-Null
    }
  }

  $distinctStopReasons = @($chunkStopReasons | Sort-Object -Unique)
  $sharedStopReason = if ($distinctStopReasons.Count -eq 1) { [string]$distinctStopReasons[0] } else { $null }

  $resultsRoot = Split-Path -Parent $ResolvedEvidenceGraphPath
  $artifactSurfaces = New-Object 'System.Collections.Generic.List[object]'
  foreach ($entry in @(ConvertTo-SurfaceReferenceArray -Value $graph.surfaces.artifactSurfaces)) {
    $artifactSurfaces.Add($entry) | Out-Null
  }
  Add-SurfaceReference -Target $artifactSurfaces -Entry (New-SurfaceReference -ResultsRoot $resultsRoot -Kind 'shared-evidence-json' -Path $ResolvedOutputPath -ContentType 'application/json' -AllowMissing)

  return [ordered]@{
    schema = 'comparevi-history/shared-evidence@v1'
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    source = [ordered]@{
      schema = 'comparevi-history/evidence-graph@v1'
      path = $ResolvedEvidenceGraphPath
    }
    consumer = [ordered]@{
      repository = [string]$graph.consumer.repository
      ref = [string]$graph.consumer.ref
    }
    target = [ordered]@{
      path = [string]$graph.target.path
      selectedRef = [string]$graph.target.selectedRef
      extension = [string]$graph.target.extension
      targetId = $null
    }
    configuration = [ordered]@{
      requestedModes = @($graph.configuration.requestedModes | ForEach-Object { [string]$_ })
      noisePolicy = [string]$graph.configuration.noisePolicy
      includeMergeParents = [bool]$graph.configuration.includeMergeParents
    }
    summary = [ordered]@{
      modeCount = @($graph.configuration.requestedModes).Count
      totalProcessed = $totalProcessed
      totalDiffs = $totalDiffs
      stopReason = $sharedStopReason
    }
    surfaces = [ordered]@{
      suppressionProfile = [string]$graph.surfaces.suppressionProfile
      comparisonArtifactCount = [int]$graph.surfaces.comparisonArtifactCount
      captureCount = [int]$graph.surfaces.captureCount
      imageArtifactCount = [int]$graph.surfaces.imageArtifactCount
      imageMimeTypes = @($graph.surfaces.imageMimeTypes | ForEach-Object { [string]$_ })
      categoryCounts = ConvertTo-OrderedCountMap -Value $graph.surfaces.categoryCounts
      comparisonPairs = @(ConvertTo-ComparisonPairArray -Value $graph.surfaces.comparisonPairs)
      bucketCounts = ConvertTo-OrderedCountMap -Value $graph.surfaces.bucketCounts
      previewImages = @(ConvertTo-PreviewImageArray -Value $graph.surfaces.previewImages -Scope 'chunk' -ResultsRoot (Split-Path -Parent $ResolvedEvidenceGraphPath))
      renderSurfaces = @(ConvertTo-SurfaceReferenceArray -Value $graph.surfaces.renderSurfaces)
      artifactSurfaces = @($artifactSurfaces | ForEach-Object { $_ })
    }
    completeness = [ordered]@{
      finalStatus = [string]$graph.completeness.finalStatus
      finalReason = [string]$graph.completeness.finalReason
      replayStatus = [string]$graph.completeness.replayStatus
      replayReason = [string]$graph.completeness.replayReason
    }
  }
}

$resolvedOutputPath = Resolve-AbsolutePath -Path $OutputPath -BasePath (Get-Location).Path
$outputDirectory = Split-Path -Parent $resolvedOutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
  New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$sharedEvidence = switch ($PSCmdlet.ParameterSetName) {
  'public-run' {
    $resolvedPublicRunPath = Resolve-AbsolutePath -Path $PublicRunPath -BasePath (Get-Location).Path
    $resolvedModeSummaryJsonPath = Resolve-AbsolutePath -Path $ModeSummaryJsonPath -BasePath (Get-Location).Path
    $resolvedModeSummaryPath = if ([string]::IsNullOrWhiteSpace($ModeSummaryPath)) { $null } else { Resolve-AbsolutePath -Path $ModeSummaryPath -BasePath (Get-Location).Path }
    New-SharedEvidenceFromPublicRun -ResolvedPublicRunPath $resolvedPublicRunPath -ResolvedModeSummaryJsonPath $resolvedModeSummaryJsonPath -ResolvedModeSummaryPath $resolvedModeSummaryPath -ResolvedOutputPath $resolvedOutputPath
  }
  'graph' {
    $resolvedEvidenceGraphPath = Resolve-AbsolutePath -Path $EvidenceGraphPath -BasePath (Get-Location).Path
    New-SharedEvidenceFromGraph -ResolvedEvidenceGraphPath $resolvedEvidenceGraphPath -ResolvedOutputPath $resolvedOutputPath
  }
  default {
    throw "Unsupported parameter set '$($PSCmdlet.ParameterSetName)'."
  }
}

$sharedEvidence | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $resolvedOutputPath -Encoding utf8

Write-ActionOutput -Key 'shared-evidence-path' -Value $resolvedOutputPath

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  @(
    '### comparevi-history shared evidence'
    ''
    ('- Shared evidence: `{0}`' -f $resolvedOutputPath)
    ('- Source schema: `{0}`' -f [string]$sharedEvidence.source.schema)
    ('- Final status: `{0}`' -f [string]$sharedEvidence.completeness.finalStatus)
    ('- Replay status: `{0}`' -f [string]$sharedEvidence.completeness.replayStatus)
  ) | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
}

$sharedEvidence | ConvertTo-Json -Depth 64
