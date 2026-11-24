param(
  [Parameter(Mandatory = $true)][string]$ImageDir,
  [string]$BaseUrl = "http://127.0.0.1:8765",
  [string]$Market = "crypto",
  [string]$Asset = "BTC",
  [string]$Timeframe = "5m",
  [string]$OutDir = "live-results"
)

# Envia capturas reais para o servidor local e registra o resultado de cada uma.
# consome creditos da OpenAI e nao faz parte do npm test.

$ErrorActionPreference = "Stop"

$images = @(Get-ChildItem -LiteralPath $ImageDir -File |
    Where-Object { $_.Extension -in @(".png", ".jpg", ".jpeg", ".webp") } |
    Sort-Object Name)

if ($images.Count -eq 0) {
  throw "Nenhuma imagem PNG/JPG/WEBP encontrada em $ImageDir."
}

$resultsDir = Join-Path (Get-Location) $OutDir
New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$mimeByExtension = @{
  ".png" = "image/png"; ".jpg" = "image/jpeg"; ".jpeg" = "image/jpeg"; ".webp" = "image/webp"
}

$rows = @()
foreach ($image in $images) {
  $mime = $mimeByExtension[$image.Extension.ToLowerInvariant()]
  $payload = @{
    image     = [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($image.FullName))
    mimeType  = $mime
    market    = $Market
    asset     = $Asset
    timeframe = $Timeframe
  } | ConvertTo-Json -Compress

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    $response = Invoke-WebRequest -Uri "$BaseUrl/api/analyze" -Method Post `
      -ContentType "application/json" -Headers @{ Origin = $BaseUrl } `
      -Body $payload -UseBasicParsing -TimeoutSec 300
    $sw.Stop()
    $text = [System.Text.Encoding]::UTF8.GetString($response.RawContentStream.ToArray())
    $data = $text | ConvertFrom-Json
    $outFile = Join-Path $resultsDir ($image.BaseName + ".json")
    [System.IO.File]::WriteAllText($outFile, $text, $utf8NoBom)
    # Id e cache vem do cabecalho: o id e o que permite registrar o desfecho
    # real depois, e o cache explica um resultado reaproveitado.
    $analysisId = [string]($response.Headers["X-ZNX-Analysis-Id"] | Select-Object -First 1)
    $cacheState = [string]($response.Headers["X-ZNX-Cache"] | Select-Object -First 1)
    $preprocess = [string]($response.Headers["X-ZNX-Preprocess"] | Select-Object -First 1)
    $rows += [pscustomobject]@{
      arquivo     = $image.Name
      http        = $response.StatusCode
      classe      = $data.image_class
      direcao     = $data.direction
      acao        = $data.signal_timing.action
      confidence  = $data.confidence
      cobertura   = $data.analysis_coverage
      limitacoes  = @($data.risk).Count
      niveis      = @($data.levels).Count
      palavras    = ([regex]::Matches([string]$data.summary, "\S+")).Count
      segundos    = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
      id          = $analysisId
      cache       = $cacheState
      realce      = $preprocess
      erro        = ""
    }
  }
  catch {
    $sw.Stop()
    $rows += [pscustomobject]@{
      arquivo = $image.Name; http = 0; classe = ""; direcao = ""; acao = ""
      confidence = ""; cobertura = ""; limitacoes = ""; niveis = ""; palavras = ""
      segundos = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
      id = ""; cache = ""; realce = ""
      erro = $_.Exception.Message
    }
  }
}

$csvPath = Join-Path $resultsDir "resumo.csv"
$rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

# Metadados da rodada: sem modelo/contrato, dois lotes parecem comparaveis
# quando nao sao. Eles entram no meta.json para o antes/depois ser honesto.
$contractVersion = ""
try {
  Import-Module (Join-Path $PSScriptRoot "..\src\analysis-contract.psm1") -Force -WarningAction SilentlyContinue
  $contractVersion = Get-AnalysisContractVersion
}
catch { $contractVersion = "" }
$modelName = ""
try {
  $status = Invoke-RestMethod -Uri "$BaseUrl/api/status" -UseBasicParsing -TimeoutSec 15
  $modelName = [string]$status.model
}
catch { $modelName = "" }

$meta = [ordered]@{
  geradoEm      = [datetime]::UtcNow.ToString("o")
  baseUrl       = $BaseUrl
  modelo        = $modelName
  contrato      = $contractVersion
  mercado       = $Market
  ativo         = $Asset
  timeframe     = $Timeframe
  imagens       = $images.Count
  respostas     = @($rows | Where-Object { -not $_.erro }).Count
  erros         = @($rows | Where-Object { $_.erro }).Count
  comCacheHit   = @($rows | Where-Object { $_.cache -eq "hit" }).Count
  comRealce     = @($rows | Where-Object { $_.realce }).Count
}
$metaPath = Join-Path $resultsDir "meta.json"
[System.IO.File]::WriteAllText($metaPath, (ConvertTo-Json -InputObject $meta -Depth 6), $utf8NoBom)

$rows | Format-Table -AutoSize
Write-Host "Respostas em $resultsDir | resumo em $csvPath | metadados em $metaPath"
if ($meta.comCacheHit -gt 0) {
  Write-Warning "$($meta.comCacheHit) resposta(s) vieram do cache local: reinicie o servidor antes de comparar prompt ou modelo."
}
Write-Host "Para medir acerto real: tools\record-outcome.ps1 -AnalysisId <id> -Outcome favorable|adverse|neutral -HorizonMinutes <min> e depois tools\evaluate.ps1"
