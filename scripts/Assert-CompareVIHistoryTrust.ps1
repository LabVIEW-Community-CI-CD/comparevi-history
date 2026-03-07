param(
  [Parameter(Mandatory = $true)]
  [string]$EventName,
  [string]$EventPath,
  [string]$Repository,
  [string]$CompareviRepository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
  [string]$CompareviRef,
  [string]$InvokeScriptPath,
  [string]$DefaultCompareviRepository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
  [string]$StepSummaryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NestedValue {
  param(
    [Parameter(Mandatory = $true)]
    [AllowNull()]
    [object]$Object,
    [Parameter(Mandatory = $true)]
    [string[]]$Path
  )

  $current = $Object
  foreach ($segment in $Path) {
    if ($null -eq $current) {
      return $null
    }

    $property = $current.PSObject.Properties[$segment]
    if ($null -eq $property) {
      return $null
    }

    $current = $property.Value
  }

  return $current
}

$eventPayload = $null
if (-not [string]::IsNullOrWhiteSpace($EventPath) -and (Test-Path -LiteralPath $EventPath -PathType Leaf)) {
  $rawEvent = Get-Content -LiteralPath $EventPath -Raw
  if (-not [string]::IsNullOrWhiteSpace($rawEvent)) {
    $eventPayload = $rawEvent | ConvertFrom-Json -Depth 32
  }
}

$overrideInputs = [System.Collections.Generic.List[string]]::new()
if ($CompareviRepository -ne $DefaultCompareviRepository) {
  $overrideInputs.Add('comparevi_repository') | Out-Null
}
if (-not [string]::IsNullOrWhiteSpace($CompareviRef)) {
  $overrideInputs.Add('comparevi_ref') | Out-Null
}
if (-not [string]::IsNullOrWhiteSpace($InvokeScriptPath)) {
  $overrideInputs.Add('invoke_script_path') | Out-Null
}

$pullRequest = if ($null -ne $eventPayload) { Get-NestedValue -Object $eventPayload -Path @('pull_request') } else { $null }
$isPullRequestEvent = $EventName -in @('pull_request','pull_request_target')
$authorAssociation = [string](Get-NestedValue -Object $pullRequest -Path @('author_association'))
$headFork = [bool](Get-NestedValue -Object $pullRequest -Path @('head','repo','fork'))
$headFullName = [string](Get-NestedValue -Object $pullRequest -Path @('head','repo','full_name'))
$baseFullName = [string](Get-NestedValue -Object $pullRequest -Path @('base','repo','full_name'))
$isForkPullRequest = $false

if ($isPullRequestEvent -and $null -ne $pullRequest) {
  $isForkPullRequest = $headFork
  if (-not $isForkPullRequest -and -not [string]::IsNullOrWhiteSpace($headFullName) -and -not [string]::IsNullOrWhiteSpace($baseFullName)) {
    $isForkPullRequest = $headFullName -ne $baseFullName
  }
}

$trustedAssociations = @('OWNER','MEMBER','COLLABORATOR')
$hasTrustedAssociation = $trustedAssociations -contains $authorAssociation

if ($isForkPullRequest) {
  $eventLabel = if ($EventName -eq 'pull_request_target') { 'fork pull_request_target' } else { 'fork pull_request' }
  $guidance = 'Use a maintainer-dispatched workflow such as workflow_dispatch or a comment-gated trusted workflow instead.'

  if ($overrideInputs.Count -gt 0) {
    throw ("comparevi-history refuses to run on {0} events, and override inputs were supplied ({1}). {2}" -f $eventLabel, ($overrideInputs -join ', '), $guidance)
  }

  throw ("comparevi-history refuses to run on {0} events because the facade assumes a trusted runner and trusted refs. {1}" -f $eventLabel, $guidance)
}

if ($overrideInputs.Count -gt 0 -and $isPullRequestEvent -and -not $hasTrustedAssociation) {
  $associationLabel = if ([string]::IsNullOrWhiteSpace($authorAssociation)) { 'unknown' } else { $authorAssociation }
  throw ("comparevi-history override inputs ({0}) are restricted to trusted maintainer scenarios. Current author_association is '{1}'. Remove the overrides or rerun from workflow_dispatch on a trusted branch." -f ($overrideInputs -join ', '), $associationLabel)
}

if ($StepSummaryPath) {
  @(
    '## comparevi-history trust'
    ''
    ('- Event: `{0}`' -f $EventName)
    ('- Repository: `{0}`' -f $Repository)
    ('- Fork PR detected: `{0}`' -f $isForkPullRequest.ToString().ToLowerInvariant())
    ('- Override inputs: `{0}`' -f ($(if ($overrideInputs.Count -eq 0) { 'none' } else { $overrideInputs -join ', ' })))
    ('- Author association: `{0}`' -f ($(if ([string]::IsNullOrWhiteSpace($authorAssociation)) { 'n/a' } else { $authorAssociation })))
  ) | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
}
