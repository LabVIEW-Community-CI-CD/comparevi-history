param(
  [Parameter(Mandatory = $true)]
  [string]$DestinationPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$destinationDir = Split-Path -Parent $DestinationPath
if (-not [string]::IsNullOrWhiteSpace($destinationDir)) {
  New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
}

@'
param(
    [string]$BaseVi,
    [string]$HeadVi,
    [string]$OutputDir,
    [string[]]$Flags,
    [switch]$RenderReport,
    [string]$ReportFormat = 'html',
    [string]$NoiseProfile = 'full'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $OutputDir) {
    $OutputDir = Join-Path $env:TEMP ("lvcompare-stub-" + [guid]::NewGuid().ToString('N'))
}

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
$imagesDir = Join-Path $OutputDir 'cli-images'
New-Item -ItemType Directory -Path $imagesDir -Force | Out-Null

$stdoutPath = Join-Path $OutputDir 'lvcompare-stdout.txt'
$stderrPath = Join-Path $OutputDir 'lvcompare-stderr.txt'
$capturePath = Join-Path $OutputDir 'lvcompare-capture.json'

"Stub LVCompare run for $BaseVi -> $HeadVi" | Set-Content -LiteralPath $stdoutPath -Encoding utf8
"" | Set-Content -LiteralPath $stderrPath -Encoding utf8
[System.IO.File]::WriteAllBytes((Join-Path $imagesDir 'cli-image-00.png'), @(0xCA,0xFE,0xBA,0xBE))

$exitCode = 1

$capture = [ordered]@{
    schema    = 'lvcompare-capture-v1'
    timestamp = (Get-Date).ToString('o')
    base      = $BaseVi
    head      = $HeadVi
    cliPath   = 'Stub LVCompare'
    args      = $Flags
    exitCode  = $exitCode
    seconds   = 0.05
    command   = "Stub LVCompare ""$BaseVi"" ""$HeadVi"""
    environment = @{
        cli = @{
            artifacts = @{
                images = @(
                    @{
                        index      = 0
                        mimeType   = 'image/png'
                        byteLength = 4
                        savedPath  = (Join-Path $imagesDir 'cli-image-00.png')
                    }
                )
            }
        }
    }
}
$capture | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $capturePath -Encoding utf8

if ($RenderReport.IsPresent -or $ReportFormat.ToLowerInvariant() -eq 'html') {
    @"
<!DOCTYPE html>
<html>
<body>
  <div class="included-attributes">
    <ul class="inclusion-list">
      <li class="checked">VI Attribute</li>
    </ul>
  </div>
  <details open>
    <summary class="difference-heading">1. VI Attribute - Window Size/Appearance</summary>
    <ol class="detailed-description-list">
      <li class="diff-detail">Window bounds changed for VIP custom action dialog.</li>
    </ol>
  </details>
</body>
</html>
"@ | Set-Content -LiteralPath (Join-Path $OutputDir 'compare-report.html') -Encoding utf8
}

exit $exitCode
'@ | Set-Content -LiteralPath $DestinationPath -Encoding utf8
