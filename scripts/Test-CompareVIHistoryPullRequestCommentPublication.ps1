Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'Publish-CompareVIHistoryPullRequestComment.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('comparevi-history-pr-publish-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

function New-PreviewPair {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Mode,
    [Parameter(Mandatory = $true)]
    [int]$ComparisonIndex
  )

  return [ordered]@{
    targetId = 'dynamic-demo-target'
    targetPath = 'Tooling/demo/Demo.vi'
    mode = $Mode
    comparison = [ordered]@{
      index = $ComparisonIndex
      baseRef = ('{0}-base-{1}' -f $Mode, $ComparisonIndex)
      headRef = ('{0}-head-{1}' -f $Mode, $ComparisonIndex)
      baseShortRef = ('base-{0:D2}' -f $ComparisonIndex)
      headShortRef = ('head-{0:D2}' -f $ComparisonIndex)
      baseSubject = ('Base subject {0}' -f $ComparisonIndex)
      headSubject = ('Head subject {0}' -f $ComparisonIndex)
    }
    sectionKind = 'overview'
    sectionOrdinal = 0
    label = if ($Mode -eq 'block-diagram') { 'Block Diagram Overview' } else { 'Front Panel Overview' }
    reportHtmlRelativePath = ('targets/001/history/{0}/Demo.vi-{1:D3}-artifacts/compare-report.html' -f $Mode, $ComparisonIndex)
    baseImageRelativePath = ('targets/001/history/{0}/Demo.vi-{1:D3}-artifacts/compare-report_files/{2}_1.png' -f $Mode, $ComparisonIndex, $(if ($Mode -eq 'block-diagram') { 'bd' } else { 'fp' }))
    headImageRelativePath = ('targets/001/history/{0}/Demo.vi-{1:D3}-artifacts/compare-report_files/{2}_2.png' -f $Mode, $ComparisonIndex, $(if ($Mode -eq 'block-diagram') { 'bd' } else { 'fp' }))
    baseByteLength = 4
    headByteLength = 4
    sortKey = ('Tooling/demo/Demo.vi|{0}|{1:D4}|00|0000|{2}' -f $Mode, $ComparisonIndex, $(if ($Mode -eq 'block-diagram') { 'block-diagram-overview' } else { 'front-panel-overview' }))
  }
}

function New-PreviewCard {
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$PreviewPairs,
    [Parameter(Mandatory = $true)]
    [int]$ComparisonIndex
  )

  $matchingPairs = @(
    $PreviewPairs |
      Where-Object { [int]$_.comparison.index -eq $ComparisonIndex -and [string]$_.mode -in @('front-panel', 'block-diagram') } |
      Sort-Object {
        switch ([string]$_.mode) {
          'front-panel' { 0 }
          'block-diagram' { 1 }
          default { 99 }
        }
      }
  )

  return [ordered]@{
    targetId = 'dynamic-demo-target'
    targetPath = 'Tooling/demo/Demo.vi'
    comparison = $matchingPairs[0].comparison
    changeDetails = [ordered]@{
      label = 'Change details'
      sourceMode = 'attributes'
      reportHtmlRelativePath = ('targets/001/history/attributes/Demo.vi-{0:D3}-artifacts/compare-report.html' -f $ComparisonIndex)
      includedCategories = $(if ($ComparisonIndex -eq 1) { @('Block Diagram Functional', 'VI Attribute') } else { @('VI Attribute') })
      groupCount = 1
      omittedGroupCount = 0
      sectionCount = $(if ($ComparisonIndex -eq 1) { 2 } else { 1 })
      detailCount = $(if ($ComparisonIndex -eq 1) { 4 } else { 1 })
      groups = @(
        [ordered]@{
          heading = $(if ($ComparisonIndex -eq 1) { 'Block Diagram objects' } else { 'VI Attribute - Miscellaneous' })
          sectionCount = $(if ($ComparisonIndex -eq 1) { 2 } else { 1 })
          detailCount = $(if ($ComparisonIndex -eq 1) { 4 } else { 1 })
          sampleDetails = $(if ($ComparisonIndex -eq 1) {
              @(
                'Property Node - moved : changed from "(-35,102)" to "(-55,77)"',
                'Tunnel - moved : changed from "(141,124)" to "(141,124)"',
                'Case Selector - moved : changed from "(141,143)" to "(141,143)"'
              )
            } else {
              @('VI Version : changed from "21.0" to "20.0"')
            })
          omittedDetailCount = $(if ($ComparisonIndex -eq 1) { 1 } else { 0 })
        }
      )
    }
    surfaces = @(
      $matchingPairs |
        ForEach-Object {
          [ordered]@{
            surfaceKind = [string]$_.mode
            surfaceLabel = if ([string]$_.mode -eq 'front-panel') { 'Front panel' } else { 'Block diagram' }
            reportHtmlRelativePath = [string]$_.reportHtmlRelativePath
            baseImageRelativePath = [string]$_.baseImageRelativePath
            headImageRelativePath = [string]$_.headImageRelativePath
          }
        }
    )
  }
}

function New-PublicationArtifactZip {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RootPath,
    [Parameter(Mandatory = $true)]
    [int]$PullRequestNumber,
    [Parameter(Mandatory = $true)]
    [string]$FinalStatus,
    [Parameter(Mandatory = $true)]
    [string]$CommentBody,
    [switch]$IncludePreviewManifest
  )

  $artifactRoot = Join-Path $RootPath 'artifact-src'
  $zipPath = Join-Path $RootPath 'artifact.zip'
  New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null

  $previewPairs = @(
    (New-PreviewPair -Mode 'front-panel' -ComparisonIndex 1),
    (New-PreviewPair -Mode 'block-diagram' -ComparisonIndex 1),
    (New-PreviewPair -Mode 'front-panel' -ComparisonIndex 2),
    (New-PreviewPair -Mode 'block-diagram' -ComparisonIndex 2)
  )
  $commentPreviewCards = @(
    (New-PreviewCard -PreviewPairs $previewPairs -ComparisonIndex 1),
    (New-PreviewCard -PreviewPairs $previewPairs -ComparisonIndex 2)
  )

  ([ordered]@{
      schema = 'comparevi-history/pr-run@v2'
      generatedAtUtc = '2026-03-17T00:00:00Z'
      pullRequest = [ordered]@{
        number = $PullRequestNumber
        htmlUrl = "https://github.com/example/repo/pull/$PullRequestNumber"
        baseRepository = 'LabVIEW-Community-CI-CD/labview-icon-editor-demo'
        baseRef = 'develop'
        baseSha = 'base-sha'
        headRepository = 'LabVIEW-Community-CI-CD/labview-icon-editor-demo'
        headRef = 'feature/history'
        headSha = 'head-sha'
        isFork = $false
      }
      prPolicy = [ordered]@{
        schema = 'comparevi-history/pr-policy@v2'
        path = 'C:/repo/.github/comparevi-history-pr-policy.json'
        applied = $true
        discovery = @{}
        execution = @{}
        reviewerSurface = @{}
        trust = @{}
      }
      executionContext = [ordered]@{
        selectionMode = 'dynamic-paths'
        forkBehavior = 'hosted-auto'
        fullSurface = 'artifact-index'
      }
      discovery = [ordered]@{
        schema = 'comparevi-history/changed-vi-discovery@v2'
        path = 'C:/results/changed-vi-discovery.json'
        status = 'ready'
        reason = 'selected-targets'
        changedViCount = 1
        eligibleChangedViCount = 1
        excludedViCount = 0
        selectedTargetCount = 1
        overflowed = $false
        overflowChangedViCount = 0
      }
      outputs = [ordered]@{
        resultsDir = 'C:/results'
        prRunPath = 'C:/results/pr-run.json'
        publicCommentPath = 'C:/results/pr-comment.md'
        publicStepSummaryPath = 'C:/results/pr-step-summary.md'
        targetRunsManifestPath = 'C:/results/pr-target-runs-manifest.json'
        previewManifestPath = $(if ($IncludePreviewManifest.IsPresent) { 'C:/results/pr-preview-manifest.json' } else { $null })
        indexMarkdownPath = 'C:/results/index.md'
        indexHtmlPath = 'C:/results/index.html'
        workflowRunUrl = 'https://github.com/example/repo/actions/runs/321'
        artifactName = 'comparevi-history-pr-diagnostics-321'
      }
        summary = [ordered]@{
          finalStatus = $FinalStatus
          finalReason = 'completed'
        changedViCount = 1
        eligibleChangedViCount = 1
        excludedViCount = 0
        selectedTargetCount = 1
        overflowed = $false
        overflowChangedViCount = 0
        executedTargetCount = 1
        failedTargetCount = 0
        totalProcessed = 5
        totalDiffs = 2
        previewPairCount = $(if ($IncludePreviewManifest.IsPresent) { 4 } else { 0 })
        rawPreviewPairCount = $(if ($IncludePreviewManifest.IsPresent) { 4 } else { 0 })
        reviewerPreviewPairCount = $(if ($IncludePreviewManifest.IsPresent) { 2 } else { 0 })
        reviewerPreviewCardCount = $(if ($IncludePreviewManifest.IsPresent) { 2 } else { 0 })
        reviewerPreviewSurfaceCount = $(if ($IncludePreviewManifest.IsPresent) { 4 } else { 0 })
        commentPreviewPairCap = 4
        commentPreviewPairCount = $(if ($IncludePreviewManifest.IsPresent) { 2 } else { 0 })
        commentPreviewPairOmittedCount = 0
        commentPreviewCardCount = $(if ($IncludePreviewManifest.IsPresent) { 2 } else { 0 })
        commentPreviewSurfaceCount = $(if ($IncludePreviewManifest.IsPresent) { 4 } else { 0 })
        commentCardSelectionPolicy = 'reviewer-multisurface@v1'
        indexPreviewPairCap = 12
        indexPreviewPairCount = $(if ($IncludePreviewManifest.IsPresent) { 2 } else { 0 })
        indexPreviewPairOmittedCount = 0
        indexPreviewCardCount = $(if ($IncludePreviewManifest.IsPresent) { 2 } else { 0 })
        indexPreviewSurfaceCount = $(if ($IncludePreviewManifest.IsPresent) { 4 } else { 0 })
        indexCardSelectionPolicy = 'reviewer-multisurface@v1'
      }
      excludedViFiles = @()
      targets = @()
    } | ConvertTo-Json -Depth 64) | Set-Content -LiteralPath (Join-Path $artifactRoot 'pr-run.json') -Encoding utf8
  $CommentBody | Set-Content -LiteralPath (Join-Path $artifactRoot 'pr-comment.md') -Encoding utf8

  if ($IncludePreviewManifest.IsPresent) {
    foreach ($previewPair in $previewPairs) {
      foreach ($relativePath in @([string]$previewPair.baseImageRelativePath, [string]$previewPair.headImageRelativePath)) {
        $fullPath = Join-Path $artifactRoot ($relativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        New-Item -ItemType Directory -Path (Split-Path -Parent $fullPath) -Force | Out-Null
        [System.IO.File]::WriteAllBytes($fullPath, @(0xCA, 0xFE, 0xBA, 0xBE))
      }
    }

    ([ordered]@{
        schema = 'comparevi-history/pr-preview-manifest@v1'
        generatedAtUtc = '2026-03-17T00:00:00Z'
        targetRunsManifestPath = 'C:/results/pr-target-runs-manifest.json'
        resultsDir = 'C:/results'
        summary = [ordered]@{
          targetCount = 1
          previewPairCount = 4
          rawPreviewPairCount = 4
          reviewerPreviewPairCount = 2
          reviewerPreviewCardCount = 2
          reviewerPreviewSurfaceCount = 4
          commentPreviewPairCap = 4
          commentSelectionPolicy = 'reviewer-canonical@v1'
          commentPreviewPairCount = 2
          commentPreviewPairOmittedCount = 0
          commentPreviewCardCount = 2
          commentPreviewSurfaceCount = 4
          commentCardSelectionPolicy = 'reviewer-multisurface@v1'
          indexPreviewPairCap = 12
          indexSelectionPolicy = 'reviewer-canonical@v1'
          indexPreviewPairCount = 2
          indexPreviewPairOmittedCount = 0
          indexPreviewCardCount = 2
          indexPreviewSurfaceCount = 4
          indexCardSelectionPolicy = 'reviewer-multisurface@v1'
        }
        targets = @(
          [ordered]@{
            targetId = 'dynamic-demo-target'
            targetPath = 'Tooling/demo/Demo.vi'
            finalStatus = 'succeeded'
            finalReason = 'completed'
            previewPairCount = 4
            previewPairs = $previewPairs
          }
        )
        previewPairs = $previewPairs
        commentPreviewPairs = @($previewPairs | Where-Object { [int]$_.comparison.index -in @(1, 2) -and [string]$_.mode -eq 'front-panel' })
        indexPreviewPairs = @($previewPairs | Where-Object { [int]$_.comparison.index -in @(1, 2) -and [string]$_.mode -eq 'front-panel' })
        reviewerPreviewCards = $commentPreviewCards
        commentPreviewCards = $commentPreviewCards
        indexPreviewCards = $commentPreviewCards
      } | ConvertTo-Json -Depth 64) | Set-Content -LiteralPath (Join-Path $artifactRoot 'pr-preview-manifest.json') -Encoding utf8
  }

  if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
  }
  Compress-Archive -Path (Join-Path $artifactRoot '*') -DestinationPath $zipPath -Force
  return $zipPath
}

try {
  $global:MockScenario = @{}
  $global:RecordedPosts = New-Object System.Collections.Generic.List[object]
  $global:RecordedPatches = New-Object System.Collections.Generic.List[object]
  $global:RecordedContentWrites = New-Object System.Collections.Generic.List[object]
  $global:RecordedRefCreates = New-Object System.Collections.Generic.List[object]
  $global:MockContentState = @{}

  function Invoke-RestMethod {
    param(
      [string]$Method,
      [string]$Uri,
      [hashtable]$Headers,
      [string]$Body,
      [string]$ContentType
    )

    $methodKey = if ([string]::IsNullOrWhiteSpace($Method)) { 'Get' } else { $Method }
    if ($Uri -like 'https://api.github.com/repos/*/actions/runs/*/artifacts?per_page=100') {
      return @{
        artifacts = @(
          @{
            name = $global:MockScenario.ArtifactName
            archive_download_url = 'https://example.test/artifact.zip'
          }
        )
      }
    }

    if ($Uri -like 'https://api.github.com/repos/*/issues/*/comments?per_page=100&page=1') {
      return @($global:MockScenario.ExistingComments)
    }

    if ($methodKey -eq 'Get' -and $Uri -eq 'https://api.github.com/repos/LabVIEW-Community-CI-CD/labview-icon-editor-demo') {
      return @{
        default_branch = 'develop'
      }
    }

    if ($methodKey -eq 'Get' -and $Uri -eq 'https://api.github.com/repos/LabVIEW-Community-CI-CD/labview-icon-editor-demo/git/ref/heads/comparevi-history-pr-previews') {
      return $null
    }

    if ($methodKey -eq 'Get' -and $Uri -eq 'https://api.github.com/repos/LabVIEW-Community-CI-CD/labview-icon-editor-demo/git/ref/heads/develop') {
      return @{
        object = @{
          sha = 'develop-sha'
        }
      }
    }

    if ($methodKey -eq 'Post' -and $Uri -eq 'https://api.github.com/repos/LabVIEW-Community-CI-CD/labview-icon-editor-demo/git/refs') {
      $payload = $Body | ConvertFrom-Json -Depth 20
      $global:RecordedRefCreates.Add($payload) | Out-Null
      return @{
        object = @{
          sha = 'preview-branch-sha'
        }
      }
    }

    if ($methodKey -eq 'Get' -and $Uri -like 'https://api.github.com/repos/LabVIEW-Community-CI-CD/labview-icon-editor-demo/contents/*') {
      $encodedPath = $Uri.Split('/contents/')[1].Split('?')[0]
      if ($global:MockContentState.ContainsKey($encodedPath)) {
        return @{
          sha = [string]$global:MockContentState[$encodedPath]
        }
      }
      return $null
    }

    if ($methodKey -eq 'Put' -and $Uri -like 'https://api.github.com/repos/LabVIEW-Community-CI-CD/labview-icon-editor-demo/contents/*') {
      $encodedPath = $Uri.Split('/contents/')[1]
      $payload = $Body | ConvertFrom-Json -Depth 20
      $global:RecordedContentWrites.Add([pscustomobject]@{
          path = $encodedPath
          payload = $payload
        }) | Out-Null
      $global:MockContentState[$encodedPath] = 'sha-' + ($global:RecordedContentWrites.Count.ToString('000'))
      return @{
        content = @{
          sha = [string]$global:MockContentState[$encodedPath]
        }
      }
    }

    if ($Uri -like 'https://api.github.com/repos/*/issues/*/comments?per_page=100&page=2') {
      return @()
    }

    if ($methodKey -eq 'Post' -and $Uri -like 'https://api.github.com/repos/*/issues/*/comments') {
      $payload = $Body | ConvertFrom-Json -Depth 10
      $global:RecordedPosts.Add($payload) | Out-Null
      return @{
        id = 991
        html_url = 'https://github.com/example/repo/pull/55#issuecomment-991'
      }
    }

    if ($methodKey -eq 'Patch' -and $Uri -like 'https://api.github.com/repos/*/issues/comments/*') {
      $payload = $Body | ConvertFrom-Json -Depth 10
      $global:RecordedPatches.Add($payload) | Out-Null
      return @{
        id = 771
        html_url = 'https://github.com/example/repo/pull/55#issuecomment-771'
      }
    }

    throw "Unexpected REST call: $methodKey $Uri"
  }

  function Invoke-WebRequest {
    param(
      [string]$Uri,
      [hashtable]$Headers,
      [string]$OutFile
    )

    Copy-Item -LiteralPath $global:MockScenario.ZipPath -Destination $OutFile -Force
  }

  $createRoot = Join-Path $tempRoot 'create'
  New-Item -ItemType Directory -Path $createRoot -Force | Out-Null
  $createComment = @'
<!-- comparevi-history:pull-request-diagnostics -->
## comparevi-history PR diagnostics

- Final status: `succeeded`
- Workflow run: [view run](https://github.com/example/repo/actions/runs/321)

The full unsuppressed history suite lives in the uploaded artifact bundle. Use the workflow run entry above, download the artifact, and start at `index.html` or `index.md`.
'@
  $createZipPath = New-PublicationArtifactZip -RootPath $createRoot -PullRequestNumber 55 -FinalStatus 'succeeded' -CommentBody $createComment -IncludePreviewManifest
  $global:MockScenario = @{
    ArtifactName = 'comparevi-history-pr-diagnostics-321'
    ExistingComments = @()
    ZipPath = $createZipPath
  }

  $createOutputPath = Join-Path $createRoot 'publish.out'
  $createReceiptJson = & $scriptPath `
    -Repository 'LabVIEW-Community-CI-CD/labview-icon-editor-demo' `
    -WorkflowRunId '321' `
    -GitHubToken 'token' `
    -ResultsDir (Join-Path $createRoot 'results') `
    -GitHubOutputPath $createOutputPath

  $createReceipt = $createReceiptJson | ConvertFrom-Json -Depth 64
  if ($createReceipt.schema -ne 'comparevi-history/pr-comment-publication@v1') {
    throw 'Publication receipt schema mismatch.'
  }
  if ($createReceipt.summary.status -ne 'succeeded' -or $createReceipt.summary.commentAction -ne 'created') {
    throw 'Expected the first publication path to create a sticky PR comment.'
  }
  if ([string]$createReceipt.previewPublication.status -ne 'succeeded') {
    throw 'Expected preview publication to succeed for the first path.'
  }
  if ([int]$createReceipt.previewPublication.previewPairCount -ne 2 -or
    [int]$createReceipt.previewPublication.publishedSurfaceCount -ne 4 -or
    [int]$createReceipt.previewPublication.publishedImageCount -ne 8) {
    throw 'Preview publication counts mismatch for the first path.'
  }
  if ($global:RecordedPosts.Count -ne 1) {
    throw 'Expected one PR comment creation request.'
  }
  if ($global:RecordedPosts[0].body -notmatch [regex]::Escape('<!-- comparevi-history:pull-request-diagnostics -->')) {
    throw 'Created PR comment body is missing the sticky marker.'
  }
  if ([regex]::Matches($global:RecordedPosts[0].body, [regex]::Escape('<h4><code>Tooling/demo/Demo.vi</code></h4>')).Count -ne 2) {
    throw 'Created PR comment body should render two reviewer-canonical preview gallery sections.'
  }
  if ([regex]::Matches($global:RecordedPosts[0].body, [regex]::Escape('<p>History pair 1</p>')).Count -ne 1 -or
    [regex]::Matches($global:RecordedPosts[0].body, [regex]::Escape('<p>History pair 2</p>')).Count -ne 1) {
    throw 'Created PR comment body should render stable history-pair subtitles.'
  }
  if ($global:RecordedPosts[0].body -notmatch [regex]::Escape('<p><code>base-01 -&gt; head-01</code></p>') -or
    $global:RecordedPosts[0].body -notmatch [regex]::Escape('Base subject 1') -or
    $global:RecordedPosts[0].body -notmatch [regex]::Escape('Head subject 1')) {
    throw 'Created PR comment body should surface revision refs and commit-subject context.'
  }
  if ([regex]::Matches($global:RecordedPosts[0].body, [regex]::Escape('<p><strong>Front panel</strong></p>')).Count -ne 2 -or
    [regex]::Matches($global:RecordedPosts[0].body, [regex]::Escape('<p><strong>Block diagram</strong></p>')).Count -ne 2) {
    throw 'Created PR comment body should render both front-panel and block-diagram surfaces for each history pair.'
  }
  if ([regex]::Matches($global:RecordedPosts[0].body, [regex]::Escape('<p><strong>Change details</strong></p>')).Count -ne 2 -or
    $global:RecordedPosts[0].body -notmatch [regex]::Escape('Block Diagram objects') -or
    $global:RecordedPosts[0].body -notmatch [regex]::Escape('+1 more details in report') -or
    $global:RecordedPosts[0].body -notmatch [regex]::Escape('VI Attribute - Miscellaneous') -or
    $global:RecordedPosts[0].body -notmatch [regex]::Escape('VI Version : changed from &quot;21.0&quot; to &quot;20.0&quot;') -or
    $global:RecordedPosts[0].body -notmatch [regex]::Escape('open change details report')) {
    throw 'Created PR comment body should render bounded change-detail summaries from the attributes compare report.'
  }
  if ([regex]::Matches($global:RecordedPosts[0].body, 'https://raw\.githubusercontent\.com/.+?/base\.png').Count -ne 4 -or
    [regex]::Matches($global:RecordedPosts[0].body, 'https://raw\.githubusercontent\.com/.+?/head\.png').Count -ne 4) {
    throw 'Created PR comment body should embed eight preview image URLs.'
  }
  if ($global:RecordedPosts[0].body -match [regex]::Escape('| front-panel |') -or
    $global:RecordedPosts[0].body -match [regex]::Escape('| block-diagram |') -or
    $global:RecordedPosts[0].body -match [regex]::Escape('| attributes |') -or
    $global:RecordedPosts[0].body -match [regex]::Escape('Front Panel Overview')) {
    throw 'Created PR comment body should not surface execution modes or report captions in reviewer-facing preview headings.'
  }
  if ($global:RecordedRefCreates.Count -ne 1) {
    throw 'Expected one preview branch creation request.'
  }
  if ($global:RecordedContentWrites.Count -ne 9) {
    throw 'Expected preview publication to write eight images and one manifest.'
  }

  $publishedPairOrder = @(
    $createReceipt.previewPublication.commentPreviewPairs |
      ForEach-Object { '{0}:{1}' -f [string]$_.mode, [int]$_.comparison.index }
  ) -join ','
  if ($publishedPairOrder -ne 'front-panel:1,front-panel:2') {
    throw "Preview publication order mismatch: $publishedPairOrder"
  }
  if ($createReceipt.previewPublication.commentPreviewCards.Count -ne 2 -or
    (@($createReceipt.previewPublication.commentPreviewCards[0].surfaces | ForEach-Object { [string]$_.surfaceKind }) -join ',') -ne 'front-panel,block-diagram') {
    throw 'Preview publication should retain reviewer cards with both front-panel and block-diagram surfaces.'
  }
  if ([string]$createReceipt.previewPublication.commentPreviewCards[0].changeDetails.label -ne 'Change details' -or
    [string]$createReceipt.previewPublication.commentPreviewCards[0].changeDetails.groups[0].heading -ne 'Block Diagram objects' -or
    [string]$createReceipt.previewPublication.commentPreviewCards[1].changeDetails.groups[0].heading -ne 'VI Attribute - Miscellaneous') {
    throw 'Preview publication should retain reviewer-facing change-detail summaries.'
  }

  $writeOrder = @(
    $global:RecordedContentWrites |
      ForEach-Object { [string]$_.path }
  )
  $expectedImagePrefixes = @(
    '.comparevi-history/pr-diagnostics/previews/pull-request-00055/workflow-run-321/001-history-pair-01/01-front-panel/base.png',
    '.comparevi-history/pr-diagnostics/previews/pull-request-00055/workflow-run-321/001-history-pair-01/01-front-panel/head.png',
    '.comparevi-history/pr-diagnostics/previews/pull-request-00055/workflow-run-321/001-history-pair-01/02-block-diagram/base.png',
    '.comparevi-history/pr-diagnostics/previews/pull-request-00055/workflow-run-321/001-history-pair-01/02-block-diagram/head.png',
    '.comparevi-history/pr-diagnostics/previews/pull-request-00055/workflow-run-321/002-history-pair-02/01-front-panel/base.png',
    '.comparevi-history/pr-diagnostics/previews/pull-request-00055/workflow-run-321/002-history-pair-02/01-front-panel/head.png',
    '.comparevi-history/pr-diagnostics/previews/pull-request-00055/workflow-run-321/002-history-pair-02/02-block-diagram/base.png',
    '.comparevi-history/pr-diagnostics/previews/pull-request-00055/workflow-run-321/002-history-pair-02/02-block-diagram/head.png'
  )
  foreach ($index in 0..7) {
    if ([string]$writeOrder[$index] -ne $expectedImagePrefixes[$index]) {
      throw "Published preview write order mismatch at position $index."
    }
  }

  $createOutputText = Get-Content -LiteralPath $createOutputPath -Raw
  foreach ($requiredKey in @(
      'publication-receipt-path=',
      'publication-status=succeeded',
      'publication-reason=comment-created',
      'comment-id=991',
      'comment-url=https://github.com/example/repo/pull/55#issuecomment-991',
      'preview-publication-status=succeeded',
      'preview-publication-reason=preview-images-published',
      'preview-pair-count=2',
      'published-image-count=8',
      'published-surface-count=4'
    )) {
    if ($createOutputText -notmatch [regex]::Escape($requiredKey)) {
      throw "Expected GitHub output '$requiredKey'."
    }
  }

  $updateRoot = Join-Path $tempRoot 'update'
  New-Item -ItemType Directory -Path $updateRoot -Force | Out-Null
  $updatedComment = @'
<!-- comparevi-history:pull-request-diagnostics -->
## comparevi-history PR diagnostics

- Final status: `blocked`
- Final reason: `max-changed-vi-count-exceeded`
'@
  $updateZipPath = New-PublicationArtifactZip -RootPath $updateRoot -PullRequestNumber 55 -FinalStatus 'blocked' -CommentBody $updatedComment
  $global:MockScenario = @{
    ArtifactName = 'comparevi-history-pr-diagnostics-654'
    ExistingComments = @(
      @{
        id = 771
        html_url = 'https://github.com/example/repo/pull/55#issuecomment-771'
        body = "<!-- comparevi-history:pull-request-diagnostics -->`nold body"
        updated_at = '2026-03-17T00:00:00Z'
      }
    )
    ZipPath = $updateZipPath
  }

  $updateReceiptJson = & $scriptPath `
    -Repository 'LabVIEW-Community-CI-CD/labview-icon-editor-demo' `
    -WorkflowRunId '654' `
    -ArtifactName 'comparevi-history-pr-diagnostics-654' `
    -GitHubToken 'token' `
    -ResultsDir (Join-Path $updateRoot 'results')

  $updateReceipt = $updateReceiptJson | ConvertFrom-Json -Depth 64
  if ($updateReceipt.summary.status -ne 'succeeded' -or $updateReceipt.summary.commentAction -ne 'updated') {
    throw 'Expected the second publication path to update the existing sticky PR comment.'
  }
  if ($global:RecordedPatches.Count -ne 1) {
    throw 'Expected one PR comment update request.'
  }
  if ($global:RecordedPatches[0].body -notmatch [regex]::Escape('Final status: `blocked`')) {
    throw 'Updated PR comment body mismatch.'
  }

  $failureRoot = Join-Path $tempRoot 'failure'
  New-Item -ItemType Directory -Path $failureRoot -Force | Out-Null
  $global:MockScenario = @{
    ArtifactName = 'comparevi-history-pr-diagnostics-999'
    ExistingComments = @()
    ZipPath = $createZipPath
  }

  $failureOutputPath = Join-Path $failureRoot 'publish.out'
  $failedAsExpected = $false
  try {
    & $scriptPath `
      -Repository 'LabVIEW-Community-CI-CD/labview-icon-editor-demo' `
      -WorkflowRunId '999' `
      -ArtifactName 'comparevi-history-pr-diagnostics-missing' `
      -GitHubToken 'token' `
      -ResultsDir (Join-Path $failureRoot 'results') `
      -GitHubOutputPath $failureOutputPath | Out-Null
  } catch {
    $failedAsExpected = $true
  }

  if (-not $failedAsExpected) {
    throw 'Publication should fail closed when the expected artifact is missing.'
  }
  $failureReceiptPath = Join-Path $failureRoot 'results' 'pr-comment-publication.json'
  if (-not (Test-Path -LiteralPath $failureReceiptPath -PathType Leaf)) {
    throw 'Publication failure should still write a receipt.'
  }
  $failureReceipt = Get-Content -LiteralPath $failureReceiptPath -Raw | ConvertFrom-Json -Depth 64
  if ($failureReceipt.summary.status -ne 'failed') {
    throw 'Failure receipt status mismatch.'
  }
  if ($failureReceipt.summary.reason -notmatch 'did not publish artifact') {
    throw 'Failure receipt reason mismatch.'
  }
} finally {
  Remove-Item function:Invoke-RestMethod -ErrorAction SilentlyContinue
  Remove-Item function:Invoke-WebRequest -ErrorAction SilentlyContinue
  Remove-Variable MockScenario, RecordedPosts, RecordedPatches, RecordedContentWrites, RecordedRefCreates, MockContentState -Scope Global -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
