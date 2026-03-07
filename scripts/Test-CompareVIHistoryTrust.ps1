Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'Assert-CompareVIHistoryTrust.ps1'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("comparevi-history-trust-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

function New-EventPayloadPath {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Payload
  )

  $path = Join-Path $tempRoot ([guid]::NewGuid().ToString('N') + '.json')
  $Payload | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $path -Encoding utf8
  return $path
}

function Invoke-TrustCase {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [Parameter(Mandatory = $true)]
    [string]$EventName,
    [object]$Payload,
    [string]$CompareviRepository = 'LabVIEW-Community-CI-CD/compare-vi-cli-action',
    [string]$CompareviRef,
    [string]$InvokeScriptPath,
    [Parameter(Mandatory = $true)]
    [bool]$ShouldPass,
    [string]$ExpectedMessagePattern
  )

  $eventPath = if ($null -ne $Payload) { New-EventPayloadPath -Payload $Payload } else { $null }

  try {
    & $scriptPath `
      -EventName $EventName `
      -EventPath $eventPath `
      -Repository 'LabVIEW-Community-CI-CD/comparevi-history' `
      -CompareviRepository $CompareviRepository `
      -CompareviRef $CompareviRef `
      -InvokeScriptPath $InvokeScriptPath

    if (-not $ShouldPass) {
      throw "Expected failure for case '$Name', but the guard passed."
    }
  } catch {
    if ($ShouldPass) {
      throw "Expected pass for case '$Name', but guard failed: $($_.Exception.Message)"
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedMessagePattern) -and $_.Exception.Message -notmatch $ExpectedMessagePattern) {
      throw "Case '$Name' failed with unexpected message: $($_.Exception.Message)"
    }
  }
}

try {
  Invoke-TrustCase -Name 'push-default' -EventName 'push' -Payload @{ ref = 'refs/heads/main' } -ShouldPass $true

  Invoke-TrustCase -Name 'fork-pr-default' -EventName 'pull_request' -Payload @{
    pull_request = @{
      author_association = 'CONTRIBUTOR'
      head = @{ repo = @{ fork = $true; full_name = 'someone/comparevi-history' } }
      base = @{ repo = @{ full_name = 'LabVIEW-Community-CI-CD/comparevi-history' } }
    }
  } -ShouldPass $false -ExpectedMessagePattern 'fork pull_request'

  Invoke-TrustCase -Name 'fork-pr-target-override' -EventName 'pull_request_target' -Payload @{
    pull_request = @{
      author_association = 'CONTRIBUTOR'
      head = @{ repo = @{ fork = $true; full_name = 'someone/comparevi-history' } }
      base = @{ repo = @{ full_name = 'LabVIEW-Community-CI-CD/comparevi-history' } }
    }
  } -CompareviRef 'develop' -ShouldPass $false -ExpectedMessagePattern 'override inputs were supplied'

  Invoke-TrustCase -Name 'trusted-pr-override' -EventName 'pull_request' -Payload @{
    pull_request = @{
      author_association = 'CONTRIBUTOR'
      head = @{ repo = @{ fork = $false; full_name = 'LabVIEW-Community-CI-CD/comparevi-history' } }
      base = @{ repo = @{ full_name = 'LabVIEW-Community-CI-CD/comparevi-history' } }
    }
  } -CompareviRef 'develop' -InvokeScriptPath 'tests/results/stub.ps1' -ShouldPass $true

  Invoke-TrustCase -Name 'unknown-pr-override' -EventName 'pull_request' -Payload @{
    pull_request = @{
      author_association = 'CONTRIBUTOR'
      head = @{ repo = @{ fork = $false } }
      base = @{ repo = @{ } }
    }
  } -CompareviRef 'develop' -ShouldPass $false -ExpectedMessagePattern 'does not prove a repo-local trusted branch'
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
