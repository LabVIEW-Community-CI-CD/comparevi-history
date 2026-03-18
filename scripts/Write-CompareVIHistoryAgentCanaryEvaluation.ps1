param(
  [Parameter(Mandatory = $true)]
  [string]$Repository,
  [Parameter(Mandatory = $true)]
  [string]$WorkflowRunId,
  [Parameter(Mandatory = $true)]
  [string]$CanaryPolicyPath,
  [Parameter(Mandatory = $true)]
  [string]$GitHubToken,
  [string]$ArtifactName,
  [string]$ResultsDir = 'tests/results/pr-diagnostics/canary',
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

function Read-JsonFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $raw = Get-Content -LiteralPath $Path -Raw
  if ([string]::IsNullOrWhiteSpace($raw)) {
    throw "JSON file was empty: $Path"
  }

  return $raw | ConvertFrom-Json -Depth 100
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

function ConvertTo-StringArray {
  param([AllowNull()]$Value)

  return @(
    ConvertTo-ObjectArray -Value $Value |
      ForEach-Object { Get-OptionalString -Value $_ } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  )
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
    'User-Agent' = 'comparevi-history-agent-canary'
    'X-GitHub-Api-Version' = '2022-11-28'
  }
}

function Invoke-GitHubJson {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Method,
    [Parameter(Mandatory = $true)]
    [string]$Uri
  )

  return Invoke-RestMethod -Method $Method -Uri $Uri -Headers (Get-GitHubHeaders)
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
  if ($exact.Count -gt 0) {
    return $exact[0]
  }

  $prefix = @($artifacts | Where-Object { [string]$_.name -like "$RequestedArtifactName*" } | Select-Object -First 1)
  if ($prefix.Count -gt 0) {
    return $prefix[0]
  }

  # workflow_run follow-ons can know the publisher run id but not always the execution-derived artifact name.
  # When the publisher exposes a single artifact, treat it as the canonical publication payload.
  if ($artifacts.Count -eq 1) {
    return $artifacts[0]
  }

  $publicationArtifacts = @($artifacts | Where-Object { [string]$_.name -like 'comparevi-history-pr-diagnostics-publish-*' })
  if ($publicationArtifacts.Count -eq 1) {
    return $publicationArtifacts[0]
  }

  return $null
}

function Find-ExpandedArtifactFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ArtifactRoot,
    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  return Get-ChildItem -LiteralPath $ArtifactRoot -Recurse -Filter $Name -File | Select-Object -First 1
}

function Get-CheckResult {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [string[]]$Reasons
  )

  return [ordered]@{
    matched = ($Reasons.Count -eq 0)
    reasons = @($Reasons)
  }
}

function Get-PullRequestDetails {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepositorySlug,
    [Parameter(Mandatory = $true)]
    [int]$PullRequestNumber
  )

  $uri = "https://api.github.com/repos/$RepositorySlug/pulls/$PullRequestNumber"
  return Invoke-GitHubJson -Method Get -Uri $uri
}

$basePath = (Get-Location).Path
$resultsDirResolved = Resolve-AbsolutePath -Path $ResultsDir -BasePath $basePath
$canaryPolicyPathResolved = Resolve-AbsolutePath -Path $CanaryPolicyPath -BasePath $basePath
if (-not (Test-Path -LiteralPath $canaryPolicyPathResolved -PathType Leaf)) {
  throw "Canary policy not found: $canaryPolicyPathResolved"
}

New-Item -ItemType Directory -Path $resultsDirResolved -Force | Out-Null

$requestedArtifactName = if ([string]::IsNullOrWhiteSpace($ArtifactName)) {
  "comparevi-history-pr-diagnostics-publish-$WorkflowRunId"
} else {
  $ArtifactName.Trim()
}
$effectiveArtifactName = $requestedArtifactName

$receiptPath = Join-Path $resultsDirResolved 'agent-canary-evaluation.json'
$downloadZipPath = Join-Path $resultsDirResolved 'publication-artifact.zip'
$publicationArtifactRoot = Join-Path $resultsDirResolved 'publication-artifact'
if (Test-Path -LiteralPath $publicationArtifactRoot) {
  Remove-Item -LiteralPath $publicationArtifactRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $publicationArtifactRoot -Force | Out-Null

$status = 'failed'
$reason = 'unknown'
$matchedPolicy = $false
$failureReasons = New-Object System.Collections.Generic.List[string]
$canaryPolicy = $null
$publicationReceipt = $null
$prRun = $null
$discovery = $null
$pullRequestDetails = $null
$publicationReceiptPath = $null
$prRunPath = $null
$discoveryPath = $null
$indexMarkdownPath = $null
$indexHtmlPath = $null
$pullRequest = $null
$trustContext = $null
$checks = $null

try {
  $canaryPolicy = Read-JsonFile -Path $canaryPolicyPathResolved
  if ([string]$canaryPolicy.schema -ne 'comparevi-history/agent-canary-policy@v1') {
    throw "Unsupported canary policy schema in '$canaryPolicyPathResolved': $($canaryPolicy.schema)"
  }

  $artifact = Find-Artifact -RepositorySlug $Repository -RunId $WorkflowRunId -RequestedArtifactName $requestedArtifactName
  if (-not $artifact) {
    throw "missing-publication-artifact:$requestedArtifactName"
  }
  $effectiveArtifactName = [string]$artifact.name

  Invoke-WebRequest -Uri ([string]$artifact.archive_download_url) -Headers (Get-GitHubHeaders) -OutFile $downloadZipPath
  Expand-Archive -Path $downloadZipPath -DestinationPath $publicationArtifactRoot -Force

  $publicationReceiptFile = Find-ExpandedArtifactFile -ArtifactRoot $publicationArtifactRoot -Name 'pr-comment-publication.json'
  if (-not $publicationReceiptFile) {
    throw 'missing-pr-comment-publication'
  }
  $publicationReceiptPath = $publicationReceiptFile.FullName
  $publicationReceipt = Read-JsonFile -Path $publicationReceiptPath
  if ([string]$publicationReceipt.schema -ne 'comparevi-history/pr-comment-publication@v1') {
    throw "Unsupported publication receipt schema in '$publicationReceiptPath': $($publicationReceipt.schema)"
  }

  $prRunFile = Find-ExpandedArtifactFile -ArtifactRoot $publicationArtifactRoot -Name 'pr-run.json'
  if (-not $prRunFile) {
    throw 'missing-pr-run'
  }
  $prRunPath = $prRunFile.FullName
  $prRun = Read-JsonFile -Path $prRunPath
  if ([string]$prRun.schema -ne 'comparevi-history/pr-run@v2') {
    throw "Unsupported PR run schema in '$prRunPath': $($prRun.schema)"
  }

  $discoveryFile = Find-ExpandedArtifactFile -ArtifactRoot $publicationArtifactRoot -Name 'changed-vi-discovery.json'
  if (-not $discoveryFile) {
    throw 'missing-changed-vi-discovery'
  }
  $discoveryPath = $discoveryFile.FullName
  $discovery = Read-JsonFile -Path $discoveryPath
  if ([string]$discovery.schema -ne 'comparevi-history/changed-vi-discovery@v2') {
    throw "Unsupported discovery schema in '$discoveryPath': $($discovery.schema)"
  }

  $indexMarkdownFile = Find-ExpandedArtifactFile -ArtifactRoot $publicationArtifactRoot -Name 'index.md'
  $indexHtmlFile = Find-ExpandedArtifactFile -ArtifactRoot $publicationArtifactRoot -Name 'index.html'
  $indexMarkdownPath = if ($indexMarkdownFile) { $indexMarkdownFile.FullName } else { $null }
  $indexHtmlPath = if ($indexHtmlFile) { $indexHtmlFile.FullName } else { $null }

  $pullRequestNumber = [int]$prRun.pullRequest.number
  $pullRequestDetails = Get-PullRequestDetails -RepositorySlug $Repository -PullRequestNumber $pullRequestNumber
  $pullRequestLabels = @(
    ConvertTo-ObjectArray -Value $pullRequestDetails.labels |
      ForEach-Object { Get-OptionalString -Value (Get-NestedValue -Object $_ -Path @('name')) } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  )

  $pullRequest = [ordered]@{
    number = [int]$prRun.pullRequest.number
    htmlUrl = Get-OptionalString -Value $prRun.pullRequest.htmlUrl
    baseRepository = [string]$prRun.pullRequest.baseRepository
    baseRef = [string]$prRun.pullRequest.baseRef
    baseSha = [string]$prRun.pullRequest.baseSha
    headRepository = [string]$prRun.pullRequest.headRepository
    headRef = [string]$prRun.pullRequest.headRef
    headSha = [string]$prRun.pullRequest.headSha
    isFork = [bool]$prRun.pullRequest.isFork
    draft = [bool]$pullRequestDetails.draft
    labels = @($pullRequestLabels)
  }

  $trustContext = [ordered]@{
    sameRepository = ($pullRequest.baseRepository -eq $pullRequest.headRepository -and -not $pullRequest.isFork)
    forkBehavior = Get-OptionalString -Value $prRun.executionContext.forkBehavior
    fullSurface = Get-OptionalString -Value $prRun.executionContext.fullSurface
  }

  $branchPrefix = [string]$canaryPolicy.prIdentification.branchPrefix
  $requiredLabels = @(ConvertTo-StringArray -Value $canaryPolicy.prIdentification.requiredLabels)
  $prMode = [string]$canaryPolicy.promotionContract.prMode
  $expectedPath = [string]$canaryPolicy.targetContract.canonicalPath
  $expectedChangedViCount = [int]$canaryPolicy.targetContract.expectedChangedViCount
  $expectedSelectedTargetCount = [int]$canaryPolicy.targetContract.expectedSelectedTargetCount
  $expectedPublicModes = @(ConvertTo-StringArray -Value $canaryPolicy.executionContract.expectedPublicModes)
  $expectedNoisePolicy = [string]$canaryPolicy.executionContract.expectedNoisePolicy
  $expectedFullSurface = [string]$canaryPolicy.executionContract.expectedFullSurface
  $stickyCommentRequired = [bool]$canaryPolicy.publicationContract.stickyCommentRequired
  $requiredPublicationStatus = [string]$canaryPolicy.publicationContract.requiredStatus

  $identificationReasons = New-Object System.Collections.Generic.List[string]
  if (-not $trustContext.sameRepository) {
    $identificationReasons.Add('same-repo-required') | Out-Null
  }
  if (-not $pullRequest.headRef.StartsWith($branchPrefix, [System.StringComparison]::Ordinal)) {
    $identificationReasons.Add('branch-prefix-mismatch') | Out-Null
  }
  foreach ($requiredLabel in $requiredLabels) {
    if ($pullRequest.labels -notcontains $requiredLabel) {
      $identificationReasons.Add(("missing-required-label:{0}" -f $requiredLabel)) | Out-Null
    }
  }
  switch ($prMode) {
    'draft' {
      if (-not $pullRequest.draft) {
        $identificationReasons.Add('pr-not-draft') | Out-Null
      }
    }
    'ready-for-review' {
      if ($pullRequest.draft) {
        $identificationReasons.Add('pr-not-ready-for-review') | Out-Null
      }
    }
  }

  $selectedTargetPaths = @(
    ConvertTo-ObjectArray -Value $discovery.selectedTargets |
      ForEach-Object { Get-OptionalString -Value $_.targetPath } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  )

  $targetReasons = New-Object System.Collections.Generic.List[string]
  if ([int]$discovery.summary.changedViCount -ne $expectedChangedViCount) {
    $targetReasons.Add('wrong-changed-vi-count') | Out-Null
  }
  if ([int]$discovery.summary.selectedTargetCount -ne $expectedSelectedTargetCount) {
    $targetReasons.Add('wrong-selected-target-count') | Out-Null
  }
  if ($selectedTargetPaths.Count -ne 1 -or [string]$selectedTargetPaths[0] -ne $expectedPath) {
    $targetReasons.Add('wrong-target-path') | Out-Null
  }

  $observedPublicModes = @(
    ConvertTo-StringArray -Value (Get-NestedValue -Object $prRun -Path @('prPolicy', 'execution', 'publicModes'))
  )
  $executionReasons = New-Object System.Collections.Generic.List[string]
  if ([string]$prRun.summary.finalStatus -ne 'succeeded') {
    $executionReasons.Add('failed-execution') | Out-Null
  }
  if (($observedPublicModes -join ',') -ne ($expectedPublicModes -join ',')) {
    $executionReasons.Add('wrong-public-modes') | Out-Null
  }
  if ([string](Get-NestedValue -Object $prRun -Path @('prPolicy', 'execution', 'noisePolicy')) -ne $expectedNoisePolicy) {
    $executionReasons.Add('wrong-noise-policy') | Out-Null
  }
  if ([string](Get-NestedValue -Object $prRun -Path @('executionContext', 'fullSurface')) -ne $expectedFullSurface) {
    $executionReasons.Add('wrong-full-surface') | Out-Null
  }

  $publicationReasons = New-Object System.Collections.Generic.List[string]
  if ([string]$publicationReceipt.summary.status -ne $requiredPublicationStatus) {
    $publicationReasons.Add('failed-publication') | Out-Null
  }
  if ($stickyCommentRequired) {
    $hasStickyComment = (
      [string]$publicationReceipt.summary.commentAction -in @('created', 'updated', 'unchanged') -and
      $null -ne $publicationReceipt.summary.commentId -and
      -not [string]::IsNullOrWhiteSpace([string]$publicationReceipt.summary.commentUrl)
    )
    if (-not $hasStickyComment) {
      $publicationReasons.Add('missing-sticky-comment') | Out-Null
    }
  }

  $artifactReasons = New-Object System.Collections.Generic.List[string]
  if (-not $indexMarkdownFile -or -not $indexHtmlFile) {
    $artifactReasons.Add('missing-index-surface') | Out-Null
  }

  $checks = [ordered]@{
    identification = Get-CheckResult -Reasons @($identificationReasons)
    targetContract = Get-CheckResult -Reasons @($targetReasons)
    executionContract = Get-CheckResult -Reasons @($executionReasons)
    publicationContract = Get-CheckResult -Reasons @($publicationReasons)
    artifactContract = Get-CheckResult -Reasons @($artifactReasons)
  }

  $matchedPolicy = [bool]$checks.identification.matched
  if (-not $matchedPolicy) {
    $status = 'skipped'
    $reason = 'non-canary-pr'
    foreach ($entry in @($checks.identification.reasons)) {
      $failureReasons.Add([string]$entry) | Out-Null
    }
  } else {
    foreach ($group in @($checks.targetContract.reasons, $checks.executionContract.reasons, $checks.publicationContract.reasons, $checks.artifactContract.reasons)) {
      foreach ($entry in @($group)) {
        $failureReasons.Add([string]$entry) | Out-Null
      }
    }

    if ($failureReasons.Count -gt 0) {
      $status = 'failed'
      $reason = [string]$failureReasons[0]
    } else {
      $status = 'succeeded'
      $reason = 'canary-acceptance-satisfied'
    }
  }
} catch {
  $status = 'failed'
  $reason = $_.Exception.Message
  if ($failureReasons.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($reason)) {
    $failureReasons.Add($reason) | Out-Null
  }
}

$policyReceipt = if ($null -eq $canaryPolicy) {
  [ordered]@{
    schema = 'comparevi-history/agent-canary-policy@v1'
    path = $canaryPolicyPathResolved
    prIdentification = [ordered]@{}
    targetContract = [ordered]@{}
    executionContract = [ordered]@{}
    publicationContract = [ordered]@{}
    promotionContract = [ordered]@{}
  }
} else {
  [ordered]@{
    schema = [string]$canaryPolicy.schema
    path = $canaryPolicyPathResolved
    prIdentification = $canaryPolicy.prIdentification
    targetContract = $canaryPolicy.targetContract
    executionContract = $canaryPolicy.executionContract
    publicationContract = $canaryPolicy.publicationContract
    promotionContract = $canaryPolicy.promotionContract
  }
}

if ($null -eq $pullRequest) {
  $pullRequest = [ordered]@{
    number = $(if ($null -ne $prRun -and $null -ne $prRun.pullRequest -and $null -ne $prRun.pullRequest.number) { [int]$prRun.pullRequest.number } else { 0 })
    htmlUrl = $(if ($null -ne $prRun) { Get-OptionalString -Value $prRun.pullRequest.htmlUrl } else { $null })
    baseRepository = $(if ($null -ne $prRun) { [string]$prRun.pullRequest.baseRepository } else { $Repository })
    baseRef = $(if ($null -ne $prRun) { [string]$prRun.pullRequest.baseRef } else { '' })
    baseSha = $(if ($null -ne $prRun) { [string]$prRun.pullRequest.baseSha } else { '' })
    headRepository = $(if ($null -ne $prRun) { [string]$prRun.pullRequest.headRepository } else { $Repository })
    headRef = $(if ($null -ne $prRun) { [string]$prRun.pullRequest.headRef } else { '' })
    headSha = $(if ($null -ne $prRun) { [string]$prRun.pullRequest.headSha } else { '' })
    isFork = $(if ($null -ne $prRun) { [bool]$prRun.pullRequest.isFork } else { $false })
    draft = $(if ($null -ne $pullRequestDetails) { [bool]$pullRequestDetails.draft } else { $false })
    labels = @()
  }
}

if ($null -eq $trustContext) {
  $trustContext = [ordered]@{
    sameRepository = ($pullRequest.baseRepository -eq $pullRequest.headRepository -and -not $pullRequest.isFork)
    forkBehavior = $(if ($null -ne $prRun) { Get-OptionalString -Value $prRun.executionContext.forkBehavior } else { $null })
    fullSurface = $(if ($null -ne $prRun) { Get-OptionalString -Value $prRun.executionContext.fullSurface } else { $null })
  }
}

if ($null -eq $checks) {
  $checks = [ordered]@{
    identification = Get-CheckResult -Reasons @()
    targetContract = Get-CheckResult -Reasons @()
    executionContract = Get-CheckResult -Reasons @()
    publicationContract = Get-CheckResult -Reasons @()
    artifactContract = Get-CheckResult -Reasons @()
  }
}

$evaluation = [ordered]@{
  schema = 'comparevi-history/agent-canary-evaluation@v1'
  generatedAtUtc = [DateTime]::UtcNow.ToString('o')
  repository = $Repository
  workflowRunId = $WorkflowRunId
  artifactName = $effectiveArtifactName
  canaryPolicy = $policyReceipt
  pullRequest = $pullRequest
  trustContext = $trustContext
  discovery = [ordered]@{
    schema = $(if ($null -ne $discovery) { [string]$discovery.schema } else { 'comparevi-history/changed-vi-discovery@v2' })
    path = $(if ([string]::IsNullOrWhiteSpace($discoveryPath)) { $null } else { $discoveryPath })
    status = $(if ($null -ne $discovery) { [string]$discovery.summary.executionStatus } else { 'blocked' })
    reason = $(if ($null -ne $discovery) { [string]$discovery.summary.executionReason } else { 'missing-changed-vi-discovery' })
    changedViCount = $(if ($null -ne $discovery) { [int]$discovery.summary.changedViCount } else { 0 })
    selectedTargetCount = $(if ($null -ne $discovery) { [int]$discovery.summary.selectedTargetCount } else { 0 })
    selectedTargetPaths = @(
      if ($null -ne $discovery) {
        ConvertTo-ObjectArray -Value $discovery.selectedTargets |
          ForEach-Object { Get-OptionalString -Value $_.targetPath } |
          Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
      }
    )
  }
  execution = [ordered]@{
    schema = $(if ($null -ne $prRun) { [string]$prRun.schema } else { 'comparevi-history/pr-run@v2' })
    path = $(if ([string]::IsNullOrWhiteSpace($prRunPath)) { $null } else { $prRunPath })
    finalStatus = $(if ($null -ne $prRun) { [string]$prRun.summary.finalStatus } else { 'failed' })
    finalReason = $(if ($null -ne $prRun) { [string]$prRun.summary.finalReason } else { 'missing-pr-run' })
    publicModes = @(
      if ($null -ne $prRun) {
        ConvertTo-StringArray -Value (Get-NestedValue -Object $prRun -Path @('prPolicy', 'execution', 'publicModes'))
      }
    )
    noisePolicy = $(if ($null -ne $prRun) { Get-OptionalString -Value (Get-NestedValue -Object $prRun -Path @('prPolicy', 'execution', 'noisePolicy')) } else { $null })
    fullSurface = $(if ($null -ne $prRun) { Get-OptionalString -Value (Get-NestedValue -Object $prRun -Path @('executionContext', 'fullSurface')) } else { $null })
  }
  publication = [ordered]@{
    schema = $(if ($null -ne $publicationReceipt) { [string]$publicationReceipt.schema } else { 'comparevi-history/pr-comment-publication@v1' })
    path = $(if ([string]::IsNullOrWhiteSpace($publicationReceiptPath)) { $null } else { $publicationReceiptPath })
    status = $(if ($null -ne $publicationReceipt) { [string]$publicationReceipt.summary.status } else { 'failed' })
    reason = $(if ($null -ne $publicationReceipt) { [string]$publicationReceipt.summary.reason } else { 'missing-pr-comment-publication' })
    commentAction = $(if ($null -ne $publicationReceipt) { [string]$publicationReceipt.summary.commentAction } else { 'none' })
    commentId = $(if ($null -ne $publicationReceipt -and $null -ne $publicationReceipt.summary.commentId) { [int64]$publicationReceipt.summary.commentId } else { $null })
    commentUrl = $(if ($null -ne $publicationReceipt) { Get-OptionalString -Value $publicationReceipt.summary.commentUrl } else { $null })
  }
  outputs = [ordered]@{
    resultsDir = $resultsDirResolved
    evaluationPath = $receiptPath
    publicationArtifactRoot = $publicationArtifactRoot
    publicationReceiptPath = $(if ([string]::IsNullOrWhiteSpace($publicationReceiptPath)) { $null } else { $publicationReceiptPath })
    prRunPath = $(if ([string]::IsNullOrWhiteSpace($prRunPath)) { $null } else { $prRunPath })
    discoveryPath = $(if ([string]::IsNullOrWhiteSpace($discoveryPath)) { $null } else { $discoveryPath })
    indexMarkdownPath = $(if ([string]::IsNullOrWhiteSpace($indexMarkdownPath)) { $null } else { $indexMarkdownPath })
    indexHtmlPath = $(if ([string]::IsNullOrWhiteSpace($indexHtmlPath)) { $null } else { $indexHtmlPath })
  }
  checks = $checks
  summary = [ordered]@{
    matchedPolicy = $matchedPolicy
    status = $status
    reason = $reason
    failureReasons = @($failureReasons)
    changedViCount = $(if ($null -ne $discovery) { [int]$discovery.summary.changedViCount } else { 0 })
    selectedTargetCount = $(if ($null -ne $discovery) { [int]$discovery.summary.selectedTargetCount } else { 0 })
    executionFinalStatus = $(if ($null -ne $prRun) { [string]$prRun.summary.finalStatus } else { 'failed' })
    executionFinalReason = $(if ($null -ne $prRun) { [string]$prRun.summary.finalReason } else { 'missing-pr-run' })
    publicationStatus = $(if ($null -ne $publicationReceipt) { [string]$publicationReceipt.summary.status } else { 'failed' })
    publicationReason = $(if ($null -ne $publicationReceipt) { [string]$publicationReceipt.summary.reason } else { 'missing-pr-comment-publication' })
  }
}
$evaluation | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $receiptPath -Encoding utf8

Write-ActionOutput -Key 'evaluation-path' -Value $receiptPath
Write-ActionOutput -Key 'evaluation-status' -Value $status
Write-ActionOutput -Key 'evaluation-reason' -Value $reason
Write-ActionOutput -Key 'matched-policy' -Value $matchedPolicy.ToString().ToLowerInvariant()
Write-ActionOutput -Key 'artifact-name' -Value $effectiveArtifactName
Write-ActionOutput -Key 'publication-receipt-path' -Value $(if ([string]::IsNullOrWhiteSpace($publicationReceiptPath)) { '' } else { $publicationReceiptPath })
Write-ActionOutput -Key 'pr-run-path' -Value $(if ([string]::IsNullOrWhiteSpace($prRunPath)) { '' } else { $prRunPath })

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  @(
    '## comparevi-history agent canary evaluation'
    ''
    ('- Workflow run id: `{0}`' -f $WorkflowRunId)
    ('- Artifact name: `{0}`' -f $effectiveArtifactName)
    ('- Matched canary policy: `{0}`' -f $matchedPolicy.ToString().ToLowerInvariant())
    ('- Evaluation status: `{0}`' -f $status)
    ('- Evaluation reason: `{0}`' -f $reason)
    ('- Pull request number: `{0}`' -f $(if ($evaluation.pullRequest.number -gt 0) { [string]$evaluation.pullRequest.number } else { 'n/a' }))
    ('- Pull request ref: `{0}`' -f $(if ([string]::IsNullOrWhiteSpace($evaluation.pullRequest.headRef)) { 'n/a' } else { $evaluation.pullRequest.headRef }))
    ('- Changed VIs: `{0}`' -f $evaluation.summary.changedViCount)
    ('- Selected targets: `{0}`' -f $evaluation.summary.selectedTargetCount)
    ('- Execution final status: `{0}`' -f $evaluation.summary.executionFinalStatus)
    ('- Publication status: `{0}`' -f $evaluation.summary.publicationStatus)
    ('- Receipt: `{0}`' -f $receiptPath)
  ) | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
}

if ($status -eq 'failed') {
  throw $reason
}

$evaluation | ConvertTo-Json -Depth 64
