param(
  [Parameter(Mandatory = $true)]
  [string]$RepositoryRoot,
  [Parameter(Mandatory = $true)]
  [string]$TargetPath,
  [string]$SelectedRef = 'HEAD',
  [string]$ConsumerRepository,
  [string]$ConsumerRef,
  [string]$ResultsDir = 'tests/results/ref-compare/history-exploration',
  [switch]$IncludeMergeParents,
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
  param(
    [AllowNull()]
    $Value
  )

  if ($null -eq $Value) {
    return $null
  }

  $stringValue = [string]$Value
  if ([string]::IsNullOrWhiteSpace($stringValue)) {
    return $null
  }

  return $stringValue.Trim()
}

function Normalize-RepoRelativeViPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $candidate = $Path.Trim()
  if ([string]::IsNullOrWhiteSpace($candidate)) {
    throw 'VI path must not be empty.'
  }

  $candidate = $candidate -replace '\\', '/'
  if ([System.IO.Path]::IsPathRooted($candidate) -or $candidate.StartsWith('/')) {
    throw "VI path must be repository-relative: '$Path'"
  }

  $segments = @()
  foreach ($segment in @($candidate -split '/')) {
    if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.') {
      continue
    }
    if ($segment -eq '..') {
      throw "VI path cannot traverse outside the repository root: '$Path'"
    }
    $segments += $segment
  }

  if ($segments.Count -eq 0) {
    throw "VI path '$Path' did not resolve to a repository-relative file."
  }

  $normalized = ($segments -join '/')
  if ([System.IO.Path]::GetExtension($normalized).ToLowerInvariant() -ne '.vi') {
    throw "VI path must point to a .vi file: '$Path'"
  }

  return $normalized
}

function Invoke-GitCapture {
  param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryRoot,
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  $output = & git -C $RepositoryRoot @Arguments 2>&1
  if ($LASTEXITCODE -ne 0) {
    $rendered = if ($output) { ($output -join [Environment]::NewLine) } else { 'git command failed.' }
    throw $rendered
  }

  return [string]::Join([Environment]::NewLine, @($output))
}

function ConvertTo-ChangeKind {
  param(
    [Parameter(Mandatory = $true)]
    [string]$StatusToken
  )

  switch ($StatusToken.Substring(0, 1).ToUpperInvariant()) {
    'A' { return 'added' }
    'M' { return 'modified' }
    'D' { return 'deleted' }
    'R' { return 'renamed' }
    'C' { return 'copied' }
    'T' { return 'type-changed' }
    default { return 'unknown' }
  }
}

function Parse-RevisionRecord {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Record
  )

  $lines = @(
    $Record -split "`r?`n" |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  )
  if ($lines.Count -eq 0) {
    return $null
  }

  $headerFields = $lines[0] -split ([regex]::Escape([string][char]0x1f))
  if ($headerFields.Count -lt 4) {
    throw "Malformed revision header: '$($lines[0])'"
  }

  $statusLine = $null
  if ($lines.Count -gt 1) {
    $statusLine = $lines[1]
  }

  $statusToken = 'M'
  $path = $null
  $previousPath = $null
  if (-not [string]::IsNullOrWhiteSpace($statusLine)) {
    $statusParts = $statusLine -split "`t"
    if ($statusParts.Count -ge 2) {
      $statusToken = $statusParts[0].Trim()
      $kindKey = $statusToken.Substring(0, 1).ToUpperInvariant()
      if ($kindKey -in @('R', 'C') -and $statusParts.Count -ge 3) {
        $previousPath = $statusParts[1]
        $path = $statusParts[2]
      } else {
        $path = $statusParts[1]
      }
    }
  }

  if ([string]::IsNullOrWhiteSpace($path)) {
    $path = ''
  }

  return [pscustomobject]@{
    commit         = $headerFields[0]
    parents        = @($headerFields[1] -split ' ' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    committedAtUtc = $headerFields[2]
    subject        = $headerFields[3]
    changeKind     = ConvertTo-ChangeKind -StatusToken $statusToken
    statusToken    = $statusToken
    path           = $path
    previousPath   = $(if ([string]::IsNullOrWhiteSpace($previousPath)) { $null } else { $previousPath })
  }
}

$repositoryRootResolved = Resolve-AbsolutePath -Path $RepositoryRoot -BasePath (Get-Location).Path
if (-not (Test-Path -LiteralPath $repositoryRootResolved -PathType Container)) {
  throw "Repository root not found: $repositoryRootResolved"
}

$gitTopLevel = Invoke-GitCapture -RepositoryRoot $repositoryRootResolved -Arguments @('rev-parse', '--show-toplevel')
if ([string]::IsNullOrWhiteSpace($gitTopLevel)) {
  throw "Repository root '$repositoryRootResolved' is not a git checkout."
}

$normalizedTargetPath = Normalize-RepoRelativeViPath -Path $TargetPath
$resolvedTargetPath = [System.IO.Path]::GetFullPath((Join-Path $repositoryRootResolved $normalizedTargetPath))
$repositoryRootWithSeparator = $repositoryRootResolved.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
if (-not $resolvedTargetPath.StartsWith($repositoryRootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) {
  throw "VI path '$TargetPath' resolved outside the repository root."
}

$selectedRefTrimmed = Get-OptionalString -Value $SelectedRef
if ([string]::IsNullOrWhiteSpace($selectedRefTrimmed)) {
  $selectedRefTrimmed = 'HEAD'
}

[void](Invoke-GitCapture -RepositoryRoot $repositoryRootResolved -Arguments @('rev-parse', '--verify', "$selectedRefTrimmed^{commit}"))

$targetObjectRef = "$selectedRefTrimmed`:$normalizedTargetPath"
[void](Invoke-GitCapture -RepositoryRoot $repositoryRootResolved -Arguments @('cat-file', '-e', $targetObjectRef))

$resultsDirResolved = Resolve-AbsolutePath -Path $ResultsDir -BasePath $repositoryRootResolved
New-Item -ItemType Directory -Path $resultsDirResolved -Force | Out-Null
$revisionCatalogPath = Join-Path $resultsDirResolved 'revision-catalog.json'

$logArguments = @(
  'log',
  $selectedRefTrimmed
)
$logArguments += @(
  '--follow',
  '--find-renames=90%',
  '--name-status',
  '--format=%x1e%H%x1f%P%x1f%cI%x1f%s',
  '--',
  $normalizedTargetPath
)

$logOutput = Invoke-GitCapture -RepositoryRoot $repositoryRootResolved -Arguments $logArguments
$revisionRecords = @(
  $logOutput -split ([regex]::Escape([string][char]0x1e)) |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    ForEach-Object { Parse-RevisionRecord -Record $_ } |
    Where-Object { $null -ne $_ }
)

$orderedRecords = [System.Collections.Generic.List[object]]::new()
for ($index = $revisionRecords.Count - 1; $index -ge 0; $index--) {
  $record = $revisionRecords[$index]
  $orderedRecords.Add([pscustomobject]@{
      ordinal        = $orderedRecords.Count + 1
      commit         = $record.commit
      parents        = @($record.parents)
      committedAtUtc = $record.committedAtUtc
      subject        = $record.subject
      changeKind     = $record.changeKind
      statusToken    = $record.statusToken
      path           = $record.path
      previousPath   = $record.previousPath
    }) | Out-Null
}

$renameCount = @($orderedRecords | Where-Object { $_.changeKind -eq 'renamed' }).Count
$deleteCount = @($orderedRecords | Where-Object { $_.changeKind -eq 'deleted' }).Count
$continuityStatus = if ($deleteCount -gt 0) { 'break-detected' } else { 'continuous' }

$catalog = [ordered]@{
  schema         = 'comparevi-history/revision-catalog@v1'
  generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
  consumer       = [ordered]@{
    repository = $(if ([string]::IsNullOrWhiteSpace($ConsumerRepository)) { '' } else { $ConsumerRepository })
    ref        = $(if ([string]::IsNullOrWhiteSpace($ConsumerRef)) { $selectedRefTrimmed } else { $ConsumerRef })
  }
  target         = [ordered]@{
    path        = $normalizedTargetPath
    selectedRef = $selectedRefTrimmed
    extension   = '.vi'
  }
  discovery      = [ordered]@{
    includeMergeParents = [bool]$IncludeMergeParents.IsPresent
    historyMode         = $(if ($IncludeMergeParents.IsPresent) { 'ancestry' } else { 'touch-history' })
    followRenames       = $true
    complete            = $true
    completenessReason  = 'selected-ref-lineage'
    continuityStatus    = $continuityStatus
  }
  summary        = [ordered]@{
    revisionCount    = $orderedRecords.Count
    renameCount      = $renameCount
    deleteCount      = $deleteCount
    continuityStatus = $continuityStatus
    firstCommit      = $(if ($orderedRecords.Count -eq 0) {
        $null
      } else {
        [ordered]@{
          sha            = $orderedRecords[0].commit
          committedAtUtc = $orderedRecords[0].committedAtUtc
        }
      })
    lastCommit       = $(if ($orderedRecords.Count -eq 0) {
        $null
      } else {
        [ordered]@{
          sha            = $orderedRecords[$orderedRecords.Count - 1].commit
          committedAtUtc = $orderedRecords[$orderedRecords.Count - 1].committedAtUtc
        }
      })
  }
  revisions      = @($orderedRecords)
}

$catalog | ConvertTo-Json -Depth 64 | Out-File -FilePath $revisionCatalogPath -Encoding utf8

Write-ActionOutput -Key 'revision-catalog-path' -Value $revisionCatalogPath
Write-ActionOutput -Key 'normalized-target-path' -Value $normalizedTargetPath
Write-ActionOutput -Key 'revision-count' -Value ([string]$orderedRecords.Count)
Write-ActionOutput -Key 'catalog-complete' -Value 'true'
Write-ActionOutput -Key 'catalog-completeness-reason' -Value 'selected-ref-lineage'

if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
  @(
    '## comparevi-history manual VI exploration'
    ''
    ('- Target path: `{0}`' -f $normalizedTargetPath)
    ('- Selected ref: `{0}`' -f $selectedRefTrimmed)
    ('- Revision count: `{0}`' -f $orderedRecords.Count)
    ('- Continuity: `{0}`' -f $continuityStatus)
    ('- Revision catalog: `{0}`' -f $revisionCatalogPath)
  ) | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
}

$catalog | ConvertTo-Json -Depth 64
