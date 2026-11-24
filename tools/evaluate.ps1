param(
  [string]$AnalysesPath = (Join-Path $PSScriptRoot "..\logs\analyses.jsonl"),
  [string]$FeedbackPath = (Join-Path $PSScriptRoot "..\logs\feedback.jsonl"),
  [string]$OutcomesPath = (Join-Path $PSScriptRoot "..\data\outcomes.jsonl"),
  [string]$OutDir = (Join-Path $PSScriptRoot "..\evaluation")
)

# Transforma "parece bom" em numero: taxa de acerto direcional, taxa de WAIT,
# feedback humano e calibracao de confidence por faixa. Le apenas arquivos
# gerados pelo proprio projeto; nao chama OpenAI nem inventa amostra.

$ErrorActionPreference = "Stop"

# A conta do erro quadratico vive em market.psm1 para o painel e o relatorio
# usarem a mesma formula. Importar o modulo nao faz chamada de rede.
Import-Module -Name (Join-Path $PSScriptRoot "..\src\market.psm1") -Force

function Read-JsonLines {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
  $rows = @()
  foreach ($line in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $rows += ConvertFrom-Json -InputObject $line }
    catch { Write-Warning "Linha invalida ignorada em $Path" }
  }
  return $rows
}

function Get-Rate {
  param([int]$Part, [int]$Total)
  if ($Total -le 0) { return $null }
  return [Math]::Round((100.0 * $Part / $Total), 1)
}

$analyses = @(Read-JsonLines -Path $AnalysesPath)
$feedback = @(Read-JsonLines -Path $FeedbackPath)
$outcomes = @(Read-JsonLines -Path $OutcomesPath)

$directional = @($analyses | Where-Object { $_.direction -in @("BUY", "SELL") })
$waitSignals = @($analyses | Where-Object { $_.action -eq "WAIT" })

# Desfechos pontuados: apenas sinais BUY/SELL com resultado binario definido.
# NEUTRAL, WAIT e "neutral" nao viram acerto nem erro.
$scored = @($outcomes | Where-Object {
  $_.outcome -in @("favorable", "adverse") -and $_.direction -in @("BUY", "SELL")
})
$hits = @($scored | Where-Object { $_.outcome -eq "favorable" })
$unscored = @($outcomes | Where-Object {
  $_.outcome -eq "neutral" -or $_.direction -notin @("BUY", "SELL")
})

$feedbackCounts = [ordered]@{ hit = 0; miss = 0; invented_level = 0 }
foreach ($item in $feedback) {
  $verdict = [string]$item.verdict
  if ($feedbackCounts.Contains($verdict)) {
    $feedbackCounts[$verdict] = $feedbackCounts[$verdict] + 1
  }
}

$byDirection = @()
foreach ($side in @("BUY", "SELL")) {
  $rows = @($scored | Where-Object { $_.direction -eq $side })
  $sideHits = @($rows | Where-Object { $_.outcome -eq "favorable" })
  $byDirection += [pscustomobject]@{
    direcao   = $side
    amostras  = $rows.Count
    acertos   = $sideHits.Count
    taxaAcerto = Get-Rate -Part $sideHits.Count -Total $rows.Count
  }
}

$buckets = @(
  @{ Label = "0-54"; Min = 0; Max = 54 },
  @{ Label = "55-69"; Min = 55; Max = 69 },
  @{ Label = "70-84"; Min = 70; Max = 84 },
  @{ Label = "85-100"; Min = 85; Max = 100 }
)
# Faixas de calibracao: confidence validado antes de classificar. Registro com
# confidence ausente, textual ou fora de 0..100 fica de fora em vez de cair em
# zero (faixa 0-54) ou derrubar o relatorio.
$calibrated = @()
foreach ($row in $scored) {
  $confidence = ConvertTo-ZnxConfidenceNumber -Confidence $row.confidence
  if ($null -eq $confidence) { continue }
  $calibrated += [pscustomobject]@{
    outcome    = [string]$row.outcome
    confidence = $confidence
    # Mesma faixa do painel e do erro quadratico (market.psm1).
    bucket     = Get-ZnxConfidenceBucketLabel -Confidence $confidence
  }
}

$calibration = @()
foreach ($bucket in $buckets) {
  $rows = @($calibrated | Where-Object { $_.bucket -eq $bucket.Label })
  $bucketHits = @($rows | Where-Object { $_.outcome -eq "favorable" })
  $meanConfidence = $null
  if ($rows.Count -gt 0) {
    $meanConfidence = ($rows | Measure-Object -Property confidence -Average).Average
  }
  $rate = Get-Rate -Part $bucketHits.Count -Total $rows.Count
  $bias = $null
  if ($null -ne $rate -and $null -ne $meanConfidence) {
    $bias = [Math]::Round([double]$rate - [double]$meanConfidence, 1)
  }
  $calibration += [pscustomobject]@{
    faixa            = $bucket.Label
    amostras         = $rows.Count
    acertos          = $bucketHits.Count
    taxaAcerto       = $rate
    confidenceMedia  = if ($null -ne $meanConfidence) { [Math]::Round([double]$meanConfidence, 1) } else { $null }
    vies             = $bias
  }
}

# Erro de consistencia so sobre os desfechos ja filtrados ($scored);
# sem amostra, nulo.
$consistency = Get-ZnxConfidenceOutcomeError -Outcomes $scored

$report = [ordered]@{
  geradoEm = [datetime]::UtcNow.ToString("o")
  fontes = [ordered]@{
    analises = $AnalysesPath
    feedback = $FeedbackPath
    desfechos = $OutcomesPath
  }
  analises = [ordered]@{
    total       = $analyses.Count
    direcionais = $directional.Count
    aguardar    = $waitSignals.Count
    taxaAguardar = Get-Rate -Part $waitSignals.Count -Total $analyses.Count
  }
  feedback = [ordered]@{
    total          = $feedback.Count
    acertou        = $feedbackCounts["hit"]
    errou          = $feedbackCounts["miss"]
    nivelInventado = $feedbackCounts["invented_level"]
  }
  desfechos = [ordered]@{
    total      = $outcomes.Count
    avaliados  = $scored.Count
    ignorados  = $unscored.Count
    acertos    = $hits.Count
    taxaAcerto = Get-Rate -Part $hits.Count -Total $scored.Count
    porDirecao = $byDirection
    calibracao = $calibration
    confidenceOutcomeError = $consistency.confidenceOutcomeError
    sampleCount            = $consistency.sampleCount
    invalidSampleCount     = $consistency.invalidSampleCount
    confidenceOutcomeBands = $consistency.bands
  }
}

$resolvedOutDir = $OutDir
if (-not [System.IO.Path]::IsPathRooted($resolvedOutDir)) {
  $resolvedOutDir = Join-Path (Get-Location) $resolvedOutDir
}
if (-not (Test-Path -LiteralPath $resolvedOutDir)) {
  [void](New-Item -ItemType Directory -Path $resolvedOutDir -Force)
}
$reportPath = Join-Path $resolvedOutDir "report.json"
$reportJson = ConvertTo-Json -InputObject $report -Depth 8
[System.IO.File]::WriteAllText($reportPath, $reportJson, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ""
Write-Host "Analises registradas: $($analyses.Count) | direcionais: $($directional.Count) | aguardar: $($waitSignals.Count)"
Write-Host "Feedback humano: $($feedback.Count) (acertou $($feedbackCounts['hit']), errou $($feedbackCounts['miss']), nivel inventado $($feedbackCounts['invented_level']))"

if ($scored.Count -eq 0) {
  Write-Host "Desfechos pontuados: 0. Registre o resultado real com tools\\record-outcome.ps1 -AnalysisId <id> -Outcome favorable|adverse|neutral -HorizonMinutes <min>."
  if ($consistency.invalidSampleCount -gt 0) {
    Write-Host "Registros pontuados ignorados por confidence invalido: $($consistency.invalidSampleCount)."
  }
}
else {
  Write-Host "Desfechos pontuados: $($scored.Count) | acertos: $($hits.Count) | taxa de acerto direcional: $($report.desfechos.taxaAcerto)%"
  Write-Host ""
  $byDirection | Format-Table -AutoSize | Out-String | Write-Host
  Write-Host "Calibracao (vies = taxa de acerto - confidence media; positivo = a IA se subestima):"
  $calibration | Format-Table -AutoSize | Out-String | Write-Host
  Write-Host "Erro quadratico de consistencia (confidence tecnico x desfecho): $($consistency.confidenceOutcomeError) | N: $($consistency.sampleCount) | invalidos: $($consistency.invalidSampleCount)"
  Write-Host "Diagnostico de discrepancia numerica, nao probabilidade de acerto nem vantagem operacional."
  $consistency.bands | Format-Table -AutoSize | Out-String | Write-Host
}

Write-Host "Relatorio: $reportPath"
