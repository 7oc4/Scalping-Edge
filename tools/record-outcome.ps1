param(
  [Parameter(Mandatory = $true)][string]$AnalysisId,
  [Parameter(Mandatory = $true)][ValidateSet("favorable", "adverse", "neutral")][string]$Outcome,
  [Parameter(Mandatory = $true)][int]$HorizonMinutes,
  [AllowNull()][Nullable[double]]$PriceAtSignal = $null,
  [AllowNull()][Nullable[double]]$PriceAfter = $null,
  [string]$Note = "",
  [string]$AnalysesPath = (Join-Path $PSScriptRoot "..\logs\analyses.jsonl"),
  [string]$OutcomesPath = (Join-Path $PSScriptRoot "..\data\outcomes.jsonl")
)

# Registra o que o mercado fez depois de uma analise. "favorable" significa que
# o preco andou na direcao indicada (BUY subiu, SELL caiu), "adverse" o
# contrario e "neutral" nao houve movimento claro. Sem este arquivo qualquer
# medida de acerto e apenas impressao.

$ErrorActionPreference = "Stop"

$analysesResolved = (Resolve-Path -LiteralPath $AnalysesPath -ErrorAction Stop).Path
$analysis = $null
foreach ($line in [System.IO.File]::ReadAllLines($analysesResolved, [System.Text.Encoding]::UTF8)) {
  if ([string]::IsNullOrWhiteSpace($line)) { continue }
  $row = $null
  try { $row = ConvertFrom-Json -InputObject $line } catch { continue }
  if ([string]::Equals([string]$row.id, $AnalysisId, [System.StringComparison]::OrdinalIgnoreCase)) {
    $analysis = $row
    break
  }
}

if ($null -eq $analysis) {
  throw "Analise $AnalysisId nao encontrada em $AnalysesPath. Rode a analise no painel e confira o id no cabecalho X-ZNX-Analysis-Id."
}

if ($analysis.direction -eq "NEUTRAL") {
  Write-Warning "A analise $AnalysisId e NEUTRAL. O desfecho sera gravado, mas tools/evaluate.ps1 so pontua BUY/SELL."
}

$row = [ordered]@{
  analysisId     = [string]$analysis.id
  registeredAt   = [datetime]::UtcNow.ToString("o")
  outcome        = $Outcome
  horizonMinutes = $HorizonMinutes
  priceAtSignal  = if ($null -eq $PriceAtSignal) { $null } else { [double]$PriceAtSignal }
  priceAfter     = if ($null -eq $PriceAfter) { $null } else { [double]$PriceAfter }
  direction      = [string]$analysis.direction
  action         = [string]$analysis.action
  confidence     = [int]$analysis.confidence
  asset          = [string]$analysis.asset
  timeframe      = [string]$analysis.timeframe
  model          = [string]$analysis.model
  contract       = [string]$analysis.contract
  note           = $Note
}

$directory = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($OutcomesPath))
if ($directory -and -not (Test-Path -LiteralPath $directory)) {
  [void](New-Item -ItemType Directory -Path $directory -Force)
}
$json = ConvertTo-Json -InputObject $row -Depth 6 -Compress
[System.IO.File]::AppendAllText(
  [System.IO.Path]::GetFullPath($OutcomesPath),
  $json + "`n",
  (New-Object System.Text.UTF8Encoding($false))
)

Write-Host "Desfecho gravado para $AnalysisId ($($row.direction), confidence $($row.confidence)): $Outcome em $HorizonMinutes min."
Write-Host "Arquivo: $OutcomesPath"
