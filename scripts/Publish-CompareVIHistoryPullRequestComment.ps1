param(
  [Parameter(Mandatory = $true)]
  [string]$Repository,
  [Parameter(Mandatory = $true)]
  [string]$WorkflowRunId,
  [Parameter(Mandatory = $true)]
  [string]$GitHubToken,
  [string]$ArtifactName,
  [string]$ResultsDir = 'tests/results/pr-diagnostics/publish',
  [string]$StickyMarker = '<!-- comparevi-history:pull-request-diagnostics -->',
  [string]$PreviewBranch = 'comparevi-history-pr-previews',
  [string]$PreviewRoot = '.comparevi-history/pr-diagnostics/previews',
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

function Get-OptionalString {
  param([AllowNull()]$Value)

  if ($null -eq $Value) {
    return $null
  }

  $stringValue = [string]$Value
  if ([string]::IsNullOrWhiteSpace($stringValue)) {
    return $null
  }

  return $stringValue.Trim()
}

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][string]$Path)

  $raw = Get-Content -LiteralPath $Path -Raw
  if ([string]::IsNullOrWhiteSpace($raw)) {
    throw "JSON file was empty: $Path"
  }

  return $raw | ConvertFrom-Json -Depth 100
}

function Get-NestedValue {
  param(
    [AllowNull()]
    [object]$Object,
    [Parameter(Mandatory = $true)]
    [string[]]$Path,
    [AllowNull()]
    $Default = $null
  )

  $current = $Object
  foreach ($segment in $Path) {
    if ($null -eq $current) {
      return $Default
    }

    if ($current -is [System.Collections.IDictionary]) {
      if (-not $current.Contains($segment)) {
        return $Default
      }

      $current = $current[$segment]
      continue
    }

    $property = $current.PSObject.Properties[$segment]
    if ($null -eq $property) {
      return $Default
    }

    $current = $property.Value
  }

  if ($null -eq $current) {
    return $Default
  }

  return $current
}

function Get-GitHubHeaders {
  return @{
    Accept = 'application/vnd.github+json'
    Authorization = "Bearer $GitHubToken"
    'User-Agent' = 'comparevi-history-pr-publish'
    'X-GitHub-Api-Version' = '2022-11-28'
  }
}

function Invoke-GitHubJson {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Method,
    [Parameter(Mandatory = $true)]
    [string]$Uri,
    [AllowNull()]
    $Body = $null
  )

  $invokeArgs = @{
    Method = $Method
    Uri = $Uri
    Headers = Get-GitHubHeaders
  }
  if ($null -ne $Body) {
    $invokeArgs.Body = ($Body | ConvertTo-Json -Depth 20)
    $invokeArgs.ContentType = 'application/json'
  }

  return Invoke-RestMethod @invokeArgs
}

function Invoke-GitHubJsonOptional {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Method,
    [Parameter(Mandatory = $true)]
    [string]$Uri,
    [AllowNull()]
    $Body = $null
  )

  try {
    return Invoke-GitHubJson -Method $Method -Uri $Uri -Body $Body
  } catch {
    $responseProperty = $_.Exception.PSObject.Properties['Response']
    $response = if ($null -eq $responseProperty) { $null } else { $responseProperty.Value }
    if ($null -ne $response -and [int]$response.StatusCode -eq 404) {
      return $null
    }

    throw
  }
}

function Find-Artifact {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepositorySlug,
    [Parameter(Mandatory = $true)]
    [string]$RunId,
    [Parameter(Mandatory = $true)]
    [string]$RequestedArtifactName
  )

  $uri = "https://api.github.com/repos/$RepositorySlug/actions/runs/$RunId/artifacts?per_page=100"
  $response = Invoke-GitHubJson -Method Get -Uri $uri
  $artifacts = @($response.artifacts | Where-Object { $null -ne $_ })
  $exact = @($artifacts | Where-Object { [string]$_.name -eq $RequestedArtifactName } | Select-Object -First 1)
  if ($exact) {
    return $exact
  }

  return @($artifacts | Where-Object { [string]$_.name -like "$RequestedArtifactName*" } | Select-Object -First 1)
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

function ConvertTo-Slug {
  param(
    [AllowNull()]
    [string]$Value,
    [string]$Fallback = 'preview'
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $Fallback
  }

  $slug = $Value.ToLowerInvariant() -replace '[^a-z0-9]+', '-'
  $slug = $slug.Trim('-')
  if ([string]::IsNullOrWhiteSpace($slug)) {
    return $Fallback
  }

  return $slug
}

function ConvertTo-HtmlText {
  param([AllowNull()][string]$Value)

  if ($null -eq $Value) {
    return ''
  }

  return [System.Net.WebUtility]::HtmlEncode($Value)
}

function ConvertTo-ShortRef {
  param([AllowNull()][string]$Ref)

  $refValue = Get-OptionalString -Value $Ref
  if ([string]::IsNullOrWhiteSpace($refValue)) {
    return $null
  }

  if ($refValue.Length -le 12) {
    return $refValue
  }

  return $refValue.Substring(0, 12)
}

function Get-ReviewerPreviewComparisonIndex {
  param([Parameter(Mandatory = $true)][object]$PreviewPair)

  return [int](Get-NestedValue -Object $PreviewPair -Path @('comparison', 'index') -Default 0)
}

function Get-ReviewerPreviewRevisionContext {
  param([Parameter(Mandatory = $true)][object]$PreviewPair)

  $baseShortRef = Get-OptionalString -Value (Get-NestedValue -Object $PreviewPair -Path @('comparison', 'baseShortRef'))
  if ([string]::IsNullOrWhiteSpace($baseShortRef)) {
    $baseShortRef = ConvertTo-ShortRef -Ref (Get-OptionalString -Value (Get-NestedValue -Object $PreviewPair -Path @('comparison', 'baseRef')))
  }

  $headShortRef = Get-OptionalString -Value (Get-NestedValue -Object $PreviewPair -Path @('comparison', 'headShortRef'))
  if ([string]::IsNullOrWhiteSpace($headShortRef)) {
    $headShortRef = ConvertTo-ShortRef -Ref (Get-OptionalString -Value (Get-NestedValue -Object $PreviewPair -Path @('comparison', 'headRef')))
  }

  if ([string]::IsNullOrWhiteSpace($baseShortRef) -and [string]::IsNullOrWhiteSpace($headShortRef)) {
    return $null
  }

  if ([string]::IsNullOrWhiteSpace($baseShortRef)) {
    return $headShortRef
  }

  if ([string]::IsNullOrWhiteSpace($headShortRef)) {
    return $baseShortRef
  }

  return '{0} -> {1}' -f $baseShortRef, $headShortRef
}

function Get-ReviewerPreviewDetailLines {
  param([Parameter(Mandatory = $true)][object]$PreviewPair)

  $lines = New-Object System.Collections.Generic.List[string]
  $baseSubject = Get-OptionalString -Value (Get-NestedValue -Object $PreviewPair -Path @('comparison', 'baseSubject'))
  if (-not [string]::IsNullOrWhiteSpace($baseSubject)) {
    $lines.Add('Base: {0}' -f $baseSubject) | Out-Null
  }

  $headSubject = Get-OptionalString -Value (Get-NestedValue -Object $PreviewPair -Path @('comparison', 'headSubject'))
  if (-not [string]::IsNullOrWhiteSpace($headSubject)) {
    $lines.Add('Head: {0}' -f $headSubject) | Out-Null
  }

  return @($lines | ForEach-Object { $_ })
}

function Get-ReviewerPreviewTitle {
  param([Parameter(Mandatory = $true)][object]$PreviewPair)

  return [string]$PreviewPair.targetPath
}

function Get-ReviewerPreviewSubtitle {
  param([Parameter(Mandatory = $true)][object]$PreviewPair)

  return 'History pair {0}' -f (Get-ReviewerPreviewComparisonIndex -PreviewPair $PreviewPair)
}

function ConvertTo-GitHubContentPath {
  param([Parameter(Mandatory = $true)][string]$Path)

  return (($Path -split '[\\/]' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) | ForEach-Object {
      [uri]::EscapeDataString($_)
    }) -join '/'
}

function Get-RepositoryInfo {
  param([Parameter(Mandatory = $true)][string]$RepositorySlug)

  return Invoke-GitHubJson -Method Get -Uri "https://api.github.com/repos/$RepositorySlug"
}

function Get-GitRef {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepositorySlug,
    [Parameter(Mandatory = $true)]
    [string]$BranchName
  )

  $encodedRef = ConvertTo-GitHubContentPath -Path ("heads/$BranchName")
  return Invoke-GitHubJsonOptional -Method Get -Uri "https://api.github.com/repos/$RepositorySlug/git/ref/$encodedRef"
}

function Ensure-PreviewBranch {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepositorySlug,
    [Parameter(Mandatory = $true)]
    [string]$BranchName
  )

  $existing = Get-GitRef -RepositorySlug $RepositorySlug -BranchName $BranchName
  if ($null -ne $existing) {
    return [string]$existing.object.sha
  }

  $repositoryInfo = Get-RepositoryInfo -RepositorySlug $RepositorySlug
  $defaultBranch = [string]$repositoryInfo.default_branch
  if ([string]::IsNullOrWhiteSpace($defaultBranch)) {
    throw "Repository '$RepositorySlug' did not declare a default branch."
  }

  $defaultRef = Get-GitRef -RepositorySlug $RepositorySlug -BranchName $defaultBranch
  if ($null -eq $defaultRef) {
    throw "Failed to resolve default branch '$defaultBranch' for repository '$RepositorySlug'."
  }

  $created = Invoke-GitHubJson -Method Post -Uri "https://api.github.com/repos/$RepositorySlug/git/refs" -Body @{
    ref = "refs/heads/$BranchName"
    sha = [string]$defaultRef.object.sha
  }

  return [string]$created.object.sha
}

function Get-RepositoryContent {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepositorySlug,
    [Parameter(Mandatory = $true)]
    [string]$BranchName,
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $encodedPath = ConvertTo-GitHubContentPath -Path $Path
  $uri = "https://api.github.com/repos/$RepositorySlug/contents/${encodedPath}?ref=$([uri]::EscapeDataString($BranchName))"
  return Invoke-GitHubJsonOptional -Method Get -Uri $uri
}

function Set-RepositoryContent {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepositorySlug,
    [Parameter(Mandatory = $true)]
    [string]$BranchName,
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [Parameter(Mandatory = $true)]
    [byte[]]$Bytes,
    [Parameter(Mandatory = $true)]
    [string]$Message
  )

  $existing = Get-RepositoryContent -RepositorySlug $RepositorySlug -BranchName $BranchName -Path $Path
  $encodedPath = ConvertTo-GitHubContentPath -Path $Path
  $body = [ordered]@{
    message = $Message
    content = [Convert]::ToBase64String($Bytes)
    branch = $BranchName
  }
  if ($null -ne $existing) {
    $body.sha = [string]$existing.sha
  }

  return Invoke-GitHubJson -Method Put -Uri "https://api.github.com/repos/$RepositorySlug/contents/$encodedPath" -Body $body
}

function ConvertTo-RawGitHubUrl {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepositorySlug,
    [Parameter(Mandatory = $true)]
    [string]$BranchName,
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  return 'https://raw.githubusercontent.com/{0}/{1}/{2}' -f $RepositorySlug, $BranchName, ($Path -replace '\\', '/')
}

function ConvertTo-BlobGitHubUrl {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepositorySlug,
    [Parameter(Mandatory = $true)]
    [string]$BranchName,
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  return 'https://github.com/{0}/blob/{1}/{2}' -f $RepositorySlug, $BranchName, ($Path -replace '\\', '/')
}

function New-CommentPreviewMarkdown {
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$PreviewPairs,
    [AllowNull()]
    [string]$RunUrl
  )

  if ($PreviewPairs.Count -eq 0) {
    return ''
  }

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('### Preview gallery') | Out-Null
  $lines.Add('') | Out-Null
  foreach ($previewPair in $PreviewPairs) {
    $title = Get-ReviewerPreviewTitle -PreviewPair $previewPair
    $subtitle = Get-ReviewerPreviewSubtitle -PreviewPair $previewPair
    $revisionContext = Get-ReviewerPreviewRevisionContext -PreviewPair $previewPair
    $detailLines = @(Get-ReviewerPreviewDetailLines -PreviewPair $previewPair)
    $detailHtml = if ($detailLines.Count -eq 0) {
      ''
    } else {
      '<div class="comparevi-preview-history">' + (($detailLines | ForEach-Object { '<p>' + (ConvertTo-HtmlText $_) + '</p>' }) -join '') + '</div>'
    }
    $baseUrl = [string]$previewPair.baseImageUrl
    $headUrl = [string]$previewPair.headImageUrl
    $linkUrl = if ([string]::IsNullOrWhiteSpace($RunUrl)) { $headUrl } else { $RunUrl }
    $baseAlt = '{0} base' -f $subtitle
    $headAlt = '{0} head' -f $subtitle
    $lines.Add(('<h4><code>{0}</code></h4>' -f (ConvertTo-HtmlText $title))) | Out-Null
    $lines.Add(('<p>{0}</p>' -f (ConvertTo-HtmlText $subtitle))) | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($revisionContext)) {
      $lines.Add(('<p><code>{0}</code></p>' -f (ConvertTo-HtmlText $revisionContext))) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($detailHtml)) {
      $lines.Add($detailHtml) | Out-Null
    }
    $lines.Add('') | Out-Null
    $lines.Add('<table>') | Out-Null
    $lines.Add('<thead><tr><th>Base</th><th>Head</th></tr></thead>') | Out-Null
    $lines.Add('<tbody><tr>') | Out-Null
    $lines.Add(('<td><a href="{0}"><img alt="{1}" src="{2}" width="320"></a></td>' -f (ConvertTo-HtmlText $linkUrl), (ConvertTo-HtmlText $baseAlt), (ConvertTo-HtmlText $baseUrl))) | Out-Null
    $lines.Add(('<td><a href="{0}"><img alt="{1}" src="{2}" width="320"></a></td>' -f (ConvertTo-HtmlText $linkUrl), (ConvertTo-HtmlText $headAlt), (ConvertTo-HtmlText $headUrl))) | Out-Null
    $lines.Add('</tr></tbody>') | Out-Null
    $lines.Add('</table>') | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($RunUrl)) {
      $lines.Add(('<p><a href="{0}">workflow run</a></p>' -f (ConvertTo-HtmlText $RunUrl))) | Out-Null
    }
    $lines.Add('') | Out-Null
  }

  return $lines -join "`n"
}

function Insert-PreviewGallery {
  param(
    [Parameter(Mandatory = $true)]
    [string]$CommentBody,
    [Parameter(Mandatory = $true)]
    [string]$PreviewMarkdown
  )

  if ([string]::IsNullOrWhiteSpace($PreviewMarkdown)) {
    return $CommentBody
  }

  $footer = 'The full unsuppressed history suite lives in the uploaded artifact bundle. Use the workflow run entry above, download the artifact, and start at `index.html` or `index.md`.'
  if ($CommentBody.Contains($footer)) {
    return $CommentBody.Replace($footer, ($PreviewMarkdown + "`n`n" + $footer))
  }

  return ($CommentBody.TrimEnd() + "`n`n" + $PreviewMarkdown + "`n")
}

function Publish-CommentPreviewSurface {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepositorySlug,
    [Parameter(Mandatory = $true)]
    [string]$BranchName,
    [Parameter(Mandatory = $true)]
    [string]$RootPath,
    [Parameter(Mandatory = $true)]
    [string]$ExecutionRunId,
    [Parameter(Mandatory = $true)]
    [string]$ArtifactRoot,
    [Parameter(Mandatory = $true)]
    [object]$PreviewManifest
  )

  Ensure-PreviewBranch -RepositorySlug $RepositorySlug -BranchName $BranchName | Out-Null

  $prNumber = [int](Get-OptionalString -Value (Get-NestedValue -Object $PreviewManifest -Path @('pullRequest', 'number') -Default 0))
  $previewPairs = @(ConvertTo-ObjectArray -Value (Get-NestedValue -Object $PreviewManifest -Path @('commentPreviewPairs') -Default @()))
  if ($previewPairs.Count -eq 0) {
    return [ordered]@{
      status = 'not-required'
      reason = 'no-comment-preview-pairs'
      branch = $BranchName
      root = $RootPath
      manifestPath = $null
      manifestUrl = $null
      previewPairCount = 0
      publishedImageCount = 0
      commentPreviewPairs = @()
    }
  }

  $runRoot = '{0}/pull-request-{1}/workflow-run-{2}' -f $RootPath.TrimEnd('/'), ('{0:D5}' -f $prNumber), $ExecutionRunId
  $publishedPreviewPairs = New-Object System.Collections.Generic.List[object]
  $publishedImageCount = 0
  $pairOrdinal = 1
  foreach ($previewPair in $previewPairs) {
    $pairRoot = '{0}/{1}-{2}' -f $runRoot, ('{0:D3}' -f $pairOrdinal), (ConvertTo-Slug -Value ([string]$previewPair.label) -Fallback 'preview')
    $baseRelativePath = [string]$previewPair.baseImageRelativePath
    $headRelativePath = [string]$previewPair.headImageRelativePath
    $baseImagePath = Join-Path $ArtifactRoot ($baseRelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    $headImagePath = Join-Path $ArtifactRoot ($headRelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $baseImagePath -PathType Leaf)) {
      throw "Preview base image was missing from the downloaded artifact: $baseRelativePath"
    }
    if (-not (Test-Path -LiteralPath $headImagePath -PathType Leaf)) {
      throw "Preview head image was missing from the downloaded artifact: $headRelativePath"
    }

    $baseExtension = [System.IO.Path]::GetExtension($baseImagePath)
    $headExtension = [System.IO.Path]::GetExtension($headImagePath)
    $basePublishPath = '{0}/base{1}' -f $pairRoot, $baseExtension
    $headPublishPath = '{0}/head{1}' -f $pairRoot, $headExtension

    $messageBase = 'comparevi-history: publish PR preview images for run {0}' -f $ExecutionRunId
    Set-RepositoryContent -RepositorySlug $RepositorySlug -BranchName $BranchName -Path $basePublishPath -Bytes ([System.IO.File]::ReadAllBytes($baseImagePath)) -Message $messageBase | Out-Null
    Set-RepositoryContent -RepositorySlug $RepositorySlug -BranchName $BranchName -Path $headPublishPath -Bytes ([System.IO.File]::ReadAllBytes($headImagePath)) -Message $messageBase | Out-Null
    $publishedImageCount += 2

    $publishedPreviewPairs.Add([ordered]@{
        targetId = [string]$previewPair.targetId
        targetPath = [string]$previewPair.targetPath
        mode = [string]$previewPair.mode
        label = [string]$previewPair.label
        sectionKind = [string]$previewPair.sectionKind
        comparison = $previewPair.comparison
        reportHtmlRelativePath = Get-OptionalString -Value $previewPair.reportHtmlRelativePath
        baseImagePath = $basePublishPath
        baseImageUrl = ConvertTo-RawGitHubUrl -RepositorySlug $RepositorySlug -BranchName $BranchName -Path $basePublishPath
        headImagePath = $headPublishPath
        headImageUrl = ConvertTo-RawGitHubUrl -RepositorySlug $RepositorySlug -BranchName $BranchName -Path $headPublishPath
      }) | Out-Null

    $pairOrdinal += 1
  }

  $publishedManifestPath = "$runRoot/preview-manifest.json"
  $publishedManifest = [ordered]@{
    schema = 'comparevi-history/pr-comment-preview-publication@v1'
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    repository = $RepositorySlug
    branch = $BranchName
    root = $runRoot
    previewPairs = @($publishedPreviewPairs | ForEach-Object { $_ })
  }
  $publishedManifestBytes = [System.Text.Encoding]::UTF8.GetBytes(($publishedManifest | ConvertTo-Json -Depth 32))
  Set-RepositoryContent -RepositorySlug $RepositorySlug -BranchName $BranchName -Path $publishedManifestPath -Bytes $publishedManifestBytes -Message ('comparevi-history: publish PR preview manifest for run {0}' -f $ExecutionRunId) | Out-Null

  return [ordered]@{
    status = 'succeeded'
    reason = 'preview-images-published'
    branch = $BranchName
    root = $runRoot
    manifestPath = $publishedManifestPath
    manifestUrl = ConvertTo-BlobGitHubUrl -RepositorySlug $RepositorySlug -BranchName $BranchName -Path $publishedManifestPath
    previewPairCount = $publishedPreviewPairs.Count
    publishedImageCount = $publishedImageCount
    commentPreviewPairs = @($publishedPreviewPairs | ForEach-Object { $_ })
  }
}

function Get-CommentPages {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepositorySlug,
    [Parameter(Mandatory = $true)]
    [string]$PullRequestNumber
  )

  $comments = New-Object System.Collections.Generic.List[object]
  $page = 1
  while ($true) {
    $uri = "https://api.github.com/repos/$RepositorySlug/issues/$PullRequestNumber/comments?per_page=100&page=$page"
    $response = Invoke-GitHubJson -Method Get -Uri $uri
    $pageEntries = @($response | Where-Object { $null -ne $_ })
    foreach ($entry in $pageEntries) {
      $comments.Add($entry) | Out-Null
    }

    if ($pageEntries.Count -lt 100) {
      break
    }

    $page += 1
  }

  return @($comments | ForEach-Object { $_ })
}

$basePath = (Get-Location).Path
$resultsDirResolved = Resolve-AbsolutePath -Path $ResultsDir -BasePath $basePath
New-Item -ItemType Directory -Path $resultsDirResolved -Force | Out-Null

$effectiveArtifactName = if ([string]::IsNullOrWhiteSpace($ArtifactName)) {
  "comparevi-history-pr-diagnostics-$WorkflowRunId"
} else {
  $ArtifactName.Trim()
}

$receiptPath = Join-Path $resultsDirResolved 'pr-comment-publication.json'
$downloadZipPath = Join-Path $resultsDirResolved 'artifact.zip'
$artifactRoot = Join-Path $resultsDirResolved 'artifact'
if (Test-Path -LiteralPath $artifactRoot) {
  Remove-Item -LiteralPath $artifactRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $artifactRoot -Force | Out-Null

$status = 'failed'
$reason = 'unknown'
$commentId = $null
$commentUrl = $null
$commentAction = 'none'
$prRunPath = $null
$commentBodyPath = $null
$pullRequestNumber = $null
$workflowRunUrl = $null
$previewPublication = [ordered]@{
  status = 'not-required'
  reason = 'preview-manifest-not-present'
  branch = $PreviewBranch
  root = $PreviewRoot
  manifestPath = $null
  manifestUrl = $null
  previewPairCount = 0
  publishedImageCount = 0
  commentPreviewPairs = @()
}

try {
  $artifact = Find-Artifact -RepositorySlug $Repository -RunId $WorkflowRunId -RequestedArtifactName $effectiveArtifactName
  if (-not $artifact) {
    throw "Workflow run $WorkflowRunId did not publish artifact '$effectiveArtifactName'."
  }

  Invoke-WebRequest -Uri ([string]$artifact.archive_download_url) -Headers (Get-GitHubHeaders) -OutFile $downloadZipPath
  Expand-Archive -Path $downloadZipPath -DestinationPath $artifactRoot -Force

  $prRunFile = Get-ChildItem -LiteralPath $artifactRoot -Recurse -Filter 'pr-run.json' | Select-Object -First 1
  if (-not $prRunFile) {
    throw 'Downloaded artifact did not contain pr-run.json.'
  }
  $prRunPath = $prRunFile.FullName
  $prRun = Read-JsonFile -Path $prRunPath
  if ([string]$prRun.schema -ne 'comparevi-history/pr-run@v2') {
    throw "Unsupported PR run schema in '$prRunPath': $($prRun.schema)"
  }

  $commentFile = Get-ChildItem -LiteralPath $artifactRoot -Recurse -Filter 'pr-comment.md' | Select-Object -First 1
  if (-not $commentFile) {
    throw 'Downloaded artifact did not contain pr-comment.md.'
  }
  $commentBodyPath = $commentFile.FullName
  $commentBody = Get-Content -LiteralPath $commentBodyPath -Raw
  if ([string]::IsNullOrWhiteSpace($commentBody)) {
    throw 'Downloaded artifact contained an empty pr-comment.md.'
  }
  if ($commentBody -notmatch [regex]::Escape($StickyMarker)) {
    throw 'Prepared PR comment body did not include the sticky marker.'
  }

  $pullRequestNumber = [string]$prRun.pullRequest.number
  if ([string]::IsNullOrWhiteSpace($pullRequestNumber)) {
    throw 'PR run receipt did not declare pullRequest.number.'
  }
  $workflowRunUrl = Get-OptionalString -Value $prRun.outputs.workflowRunUrl

  $previewManifestFile = Get-ChildItem -LiteralPath $artifactRoot -Recurse -Filter 'pr-preview-manifest.json' | Select-Object -First 1
  if ($previewManifestFile) {
      $previewManifest = Read-JsonFile -Path $previewManifestFile.FullName
      if ([string]$previewManifest.schema -ne 'comparevi-history/pr-preview-manifest@v1') {
        throw "Unsupported preview manifest schema in '$($previewManifestFile.FullName)': $($previewManifest.schema)"
      }

      $previewManifest | Add-Member -NotePropertyName pullRequest -NotePropertyValue $prRun.pullRequest -Force
      if ([int](Get-NestedValue -Object $previewManifest -Path @('summary', 'commentPreviewPairCount') -Default 0) -gt 0) {
        $previewPublication = Publish-CommentPreviewSurface -RepositorySlug $Repository -BranchName $PreviewBranch -RootPath $PreviewRoot -ExecutionRunId $WorkflowRunId -ArtifactRoot $artifactRoot -PreviewManifest $previewManifest
        $previewMarkdown = New-CommentPreviewMarkdown -PreviewPairs @($previewPublication.commentPreviewPairs | ForEach-Object { $_ }) -RunUrl $workflowRunUrl
        $commentBody = Insert-PreviewGallery -CommentBody $commentBody -PreviewMarkdown $previewMarkdown
        $commentBody | Set-Content -LiteralPath $commentBodyPath -Encoding utf8
      } else {
        $previewPublication = [ordered]@{
        status = 'not-required'
        reason = 'no-comment-preview-pairs'
        branch = $PreviewBranch
        root = $PreviewRoot
        manifestPath = $null
        manifestUrl = $null
        previewPairCount = 0
        publishedImageCount = 0
        commentPreviewPairs = @()
      }
    }
  }

  $existingComments = Get-CommentPages -RepositorySlug $Repository -PullRequestNumber $pullRequestNumber
  $existingComment = @(
    $existingComments |
      Where-Object { [string]$_.body -match [regex]::Escape($StickyMarker) } |
      Sort-Object { [DateTime]$_.updated_at } -Descending |
      Select-Object -First 1
  )

  if ($existingComment) {
    $commentId = [string]$existingComment.id
    $commentUrl = [string]$existingComment.html_url
    if ([string]$existingComment.body -eq $commentBody) {
      $status = 'succeeded'
      $reason = 'comment-unchanged'
      $commentAction = 'unchanged'
    } else {
      $updateUri = "https://api.github.com/repos/$Repository/issues/comments/$commentId"
      $updated = Invoke-GitHubJson -Method Patch -Uri $updateUri -Body @{ body = $commentBody }
      $status = 'succeeded'
      $reason = 'comment-updated'
      $commentAction = 'updated'
      $commentUrl = [string]$updated.html_url
    }
  } else {
    $createUri = "https://api.github.com/repos/$Repository/issues/$pullRequestNumber/comments"
    $created = Invoke-GitHubJson -Method Post -Uri $createUri -Body @{ body = $commentBody }
    $status = 'succeeded'
    $reason = 'comment-created'
    $commentAction = 'created'
    $commentId = [string]$created.id
    $commentUrl = [string]$created.html_url
  }
} catch {
  $status = 'failed'
  $reason = $_.Exception.Message
}

$receipt = [ordered]@{
  schema = 'comparevi-history/pr-comment-publication@v1'
  generatedAtUtc = [DateTime]::UtcNow.ToString('o')
  repository = $Repository
  workflowRunId = $WorkflowRunId
  artifactName = $effectiveArtifactName
  artifactZipPath = $downloadZipPath
  artifactRoot = $artifactRoot
  prRunPath = $prRunPath
  commentBodyPath = $commentBodyPath
  pullRequestNumber = if ([string]::IsNullOrWhiteSpace($pullRequestNumber)) { $null } else { [int]$pullRequestNumber }
  workflowRunUrl = if ([string]::IsNullOrWhiteSpace($workflowRunUrl)) { $null } else { $workflowRunUrl }
  previewPublication = $previewPublication
  summary = [ordered]@{
    status = $status
    reason = $reason
    commentAction = $commentAction
    commentId = if ([string]::IsNullOrWhiteSpace($commentId)) { $null } else { [int64]$commentId }
    commentUrl = if ([string]::IsNullOrWhiteSpace($commentUrl)) { $null } else { $commentUrl }
  }
}
$receipt | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $receiptPath -Encoding utf8

Write-ActionOutput -Key 'publication-receipt-path' -Value $receiptPath
Write-ActionOutput -Key 'publication-status' -Value $status
Write-ActionOutput -Key 'publication-reason' -Value $reason
Write-ActionOutput -Key 'comment-id' -Value $(if ([string]::IsNullOrWhiteSpace($commentId)) { '' } else { $commentId })
Write-ActionOutput -Key 'comment-url' -Value $(if ([string]::IsNullOrWhiteSpace($commentUrl)) { '' } else { $commentUrl })
Write-ActionOutput -Key 'artifact-name' -Value $effectiveArtifactName
Write-ActionOutput -Key 'preview-publication-status' -Value ([string]$previewPublication.status)
Write-ActionOutput -Key 'preview-publication-reason' -Value ([string]$previewPublication.reason)
Write-ActionOutput -Key 'preview-manifest-url' -Value $(if ([string]::IsNullOrWhiteSpace([string]$previewPublication.manifestUrl)) { '' } else { [string]$previewPublication.manifestUrl })
Write-ActionOutput -Key 'preview-pair-count' -Value ([string]$previewPublication.previewPairCount)
Write-ActionOutput -Key 'published-image-count' -Value ([string]$previewPublication.publishedImageCount)

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  @(
    '## comparevi-history PR comment publication'
    ''
    ('- Workflow run id: `{0}`' -f $WorkflowRunId)
    ('- Artifact name: `{0}`' -f $effectiveArtifactName)
    ('- Publication status: `{0}`' -f $status)
    ('- Publication reason: `{0}`' -f $reason)
    ('- Comment action: `{0}`' -f $commentAction)
    ('- Comment id: `{0}`' -f $(if ([string]::IsNullOrWhiteSpace($commentId)) { 'n/a' } else { $commentId }))
    ('- Comment URL: `{0}`' -f $(if ([string]::IsNullOrWhiteSpace($commentUrl)) { 'n/a' } else { $commentUrl }))
    ('- Preview publication status: `{0}`' -f [string]$previewPublication.status)
    ('- Preview publication reason: `{0}`' -f [string]$previewPublication.reason)
    ('- Preview publication manifest: `{0}`' -f $(if ([string]::IsNullOrWhiteSpace([string]$previewPublication.manifestUrl)) { 'n/a' } else { [string]$previewPublication.manifestUrl }))
    ('- Published preview pairs: `{0}`' -f [string]$previewPublication.previewPairCount)
    ('- Published preview images: `{0}`' -f [string]$previewPublication.publishedImageCount)
    ('- Receipt: `{0}`' -f $receiptPath)
  ) | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
}

if ($status -eq 'failed') {
  throw $reason
}

$receipt | ConvertTo-Json -Depth 32
