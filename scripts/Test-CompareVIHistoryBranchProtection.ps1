param(
  [string]$Repository = 'LabVIEW-Community-CI-CD/comparevi-history',
  [string]$Branch = 'main',
  [string]$PolicyPath = '.github/branch-protection-main.json',
  [string]$ResultsDir = 'tests/results/_branch-protection-drift',
  [string]$GitHubToken,
  [string]$TokenSource = 'GITHUB_TOKEN',
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

  $safeValue = if ($null -eq $Value) { '' } else { $Value }
  "$Key=$safeValue" | Out-File -FilePath $GitHubOutputPath -Encoding utf8 -Append
}

function Resolve-FullPath {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }

  return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
}

function ConvertTo-NormalizedValue {
  param([AllowNull()][object]$Value)

  if ($null -eq $Value) {
    return $null
  }

  if (
    $Value -is [string] -or
    $Value -is [bool] -or
    $Value -is [int] -or
    $Value -is [long] -or
    $Value -is [double] -or
    $Value -is [decimal]
  ) {
    return $Value
  }

  if ($Value -is [System.Collections.IDictionary]) {
    $normalized = [ordered]@{}
    foreach ($key in ($Value.Keys | Sort-Object)) {
      $normalized[[string]$key] = ConvertTo-NormalizedValue -Value $Value[$key]
    }
    return $normalized
  }

  if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
    $items = @()
    foreach ($item in $Value) {
      $items += ,(ConvertTo-NormalizedValue -Value $item)
    }
    return $items
  }

  $propertyNames = @($Value.PSObject.Properties.Name)
  if ($propertyNames.Count -gt 0) {
    $normalized = [ordered]@{}
    foreach ($propertyName in ($propertyNames | Sort-Object)) {
      $normalized[$propertyName] = ConvertTo-NormalizedValue -Value $Value.$propertyName
    }
    return $normalized
  }

  return $Value
}

function ConvertTo-ComparableJson {
  param([AllowNull()][object]$Value)

  if ($null -eq $Value) {
    return 'null'
  }

  return [string]($Value | ConvertTo-Json -Depth 20 -Compress)
}

function Resolve-EnabledFlag {
  param([AllowNull()][object]$Value)

  if ($null -eq $Value) {
    return $null
  }

  if ($Value -is [bool]) {
    return [bool]$Value
  }

  $propertyNames = @($Value.PSObject.Properties.Name)
  if ($propertyNames -contains 'enabled') {
    return [bool]$Value.enabled
  }

  return [bool]$Value
}

function Get-ObjectPropertyValue {
  param(
    [AllowNull()][object]$Object,
    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  if ($null -eq $Object) {
    return $null
  }

  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) {
    return $null
  }

  return $property.Value
}

function Normalize-ExpectedPolicy {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Policy
  )

  return [ordered]@{
    required_status_checks = [ordered]@{
      strict = [bool]$Policy.required_status_checks.strict
      contexts = @(
        @($Policy.required_status_checks.contexts | ForEach-Object { [string]$_ }) |
          Sort-Object -Unique
      )
    }
    enforce_admins = if ($null -eq $Policy.enforce_admins) { $null } else { [bool]$Policy.enforce_admins }
    required_pull_request_reviews = ConvertTo-NormalizedValue -Value $Policy.required_pull_request_reviews
    restrictions = ConvertTo-NormalizedValue -Value $Policy.restrictions
    required_linear_history = if ($null -eq $Policy.required_linear_history) { $null } else { [bool]$Policy.required_linear_history }
    allow_force_pushes = if ($null -eq $Policy.allow_force_pushes) { $null } else { [bool]$Policy.allow_force_pushes }
    allow_deletions = if ($null -eq $Policy.allow_deletions) { $null } else { [bool]$Policy.allow_deletions }
    block_creations = if ($null -eq $Policy.block_creations) { $null } else { [bool]$Policy.block_creations }
    required_conversation_resolution = if ($null -eq $Policy.required_conversation_resolution) { $null } else { [bool]$Policy.required_conversation_resolution }
    lock_branch = if ($null -eq $Policy.lock_branch) { $null } else { [bool]$Policy.lock_branch }
    allow_fork_syncing = if ($null -eq $Policy.allow_fork_syncing) { $null } else { [bool]$Policy.allow_fork_syncing }
  }
}

function Normalize-ActualProtection {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Protection
  )

  $contextValues = @()
  $requiredStatusChecks = Get-ObjectPropertyValue -Object $Protection -Name 'required_status_checks'
  if ($null -ne $requiredStatusChecks) {
    $statusContexts = Get-ObjectPropertyValue -Object $requiredStatusChecks -Name 'contexts'
    $statusChecks = Get-ObjectPropertyValue -Object $requiredStatusChecks -Name 'checks'
    if ($null -ne $statusContexts) {
      $contextValues = @($statusContexts | ForEach-Object { [string]$_ })
    } elseif ($null -ne $statusChecks) {
      $contextValues = @(
        $statusChecks |
          ForEach-Object { [string]$_.context } |
          Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
      )
    }
  }

  return [ordered]@{
    required_status_checks = [ordered]@{
      strict = if ($null -eq $requiredStatusChecks) { $null } else { [bool](Get-ObjectPropertyValue -Object $requiredStatusChecks -Name 'strict') }
      contexts = @($contextValues | Sort-Object -Unique)
    }
    enforce_admins = Resolve-EnabledFlag -Value (Get-ObjectPropertyValue -Object $Protection -Name 'enforce_admins')
    required_pull_request_reviews = ConvertTo-NormalizedValue -Value (Get-ObjectPropertyValue -Object $Protection -Name 'required_pull_request_reviews')
    restrictions = ConvertTo-NormalizedValue -Value (Get-ObjectPropertyValue -Object $Protection -Name 'restrictions')
    required_linear_history = Resolve-EnabledFlag -Value (Get-ObjectPropertyValue -Object $Protection -Name 'required_linear_history')
    allow_force_pushes = Resolve-EnabledFlag -Value (Get-ObjectPropertyValue -Object $Protection -Name 'allow_force_pushes')
    allow_deletions = Resolve-EnabledFlag -Value (Get-ObjectPropertyValue -Object $Protection -Name 'allow_deletions')
    block_creations = Resolve-EnabledFlag -Value (Get-ObjectPropertyValue -Object $Protection -Name 'block_creations')
    required_conversation_resolution = Resolve-EnabledFlag -Value (Get-ObjectPropertyValue -Object $Protection -Name 'required_conversation_resolution')
    lock_branch = Resolve-EnabledFlag -Value (Get-ObjectPropertyValue -Object $Protection -Name 'lock_branch')
    allow_fork_syncing = Resolve-EnabledFlag -Value (Get-ObjectPropertyValue -Object $Protection -Name 'allow_fork_syncing')
  }
}

function Compare-BranchProtection {
  param(
    [Parameter(Mandatory = $true)]
    [System.Collections.IDictionary]$Expected,
    [Parameter(Mandatory = $true)]
    [System.Collections.IDictionary]$Actual
  )

  $diffs = [System.Collections.Generic.List[string]]::new()

  $expectedStrict = $Expected.required_status_checks.strict
  $actualStrict = $Actual.required_status_checks.strict
  if ($expectedStrict -ne $actualStrict) {
    $diffs.Add("required_status_checks.strict drifted. expected=$expectedStrict actual=$actualStrict")
  }

  $expectedContexts = @($Expected.required_status_checks.contexts)
  $actualContexts = @($Actual.required_status_checks.contexts)
  $missingContexts = @($expectedContexts | Where-Object { $_ -notin $actualContexts })
  $unexpectedContexts = @($actualContexts | Where-Object { $_ -notin $expectedContexts })
  if ($missingContexts.Count -gt 0 -or $unexpectedContexts.Count -gt 0) {
    $contextParts = @()
    if ($missingContexts.Count -gt 0) {
      $contextParts += ("missing [{0}]" -f ($missingContexts -join ', '))
    }
    if ($unexpectedContexts.Count -gt 0) {
      $contextParts += ("unexpected [{0}]" -f ($unexpectedContexts -join ', '))
    }
    $diffs.Add("required_status_checks.contexts mismatch ({0})" -f ($contextParts -join '; '))
  }

  foreach ($propertyName in @(
    'enforce_admins',
    'required_linear_history',
    'allow_force_pushes',
    'allow_deletions',
    'block_creations',
    'required_conversation_resolution',
    'lock_branch',
    'allow_fork_syncing',
    'required_pull_request_reviews',
    'restrictions'
  )) {
    $expectedValue = $Expected[$propertyName]
    $actualValue = $Actual[$propertyName]
    $expectedJson = ConvertTo-ComparableJson -Value $expectedValue
    $actualJson = ConvertTo-ComparableJson -Value $actualValue
    if ($expectedJson -ne $actualJson) {
      $diffs.Add("{0} drifted. expected={1} actual={2}" -f $propertyName, $expectedJson, $actualJson)
    }
  }

  return $diffs
}

function Get-HttpStatusCode {
  param([Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord)

  $exceptionPropertyNames = @($ErrorRecord.Exception.PSObject.Properties.Name)
  if ($exceptionPropertyNames -notcontains 'Response') {
    return $null
  }

  $response = $ErrorRecord.Exception.Response
  if ($null -eq $response) {
    return $null
  }

  try {
    if ($response.StatusCode) {
      return [int]$response.StatusCode
    }
  } catch {
  }

  return $null
}

$resultsPath = Resolve-FullPath -Path $ResultsDir
New-Item -ItemType Directory -Path $resultsPath -Force | Out-Null

$reportPath = Join-Path $resultsPath 'branch-protection-drift-report.json'
$expectedPath = Join-Path $resultsPath 'branch-protection-expected.json'
$actualRawPath = Join-Path $resultsPath 'branch-protection-live.json'
$actualNormalizedPath = Join-Path $resultsPath 'branch-protection-normalized.json'

$policyFullPath = Resolve-FullPath -Path $PolicyPath
$expectedPolicy = $null
$actualProtection = $null
$actualNormalized = $null
$status = 'error'
$diffs = @()
$errorMessage = $null
$httpStatusCode = $null

$remediationCommand = @"
gh api repos/$Repository/branches/$Branch/protection \
  --method PUT \
  --input .github/branch-protection-main.json
"@

try {
  if (-not (Test-Path -LiteralPath $policyFullPath -PathType Leaf)) {
    throw "Branch protection policy not found: $policyFullPath"
  }

  if ([string]::IsNullOrWhiteSpace($GitHubToken)) {
    throw 'No GitHub token was provided. Configure the COMPAREVI_BRANCH_PROTECTION_TOKEN secret or supply -GitHubToken with repo-admin access.'
  }

  $expectedPolicy = Normalize-ExpectedPolicy -Policy (Get-Content -LiteralPath $policyFullPath -Raw | ConvertFrom-Json)

  $headers = @{
    Accept = 'application/vnd.github+json'
    Authorization = "Bearer $GitHubToken"
    'User-Agent' = 'comparevi-history-branch-protection-drift'
    'X-GitHub-Api-Version' = '2022-11-28'
  }

  $uri = "https://api.github.com/repos/$Repository/branches/$Branch/protection"
  $actualProtection = Invoke-RestMethod -Uri $uri -Headers $headers
  $actualNormalized = Normalize-ActualProtection -Protection $actualProtection
  $diffs = @(Compare-BranchProtection -Expected $expectedPolicy -Actual $actualNormalized)
  $status = if ($diffs.Count -eq 0) { 'ok' } else { 'drift' }
} catch {
  $status = 'error'
  $httpStatusCode = Get-HttpStatusCode -ErrorRecord $_
  $errorMessage = $_.Exception.Message

  if ($null -ne $httpStatusCode -and $httpStatusCode -eq 403) {
    $errorMessage = "{0} Configure the COMPAREVI_BRANCH_PROTECTION_TOKEN secret with repo-admin access if the default workflow token cannot read branch protection." -f $errorMessage
  }
} finally {
  if ($null -ne $expectedPolicy) {
    $expectedPolicy | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $expectedPath -Encoding utf8
  }
  if ($null -ne $actualProtection) {
    $actualProtection | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $actualRawPath -Encoding utf8
  }
  if ($null -ne $actualNormalized) {
    $actualNormalized | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $actualNormalizedPath -Encoding utf8
  }

  $report = [ordered]@{
    schema = 'comparevi-history/branch-protection-drift@v1'
    checkedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    repository = $Repository
    branch = $Branch
    policyPath = $policyFullPath
    status = $status
    tokenSource = $TokenSource
    httpStatusCode = $httpStatusCode
    diffs = @($diffs)
    error = $errorMessage
    expectedPolicyPath = if (Test-Path -LiteralPath $expectedPath) { $expectedPath } else { $null }
    liveProtectionPath = if (Test-Path -LiteralPath $actualRawPath) { $actualRawPath } else { $null }
    normalizedProtectionPath = if (Test-Path -LiteralPath $actualNormalizedPath) { $actualNormalizedPath } else { $null }
    remediation = [ordered]@{
      command = $remediationCommand.Trim()
      note = 'Apply the checked-in policy file to the live main branch protection settings.'
    }
  }

  $report | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $reportPath -Encoding utf8

  $expectedPolicyOutputPath = if (Test-Path -LiteralPath $expectedPath) { $expectedPath } else { $null }
  $liveProtectionOutputPath = if (Test-Path -LiteralPath $actualRawPath) { $actualRawPath } else { $null }
  $normalizedProtectionOutputPath = if (Test-Path -LiteralPath $actualNormalizedPath) { $actualNormalizedPath } else { $null }

  Write-ActionOutput -Key 'status' -Value $status
  Write-ActionOutput -Key 'report-path' -Value $reportPath
  Write-ActionOutput -Key 'expected-policy-path' -Value $expectedPolicyOutputPath
  Write-ActionOutput -Key 'live-protection-path' -Value $liveProtectionOutputPath
  Write-ActionOutput -Key 'normalized-protection-path' -Value $normalizedProtectionOutputPath

  if (-not [string]::IsNullOrWhiteSpace($StepSummaryPath)) {
    $summaryLines = [System.Collections.Generic.List[string]]::new()
    $summaryLines.Add('## comparevi-history branch protection drift')
    $summaryLines.Add('')
    $summaryLines.Add(('- Repository: `{0}`' -f $Repository))
    $summaryLines.Add(('- Branch: `{0}`' -f $Branch))
    $summaryLines.Add(('- Policy file: `{0}`' -f $policyFullPath))
    $summaryLines.Add(('- Token source: `{0}`' -f $TokenSource))
    $summaryLines.Add(('- Status: `{0}`' -f $status))

    if ($status -eq 'ok') {
      $summaryLines.Add('- Live branch protection matches the checked-in policy.')
    } elseif ($status -eq 'drift') {
      $summaryLines.Add('- Drift detected:')
      foreach ($diff in $diffs) {
        $summaryLines.Add(('  - {0}' -f $diff))
      }
    } else {
      $summaryLines.Add(('- Check failed before parity could be confirmed: `{0}`' -f $errorMessage))
    }

    $summaryLines.Add('')
    $summaryLines.Add('### Remediation')
    $summaryLines.Add('```bash')
    foreach ($line in ($remediationCommand.Trim() -split "`r?`n")) {
      $summaryLines.Add($line)
    }
    $summaryLines.Add('```')
    $summaryLines.Add('')
    $summaryLines.Add(('- Report artifact: `{0}`' -f $reportPath))
    $summaryLines | Out-File -FilePath $StepSummaryPath -Encoding utf8 -Append
  }
}

if ($status -eq 'drift') {
  throw ("Branch protection drift detected for {0}:{1}. Review {2} and reapply the checked-in policy." -f $Repository, $Branch, $reportPath)
}

if ($status -ne 'ok') {
  throw ("Branch protection drift check failed for {0}:{1}. Review {2}. {3}" -f $Repository, $Branch, $reportPath, $errorMessage)
}
