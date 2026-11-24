param(
  [Parameter(Mandatory = $true)][string]$FixturePath
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "..\src\analysis-contract.psm1") -Force

$resolved = (Resolve-Path -LiteralPath $FixturePath).Path
$raw = [System.IO.File]::ReadAllText($resolved, [System.Text.Encoding]::UTF8)
$payload = ConvertFrom-Json -InputObject $raw
$validated = ConvertTo-ValidatedAnalysisResult -Result $payload

$tempFile = Join-Path $env:TEMP ("znx-replay-" + [guid]::NewGuid().ToString("N") + ".json")
try {
  $json = ConvertTo-Json -InputObject $validated -Depth 12 -Compress
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($tempFile, $json, $utf8NoBom)
  node (Join-Path $PSScriptRoot "render-analysis.js") $tempFile (Split-Path -Leaf $resolved)
}
finally {
  Remove-Item -LiteralPath $tempFile -ErrorAction SilentlyContinue
}
