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
    ('- Receipt: `{0}`' -f $receiptPath)
  ) | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
}

if ($status -eq 'failed') {
  throw $reason
}

$receipt | ConvertTo-Json -Depth 32
