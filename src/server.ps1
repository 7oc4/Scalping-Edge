$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Net.Http
Import-Module -Name (Join-Path $PSScriptRoot "analysis-contract.psm1") -Force
Import-Module -Name (Join-Path $PSScriptRoot "market.psm1") -Force

# server.ps1 fica em src\; a raiz servida (paginas, assets, prompts, logs) e a
# pasta acima dela.
$script:ProjectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$script:RootPrefix  = $script:ProjectRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) +
  [System.IO.Path]::DirectorySeparatorChar
$script:MaxImageBytes = 12 * 1024 * 1024
$script:MaxBodyBytes  = 17 * 1024 * 1024

# Porta configuravel para testes locais; o uso normal continua em 8765.
$script:ListenPort   = if ($env:ZNX_PORT) { [int]$env:ZNX_PORT } else { 8765 }
$script:ListenOrigin = "http://127.0.0.1:$($script:ListenPort)"
$script:ListenHost   = "127.0.0.1:$($script:ListenPort)"

# ---------- Configuracao via ambiente ----------
$script:OpenAIModel        = if ($env:OPENAI_MODEL)              { $env:OPENAI_MODEL }              else { "gpt-4o-mini" }
$script:OpenAIEndpoint     = "https://api.openai.com/v1/chat/completions"
$script:MaxOutputTokens    = if ($env:OPENAI_MAX_TOKENS)         { [int]$env:OPENAI_MAX_TOKENS }    else { 4000 }
$script:ImageDetail        = if ($env:OPENAI_IMAGE_DETAIL)       { $env:OPENAI_IMAGE_DETAIL }       else { "high" }
$script:HttpTimeoutSeconds = if ($env:OPENAI_TIMEOUT_SECONDS)    { [int]$env:OPENAI_TIMEOUT_SECONDS } else { 180 }
# O painel consulta /api/status a cada 5 s. Com 30 s de cache o servidor ainda
# pingava a OpenAI duas vezes por minuto sem necessidade; 10 min resolve isso.
$script:StatusCacheTtlSec  = if ($env:OPENAI_STATUS_TTL_SECONDS) { [int]$env:OPENAI_STATUS_TTL_SECONDS } else { 600 }
# Uma unica retentativa cobre 429/5xx transitorios sem multiplicar o consumo da
# chave quando o provedor esta realmente fora do ar.
$script:MaxRetries         = if ($env:OPENAI_MAX_RETRIES)        { [int]$env:OPENAI_MAX_RETRIES }   else { 1 }

# Protecoes locais: limite de analises por minuto (evita loop queimando
# creditos) e tempo maximo de leitura do corpo da requisicao.
$script:MaxAnalysesPerMinute = if ($env:ZNX_RATE_LIMIT_PER_MINUTE) { [int]$env:ZNX_RATE_LIMIT_PER_MINUTE } else { 10 }
$script:RateLimitWindowSeconds = 60
$script:BodyReadTimeoutSeconds = if ($env:ZNX_READ_TIMEOUT_SECONDS) { [int]$env:ZNX_READ_TIMEOUT_SECONDS } else { 30 }
$script:AnalysisAttempts = [System.Collections.Generic.List[datetime]]::new()

# Cache local de analises identicas (mesma imagem + mesmo contexto + mesma versao
# do contrato). Reenviar a mesma captura devolve o resultado ja validado sem
# gastar uma nova chamada da chave. TTL e tamanho configuraveis.
$script:AnalysisCacheTtlSeconds = if ($env:ZNX_CACHE_TTL_SECONDS) { [int]$env:ZNX_CACHE_TTL_SECONDS } else { 900 }
$script:AnalysisCacheMaxEntries = if ($env:ZNX_CACHE_MAX_ENTRIES) { [int]$env:ZNX_CACHE_MAX_ENTRIES } else { 8 }
$script:AnalysisCache = @{}

# Diagnostico e dados de avaliacao. ZNX_LOG_DIR permite que a suite de testes
# grave em pasta temporaria sem sujar os logs reais do projeto.
$script:LogDir = if ($env:ZNX_LOG_DIR) { $env:ZNX_LOG_DIR } else { Join-Path $script:ProjectRoot "logs" }
# Desfechos reais. ZNX_OUTCOMES_PATH permite que a suite use uma fixture
# temporaria sem tocar em data\outcomes.jsonl do projeto.
$script:OutcomesPath = if ($env:ZNX_OUTCOMES_PATH) { $env:ZNX_OUTCOMES_PATH } else { Join-Path $script:ProjectRoot "data\outcomes.jsonl" }

# Pre-processamento antes de enviar a captura: "auto" realca imagens de baixo
# contraste, "on" aplica sempre que o formato permite e "off" desliga. WEBP
# nunca e reprocessado porque o GDI+ nao decodifica o formato.
$script:ImageEnhanceMode = if ($env:ZNX_IMAGE_ENHANCE) { $env:ZNX_IMAGE_ENHANCE.ToLowerInvariant() } else { "auto" }

# Releitura automatica: quando a primeira passada responde "sem grafico" (classe
# C/D), o servidor repete a leitura UMA vez com a imagem original e um checklist
# visual, em vez de devolver a recusa na hora. ZNX_REREAD=off desliga.
$script:RereadEnabled = ($env:ZNX_REREAD -ne "off")

# ---------- HttpClients reutilizaveis ----------
$script:AnalysisClient = [System.Net.Http.HttpClient]::new()
$script:AnalysisClient.Timeout = [TimeSpan]::FromSeconds($script:HttpTimeoutSeconds)
$script:StatusClient = [System.Net.Http.HttpClient]::new()
$script:StatusClient.Timeout = [TimeSpan]::FromSeconds(5)

# ---------- Cache de status ----------
$script:StatusCache   = $null
$script:StatusCacheAt = [datetime]::MinValue

# ---------- Prompt ----------
$script:AnalysisPromptPath = Join-Path $script:ProjectRoot "prompts\chart-analysis-v8.0.txt"
if (-not (Test-Path -LiteralPath $script:AnalysisPromptPath -PathType Leaf)) {
  throw "Nao foi possivel encontrar o prompt V8.0 em $script:AnalysisPromptPath."
}
$script:AnalysisSystemPrompt = [System.IO.File]::ReadAllText(
  $script:AnalysisPromptPath,
  [System.Text.Encoding]::UTF8
)

# =====================================================================
# LOG EM JSONL
# =====================================================================
function Add-JsonLogLine {
  # Uma linha JSON por evento. append-only e barato: serve para juntar analises,
  # feedback humano e desfecho real sem manter um banco local.
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Data
  )
  $directory = [System.IO.Path]::GetDirectoryName($Path)
  if ($directory -and -not (Test-Path -LiteralPath $directory)) {
    [void](New-Item -ItemType Directory -Path $directory -Force)
  }
  $json = ConvertTo-Json -InputObject $Data -Depth 8 -Compress
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::AppendAllText($Path, $json + "`n", $utf8NoBom)
}

# =====================================================================
# RESPOSTAS
# =====================================================================
# Cliente que desiste da requisicao (reload, aba fechada, polling cancelado)
# deixa o socket morto no meio da escrita. Isso NAO e erro do servidor: se a
# excecao subisse, ela passaria pelo catch da rota, que tentaria escrever uma
# segunda resposta no mesmo socket e derrubaria o laco de atendimento.
function Send-ResponseBytes {
  param(
    [Parameter(Mandatory = $true)]$Response,
    [Parameter(Mandatory = $true)][int]$StatusCode,
    [Parameter(Mandatory = $true)][string]$ContentType,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes,
    [AllowNull()][System.Collections.IDictionary]$ExtraHeaders = $null
  )
  try {
    $Response.StatusCode = $StatusCode
    $Response.ContentType = $ContentType
    $Response.Headers["Cache-Control"] = "no-store"
    if ($ExtraHeaders) {
      foreach ($headerName in $ExtraHeaders.Keys) {
        $Response.Headers[[string]$headerName] = [string]$ExtraHeaders[$headerName]
      }
    }
    $Response.ContentLength64 = $Bytes.Length
    $Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
  }
  catch {
    Write-Verbose "Resposta descartada (cliente saiu): $($_.Exception.Message)"
  }
  finally {
    try { $Response.Close() } catch { }
  }
}

function Send-JsonResponse {
  param(
    [Parameter(Mandatory = $true)]$Response,
    [Parameter(Mandatory = $true)][int]$StatusCode,
    [Parameter(Mandatory = $true)]$Data,
    [AllowNull()][System.Collections.IDictionary]$ExtraHeaders = $null
  )
  $json = ConvertTo-Json -InputObject $Data -Depth 12 -Compress
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
  Send-ResponseBytes -Response $Response -StatusCode $StatusCode `
    -ContentType "application/json; charset=utf-8" -Bytes $bytes -ExtraHeaders $ExtraHeaders
}

function Send-TextResponse {
  param(
    [Parameter(Mandatory = $true)]$Response,
    [Parameter(Mandatory = $true)][int]$StatusCode,
    [Parameter(Mandatory = $true)][string]$Message
  )
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Message)
  Send-ResponseBytes -Response $Response -StatusCode $StatusCode `
    -ContentType "text/plain; charset=utf-8" -Bytes $bytes
}

function Get-MarketName {
  param([string]$Market)
  switch ($Market) {
    "forex"       { return "Forex" }
    "crypto"      { return "criptomoedas" }
    "binary"      { return "opcoes binarias" }
    "commodities" { return "commodities" }
    "stocks"      { return "acoes" }
    default       { return $null }
  }
}

function Get-TimeframeName {
  param([string]$Timeframe)
  switch ($Timeframe) {
    ""    { return "nao informado" }
    "1m"  { return "1 minuto" }
    "5m"  { return "5 minutos" }
    "15m" { return "15 minutos" }
    "30m" { return "30 minutos" }
    "1h"  { return "1 hora" }
    "4h"  { return "4 horas" }
    "1d"  { return "diario" }
    default { return $null }
  }
}

function Get-StaticContentType {
  param([string]$Path)
  switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
    ".html" { return "text/html; charset=utf-8" }
    ".css"  { return "text/css; charset=utf-8" }
    ".js"   { return "text/javascript; charset=utf-8" }
    ".svg"  { return "image/svg+xml" }
    ".png"  { return "image/png" }
    ".jpg"  { return "image/jpeg" }
    ".jpeg" { return "image/jpeg" }
    ".webp" { return "image/webp" }
    default { return "application/octet-stream" }
  }
}

# =====================================================================
# STATUS OPENAI (com cache)
# =====================================================================
function Get-OpenAIConnectionStatusUncached {
  if (-not $env:OPENAI_API_KEY) {
    return [pscustomobject]@{ state = "disconnected"; message = "Chave da API nao configurada" }
  }
  $request = $null
  $result  = $null
  try {
    $request = [System.Net.Http.HttpRequestMessage]::new(
      [System.Net.Http.HttpMethod]::Get,
      "$($script:OpenAIEndpoint -replace '/chat/completions$', '')/models/$($script:OpenAIModel)"
    )
    $request.Headers.Authorization =
      [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $env:OPENAI_API_KEY)
    $result = $script:StatusClient.SendAsync($request).GetAwaiter().GetResult()
    $statusCode = [int]$result.StatusCode
    if ($statusCode -ge 200 -and $statusCode -lt 300) {
      return [pscustomobject]@{ state = "connected"; message = "Conectado a OpenAI" }
    }
    if ($statusCode -eq 429 -or $statusCode -ge 500) {
      return [pscustomobject]@{ state = "unstable"; message = "OpenAI instavel ou com limite temporario" }
    }
    return [pscustomobject]@{ state = "disconnected"; message = "OpenAI indisponivel: confira chave e modelo" }
  }
  catch {
    return [pscustomobject]@{ state = "unstable"; message = "Sem resposta da OpenAI" }
  }
  finally {
    if ($result)  { $result.Dispose() }
    if ($request) { $request.Dispose() }
  }
}

function Get-OpenAIConnectionStatus {
  $now = [datetime]::UtcNow
  if ($null -ne $script:StatusCache -and
      ($now - $script:StatusCacheAt).TotalSeconds -lt $script:StatusCacheTtlSec) {
    return $script:StatusCache
  }
  $fresh = Get-OpenAIConnectionStatusUncached
  $script:StatusCache   = $fresh
  $script:StatusCacheAt = $now
  return $fresh
}

# =====================================================================
# CHAMADA OPENAI COM RETRY
# =====================================================================
function Invoke-OpenAIRequest {
  param([Parameter(Mandatory = $true)][string]$JsonBody)

  $attempt       = 0
  $lastStatus    = 0
  $lastBody      = ""
  $lastException = $null
  $totalMs       = 0

  while ($attempt -le $script:MaxRetries) {
    $attempt++
    $sw   = [System.Diagnostics.Stopwatch]::StartNew()
    $req  = $null
    $resp = $null
    try {
      $req = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::Post,
        $script:OpenAIEndpoint
      )
      $req.Headers.Authorization =
        [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $env:OPENAI_API_KEY)
      $req.Content = [System.Net.Http.StringContent]::new(
        $JsonBody, [System.Text.Encoding]::UTF8, "application/json"
      )
      $resp = $script:AnalysisClient.SendAsync($req).GetAwaiter().GetResult()
      $lastStatus = [int]$resp.StatusCode
      $respBytes  = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
      $lastBody   = [System.Text.Encoding]::UTF8.GetString($respBytes)
      $sw.Stop()
      $totalMs += $sw.ElapsedMilliseconds

      if ($resp.IsSuccessStatusCode) {
        return @{ Success = $true;  StatusCode = $lastStatus; Body = $lastBody; ElapsedMs = $totalMs; Attempts = $attempt }
      }
      if ($lastStatus -ne 429 -and $lastStatus -lt 500) {
        return @{ Success = $false; StatusCode = $lastStatus; Body = $lastBody; ElapsedMs = $totalMs; Attempts = $attempt }
      }
    }
    catch {
      $sw.Stop()
      $totalMs += $sw.ElapsedMilliseconds
      $lastException = $_.Exception.Message
      $lastStatus    = 0
      $lastBody      = $lastException
    }
    finally {
      if ($resp) { $resp.Dispose() }
      if ($req)  { $req.Dispose() }
    }

    if ($attempt -le $script:MaxRetries) {
      $backoffMs = [int]([Math]::Pow(2, $attempt - 1) * 2000)
      Write-Warning "OpenAI indisponivel (tentativa $attempt/$($script:MaxRetries + 1)). Retentando em $([Math]::Round($backoffMs / 1000, 1))s..."
      Start-Sleep -Milliseconds $backoffMs
    }
  }

  return @{
    Success    = $false
    StatusCode = $lastStatus
    Body       = $lastBody
    ElapsedMs  = $totalMs
    Attempts   = $attempt
    Error      = $lastException
  }
}

# =====================================================================
# ANALISE PRINCIPAL
# =====================================================================
function Invoke-ImageAnalysis {
  param($Context)

  $request  = $Context.Request
  $response = $Context.Response

  if ($request.ContentType -notmatch '^application/json(?:\s*;|$)') {
    Send-JsonResponse -Response $response -StatusCode 415 -Data @{
      error = "O endpoint de analise aceita somente solicitacoes JSON."
    }
    return
  }

  if ($request.ContentLength64 -gt $script:MaxBodyBytes) {
    Send-JsonResponse -Response $response -StatusCode 413 -Data @{
      error = "A imagem excede o limite permitido de 12 MB."
    }
    return
  }

  if (-not $env:OPENAI_API_KEY) {
    Send-JsonResponse -Response $response -StatusCode 503 -Data @{
      error = "A chave da API OpenAI nao foi configurada. Feche o servidor e inicie novamente; informe a chave quando solicitado."
    }
    return
  }

  $rateCheck = Test-AnalysisRateLimit -Now ([datetime]::UtcNow) `
    -Timestamps $script:AnalysisAttempts.ToArray() `
    -Limit $script:MaxAnalysesPerMinute `
    -WindowSeconds $script:RateLimitWindowSeconds
  if (-not $rateCheck.Allowed) {
    $response.Headers["Retry-After"] = [string]$rateCheck.RetryAfterSeconds
    Send-JsonResponse -Response $response -StatusCode 429 -Data @{
      error = "Limite local de $($script:MaxAnalysesPerMinute) analises por minuto atingido. Aguarde $($rateCheck.RetryAfterSeconds) segundo(s) e tente novamente."
    }
    return
  }
  $script:AnalysisAttempts.Clear()
  foreach ($attemptAt in $rateCheck.Timestamps) { $script:AnalysisAttempts.Add($attemptAt) }

  $reader = $null
  $readWatch = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    $encoding = if ($request.ContentEncoding) { $request.ContentEncoding } else { [System.Text.Encoding]::UTF8 }
    $reader   = [System.IO.StreamReader]::new($request.InputStream, $encoding)
    $builder  = [System.Text.StringBuilder]::new()
    $buffer   = New-Object char[] 8192
    $totalRead = 0
    while (($read = $reader.Read($buffer, 0, $buffer.Length)) -gt 0) {
      if ($readWatch.Elapsed.TotalSeconds -gt $script:BodyReadTimeoutSeconds) {
        Send-JsonResponse -Response $response -StatusCode 408 -Data @{
          error = "A solicitacao demorou demais para ser enviada. Tente novamente."
        }
        return
      }
      $totalRead += $read
      if ($totalRead -gt $script:MaxBodyBytes) {
        Send-JsonResponse -Response $response -StatusCode 413 -Data @{
          error = "A imagem excede o limite permitido de 12 MB."
        }
        return
      }
      [void]$builder.Append($buffer, 0, $read)
    }
    $body = ConvertFrom-Json -InputObject $builder.ToString()
  }
  catch {
    Send-JsonResponse -Response $response -StatusCode 400 -Data @{
      error = "A solicitacao enviada nao contem JSON valido."
    }
    return
  }
  finally {
    if ($reader) { $reader.Dispose() }
  }

  $marketName    = Get-MarketName    -Market    ([string]$body.market)
  $timeframeName = Get-TimeframeName -Timeframe ([string]$body.timeframe)
  $mimeType      = [string]$body.mimeType
  $asset         = ([string]$body.asset).Trim()
  $imageData     = [string]$body.image

  if (-not $marketName -or $null -eq $timeframeName) {
    Send-JsonResponse -Response $response -StatusCode 400 -Data @{
      error = "Selecione um mercado e periodo validos."
    }
    return
  }

  if ($asset.Length -gt 32) {
    Send-JsonResponse -Response $response -StatusCode 400 -Data @{
      error = "O nome do ativo deve ter no maximo 32 caracteres."
    }
    return
  }

  $allowedForexPairs = @(
    "EUR/USD","EUR/GBP","AUD/JPY","EUR/JPY","GBP/USD","AUD/CAD","USD/CAD","NZD/USD","USD/JPY",
    "CAD/JPY","CHF/JPY","EUR/NZD","AUD/CHF","EUR/AUD","GBP/CHF","GBP/AUD","USD/AUD","GBP/JPY",
    "USD/CHF","NZD/JPY","EUR/CHF","CAD/CHF","EUR/CAD","BTC/USD","AUD/NZD","AUD/USD","NZD/CHF",
    "GBP/CAD","GBP/NZD","NZD/CAD"
  )
  if ($body.market -eq "forex" -and $asset -notin $allowedForexPairs) {
    Send-JsonResponse -Response $response -StatusCode 400 -Data @{
      error = "Selecione um dos pares Forex disponiveis."
    }
    return
  }

  $allowedCryptos = @("BTC","LTC","ADA","BNB","XRP","ETH","SOL","AVAX","DOGE","SUI","WLD","XLM")
  if ($body.market -eq "crypto" -and $asset -notin $allowedCryptos) {
    Send-JsonResponse -Response $response -StatusCode 400 -Data @{
      error = "Selecione uma das criptomoedas disponiveis."
    }
    return
  }

  $allowedCommodities = @("Cobre","Petroleo","Prata","Ouro")
  if ($body.market -eq "commodities" -and $asset -notin $allowedCommodities) {
    Send-JsonResponse -Response $response -StatusCode 400 -Data @{
      error = "Selecione uma das commodities disponiveis."
    }
    return
  }

  $allowedStocks = @(
    "APPLE","NETFLIX","META","TESLA","MICROSOFT","MCDONALDS","AMAZON","PAYPAL","STARBUCKS",
    "NVIDIA","DISNEY","INTEL","VISA","IBM","FORD","COCA-COLA","NIKE","MASTERCARD","SPOTIFY",
    "SPACEX","JPMORGAN","BANK OF AMERICA","CITIGROUP","WELLS FARGO","GOLDMAN SACHS","MORGAN STANLEY"
  )
  if ($body.market -eq "stocks" -and $asset -notin $allowedStocks) {
    Send-JsonResponse -Response $response -StatusCode 400 -Data @{
      error = "Selecione uma das acoes disponiveis."
    }
    return
  }

  if ($mimeType -notin @("image/png","image/jpeg","image/webp") -or
      $imageData -notmatch '^[A-Za-z0-9+/]+={0,2}$') {
    Send-JsonResponse -Response $response -StatusCode 400 -Data @{
      error = "Envie uma imagem PNG, JPG ou WEBP valida."
    }
    return
  }

  $axisMinRaw = $body.axisMin
  $axisMaxRaw = $body.axisMax
  $axisInformed = $null -ne $axisMinRaw -or $null -ne $axisMaxRaw
  $axisMin = $null
  $axisMax = $null
  if ($axisInformed) {
    $axisCulture = [System.Globalization.CultureInfo]::InvariantCulture
    $parsedAxisMin = 0.0
    $parsedAxisMax = 0.0
    $axisMinValid = if ($axisMinRaw -is [double] -or $axisMinRaw -is [int] -or $axisMinRaw -is [long] -or
      $axisMinRaw -is [decimal] -or $axisMinRaw -is [single]) {
      $parsedAxisMin = [double]$axisMinRaw
      $true
    }
    else {
      [double]::TryParse(([string]$axisMinRaw).Replace(",", "."), [System.Globalization.NumberStyles]::Float,
        $axisCulture, [ref]$parsedAxisMin)
    }
    $axisMaxValid = if ($axisMaxRaw -is [double] -or $axisMaxRaw -is [int] -or $axisMaxRaw -is [long] -or
      $axisMaxRaw -is [decimal] -or $axisMaxRaw -is [single]) {
      $parsedAxisMax = [double]$axisMaxRaw
      $true
    }
    else {
      [double]::TryParse(([string]$axisMaxRaw).Replace(",", "."), [System.Globalization.NumberStyles]::Float,
        $axisCulture, [ref]$parsedAxisMax)
    }
    if (-not $axisMinValid -or -not $axisMaxValid) {
      Send-JsonResponse -Response $response -StatusCode 400 -Data @{
        error = "Informe os dois precos do eixo como numero (ex.: 1.30950 e 1.31300)."
      }
      return
    }
    if ($parsedAxisMin -ge $parsedAxisMax) {
      Send-JsonResponse -Response $response -StatusCode 400 -Data @{
        error = "O preco minimo do eixo precisa ser menor que o maximo."
      }
      return
    }
    $axisMin = $parsedAxisMin
    $axisMax = $parsedAxisMax
  }

  try {
    $imageBytes = [System.Convert]::FromBase64String($imageData)
  }
  catch {
    Send-JsonResponse -Response $response -StatusCode 400 -Data @{
      error = "Nao foi possivel decodificar a imagem enviada."
    }
    return
  }

  if ($imageBytes.Length -eq 0 -or $imageBytes.Length -gt $script:MaxImageBytes) {
    Send-JsonResponse -Response $response -StatusCode 413 -Data @{
      error = "A imagem precisa ter entre 1 byte e 12 MB."
    }
    return
  }

  if (-not (Test-ImageSignature -Bytes $imageBytes -MimeType $mimeType)) {
    Send-JsonResponse -Response $response -StatusCode 400 -Data @{
      error = "O conteudo do arquivo nao corresponde ao formato informado. Envie uma imagem PNG, JPG ou WEBP original."
    }
    return
  }

  # Preparo adaptativo: recorta apenas bordas vazias (limite de 12% por lado)
  # e realca o contraste somente quando o miolo do grafico esta apagado. Sem
  # ganho medido (ou formato nao suportado), o original segue intacto.
  $effectiveImageData = $imageData
  $preprocessTag = ""
  if ($script:ImageEnhanceMode -ne "off") {
    try {
      $prepared = ConvertTo-PreparedImageBytes -Bytes $imageBytes -MimeType $mimeType
      if ($prepared) {
        $effectiveImageData = [System.Convert]::ToBase64String([byte[]]$prepared.Bytes)
        $preprocessTag = if ($prepared.Tag) { "$($prepared.Tag)-v2" } else { "prepared-v2" }
        Write-Host "Imagem preparada para leitura: $preprocessTag ($($prepared.Width)x$($prepared.Height))."
      }
    }
    catch {
      Write-Warning "Nao foi possivel preparar a imagem; enviando o original: $($_.Exception.Message)"
    }
  }

  $cacheKey = Get-AnalysisCacheKey -ImageData $effectiveImageData -Market ([string]$body.market) `
    -Asset $asset -Timeframe ([string]$body.timeframe) -AxisMin $axisMin -AxisMax $axisMax `
    -Model $script:OpenAIModel -Preprocess $preprocessTag
  if ($script:AnalysisCacheTtlSeconds -gt 0) {
    $nowUtc = [datetime]::UtcNow
    foreach ($cachedKey in @($script:AnalysisCache.Keys)) {
      if (($nowUtc - $script:AnalysisCache[$cachedKey].At).TotalSeconds -ge $script:AnalysisCacheTtlSeconds) {
        $script:AnalysisCache.Remove($cachedKey)
      }
    }
    if ($script:AnalysisCache.ContainsKey($cacheKey)) {
      $cachedEntry = $script:AnalysisCache[$cacheKey]
      $headers = @{ "X-ZNX-Cache" = "hit" }
      if ($cachedEntry.Id)  { $headers["X-ZNX-Analysis-Id"] = [string]$cachedEntry.Id }
      if ($cachedEntry.Preprocess) { $headers["X-ZNX-Preprocess"] = [string]$cachedEntry.Preprocess }
      Send-JsonResponse -Response $response -StatusCode 200 `
        -Data $cachedEntry.Result `
        -ExtraHeaders $headers
      Write-Host "OK Analise reaproveitada do cache local (nenhuma chamada a OpenAI)."
      return
    }
  }

  $systemPrompt = $script:AnalysisSystemPrompt
  $userPrompt = @"
Contexto declarado pelo usuario, nao comprovado visualmente: mercado $marketName; ativo $assetDescription; timeframe escolhido: $timeframeName.
Nao use os dados do formulario como evidencia nem preencha com eles asset_visible/timeframe_visible. Identifique-os somente se estiverem legiveis na imagem.
"@
  if ($null -ne $axisMin -and $null -ne $axisMax) {
    $axisCulture = [System.Globalization.CultureInfo]::InvariantCulture
    $axisMinText = $axisMin.ToString("0.#####", $axisCulture)
    $axisMaxText = $axisMax.ToString("0.#####", $axisCulture)
    $userPrompt += @"

Escala do eixo informada pelo usuario e verificada: $axisMinText a $axisMaxText.
Use exatamente esses valores em price_axis_min e price_axis_max. Nenhum valor de levels pode ficar fora dessa faixa.
"@
  }

  $requestBody = @{
    model       = $script:OpenAIModel
    temperature = 0.0
    max_tokens  = $script:MaxOutputTokens
    store       = $false
    response_format = @{
      type = "json_schema"
      json_schema = @{
        name   = "chart_analysis"
        strict = $true
        schema = (New-AnalysisResponseSchema)
      }
    }
    messages = @(
      @{ role = "system"; content = $systemPrompt },
      @{
        role    = "user"
        content = @(
          @{ type = "text"; text = $userPrompt },
          @{
            type      = "image_url"
            image_url = @{
              url    = "data:$mimeType;base64,$effectiveImageData"
              detail = $script:ImageDetail
            }
          }
        )
      }
    )
  }

  $responseReceived = $false
  $statusCode       = 0
  $errorDetails     = ""
  $finishReason     = $null

  try {
    $jsonBody     = ConvertTo-Json -InputObject $requestBody -Depth 20 -Compress
    $openAIResult = Invoke-OpenAIRequest -JsonBody $jsonBody

    $statusCode   = $openAIResult.StatusCode
    $errorDetails = $openAIResult.Body

    if (-not $openAIResult.Success) {
      throw "OpenAI HTTP $statusCode (apos $($openAIResult.Attempts) tentativa(s) em $($openAIResult.ElapsedMs)ms)"
    }

    $responseReceived = $true
    $openAIResponse   = ConvertFrom-Json -InputObject $openAIResult.Body
    $finishReason     = [string]$openAIResponse.choices[0].finish_reason
    $responseText     = [string]$openAIResponse.choices[0].message.content

    if (-not $responseText) {
      throw "A OpenAI nao retornou uma analise legivel."
    }
    if ($finishReason -eq "length") {
      $retryTokenLimit = [int][Math]::Min(16000, [Math]::Max(8000, $script:MaxOutputTokens * 2))
      if ($retryTokenLimit -gt $script:MaxOutputTokens) {
        $initialElapsedMs = $openAIResult.ElapsedMs
        $initialAttempts = $openAIResult.Attempts
        Write-Warning "A resposta foi cortada. Repetindo a analise com limite de $retryTokenLimit tokens..."
        $requestBody.max_tokens = $retryTokenLimit
        $jsonBody = ConvertTo-Json -InputObject $requestBody -Depth 20 -Compress
        $openAIResult = Invoke-OpenAIRequest -JsonBody $jsonBody
        $openAIResult.ElapsedMs += $initialElapsedMs
        $openAIResult.Attempts += $initialAttempts
        $statusCode = $openAIResult.StatusCode
        $errorDetails = $openAIResult.Body

        if (-not $openAIResult.Success) {
          throw "OpenAI HTTP $statusCode na repeticao com limite de $retryTokenLimit tokens."
        }

        $openAIResponse = ConvertFrom-Json -InputObject $openAIResult.Body
        $finishReason = [string]$openAIResponse.choices[0].finish_reason
        $responseText = [string]$openAIResponse.choices[0].message.content
      }
      if ($finishReason -eq "length") {
        throw "A resposta da OpenAI continuou incompleta mesmo com o limite de saida configurado."
      }
      if (-not $responseText) {
        throw "A OpenAI nao retornou uma analise legivel na repeticao."
      }
    }

    $responseText = Remove-ModelReasoningBlock -Text $responseText
    if (-not $responseText) {
      throw "A OpenAI retornou apenas raciocinio, sem o JSON da analise."
    }
    $result = ConvertFrom-Json -InputObject $responseText
    $result = ConvertTo-ValidatedAnalysisResult -Result $result -AxisMin $axisMin -AxisMax $axisMax

    $promptTokens = 0
    $completionTokens = 0
    if ($openAIResponse.usage) {
      $promptTokens = [int]$openAIResponse.usage.prompt_tokens
      $completionTokens = [int]$openAIResponse.usage.completion_tokens
    }

    # Releitura automatica: gpt-4o-mini as vezes responde classe C/D para uma
    # captura que tem grafico. Em vez de devolver a recusa, o servidor repete a
    # leitura uma unica vez com a imagem original (sem realce) e um checklist.
    # O resultado so e trocado se a classe melhorar, e uma falha na releitura
    # nunca derruba a primeira leitura.
    $rereadOutcome = ""
    if ($script:RereadEnabled -and (Test-AnalysisRereadNeeded -Result $result)) {
      $firstClass = [string]$result.image_class
      $rereadImageData = if ($preprocessTag) { $imageData } else { $effectiveImageData }
      $rereadInstruction = New-ImageRereadInstruction -ImageClass $firstClass
      $requestBody.messages[1].content[0].text = "$userPrompt`n`n$rereadInstruction"
      $requestBody.messages[1].content[1].image_url.url = "data:$mimeType;base64,$rereadImageData"
      try {
        $rereadJsonBody = ConvertTo-Json -InputObject $requestBody -Depth 20 -Compress
        $rereadResponse = Invoke-OpenAIRequest -JsonBody $rereadJsonBody
        $rereadOutcome = "kept"
        if ($rereadResponse.Success) {
          $rereadPayload = ConvertFrom-Json -InputObject $rereadResponse.Body
          if ($rereadPayload.usage) {
            $promptTokens += [int]$rereadPayload.usage.prompt_tokens
            $completionTokens += [int]$rereadPayload.usage.completion_tokens
          }
          $rereadText = [string]$rereadPayload.choices[0].message.content
          $rereadFinishReason = [string]$rereadPayload.choices[0].finish_reason
          if ($rereadText -and $rereadFinishReason -ne "length") {
            $rereadText = Remove-ModelReasoningBlock -Text $rereadText
            if ($rereadText) {
              $rereadResult = ConvertTo-ValidatedAnalysisResult `
                -Result (ConvertFrom-Json -InputObject $rereadText) `
                -AxisMin $axisMin -AxisMax $axisMax
              $rereadClass = [string]$rereadResult.image_class
              $improved = (Get-ImageClassRank -ImageClass $rereadClass) -gt (Get-ImageClassRank -ImageClass $firstClass)
              if ($improved) {
                $result = $rereadResult
                $effectiveImageData = $rereadImageData
                $openAIResult = $rereadResponse
                $rereadOutcome = "improved"
              }
            }
          }
        }
        else {
          $rereadOutcome = "failed"
        }
      }
      catch {
        $rereadOutcome = "failed"
        Write-Warning "Releitura automatica nao concluida; mantendo a primeira leitura: $($_.Exception.Message)"
      }
      Write-Host "Releitura da imagem: $firstClass -> $([string]$result.image_class) ($rereadOutcome)."
    }

    # Toda analise aprovada vira uma linha em logs\analyses.jsonl com um id
    # estavel. O painel usa esse id para enviar feedback e o desfecho real pode
    # ser registrado depois com tools\record-outcome.ps1.
    $analysisId = [guid]::NewGuid().ToString("N")
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
      $imageHash = ([System.BitConverter]::ToString(
        $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($effectiveImageData))
      ) -replace "-", "").ToLowerInvariant()
    }
    finally {
      $sha.Dispose()
    }
    Add-JsonLogLine -Path (Join-Path $script:LogDir "analyses.jsonl") -Data ([ordered]@{
      id                = $analysisId
      at                = [datetime]::UtcNow.ToString("o")
      market            = [string]$body.market
      asset             = $asset
      timeframe         = [string]$body.timeframe
      model             = $script:OpenAIModel
      contract          = Get-AnalysisContractVersion
      direction         = [string]$result.direction
      action            = [string]$result.signal_timing.action
      confidence        = [int]$result.confidence
      image_class       = [string]$result.image_class
      visual_quality    = [int]$result.visual_quality
      analysis_coverage = [int]$result.analysis_coverage
      preprocess        = $preprocessTag
      reread            = $rereadOutcome
      image_sha256      = $imageHash
    })

    # Quando a leitura final continua sendo "sem grafico", a captura original
    # fica guardada em disco: sem ela um novo relato de falha nao e reproduzivel.
    if ([string]$result.image_class -in @("C", "D")) {
      try {
        if (-not (Test-Path -LiteralPath $script:LogDir)) {
          [void](New-Item -ItemType Directory -Path $script:LogDir -Force)
        }
        $refusedExtension = switch ($mimeType) {
          "image/png" { "png" }
          "image/jpeg" { "jpg" }
          default { "webp" }
        }
        $refusedPath = Join-Path $script:LogDir "last-refused-image.$refusedExtension"
        [System.IO.File]::WriteAllBytes($refusedPath, $imageBytes)
        Write-Host "Imagem recusada guardada para diagnostico em $refusedPath"
      }
      catch {
        Write-Warning "Nao foi possivel guardar a imagem recusada para diagnostico."
      }
    }

    if ($script:AnalysisCacheTtlSeconds -gt 0) {
      if ($script:AnalysisCache.Count -ge $script:AnalysisCacheMaxEntries) {
        $oldestKey = @($script:AnalysisCache.Keys |
          Sort-Object { $script:AnalysisCache[$_].At })[0]
        if ($oldestKey) { $script:AnalysisCache.Remove($oldestKey) }
      }
      $script:AnalysisCache[$cacheKey] = @{
        At = [datetime]::UtcNow; Result = $result; Id = $analysisId; Preprocess = $preprocessTag
      }
    }

    $usageText = if ($promptTokens -gt 0) {
      " | tokens: $promptTokens entrada / $completionTokens saida"
    }
    else { "" }
    $preprocessText = if ($preprocessTag) { " | imagem realcada ($preprocessTag)" } else { "" }
    $resultHeaders = @{
      "X-ZNX-Analysis-Id" = $analysisId
      "X-ZNX-Preprocess"  = $preprocessTag
    }
    if ($rereadOutcome) { $resultHeaders["X-ZNX-Reread"] = $rereadOutcome }
    Send-JsonResponse -Response $response -StatusCode 200 -Data $result `
      -ExtraHeaders $resultHeaders
    Write-Host "OK Analise $analysisId concluida em $($openAIResult.ElapsedMs) ms ($($openAIResult.Attempts) tentativa(s), modelo $($script:OpenAIModel))$usageText$preprocessText."
    return
  }
  catch {
    $errorMessage = "A analise falhou. Confira o diagnostico e tente novamente."
    if ($statusCode -eq 0 -and $_.Exception.Response) {
      try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { $statusCode = 0 }
    }
    if (-not $errorDetails) {
      $errorDetails = [string]$_.ErrorDetails.Message
    }
    $providerMessage = $null
    if ($errorDetails) {
      try {
        $providerError   = ConvertFrom-Json -InputObject $errorDetails
        $providerMessage = [string]$providerError.error.message
      }
      catch { $providerMessage = $null }
    }

    # A resposta que falhou na validacao fica gravada para diagnostico local:
    # sem ela, todo erro de contrato aparece como a mesma mensagem generica.
    if ($responseReceived -and $statusCode -eq 200 -and $responseText) {
      try {
        $logDir = $script:LogDir
        if (-not (Test-Path -LiteralPath $logDir)) {
          [void](New-Item -ItemType Directory -Path $logDir -Force)
        }
        $failurePath = Join-Path $logDir "last-analysis-failure.json"
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($failurePath, $responseText, $utf8NoBom)
        Write-Host "Resposta bruta da IA gravada em $failurePath"
      }
      catch {
        Write-Warning "Nao foi possivel gravar a resposta bruta da IA para diagnostico."
      }
    }

    $diagnostic = if ($providerMessage) { $providerMessage } else { $_.Exception.Message }
    if ($env:OPENAI_API_KEY) {
      $diagnostic = $diagnostic -replace [regex]::Escape($env:OPENAI_API_KEY), "[chave oculta]"
    }
    $diagnostic = $diagnostic -replace "(?i)Bearer\s+\S+", "Bearer [oculto]"
    $detailForUser = $diagnostic
    if ($detailForUser.Length -gt 220) {
      $detailForUser = $detailForUser.Substring(0, 220) + "..."
    }
    Write-Warning "Falha na analise com OpenAI (HTTP $statusCode): $diagnostic"

    $errorMessage = Get-AnalysisFailureMessage `
      -StatusCode $statusCode `
      -Diagnostic $detailForUser `
      -ResponseReceived $responseReceived `
      -FinishReason $finishReason
    if ($responseReceived -and $statusCode -eq 200) {
      $errorMessage = "Falha na validacao da resposta da IA: $detailForUser"
    }

    $clientStatus = if ($statusCode -in @(401, 429)) { $statusCode } else { 502 }
    Send-JsonResponse -Response $response -StatusCode $clientStatus -Data @{ error = $errorMessage }
  }
}

# =====================================================================
# FEEDBACK HUMANO
# =====================================================================
function Invoke-AnalysisFeedback {
  # Fecha o ciclo do lado humano: o usuario marca se a leitura acertou, errou
  # ou inventou um nivel. O evento vai para logs\feedback.jsonl e pode ser
  # cruzado com o resultado real por tools\evaluate.ps1.
  param($Context)
  $request  = $Context.Request
  $response = $Context.Response

  if ($request.ContentType -notmatch '^application/json(?:\s*;|$)') {
    Send-JsonResponse -Response $response -StatusCode 415 -Data @{
      error = "O endpoint de feedback aceita somente solicitacoes JSON."
    }
    return
  }
  if ($request.ContentLength64 -gt 8192) {
    Send-JsonResponse -Response $response -StatusCode 413 -Data @{
      error = "O feedback excede o limite de 8 KB."
    }
    return
  }

  $reader = $null
  try {
    $encoding = if ($request.ContentEncoding) { $request.ContentEncoding } else { [System.Text.Encoding]::UTF8 }
    $reader = [System.IO.StreamReader]::new($request.InputStream, $encoding)
    $raw = $reader.ReadToEnd()
  }
  catch {
    Send-JsonResponse -Response $response -StatusCode 400 -Data @{
      error = "Nao foi possivel ler o feedback enviado."
    }
    return
  }
  finally {
    if ($reader) { $reader.Dispose() }
  }

  if ([string]::IsNullOrWhiteSpace($raw) -or $raw.Length -gt 8192) {
    Send-JsonResponse -Response $response -StatusCode 400 -Data @{
      error = "O feedback enviado nao contem JSON valido."
    }
    return
  }

  try {
    $body = ConvertFrom-Json -InputObject $raw
  }
  catch {
    Send-JsonResponse -Response $response -StatusCode 400 -Data @{
      error = "O feedback enviado nao contem JSON valido."
    }
    return
  }
  if ($null -eq $body -or $body -is [array] -or $body -isnot [System.Management.Automation.PSCustomObject]) {
    Send-JsonResponse -Response $response -StatusCode 400 -Data @{
      error = "O feedback precisa ser um objeto JSON."
    }
    return
  }

  $analysisId = ([string]$body.analysisId).Trim()
  $verdict    = ([string]$body.verdict).Trim().ToLowerInvariant()
  $note       = [string]$body.note
  if ($analysisId -notmatch '^[a-fA-F0-9]{32}$') {
    Send-JsonResponse -Response $response -StatusCode 400 -Data @{
      error = "Informe o identificador da analise que recebeu o feedback."
    }
    return
  }
  if ($verdict -notin @("hit", "miss", "invented_level")) {
    Send-JsonResponse -Response $response -StatusCode 400 -Data @{
      error = "Veredito invalido. Use hit, miss ou invented_level."
    }
    return
  }
  if ($note.Length -gt 280) { $note = $note.Substring(0, 280) }

  try {
    Add-JsonLogLine -Path (Join-Path $script:LogDir "feedback.jsonl") -Data ([ordered]@{
      at         = [datetime]::UtcNow.ToString("o")
      analysisId = $analysisId.ToLowerInvariant()
      verdict    = $verdict
      note       = $note
      model      = $script:OpenAIModel
      contract   = Get-AnalysisContractVersion
    })
  }
  catch {
    Write-Warning "Nao foi possivel registrar o feedback: $($_.Exception.Message)"
    Send-JsonResponse -Response $response -StatusCode 500 -Data @{
      error = "O feedback nao pode ser gravado no disco."
    }
    return
  }

  Send-JsonResponse -Response $response -StatusCode 200 -Data @{ ok = $true }
  Write-Host "Feedback registrado para a analise $analysisId ($verdict)."
}

# =====================================================================
# LOOP PRINCIPAL
# =====================================================================
# =====================================================================
# CALIBRACAO (feedback humano + desfecho real)
# ---------------------------------------------------------------------
# O confidence que a IA devolve e uma rubrica do prompt. Aqui ele e cruzado
# com o que o proprio projeto ja registrou: veredito do usuario
# (logs/feedback.jsonl) e resultado real do mercado (data/outcomes.jsonl).
# Sem amostra, a resposta diz que nao ha amostra; nunca inventa percentual.
# =====================================================================
function Read-ZnxJsonLines {
  param([Parameter(Mandatory = $true)][string]$Path)
  $rows = New-Object System.Collections.Generic.List[object]
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
  foreach ($line in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $rows.Add((ConvertFrom-Json -InputObject $line)) } catch { }
  }
  # Sem a virgula de retorno: os chamadores usam @() para achatar a lista.
  return $rows.ToArray()
}

function Get-ZnxConfidenceBucket {
  param([Parameter(Mandatory = $true)][double]$Confidence)
  # Regra unica (market.psm1): inteiro truncado, faixas contiguas. Sem isso o
  # painel classificava 69,5 em 70-84 e o relatorio deixava a amostra fora.
  return Get-ZnxConfidenceBucketLabel -Confidence $Confidence
}

function Get-ZnxCalibrationReport {
  $analyses = @(Read-ZnxJsonLines -Path (Join-Path $script:LogDir "analyses.jsonl"))
  $feedback = @(Read-ZnxJsonLines -Path (Join-Path $script:LogDir "feedback.jsonl"))
  $outcomes = @(Read-ZnxJsonLines -Path $script:OutcomesPath)

  $confidenceById = @{}
  foreach ($row in $analyses) {
    $id = [string]$row.id
    if (-not $id) { continue }
    # Confidence invalido nao entra no mapa: nao vira zero nem quebra a API.
    $confidence = ConvertTo-ZnxConfidenceNumber -Confidence $row.confidence
    if ($null -eq $confidence) { continue }
    $confidenceById[$id] = $confidence
  }

  $bucketOrder = @("0-54", "55-69", "70-84", "85-100")
  $report = [ordered]@{}
  foreach ($label in $bucketOrder) {
    $report[$label] = [ordered]@{
      bucket         = $label
      analyses       = 0
      hit            = 0
      miss           = 0
      inventedLevel  = 0
      outcomeSamples = 0
      outcomeHits    = 0
    }
  }
  $confidenceSum = @{}
  $confidenceCount = @{}
  foreach ($label in $bucketOrder) { $confidenceSum[$label] = 0.0; $confidenceCount[$label] = 0 }

  foreach ($row in $analyses) {
    $confidence = ConvertTo-ZnxConfidenceNumber -Confidence $row.confidence
    # Registro com confidence invalido fica fora da faixa em vez de virar 0-54.
    if ($null -eq $confidence) { continue }
    $label = Get-ZnxConfidenceBucket -Confidence $confidence
    $report[$label].analyses = [int]$report[$label].analyses + 1
    $confidenceSum[$label] = [double]$confidenceSum[$label] + [double]$row.confidence
    $confidenceCount[$label] = [int]$confidenceCount[$label] + 1
  }

  foreach ($row in $feedback) {
    $id = [string]$row.analysisId
    if (-not $confidenceById.ContainsKey($id)) { continue }
    $label = Get-ZnxConfidenceBucket -Confidence $confidenceById[$id]
    switch ([string]$row.verdict) {
      "hit"            { $report[$label].hit = [int]$report[$label].hit + 1 }
      "miss"           { $report[$label].miss = [int]$report[$label].miss + 1 }
      "invented_level" { $report[$label].inventedLevel = [int]$report[$label].inventedLevel + 1 }
    }
  }

  foreach ($row in $outcomes) {
    if ([string]$row.outcome -notin @("favorable", "adverse")) { continue }
    if ([string]$row.direction -notin @("BUY", "SELL")) { continue }
    $confidence = ConvertTo-ZnxConfidenceNumber -Confidence $row.confidence
    # Registro com confidence invalido fica fora da faixa em vez de virar 0-54.
    if ($null -eq $confidence) { continue }
    $label = Get-ZnxConfidenceBucket -Confidence $confidence
    $report[$label].outcomeSamples = [int]$report[$label].outcomeSamples + 1
    if ([string]$row.outcome -eq "favorable") {
      $report[$label].outcomeHits = [int]$report[$label].outcomeHits + 1
    }
  }

  $buckets = New-Object System.Collections.Generic.List[object]
  foreach ($label in $bucketOrder) {
    $entry = $report[$label]
    $graded = [int]$entry.hit + [int]$entry.miss
    $hitRate = $null
    if ($graded -gt 0) { $hitRate = [Math]::Round(([int]$entry.hit / [double]$graded) * 100.0, 1) }
    $outcomeRate = $null
    if ([int]$entry.outcomeSamples -gt 0) {
      $outcomeRate = [Math]::Round(
        ([int]$entry.outcomeHits / [double]$entry.outcomeSamples) * 100.0, 1)
    }
    $meanConfidence = $null
    if ([int]$confidenceCount[$label] -gt 0) {
      $meanConfidence = [Math]::Round($confidenceSum[$label] / [double]$confidenceCount[$label], 1)
    }
    $bias = $null
    if ($null -ne $hitRate -and $null -ne $meanConfidence) {
      $bias = [Math]::Round([double]$hitRate - [double]$meanConfidence, 1)
    }
    $buckets.Add([ordered]@{
      bucket         = $label
      analyses       = [int]$entry.analyses
      feedbackHit    = [int]$entry.hit
      feedbackMiss   = [int]$entry.miss
      inventedLevel  = [int]$entry.inventedLevel
      graded         = $graded
      hitRate        = $hitRate
      outcomeSamples = [int]$entry.outcomeSamples
      outcomeRate    = $outcomeRate
      meanConfidence = $meanConfidence
      bias           = $bias
    })
  }

  # Mesma conta de tools/evaluate.ps1 (market.psm1): erro quadratico de
  # consistencia so com desfechos favorable/adverse de BUY/SELL. Sem amostra
  # os campos ficam nulos.
  $consistency = Get-ZnxConfidenceOutcomeError -Outcomes $outcomes

  return [ordered]@{
    at      = [datetime]::UtcNow.ToString("o")
    buckets = $buckets.ToArray()
    totals  = [ordered]@{
      analyses = $analyses.Count
      feedback = $feedback.Count
      outcomes = $outcomes.Count
    }
    confidenceOutcomeError = $consistency.confidenceOutcomeError
    sampleCount            = $consistency.sampleCount
    invalidSampleCount     = $consistency.invalidSampleCount
    confidenceOutcomeBands = $consistency.bands
    note = "Calibracao calculada com o feedback e os desfechos registrados neste projeto. Faixas sem amostra ficam sem taxa. O erro quadratico de consistencia usa apenas desfechos favorable/adverse de sinais BUY/SELL com confidence numerico entre 0 e 100; sem amostra o campo fica nulo, e o numero nao representa probabilidade de acerto."
  }
}

# =====================================================================
# MAQUINA DO TEMPO: JOB COM PROGRESSO REAL
# ---------------------------------------------------------------------
# O calculo roda em um runspace separado e publica o progresso em uma
# hashtable sincronizada. A tela mostra o que ja foi processado de fato
# (candles e reamostragens), sem barra que anda sozinha.
# =====================================================================
$script:BacktestJob = $null
$script:BacktestHandle = $null

function New-ZnxBacktestProgress {
  param([Parameter(Mandatory = $true)][string]$Symbol)
  return [hashtable]::Synchronized(@{
    state     = "running"
    phase     = "candles"
    done      = 0
    total     = 0
    trades    = 0
    symbol    = $Symbol
    startedAt = [datetime]::UtcNow
    result    = $null
    error     = $null
  })
}

function Get-ZnxBacktestProgressPayload {
  param([Parameter(Mandatory = $true)]$Job)
  $elapsedMs = [int][Math]::Round(([datetime]::UtcNow - [datetime]$Job["startedAt"]).TotalMilliseconds)
  return [ordered]@{
    state     = [string]$Job["state"]
    phase     = [string]$Job["phase"]
    symbol    = [string]$Job["symbol"]
    done      = [int]$Job["done"]
    total     = [int]$Job["total"]
    trades    = [int]$Job["trades"]
    elapsedMs = $elapsedMs
    result    = if ([string]$Job["state"] -eq "done") { $Job["result"] } else { $null }
    error     = if ([string]$Job["state"] -eq "failed" -and $Job["error"]) { [string]$Job["error"] } else { $null }
  }
}

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("$($script:ListenOrigin)/")

try {
  $listener.Start()
}
catch {
  throw "Nao foi possivel iniciar o site em $($script:ListenOrigin)/. Verifique se a porta $($script:ListenPort) ja esta em uso. $($_.Exception.Message)"
}

Write-Host "Scalping Edge disponivel em $($script:ListenOrigin)/"
Write-Host "Modelo: $($script:OpenAIModel) | max_tokens: $($script:MaxOutputTokens) | detail: $($script:ImageDetail) | retries: $($script:MaxRetries) | realce: $($script:ImageEnhanceMode) | releitura: $(if ($script:RereadEnabled) { 'on' } else { 'off' })"
if (-not $env:OPENAI_API_KEY) {
  Write-Warning "OPENAI_API_KEY nao esta configurada. A analise nao ficara disponivel ate configurar a chave e reiniciar."
}
Write-Host "Pressione Ctrl+X para reiniciar o servidor. Pressione Ctrl+A para encerrar."
if ($global:OpenBrowserOnStart -ne $false -and -not $env:ZNX_NO_BROWSER) {
  Start-Process "$($script:ListenOrigin)/"
  $global:OpenBrowserOnStart = $false
}

try {
  $canReadShutdownShortcut = -not [Console]::IsInputRedirected
  while ($listener.IsListening) {
    $pendingContext = $listener.BeginGetContext($null, $null)
    while (-not $pendingContext.AsyncWaitHandle.WaitOne(100)) {
      if ($canReadShutdownShortcut -and [Console]::KeyAvailable) {
        $keyInfo = [Console]::ReadKey($true)
        if ($keyInfo.Key -eq [ConsoleKey]::A -and
            ($keyInfo.Modifiers -band [ConsoleModifiers]::Control)) {
          Write-Host "`nEncerrando o servidor..."
          $global:RestartRequested = $false
          $listener.Stop()
          break
        }
        if ($keyInfo.Key -eq [ConsoleKey]::X -or [int]$keyInfo.KeyChar -eq 24) {
          Write-Host "`nReiniciando o servidor..."
          $global:RestartRequested = $true
          $listener.Stop()
          break
        }
      }
    }

    if (-not $listener.IsListening) { break }

    try {
      $context = $listener.EndGetContext($pendingContext)
    }
    catch {
      # Conexao aberta e fechada antes de completar a requisicao (preconnect
      # do navegador, aba fechada, sonda de porta). Nao pode encerrar o laco.
      Write-Verbose "Conexao descartada: $($_.Exception.Message)"
      continue
    }
    if ($null -eq $context) { continue }

    $request     = $context.Request
    $response    = $context.Response
    $requestPath = [uri]::UnescapeDataString($request.Url.AbsolutePath)
    if ($requestPath.Length -gt 1) { $requestPath = $requestPath.TrimEnd("/") }

    Write-Host "$($request.HttpMethod) $requestPath"

    try {
      if ($request.HttpMethod -eq "GET" -and $requestPath -eq "/api/status") {
        $openAIStatus = Get-OpenAIConnectionStatus
        Send-JsonResponse -Response $response -StatusCode 200 -Data @{
          running           = $true
          modelAvailable    = [bool]$env:OPENAI_API_KEY
          connectionState   = $openAIStatus.state
          connectionMessage = $openAIStatus.message
          provider          = "openai"
          model             = $script:OpenAIModel
        }
        continue
      }

      if ($request.HttpMethod -eq "GET" -and $requestPath -eq "/api/market") {
        try {
          # As noticias sairam daqui: agora vivem em /api/news, na pagina delas.
          Send-JsonResponse -Response $response -StatusCode 200 -Data (Get-ZnxMarketSnapshot)
        }
        catch {
          Write-Warning "Radar de mercado indisponivel: $($_.Exception.Message)"
          Send-JsonResponse -Response $response -StatusCode 502 -Data @{
            error = "Nao foi possivel carregar as cotacoes agora. Verifique a conexao com a internet e tente atualizar."
          }
        }
        continue
      }

      if ($request.HttpMethod -eq "GET" -and $requestPath -eq "/api/news") {
        try {
          $limit = 600
          $rawLimit = [string]$request.QueryString["limit"]
          if ($rawLimit) {
            $parsedLimit = 0
            if ([int]::TryParse($rawLimit, [ref]$parsedLimit) -and $parsedLimit -gt 0) {
              $limit = [Math]::Min($parsedLimit, 900)
            }
          }
          Send-JsonResponse -Response $response -StatusCode 200 -Data (Get-ZnxMarketNews -MaxItems $limit)
        }
        catch {
          Write-Warning "Noticias indisponiveis: $($_.Exception.Message)"
          Send-JsonResponse -Response $response -StatusCode 502 -Data @{
            error = "Nao foi possivel carregar as noticias agora. Verifique a conexao e tente de novo."
          }
        }
        continue
      }

      if ($request.HttpMethod -eq "GET" -and $requestPath -eq "/api/calibration") {
        try {
          Send-JsonResponse -Response $response -StatusCode 200 -Data (Get-ZnxCalibrationReport)
        }
        catch {
          Write-Warning "Calibracao indisponivel: $($_.Exception.Message)"
          Send-JsonResponse -Response $response -StatusCode 500 -Data @{
            error = "Nao foi possivel ler o historico de calibracao agora."
          }
        }
        continue
      }

      if ($request.HttpMethod -eq "GET" -and $requestPath -eq "/api/chart") {
        try {
          $chartSymbol = [string]$request.QueryString["symbol"]
          if ([string]::IsNullOrWhiteSpace($chartSymbol)) { $chartSymbol = "BTC-USD" }
          $chartInterval = [string]$request.QueryString["interval"]
          if ([string]::IsNullOrWhiteSpace($chartInterval)) { $chartInterval = "5m" }
          Send-JsonResponse -Response $response -StatusCode 200 -Data (Get-ZnxChartSeries -Symbol $chartSymbol -Interval $chartInterval)
        }
        catch {
          Write-Warning "Grafico indisponivel: $($_.Exception.Message)"
          Send-JsonResponse -Response $response -StatusCode 502 -Data @{
            error = "Nao foi possivel montar o grafico agora. Tente outro ativo ou periodo."
          }
        }
        continue
      }

      if ($request.HttpMethod -eq "GET" -and $requestPath -eq "/api/scanner") {
        try {
          Send-JsonResponse -Response $response -StatusCode 200 -Data (Get-ZnxScanner)
        }
        catch {
          Write-Warning "Varredor indisponivel: $($_.Exception.Message)"
          Send-JsonResponse -Response $response -StatusCode 502 -Data @{
            error = "A varredura nao conseguiu dados agora. Tente novamente em alguns instantes."
          }
        }
        continue
      }

      if ($request.HttpMethod -eq "GET" -and $requestPath -eq "/api/backtest") {
        $symbol = [string]$request.QueryString["symbol"]
        if ([string]::IsNullOrWhiteSpace($symbol)) {
          Send-JsonResponse -Response $response -StatusCode 400 -Data @{
            error = "Informe o ativo para simular (ex.: ?symbol=BTC-USD)."
          }
          continue
        }
        $trackedSymbols = Get-ZnxTrackedSymbols
        if ($trackedSymbols -notcontains $symbol) {
          Send-JsonResponse -Response $response -StatusCode 400 -Data @{
            error = "Ativo fora da lista acompanhada. Escolha um ativo do radar."
          }
          continue
        }
        $simulations = 10000
        $simulationsRaw = [string]$request.QueryString["simulations"]
        $parsedSimulations = 0
        if ([int]::TryParse($simulationsRaw, [ref]$parsedSimulations)) {
          $simulations = [Math]::Max(1000, [Math]::Min(20000, $parsedSimulations))
        }
        try {
          Send-JsonResponse -Response $response -StatusCode 200 -Data (Invoke-ZnxBacktest `
            -Symbol $symbol -Simulations $simulations)
        }
        catch {
          Write-Warning "Backtest indisponivel para $($symbol): $($_.Exception.Message)"
          Send-JsonResponse -Response $response -StatusCode 502 -Data @{
            error = "Nao foi possivel simular $symbol agora. Tente novamente em alguns instantes."
          }
        }
        continue
      }

      if ($request.HttpMethod -eq "GET" -and $requestPath -eq "/api/backtest/start") {
        $symbol = [string]$request.QueryString["symbol"]
        if ([string]::IsNullOrWhiteSpace($symbol)) {
          Send-JsonResponse -Response $response -StatusCode 400 -Data @{
            error = "Informe o ativo para simular (ex.: ?symbol=BTC-USD)."
          }
          continue
        }
        $trackedSymbols = Get-ZnxTrackedSymbols
        if ($trackedSymbols -notcontains $symbol) {
          Send-JsonResponse -Response $response -StatusCode 400 -Data @{
            error = "Ativo fora da lista acompanhada. Escolha um ativo do radar."
          }
          continue
        }
        if ($null -ne $script:BacktestJob -and [string]$script:BacktestJob["state"] -eq "running") {
          Send-JsonResponse -Response $response -StatusCode 409 -Data ([ordered]@{
            error    = "Ja existe uma simulacao rodando. Aguarde o fim dela."
            progress = (Get-ZnxBacktestProgressPayload -Job $script:BacktestJob)
          })
          continue
        }
        if ($null -ne $script:BacktestHandle) {
          try { $script:BacktestHandle.Dispose() } catch { }
          $script:BacktestHandle = $null
        }

        $progress = New-ZnxBacktestProgress -Symbol $symbol
        $script:BacktestJob = $progress
        $modulePath = Join-Path $PSScriptRoot "market.psm1"
        try {
          $job = [powershell]::Create()
          [void]$job.AddScript({
            param($ModulePath, $Symbol, $Progress)
            try {
              Import-Module -Name $ModulePath -Force
              $result = Invoke-ZnxBacktest -Symbol $Symbol -Simulations 10000 -Progress $Progress
              if ($null -eq $result) { throw "A simulacao nao retornou resultado." }
              $Progress["result"] = $result
              $Progress["state"] = "done"
            }
            catch {
              $Progress["error"] = $_.Exception.Message
              $Progress["state"] = "failed"
            }
          }).AddArgument($modulePath).AddArgument($symbol).AddArgument($progress)
          $script:BacktestHandle = $job
          [void]$job.BeginInvoke()
          Send-JsonResponse -Response $response -StatusCode 202 `
            -Data (Get-ZnxBacktestProgressPayload -Job $progress)
        }
        catch {
          $script:BacktestJob = $null
          $script:BacktestHandle = $null
          Write-Warning "Nao foi possivel iniciar a simulacao: $($_.Exception.Message)"
          Send-JsonResponse -Response $response -StatusCode 500 -Data @{
            error = "Nao foi possivel iniciar a simulacao agora."
          }
        }
        continue
      }

      if ($request.HttpMethod -eq "GET" -and $requestPath -eq "/api/backtest/progress") {
        if ($null -eq $script:BacktestJob) {
          Send-JsonResponse -Response $response -StatusCode 200 -Data ([ordered]@{ state = "idle" })
          continue
        }
        $payload = Get-ZnxBacktestProgressPayload -Job $script:BacktestJob
        $state = [string]$script:BacktestJob["state"]
        if ($state -ne "running" -and $null -ne $script:BacktestHandle) {
          try { $script:BacktestHandle.Dispose() } catch { }
          $script:BacktestHandle = $null
        }
        Send-JsonResponse -Response $response -StatusCode 200 -Data $payload
        continue
      }

      if ($request.HttpMethod -eq "GET" -and $requestPath -eq "/api/plan") {
        $symbol = [string]$request.QueryString["symbol"]
        if ([string]::IsNullOrWhiteSpace($symbol)) {
          Send-JsonResponse -Response $response -StatusCode 400 -Data @{
            error = "Informe o ativo para montar o plano (ex.: ?symbol=BTC-USD)."
          }
          continue
        }
        $trackedSymbols = Get-ZnxTrackedSymbols
        if ($trackedSymbols -notcontains $symbol) {
          Send-JsonResponse -Response $response -StatusCode 400 -Data @{
            error = "Ativo fora da lista acompanhada. Escolha um ativo do radar."
          }
          continue
        }
        try {
          $candles = Get-ZnxMarketCandles -Symbol $symbol -Range "5d" -Interval "5m"
          $plan = Get-ZnxTradePlan -High $candles.High -Low $candles.Low `
            -Close $candles.Close -Price $candles.Price
          Send-JsonResponse -Response $response -StatusCode 200 -Data ([ordered]@{
            symbol    = $symbol
            label     = [string]$candles.Label
            at        = [datetime]::UtcNow.ToString("o")
            timeframe = "5m"
            plan      = $plan
          })
        }
        catch {
          Write-Warning "Plano indisponivel para $($symbol): $($_.Exception.Message)"
          Send-JsonResponse -Response $response -StatusCode 502 -Data @{
            error = "Nao foi possivel montar o plano de $symbol agora. Tente novamente."
          }
        }
        continue
      }

      if ($request.HttpMethod -eq "POST" -and $requestPath -eq "/api/analyze") {
        $requestHost   = $request.Headers["Host"]
        $requestOrigin = $request.Headers["Origin"]
        if (-not [string]::Equals($requestHost, $script:ListenHost, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals($requestOrigin, $script:ListenOrigin, [System.StringComparison]::OrdinalIgnoreCase)) {
          Send-JsonResponse -Response $response -StatusCode 403 -Data @{
            error = "Origem nao autorizada para analise. Abra o site em $($script:ListenOrigin)/."
          }
          continue
        }
        Invoke-ImageAnalysis -Context $context
        continue
      }

      if ($requestPath -eq "/api/feedback") {
        if ($request.HttpMethod -ne "POST") {
          Send-JsonResponse -Response $response -StatusCode 405 -Data @{
            error = "Use POST para registrar o feedback de uma analise."
          }
          continue
        }
        $feedbackHost   = $request.Headers["Host"]
        $feedbackOrigin = $request.Headers["Origin"]
        if (-not [string]::Equals($feedbackHost, $script:ListenHost, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals($feedbackOrigin, $script:ListenOrigin, [System.StringComparison]::OrdinalIgnoreCase)) {
          Send-JsonResponse -Response $response -StatusCode 403 -Data @{
            error = "Origem nao autorizada para feedback. Abra o site em $($script:ListenOrigin)/."
          }
          continue
        }
        Invoke-AnalysisFeedback -Context $context
        continue
      }

      if ($requestPath -eq "/api/analyze") {
        Send-JsonResponse -Response $response -StatusCode 405 -Data @{
          error = "Use POST para analisar a imagem. Abra o site em http://127.0.0.1:8765/."
        }
        continue
      }

      if ($request.HttpMethod -ne "GET") {
        Send-TextResponse -Response $response -StatusCode 405 -Message "Metodo nao permitido."
        continue
      }

      if ($requestPath -eq "/") { $requestPath = "/pages/index.html" }

      $relativePath = $requestPath.TrimStart("/")
      $allowedStaticPaths = @(
        "pages/index.html", "pages/radar.html", "pages/noticias.html", "pages/historico.html",
        "assets/css/style.css", "assets/js/app.js", "assets/js/analysis-format.js",
        "assets/js/radar.js", "assets/js/pages.js", "assets/js/news.js",
        "assets/js/history-page.js"
      )
      if ($relativePath -notin $allowedStaticPaths) {
        Send-TextResponse -Response $response -StatusCode 404 -Message "Arquivo nao encontrado."
        continue
      }

      $filePath = [System.IO.Path]::GetFullPath(
        [System.IO.Path]::Combine($script:ProjectRoot, $relativePath.Replace("/", [System.IO.Path]::DirectorySeparatorChar))
      )
      if (-not $filePath.StartsWith($script:RootPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
          -not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Send-TextResponse -Response $response -StatusCode 404 -Message "Arquivo nao encontrado."
        continue
      }

      $fileBytes = [System.IO.File]::ReadAllBytes($filePath)
      Send-ResponseBytes -Response $response -StatusCode 200 `
        -ContentType (Get-StaticContentType -Path $filePath) -Bytes $fileBytes
    }
    catch {
      # Warning, nao Error: com $ErrorActionPreference = "Stop" um Write-Error
      # aqui encerraria o servidor inteiro por causa de uma requisicao so.
      Write-Warning "Falha ao processar $($request.HttpMethod) $requestPath : $($_.Exception.Message)"
      try {
        if ($requestPath -like "/api/*") {
          Send-JsonResponse -Response $response -StatusCode 500 -Data @{
            error = "O servidor encontrou um erro ao processar a solicitacao. Feche a janela do servidor, inicie novamente com start.bat e tente outra vez."
          }
        }
        else {
          Send-TextResponse -Response $response -StatusCode 500 -Message "O servidor encontrou um erro ao carregar esta pagina."
        }
      }
      catch {
        Write-Verbose "Nao foi possivel enviar a resposta de erro: $($_.Exception.Message)"
      }
    }
  }
}
finally {
  $listener.Stop()
  $listener.Close()
  if ($script:AnalysisClient) { $script:AnalysisClient.Dispose() }
  if ($script:StatusClient)   { $script:StatusClient.Dispose() }
}