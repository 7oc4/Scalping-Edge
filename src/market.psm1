# =====================================================================
# MERCADO: cotacoes, noticias, varredor, maquina do tempo e risco
# ---------------------------------------------------------------------
# Fonte publica: Yahoo Finance (chart + RSS de noticias), sem chave.
# Nada aqui simula preco: se a fonte nao responder, a funcao lanca erro e
# a rota devolve 502 em vez de inventar numero.
# =====================================================================

$script:YahooChartBase = "https://query1.finance.yahoo.com/v8/finance/chart"
$script:YahooHeaders = @{
  "User-Agent"      = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
  "Accept"          = "application/json,text/plain,*/*"
  "Accept-Language" = "pt-BR,pt;q=0.9,en-US;q=0.8,en;q=0.7"
}

try {
  [System.Net.ServicePointManager]::SecurityProtocol =
    [System.Net.SecurityProtocolType]::Tls12
}
catch { }

# Cache em memoria por chave (cotacoes, candles, varredura e backtest).
$script:MarketCache = @{}

# REGRA DO PROJETO: nada de dado atrasado, estimado ou simulado.
# O scanner publico do TradingView so entrega tempo real para cripto (Binance)
# e moedas (FX). Bolsas, acoes e commodities vem com 10/15 min de atraso nessa
# fonte publica, entao ficam FORA do radar em vez de aparecer com preco velho.
$script:MarketUniverse = @(
  @{ symbol = "EURUSD=X"; label = "EUR/USD";       group = "forex";   currency = "USD" },
  @{ symbol = "GBPUSD=X"; label = "GBP/USD";       group = "forex";   currency = "USD" },
  @{ symbol = "USDJPY=X"; label = "USD/JPY";       group = "forex";   currency = "JPY" },
  @{ symbol = "BTC-USD";  label = "Bitcoin";       group = "crypto";  currency = "USD" },
  @{ symbol = "ETH-USD";  label = "Ethereum";      group = "crypto";  currency = "USD" },
  @{ symbol = "SOL-USD";  label = "Solana";        group = "crypto";  currency = "USD" },
  @{ symbol = "XRP-USD";  label = "XRP";           group = "crypto";  currency = "USD" }
)

$script:ScanUniverse = $script:MarketUniverse + @(
  @{ symbol = "DOGE-USD"; label = "Dogecoin";      group = "crypto"; currency = "USD" }
)

# =====================================================================
# TRADINGVIEW (cotacoes)
# ---------------------------------------------------------------------
# O scanner publico do TradingView devolve preco, variacao e o modo de
# atualizacao de cada ticker ("streaming" = tempo real; "delayed_streaming_900"
# = 15 min de atraso). E a mesma fonte que aparece no site do TradingView.
# Se o endpoint mudar, o radar continua com o Yahoo Finance.
# =====================================================================
$script:TradingViewScanUrl = "https://scanner.tradingview.com/global/scan"
$script:TradingViewSymbols = [ordered]@{
  "EURUSD=X" = "FX:EURUSD"
  "GBPUSD=X" = "FX:GBPUSD"
  "USDJPY=X" = "FX:USDJPY"
  "BTC-USD"  = "BINANCE:BTCUSDT"
  "ETH-USD"  = "BINANCE:ETHUSDT"
  "SOL-USD"  = "BINANCE:SOLUSDT"
  "XRP-USD"  = "BINANCE:XRPUSDT"
  "DOGE-USD" = "BINANCE:DOGEUSDT"
}

function Get-ZnxTradingViewQuotes {
  # Cache curto em milissegundos: o radar consulta em ritmo de tempo real e o
  # scanner do TradingView ja atualiza a cotacao continuamente. 250 ms evita
  # repetir a mesma leitura dentro do mesmo tique sem parecer preco congelado.
  param(
    [int]$CacheTtlSeconds = 0,
    [int]$CacheTtlMs = 250
  )

  $cached = Get-ZnxCachedValue -Key "tradingview" -TtlSeconds $CacheTtlSeconds -TtlMs $CacheTtlMs
  if ($null -ne $cached) { return $cached }

  # Se a fonte pediu pausa (429/5xx), nao insistimos a cada tique: isso e o
  # que derrubava o servidor deles. A espera e curta e explicita.
  if ($null -ne $script:TradingViewRetryAt -and [datetime]::UtcNow -lt $script:TradingViewRetryAt) {
    throw "TradingView pediu pausa; nova leitura em instantes."
  }

  $tickers = @($script:TradingViewSymbols.Values)
  if ($tickers.Count -eq 0) { return @{} }

  $body = @{
    symbols = @{ tickers = $tickers; query = @{ types = @() } }
    columns = @("description", "close", "change", "change_abs", "volume", "update_mode", "currency")
  } | ConvertTo-Json -Depth 6 -Compress

  $headers = @{
    "User-Agent" = [string]$script:YahooHeaders["User-Agent"]
    "Origin"     = "https://www.tradingview.com"
    "Referer"    = "https://www.tradingview.com/"
    "Accept"     = "application/json"
  }

  $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  $response = $null
  $lastError = $null
  # Uma tentativa extra curta absorve blip de rede sem esperar o proximo ciclo.
  for ($attempt = 0; $attempt -lt 2; $attempt++) {
    try {
      $response = Invoke-WebRequest -Uri $script:TradingViewScanUrl -Method Post -Headers $headers -ContentType "application/json" -Body $body -UseBasicParsing -TimeoutSec 10
      $lastError = $null
      break
    }
    catch {
      $lastError = $_
      $status = 0
      try { $status = [int]$_.Exception.Response.StatusCode } catch { $status = 0 }
      if ($status -eq 429 -or ($status -ge 500 -and $status -lt 600)) {
        $script:TradingViewRetryAt = [datetime]::UtcNow.AddSeconds(2)
      }
      if ($attempt -eq 0) { Start-Sleep -Milliseconds 120 }
    }
  }
  if ($null -eq $response) {
    throw "TradingView indisponivel: $($lastError.Exception.Message)"
  }
  $stopwatch.Stop()
  $readMs = [int]$stopwatch.ElapsedMilliseconds

  $payload = [string]$response.Content | ConvertFrom-Json
  $byTicker = @{}
  foreach ($row in @($payload.data)) {
    if ($null -eq $row) { continue }
    $data = @($row.d)
    if ($data.Count -lt 6) { continue }
    # Conversao direta: passar por [string] usaria a cultura pt-BR e leria
    # "26950.443" como 26950443 (ponto = milhar).
    $close = [double]$data[1]
    if ($close -le 0 -or [double]::IsNaN($close) -or [double]::IsInfinity($close)) { continue }

    $mode = [string]$data[5]
    $delaySeconds = 0
    if ($mode -match "delayed_streaming_(\d+)") {
      $delaySeconds = [int]$Matches[1]
    }
    elseif ($mode -ne "streaming") {
      # Modo desconhecido: tratado como atrasado para nao prometer tempo real.
      $delaySeconds = -1
    }

    $currency = ""
    if ($data.Count -gt 6 -and $data[6]) { $currency = [string]$data[6] }

    $byTicker[[string]$row.s] = [ordered]@{
      price         = $close
      changePercent = [Math]::Round([double]$data[2], 2)
      changeAbs     = [double]$data[3]
      volume        = [double]$data[4]
      updateMode    = $mode
      delaySeconds  = $delaySeconds
      currency      = $currency
      description   = [string]$data[0]
      at            = [datetime]::UtcNow.ToString("o")
      atMs          = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
      readMs        = $readMs
    }
  }

  $quotes = @{}
  foreach ($pair in $script:TradingViewSymbols.GetEnumerator()) {
    $ticker = [string]$pair.Value
    if ($byTicker.ContainsKey($ticker)) {
      $quotes[[string]$pair.Key] = $byTicker[$ticker]
    }
  }

  if ($quotes.Count -gt 0) {
    Set-ZnxCachedValue -Key "tradingview" -Value $quotes
  }
  return $quotes
}

function Invoke-ZnxRssText {
  param(
    [Parameter(Mandatory = $true)][string]$Uri,
    [int]$TimeoutSec = 15
  )
  $client = New-Object System.Net.WebClient
  $client.Headers.Add("User-Agent", [string]$script:YahooHeaders["User-Agent"])
  $client.Headers.Add("Accept", "application/rss+xml,application/xml,text/xml,*/*")
  $client.Encoding = [System.Text.Encoding]::UTF8
  try {
    return $client.DownloadString($Uri)
  }
  finally {
    $client.Dispose()
  }
}

function Get-ZnxTrackedSymbols {
  # Lista fechada de ativos que as rotas aceitam. Evita repassar qualquer
  # texto do navegador para a URL externa.
  $symbols = New-Object System.Collections.Generic.List[string]
  foreach ($item in $script:ScanUniverse) {
    if (-not $symbols.Contains([string]$item.symbol)) {
      $symbols.Add([string]$item.symbol)
    }
  }
  return ,$symbols.ToArray()
}

function Get-ZnxSymbolLabel {
  param([string]$Symbol)
  foreach ($item in $script:ScanUniverse) {
    if ([string]$item.symbol -eq $Symbol) { return [string]$item.label }
  }
  return $Symbol
}

# =====================================================================
# HTTP + CACHE
# =====================================================================
function Invoke-ZnxHttpText {
  param(
    [Parameter(Mandatory = $true)][string]$Uri,
    [int]$TimeoutSec = 15
  )
  $response = Invoke-WebRequest -Uri $Uri -Headers $script:YahooHeaders `
    -UseBasicParsing -TimeoutSec $TimeoutSec
  return [string]$response.Content
}

function Get-ZnxCachedValue {
  # TtlMs tem prioridade sobre TtlSeconds: o radar precisa de cache curto
  # (centesimos de segundo) sem perder a compatibilidade dos candles.
  param(
    [Parameter(Mandatory = $true)][string]$Key,
    [int]$TtlSeconds = 0,
    [int]$TtlMs = 0
  )
  $ttl = $TtlMs
  if ($ttl -le 0) { $ttl = $TtlSeconds * 1000 }
  if ($ttl -le 0) { return $null }
  if (-not $script:MarketCache.ContainsKey($Key)) { return $null }
  $entry = $script:MarketCache[$Key]
  $ageMs = ([datetime]::UtcNow - $entry.At).TotalMilliseconds
  if ($ageMs -ge $ttl) {
    $script:MarketCache.Remove($Key)
    return $null
  }
  return $entry.Value
}

function Set-ZnxCachedValue {
  param(
    [Parameter(Mandatory = $true)][string]$Key,
    [Parameter(Mandatory = $true)]$Value
  )
  if ($script:MarketCache.Count -gt 200) { $script:MarketCache.Clear() }
  $script:MarketCache[$Key] = @{ At = [datetime]::UtcNow; Value = $Value }
}

# =====================================================================
# INVESTIDOR10 (somente pares de cripto)
# ---------------------------------------------------------------------
# A pagina publica /criptomoedas/ mostra cotacao em US$, cotacao em R$ e
# a variacao de 24h de cada moeda. Usamos apenas para o grupo cripto; se
# a pagina mudar ou cair, o radar continua com a cotacao do Yahoo.
# =====================================================================
$script:Investidor10CryptoUrl = "https://investidor10.com.br/criptomoedas/"

function Invoke-ZnxHttpHtml {
  param([Parameter(Mandatory = $true)][string]$Uri)
  $client = New-Object System.Net.WebClient
  $client.Headers.Add("User-Agent", [string]$script:YahooHeaders["User-Agent"])
  $client.Headers.Add("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
  $client.Headers.Add("Accept-Language", "pt-BR,pt;q=0.9,en-US;q=0.8,en;q=0.7")
  try {
    $bytes = $client.DownloadData($Uri)
  }
  finally {
    $client.Dispose()
  }
  if (-not $bytes -or $bytes.Length -eq 0) { return $null }
  return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function ConvertFrom-ZnxBrDecimal {
  # "US$ 60.830,20" -> 60830.2 ; "-1,25" -> -1.25
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $clean = ([string]$Text) -replace "[^0-9,.\-]", ""
  if ([string]::IsNullOrWhiteSpace($clean)) { return $null }
  $clean = $clean -replace "\.", "" -replace ",", "."
  $value = 0.0
  $parsed = [double]::TryParse(
    $clean,
    [System.Globalization.NumberStyles]::Float,
    [System.Globalization.CultureInfo]::InvariantCulture,
    [ref]$value
  )
  if (-not $parsed) { return $null }
  return $value
}

function Get-ZnxInvestidor10Crypto {
  # 60 s: a pagina do Investidor10 nao atualiza a cada segundo, e insistir
  # mais rapido so aumentaria o risco de bloqueio sem ganho de precisao.
  param([int]$CacheTtlSeconds = 60)

  $cached = Get-ZnxCachedValue -Key "investidor10|crypto" -TtlSeconds $CacheTtlSeconds
  if ($null -ne $cached) { return $cached }

  $html = Invoke-ZnxHttpHtml -Uri $script:Investidor10CryptoUrl
  if ([string]::IsNullOrWhiteSpace($html)) { return $null }

  $coins = New-Object System.Collections.Generic.List[object]
  $rowMatches = [regex]::Matches($html, "<tr[^>]*>([\s\S]*?)</tr>")
  foreach ($rowMatch in $rowMatches) {
    $row = $rowMatch.Groups[1].Value
    if ($row -notmatch "investidor10\.com\.br/criptomoedas/([a-z0-9\-]+)/") { continue }
    $slug = $Matches[1]

    $name = $slug
    $namePattern = 'criptomoedas/' + [regex]::Escape($slug) + '/("|\s)[\s\S]*?title="([^"]+)"'
    if ($row -match $namePattern) { $name = $Matches[2] }

    $ticker = $slug.ToUpperInvariant()
    if ($row -match 'text-\[#14171F\][^>]*>\s*([A-Z0-9]{2,10})\s*<') { $ticker = $Matches[1] }

    $usd = $null
    if ($row -match 'class="price_usd">\s*([^<]+)<') {
      $usd = ConvertFrom-ZnxBrDecimal -Text $Matches[1]
    }

    $brl = $null
    if ($row -match 'class="price">\s*([^<]+)<') {
      $brl = ConvertFrom-ZnxBrDecimal -Text $Matches[1]
    }

    $change = $null
    if ($row -match 'data-name="variation_24_hours"[\s\S]*?</td>') {
      $cell = $Matches[0]
      if ($cell -match 'variation-(up|down)[^>]*>\s*(-?[0-9.,]+)\s*%') {
        $parsedChange = ConvertFrom-ZnxBrDecimal -Text $Matches[2]
        if ($null -ne $parsedChange) {
          $change = [Math]::Abs([double]$parsedChange)
          if ($Matches[1] -eq "down") { $change = -$change }
        }
      }
    }

    if ($null -eq $usd -and $null -eq $brl) { continue }

    $usdValue = $null
    if ($null -ne $usd) { $usdValue = [Math]::Round([double]$usd, 6) }
    $brlValue = $null
    if ($null -ne $brl) { $brlValue = [Math]::Round([double]$brl, 6) }
    $changeValue = $null
    if ($null -ne $change) { $changeValue = [Math]::Round([double]$change, 2) }

    $coins.Add([ordered]@{
      slug      = $slug
      ticker    = $ticker
      name      = $name
      usd       = $usdValue
      brl       = $brlValue
      change24h = $changeValue
      url       = "https://investidor10.com.br/criptomoedas/$slug/"
    })
  }

  if ($coins.Count -eq 0) { return $null }

  $payload = [ordered]@{
    at    = [datetime]::UtcNow.ToString("o")
    name  = "Investidor10"
    url   = $script:Investidor10CryptoUrl
    items = $coins.ToArray()
  }
  Set-ZnxCachedValue -Key "investidor10|crypto" -Value $payload
  return $payload
}

# =====================================================================
# TRADUCAO DAS MANCHETES (EN -> PT-BR)
# =====================================================================
$script:TranslationEndpoint = "https://api.mymemory.translated.net/get"

function ConvertFrom-ZnxTranslationPayload {
  param([string]$Raw)
  if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
  try {
    $data = $Raw | ConvertFrom-Json
  }
  catch {
    return $null
  }
  if ($null -eq $data -or $null -eq $data.responseData) { return $null }
  if ([int]$data.responseStatus -ne 200) { return $null }
  $translated = [string]$data.responseData.translatedText
  if ([string]::IsNullOrWhiteSpace($translated)) { return $null }
  if ($translated -match "MYMEMORY WARNING|QUERY LENGTH LIMIT|INVALID LANGUAGE PAIR") { return $null }
  $translated = [System.Net.WebUtility]::HtmlDecode($translated).Trim()
  if ([string]::IsNullOrWhiteSpace($translated)) { return $null }
  return $translated
}

function Get-ZnxPortugueseTitles {
  # Traduz varias manchetes em paralelo e devolve uma tabela
  # titulo original -> titulo em portugues. Falha silenciosa por item.
  param(
    [string[]]$Titles,
    [int]$TimeoutMs = 12000
  )

  $map = @{}
  $pending = New-Object System.Collections.Generic.List[object]
  $seen = @{}

  foreach ($title in $Titles) {
    if ([string]::IsNullOrWhiteSpace($title)) { continue }
    $trimmed = ([string]$title).Trim()
    if ($trimmed.Length -gt 480) { $trimmed = $trimmed.Substring(0, 480) }
    if ($seen.ContainsKey($trimmed)) { continue }
    $seen[$trimmed] = $true

    $cacheKey = "traducao|$trimmed"
    $cached = Get-ZnxCachedValue -Key $cacheKey -TtlSeconds 21600
    if ($null -ne $cached) {
      $map[$trimmed] = [string]$cached
      continue
    }
    $pending.Add([ordered]@{ key = $cacheKey; text = $trimmed })
  }

  if ($pending.Count -eq 0) { return $map }

  $userAgent = [string]$script:YahooHeaders["User-Agent"]
  $jobs = New-Object System.Collections.Generic.List[object]
  foreach ($entry in $pending) {
    $uri = "$($script:TranslationEndpoint)?q=$([uri]::EscapeDataString([string]$entry.text))&langpair=en%7Cpt-BR"
    $client = New-Object System.Net.WebClient
    $client.Headers.Add("User-Agent", $userAgent)
    $client.Headers.Add("Accept", "application/json")
    try {
      $task = $client.DownloadDataTaskAsync($uri)
      $jobs.Add([ordered]@{ client = $client; task = $task; entry = $entry })
    }
    catch {
      $client.Dispose()
    }
  }

  foreach ($job in $jobs) {
    try {
      if (-not $job.task.Wait($TimeoutMs)) { continue }
      $bytes = $job.task.Result
      if (-not $bytes -or $bytes.Length -eq 0) { continue }
      $raw = [System.Text.Encoding]::UTF8.GetString($bytes)
      $translated = ConvertFrom-ZnxTranslationPayload -Raw $raw
      if ([string]::IsNullOrWhiteSpace($translated)) { continue }
      $key = [string]$job.entry.key
      $map[[string]$job.entry.text] = $translated
      Set-ZnxCachedValue -Key $key -Value $translated
    }
    catch {
      Write-Verbose "Traducao indisponivel: $($_.Exception.Message)"
    }
    finally {
      $job.client.Dispose()
    }
  }

  return $map
}

# =====================================================================
# CANDLES
# =====================================================================
function Get-ZnxMarketCandles {
  param(
    [Parameter(Mandatory = $true)][string]$Symbol,
    [string]$Range = "5d",
    [string]$Interval = "5m",
    [int]$CacheTtlSeconds = 60,
    [int]$CacheTtlMs = 0
  )

  $cacheKey = "candles|$Symbol|$Range|$Interval"
  $cached = Get-ZnxCachedValue -Key $cacheKey -TtlSeconds $CacheTtlSeconds -TtlMs $CacheTtlMs
  if ($null -ne $cached) { return $cached }

  $prefetchedKey = "scanner-candle-payload|$Symbol|$Range|$Interval"
  $rawPayload = Get-ZnxCachedValue -Key $prefetchedKey -TtlSeconds 60
  if ($null -eq $rawPayload) {
    $encoded = [uri]::EscapeDataString($Symbol)
    $uri = "$($script:YahooChartBase)/$($encoded)?range=$($Range)&interval=$($Interval)&includePrePost=false"
    $rawPayload = Invoke-ZnxHttpText -Uri $uri -TimeoutSec 20
  }
  $payload = ConvertFrom-Json -InputObject ([string]$rawPayload)

  if ($null -eq $payload.chart -or $null -eq $payload.chart.result -or
      @($payload.chart.result).Count -eq 0) {
    throw "Sem dados de mercado para $Symbol."
  }
  $result = @($payload.chart.result)[0]
  if ($null -eq $result.timestamp -or $null -eq $result.indicators -or
      $null -eq $result.indicators.quote -or @($result.indicators.quote).Count -eq 0) {
    throw "Resposta de mercado incompleta para $Symbol."
  }

  $timestamps = @($result.timestamp)
  $quote = @($result.indicators.quote)[0]
  if ($null -eq $quote.close -or $null -eq $quote.open -or
      $null -eq $quote.high -or $null -eq $quote.low) {
    throw "Candles indisponiveis para $Symbol."
  }

  $opens = @($quote.open)
  $highs = @($quote.high)
  $lows = @($quote.low)
  $closes = @($quote.close)
  $volumes = @($quote.volume)

  $count = $timestamps.Count
  if ($opens.Count -lt $count) { $count = $opens.Count }
  if ($highs.Count -lt $count) { $count = $highs.Count }
  if ($lows.Count -lt $count) { $count = $lows.Count }
  if ($closes.Count -lt $count) { $count = $closes.Count }

  $timeList = New-Object System.Collections.Generic.List[long]
  $openList = New-Object System.Collections.Generic.List[double]
  $highList = New-Object System.Collections.Generic.List[double]
  $lowList = New-Object System.Collections.Generic.List[double]
  $closeList = New-Object System.Collections.Generic.List[double]
  $volumeList = New-Object System.Collections.Generic.List[double]

  for ($i = 0; $i -lt $count; $i++) {
    if ($null -eq $closes[$i] -or $null -eq $opens[$i] -or
        $null -eq $highs[$i] -or $null -eq $lows[$i]) {
      continue
    }
    $volume = 0.0
    if ($i -lt $volumes.Count -and $null -ne $volumes[$i]) {
      $volume = [double]$volumes[$i]
    }
    $timeList.Add([long]$timestamps[$i])
    $openList.Add([double]$opens[$i])
    $highList.Add([double]$highs[$i])
    $lowList.Add([double]$lows[$i])
    $closeList.Add([double]$closes[$i])
    $volumeList.Add($volume)
  }

  if ($closeList.Count -lt 2) {
    throw "Candles insuficientes para $Symbol."
  }

  $price = [double]$closeList[$closeList.Count - 1]
  $previousClose = 0.0
  if ($null -ne $result.meta.regularMarketPrice) {
    $price = [double]$result.meta.regularMarketPrice
  }
  # Em intervalos diarios, chartPreviousClose aponta para o fechamento antes da
  # janela inteira (5 dias), o que inflava a variacao. Para 1d usamos o candle
  # anterior; para intraday o chartPreviousClose e o fechamento de ontem, que e
  # exatamente a variacao diaria que o radar deve mostrar.
  if ($Interval -eq "1d" -and $closeList.Count -gt 1) {
    $previousClose = [double]$closeList[$closeList.Count - 2]
  }
  elseif ($null -ne $result.meta.chartPreviousClose) {
    $previousClose = [double]$result.meta.chartPreviousClose
  }
  elseif ($null -ne $result.meta.previousClose) {
    $previousClose = [double]$result.meta.previousClose
  }
  if ($previousClose -le 0 -and $closeList.Count -gt 1) {
    $previousClose = [double]$closeList[$closeList.Count - 2]
  }

  $currency = "USD"
  if ($null -ne $result.meta.currency) { $currency = [string]$result.meta.currency }

  $candles = [pscustomobject]@{
    Symbol        = $Symbol
    Label         = Get-ZnxSymbolLabel -Symbol $Symbol
    Currency      = $currency
    Price         = $price
    PreviousClose = $previousClose
    Timestamps    = $timeList.ToArray()
    Open          = $openList.ToArray()
    High          = $highList.ToArray()
    Low           = $lowList.ToArray()
    Close         = $closeList.ToArray()
    Volume        = $volumeList.ToArray()
  }

  Set-ZnxCachedValue -Key $cacheKey -Value $candles
  return $candles
}

# =====================================================================
# INDICADORES (funcoes puras, cobertas por teste)
# =====================================================================
function Get-ZnxLastValue {
  param([double[]]$Values)
  if ($null -eq $Values -or $Values.Length -eq 0) { return 0.0 }
  return [double]$Values[$Values.Length - 1]
}

function Get-ZnxEmaSeries {
  param(
    [Parameter(Mandatory = $true)][double[]]$Values,
    [int]$Period = 9
  )
  $length = $Values.Length
  $output = [double[]]::new($length)
  if ($length -eq 0) { return ,$output }
  if ($Period -lt 1) { $Period = 1 }
  $multiplier = 2.0 / ($Period + 1.0)
  $ema = $Values[0]
  for ($i = 0; $i -lt $length; $i++) {
    if ($i -eq 0) { $ema = $Values[0] }
    else { $ema = ($Values[$i] - $ema) * $multiplier + $ema }
    $output[$i] = $ema
  }
  return ,$output
}

function Get-ZnxRsiSeries {
  param(
    [Parameter(Mandatory = $true)][double[]]$Values,
    [int]$Period = 14
  )
  $length = $Values.Length
  $output = [double[]]::new($length)
  if ($length -eq 0) { return ,$output }
  if ($Period -lt 2) { $Period = 2 }

  $gainSum = 0.0
  $lossSum = 0.0
  for ($i = 1; $i -le [Math]::Min($Period, $length - 1); $i++) {
    $delta = $Values[$i] - $Values[$i - 1]
    if ($delta -ge 0) { $gainSum += $delta } else { $lossSum += [Math]::Abs($delta) }
  }
  $avgGain = $gainSum / $Period
  $avgLoss = $lossSum / $Period

  for ($i = 0; $i -lt $length; $i++) {
    if ($i -le $Period) {
      if ($i -eq $Period) {
        if ($avgLoss -eq 0) { $output[$i] = $(if ($avgGain -gt 0) { 100.0 } else { 50.0 }) }
        else { $output[$i] = 100.0 - (100.0 / (1.0 + ($avgGain / $avgLoss))) }
      }
      continue
    }
    $delta = $Values[$i] - $Values[$i - 1]
    $gain = 0.0
    $loss = 0.0
    if ($delta -ge 0) { $gain = $delta } else { $loss = [Math]::Abs($delta) }
    $avgGain = (($avgGain * ($Period - 1)) + $gain) / $Period
    $avgLoss = (($avgLoss * ($Period - 1)) + $loss) / $Period
    if ($avgLoss -eq 0) { $output[$i] = $(if ($avgGain -gt 0) { 100.0 } else { 50.0 }) }
    else { $output[$i] = 100.0 - (100.0 / (1.0 + ($avgGain / $avgLoss))) }
  }
  return ,$output
}

function Get-ZnxAtrSeries {
  param(
    [Parameter(Mandatory = $true)][double[]]$High,
    [Parameter(Mandatory = $true)][double[]]$Low,
    [Parameter(Mandatory = $true)][double[]]$Close,
    [int]$Period = 14
  )
  $length = [Math]::Min($Close.Length, [Math]::Min($High.Length, $Low.Length))
  $output = [double[]]::new($Close.Length)
  if ($length -eq 0) { return ,$output }
  if ($Period -lt 1) { $Period = 1 }

  $tr = [double[]]::new($length)
  for ($i = 0; $i -lt $length; $i++) {
    $range = $High[$i] - $Low[$i]
    if ($i -gt 0) {
      $highDiff = [Math]::Abs($High[$i] - $Close[$i - 1])
      $lowDiff = [Math]::Abs($Low[$i] - $Close[$i - 1])
      if ($highDiff -gt $range) { $range = $highDiff }
      if ($lowDiff -gt $range) { $range = $lowDiff }
    }
    $tr[$i] = $range
  }

  $atr = 0.0
  for ($i = 0; $i -lt $length; $i++) {
    if ($i -lt $Period) {
      $atr += $tr[$i]
      if ($i -eq $Period - 1) {
        $atr = $atr / $Period
        $output[$i] = $atr
      }
      continue
    }
    $atr = (($atr * ($Period - 1)) + $tr[$i]) / $Period
    $output[$i] = $atr
  }
  return ,$output
}

# =====================================================================
# COTACOES + NOTICIAS
# =====================================================================
function Get-ZnxQuote {
  param([Parameter(Mandatory = $true)]$Definition)
  $candles = Get-ZnxMarketCandles -Symbol ([string]$Definition.symbol) `
    -Range "5d" -Interval "1d" -CacheTtlSeconds 90

  $changePercent = 0.0
  if ($candles.PreviousClose -gt 0) {
    $changePercent = (($candles.Price - $candles.PreviousClose) / $candles.PreviousClose) * 100.0
  }

  $spark = @()
  $start = [Math]::Max(0, $candles.Close.Length - 20)
  for ($i = $start; $i -lt $candles.Close.Length; $i++) {
    $spark += [Math]::Round([double]$candles.Close[$i], 6)
  }

  return [ordered]@{
    symbol        = [string]$Definition.symbol
    label         = [string]$Definition.label
    group         = [string]$Definition.group
    currency      = [string]$candles.Currency
    price         = [Math]::Round([double]$candles.Price, 6)
    changePercent = [Math]::Round($changePercent, 2)
    spark         = $spark
  }
}

# =====================================================================
# GRAFICO (candles reais + preco ao vivo do TradingView)
# ---------------------------------------------------------------------
# O TradingView nao publica serie historica em endpoint aberto; o que ele
# entrega publicamente (scanner) e o preco/atualizacao do momento. A serie
# de candles vem da API publica de charts do Yahoo, que e a mesma base que
# o radar ja usa para o sparkline. O payload diz a fonte de cada coisa.
# =====================================================================
function Get-ZnxChartSeries {
  param(
    [Parameter(Mandatory = $true)][string]$Symbol,
    [string]$Interval = "5m"
  )

  $tracked = Get-ZnxTrackedSymbols
  if ($Symbol -notin $tracked) { throw "Ativo nao acompanhado pelo radar." }

  # Cada periodo tem seu proprio cache curto: o grafico de 5 min se renova a
  # cada 5 s (sem martelar o Yahoo), e periodos longos nao precisam disso.
  $intervals = @{
    "5m"  = @{ range = "1d";  interval = "5m";  label = "5 minutos"; bars = 300; cacheMs = 5000 }
    "15m" = @{ range = "5d";  interval = "15m"; label = "15 minutos"; bars = 320; cacheMs = 15000 }
    "1h"  = @{ range = "1mo"; interval = "60m"; label = "1 hora"; bars = 320; cacheMs = 30000 }
    "1d"  = @{ range = "6mo"; interval = "1d";  label = "1 dia"; bars = 180; cacheMs = 60000 }
  }
  if (-not $intervals.ContainsKey($Interval)) {
    throw "Periodo invalido. Use 5m, 15m, 1h ou 1d."
  }
  $conf = $intervals[$Interval]

  $candles = Get-ZnxMarketCandles -Symbol $Symbol -Range ([string]$conf.range) `
    -Interval ([string]$conf.interval) -CacheTtlMs ([int]$conf.cacheMs)

  $quote = $null
  try {
    $tvQuotes = Get-ZnxTradingViewQuotes
    if ($tvQuotes.ContainsKey($Symbol)) { $quote = $tvQuotes[$Symbol] }
  }
  catch { Write-Verbose "TradingView indisponivel para o grafico: $($_.Exception.Message)" }

  $times = @($candles.Timestamps)
  $opens = @($candles.Open)
  $highs = @($candles.High)
  $lows = @($candles.Low)
  $closes = @($candles.Close)
  $volumes = @($candles.Volume)

  $total = $times.Count
  $start = [Math]::Max(0, $total - [int]$conf.bars)
  $items = New-Object System.Collections.Generic.List[object]
  for ($i = $start; $i -lt $total; $i++) {
    $items.Add([ordered]@{
      t = [long]$times[$i]
      o = [Math]::Round([double]$opens[$i], 6)
      h = [Math]::Round([double]$highs[$i], 6)
      l = [Math]::Round([double]$lows[$i], 6)
      c = [Math]::Round([double]$closes[$i], 6)
      v = [Math]::Round([double]$volumes[$i], 2)
    })
  }

  if ($items.Count -lt 2) { throw "Candles insuficientes para montar o grafico." }

  $quotePayload = $null
  $price = [double]$candles.Price
  $changePercent = 0.0
  if ($null -ne $quote) {
    $price = [double]$quote.price
    $changePercent = [double]$quote.changePercent
    $quotePayload = [ordered]@{
      price         = [Math]::Round($price, 6)
      changePercent = [Math]::Round($changePercent, 2)
      live          = ([int]$quote.delaySeconds -eq 0)
      delaySeconds  = [int]$quote.delaySeconds
      currency      = [string]$quote.currency
      source        = "TradingView"
    }
  }
  else {
    if ($candles.PreviousClose -gt 0) {
      $changePercent = (($price - [double]$candles.PreviousClose) / [double]$candles.PreviousClose) * 100.0
    }
    $quotePayload = [ordered]@{
      price         = [Math]::Round($price, 6)
      changePercent = [Math]::Round($changePercent, 2)
      live          = $false
      delaySeconds  = -1
      currency      = [string]$candles.Currency
      source        = "Yahoo Finance"
    }
  }

  return [ordered]@{
    symbol        = $Symbol
    label         = [string]$candles.Label
    currency      = [string]$candles.Currency
    interval      = $Interval
    intervalLabel = [string]$conf.label
    at            = [datetime]::UtcNow.ToString("o")
    previousClose = [double]$candles.PreviousClose
    candles       = $items.ToArray()
    quote         = $quotePayload
    sources       = [ordered]@{
      candles = "Yahoo Finance"
      price   = [string]$quotePayload.source
    }
  }
}

function Get-ZnxMarketSnapshot {
  # Cache de 250 ms: cada consulta ao /api/market devolve a leitura mais
  # recente sem repetir a chamada externa dentro do mesmo tique. O custo e
  # baixo porque candles (90 s) e referencia em R$ (60 s) continuam em cache;
  # so a cotacao do TradingView e relida a cada 250 ms.
  param(
    [int]$CacheTtlSeconds = 0,
    [int]$CacheTtlMs = 250
  )

  $cached = Get-ZnxCachedValue -Key "snapshot" -TtlSeconds $CacheTtlSeconds -TtlMs $CacheTtlMs
  if ($null -ne $cached) { return $cached }
  $snapshotStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

  $groups = [ordered]@{
    forex  = @{ label = "Moedas"; items = (New-Object System.Collections.Generic.List[object]) }
    crypto = @{ label = "Cripto"; items = (New-Object System.Collections.Generic.List[object]) }
  }
  $failed = New-Object System.Collections.Generic.List[string]

  # Referencia em R$ e variacao 24h apenas para os pares de cripto.
  $cryptoReference = @{}
  $cryptoSource = $null
  try {
    $investidor10 = Get-ZnxInvestidor10Crypto
    if ($null -ne $investidor10) {
      $cryptoSource = [ordered]@{
        name = [string]$investidor10.name
        url  = [string]$investidor10.url
        at   = [string]$investidor10.at
      }
      foreach ($coin in $investidor10.items) {
        $cryptoReference[[string]$coin.slug] = $coin
      }
    }
  }
  catch {
    Write-Verbose "Investidor10 indisponivel: $($_.Exception.Message)"
  }

  # Cotacoes do TradingView chegam antes do Yahoo: preco e variacao passam a
  # ser os do TradingView, enquanto o Yahoo segue como fonte do sparkline
  # (fechamentos diarios, historico real).
  $tvQuotes = @{}
  try { $tvQuotes = Get-ZnxTradingViewQuotes }
  catch { Write-Verbose "TradingView indisponivel: $($_.Exception.Message)" }

  foreach ($definition in $script:MarketUniverse) {
    $quote = $null
    try { $quote = Get-ZnxQuote -Definition $definition }
    catch { $quote = $null }

    $tv = $null
    if ($tvQuotes.ContainsKey([string]$definition.symbol)) {
      $tv = $tvQuotes[[string]$definition.symbol]
    }

    # Regra do projeto: nada atrasado. Sem cotacao em tempo real (delay 0) o
    # ativo nao entra na mesa; o Yahoo tambem atrasa bolsas e acoes em 15 min.
    if ($null -eq $tv -or $null -eq $tv.delaySeconds -or [int]$tv.delaySeconds -ne 0) {
      if (-not $failed.Contains([string]$definition.symbol)) { $failed.Add([string]$definition.symbol) }
      continue
    }

    if ($null -eq $quote -and $null -ne $tv) {
      $quote = [ordered]@{
        symbol        = [string]$definition.symbol
        label         = [string]$definition.label
        group         = [string]$definition.group
        currency      = if ([string]$tv.currency) { [string]$tv.currency } else { [string]$definition.currency }
        price         = 0.0
        changePercent = 0.0
        spark         = @()
      }
    }
    if ($null -eq $quote) {
      if (-not $failed.Contains([string]$definition.symbol)) { $failed.Add([string]$definition.symbol) }
      continue
    }

    if ($null -ne $tv) {
      $quote.price         = [Math]::Round([double]$tv.price, 6)
      $quote.changePercent = [Math]::Round([double]$tv.changePercent, 2)
      if ([string]$tv.currency) { $quote.currency = [string]$tv.currency }
      $quote["source"]       = "TradingView"
      $quote["delaySeconds"] = [int]$tv.delaySeconds
      $quote["live"]         = ([int]$tv.delaySeconds -eq 0)
      $quote["updateMode"]   = [string]$tv.updateMode
    }

    if ([string]$definition.group -eq "crypto" -and $cryptoReference.Count -gt 0) {
      $slug = ([string]$definition.label).ToLowerInvariant() -replace "[^a-z0-9]+", "-"
      $slug = $slug.Trim("-")
      if ($cryptoReference.ContainsKey($slug)) {
        $coin = $cryptoReference[$slug]
        $quote["ticker"] = [string]$coin.ticker
        $quote["brl"] = $coin.brl
        $quote["change24h"] = $coin.change24h
        if ($null -eq $tv) {
          $quote["source"] = "Investidor10"
          $quote["url"] = [string]$coin.url
        }
      }
    }

    # Ultima barreira: so entra ativo com preco numerico e positivo. Uma falha
    # isolada da fonte tira o ativo da lista; nao derruba o painel inteiro.
    $finalPrice = [double]$quote.price
    if ([double]::IsNaN($finalPrice) -or [double]::IsInfinity($finalPrice) -or $finalPrice -le 0 -or $quote.live -ne $true) {
      if (-not $failed.Contains([string]$definition.symbol)) { $failed.Add([string]$definition.symbol) }
      continue
    }

    $groups[[string]$definition.group].items.Add($quote)
  }

  $total = 0
  foreach ($key in $groups.Keys) { $total += $groups[$key].items.Count }
  if ($total -eq 0) {
    throw "Nenhuma cotacao disponivel agora. Verifique a conexao com a internet."
  }

  $tvReadMs = 0
  if ($null -ne $tvQuotes -and $tvQuotes.Count -gt 0) {
    foreach ($tvKey in $tvQuotes.Keys) {
      $tvReadMs = [int]$tvQuotes[$tvKey].readMs
      break
    }
  }

  $payload = [ordered]@{
    at     = [datetime]::UtcNow.ToString("o")
    groups = @(
      [ordered]@{ key = "forex";  label = "Moedas"; items = $groups["forex"].items.ToArray() },
      [ordered]@{ key = "crypto"; label = "Cripto"; items = $groups["crypto"].items.ToArray() }
    )
    failed = $failed.ToArray()
    cryptoSource = $cryptoSource
    quotes = [ordered]@{
      source       = "TradingView"
      url          = "https://www.tradingview.com/markets/"
      live         = @($groups["forex"].items + $groups["crypto"].items | Where-Object { $_.live -eq $true }).Count
      delayed      = @($groups["forex"].items + $groups["crypto"].items | Where-Object { $_.live -ne $true }).Count
      cacheMs      = $CacheTtlMs
      readMs       = $tvReadMs
    }
    latencyMs = [int]$snapshotStopwatch.ElapsedMilliseconds
  }

  Set-ZnxCachedValue -Key "snapshot" -Value $payload
  return $payload
}

function Get-ZnxNewsTags {
  param([string]$Title)
  $text = $Title.ToLowerInvariant()
  $tags = New-Object System.Collections.Generic.List[string]

  if ($text -match "fed|federal reserve|juros|selic|copom|banco central|\bbc\b|taxa b[aá]sica") { $tags.Add("Juros") }
  if ($text -match "infla|ipca|igp|ipc|pre[cç]os|defla") { $tags.Add("Inflacao") }
  if ($text -match "d[oó]lar|c[aâ]mbio|divisa") { $tags.Add("Dolar") }
  if ($text -match "bitcoin|cripto|ethereum|binance|coinbase|token|stablecoin|blockchain") { $tags.Add("Cripto") }
  if ($text -match "petr[oó]leo|opep|brent|wti|gasolina|diesel|combust") { $tags.Add("Petroleo") }
  if ($text -match "ibovespa|bolsa|b3|wall street|s&p|nasdaq|dow jones|a[cç][oõ]es") { $tags.Add("Bolsa") }
  if ($text -match "ouro|commodit|min[eé]rio|soja|milho|boi|caf[eé]") { $tags.Add("Commodities") }
  if ($text -match "pib|emprego|desemprego|atividade|ind[uú]stria|varejo|consumo|cr[eé]dito|renda") { $tags.Add("Economia") }
  if ($text -match "tarifa|guerra comercial|china|eua|geopol|elei[cç]") { $tags.Add("Geopolitica") }
  if ($text -match "banco|resultado|balan[cç]|fus[aã]o|aquisic|investimento|startup") { $tags.Add("Empresas") }

  $tagsArray = $tags.ToArray()
  if ($tagsArray.Length -gt 2) {
    return ,$tagsArray[0..1]
  }
  return ,$tagsArray
}

function Get-ZnxRecentNewsItems {
  param(
    [object[]]$Items = @(),
    [datetime]$NowUtc = [datetime]::UtcNow
  )

  $now = $NowUtc.ToUniversalTime()
  $cutoff = $now.AddHours(-24)
  $dateStyles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor
    [System.Globalization.DateTimeStyles]::AdjustToUniversal
  $recent = New-Object System.Collections.Generic.List[object]

  foreach ($item in $Items) {
    $publishedAt = [datetime]::MinValue
    if (-not [datetime]::TryParse(
        [string]$item.publishedAt,
        [System.Globalization.CultureInfo]::InvariantCulture,
        $dateStyles,
        [ref]$publishedAt
      )) {
      continue
    }
    if ($publishedAt -lt $cutoff -or $publishedAt -gt $now) { continue }
    $item.publishedAt = $publishedAt.ToString("o")
    $recent.Add($item)
  }

  return @($recent.ToArray() | Sort-Object { [datetime]$_.publishedAt } -Descending)
}

function Get-ZnxMarketNews {
  param([int]$MaxItems = 600, [int]$CacheTtlSeconds = 60)

  $cached = Get-ZnxCachedValue -Key "news" -TtlSeconds $CacheTtlSeconds
  if ($null -ne $cached) {
    $cachedItems = @(Get-ZnxRecentNewsItems -Items @($cached.items))
    if ($MaxItems -gt 0 -and $cachedItems.Count -gt $MaxItems) {
      $cachedItems = $cachedItems[0..($MaxItems - 1)]
    }
    $cachedSources = @($cachedItems | ForEach-Object { [string]$_.source } | Select-Object -Unique)
    return [ordered]@{
      at          = $cached.at
      items       = $cachedItems
      count       = $cachedItems.Count
      total       = $cachedItems.Count
      failedFeeds = $cached.failedFeeds
      sources     = $cachedSources
      translated  = 0
      window      = "noticias com publicacao verificavel nas ultimas 24 horas"
      windowHours = 24
    }
  }

  # A busca e publica e nao usa IA. O operador temporal do Google reduz o feed;
  # a data publicada ainda e validada localmente antes de exibir qualquer item.
  $queries = @(
    "bitcoin OR criptomoedas",
    "forex OR cambio OR moedas",
    "bolsa americana OR Wall Street OR acoes dos Estados Unidos",
    "Nasdaq OR S&P 500 OR Dow Jones",
    "trading OR day trade OR analise tecnica",
    "mercado financeiro",
    "dolar OR cambio",
    "inflacao OR IPCA",
    "juros OR Federal Reserve OR Fed",
    "commodities",
    "ibovespa",
    "banco central"
  )
  $feeds = New-Object System.Collections.Generic.List[object]
  foreach ($query in $queries) {
    $recentQuery = "$query when:1d"
    $feeds.Add(@{
      name = "Google Noticias"
      url  = "https://news.google.com/rss/search?q=$([uri]::EscapeDataString($recentQuery))&hl=pt-BR&gl=BR&ceid=BR:pt-419"
    })
  }
  $feeds.Add(@{ name = "G1 Economia";   url = "https://g1.globo.com/rss/g1/economia/" })
  $feeds.Add(@{ name = "Folha Mercado"; url = "https://feeds.folha.uol.com.br/mercado/rss.xml" })
  $feeds.Add(@{ name = "InfoMoney";     url = "https://www.infomoney.com.br/feed/" })
  $feeds.Add(@{ name = "Money Times";   url = "https://www.moneytimes.com.br/feed/" })

  $seen = @{}
  $items = New-Object System.Collections.Generic.List[object]
  $errors = 0
  # Feeds em paralelo: a pagina de noticias nao pode segurar o radar. Antes o
  # download era sequencial (16 feeds x ate 15 s) e travava o servidor inteiro
  # por dezenas de segundos quando um feed demorava.
  $feedPayloads = @{}
  $httpClient = [System.Net.Http.HttpClient]::new()
  $httpClient.Timeout = [TimeSpan]::FromSeconds(10)
  try {
    [void]$httpClient.DefaultRequestHeaders.TryAddWithoutValidation(
      "User-Agent", [string]$script:YahooHeaders["User-Agent"])
    [void]$httpClient.DefaultRequestHeaders.TryAddWithoutValidation(
      "Accept", "application/rss+xml,application/xml,text/xml,*/*")
    $pending = New-Object System.Collections.Generic.List[object]
    foreach ($feed in $feeds) {
      try {
        $pending.Add(@{
          feed = $feed
          task = $httpClient.GetByteArrayAsync([string]$feed.url)
        })
      }
      catch { $errors++ }
    }
    foreach ($entry in $pending) {
      try {
        $bytes = $entry.task.GetAwaiter().GetResult()
        if ($null -eq $bytes -or $bytes.Length -eq 0) { continue }
        $text = [System.Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)
        $feedPayloads[[string]$entry.feed.url] = $text
      }
      catch {
        $errors++
        Write-Verbose "Feed indisponivel ($($entry.feed.name)): $($_.Exception.Message)"
      }
    }
  }
  finally {
    $httpClient.Dispose()
  }

  foreach ($feed in $feeds) {
    try {
      $raw = $feedPayloads[[string]$feed.url]
      if ([string]::IsNullOrWhiteSpace($raw)) { continue }
      $xml = [xml]$raw
      foreach ($item in @($xml.rss.channel.item)) {
        if ($null -eq $item) { continue }
        $title = ""
        $titleNode = $item.SelectSingleNode("title")
        if ($null -ne $titleNode) { $title = ([string]$titleNode.InnerText).Trim() }
        if ([string]::IsNullOrWhiteSpace($title)) { continue }
        $sourceName = [string]$feed.name
        $sourceNode = $item.SelectSingleNode("source")
        if ($null -ne $sourceNode -and -not [string]::IsNullOrWhiteSpace([string]$sourceNode.InnerText)) {
          $sourceName = [string]$sourceNode.InnerText.Trim()
        }
        # O Google anexa " - Veiculo" no fim do titulo; o veiculo ja vai no source.
        if ($sourceName -and $title.EndsWith(" - " + $sourceName, [System.StringComparison]::OrdinalIgnoreCase)) {
          $title = $title.Substring(0, $title.Length - $sourceName.Length - 3).Trim()
        }

        $key = $title.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true

        $publishedAt = ""
        try {
          $publishedAt = [datetime]::Parse(
            [string]$item.pubDate,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AdjustToUniversal
          ).ToString("o")
        }
        catch { $publishedAt = "" }

        $items.Add([ordered]@{
          title         = $title
          titlePt       = $title
          originalTitle = $null
          link          = ([string]$item.link).Trim()
          source        = $sourceName
          publishedAt   = $publishedAt
          tags          = (Get-ZnxNewsTags -Title $title)
        })
      }
    }
    catch {
      $errors++
      Write-Verbose "Feed indisponivel ($($feed.name)): $($_.Exception.Message)"
    }
  }

  $recentItems = @(Get-ZnxRecentNewsItems -Items $items.ToArray())
  if ($recentItems.Count -eq 0 -and $errors -ge $feeds.Count) {
    throw "Todos os feeds de noticias falharam; nao foi possivel verificar a janela das ultimas 24 horas."
  }

  $ordered = $recentItems
  $recentSources = @($ordered | ForEach-Object { [string]$_.source } | Select-Object -Unique)
  $payload = [ordered]@{
    at          = [datetime]::UtcNow.ToString("o")
    items       = $ordered
    failedFeeds = $errors
    sources     = $recentSources
  }
  Set-ZnxCachedValue -Key "news" -Value $payload

  $visibleItems = $ordered
  if ($MaxItems -gt 0 -and $visibleItems.Count -gt $MaxItems) {
    $visibleItems = $visibleItems[0..($MaxItems - 1)]
  }

  return [ordered]@{
    at          = $payload.at
    items       = $visibleItems
    count       = $visibleItems.Count
    total       = $ordered.Count
    failedFeeds = $errors
    sources     = $payload.sources
    translated  = 0
    window      = "noticias com publicacao verificavel nas ultimas 24 horas"
    windowHours = 24
  }
}

# =====================================================================
# VARREDOR
# =====================================================================
function Get-ZnxSetupScore {
  # Fatores extras sao opcionais: sem eles (0 / 0.5 / 1) a conta e exatamente
  # a mesma de antes, o que mantem os testes e a leitura antiga validos.
  param(
    [double]$TrendAtr,
    [double]$Rsi,
    [bool]$BreakoutUp,
    [bool]$BreakoutDown,
    [double]$VolumeRatio,
    [double]$ExtensionAtr,
    [double]$MomentumAtr = 0,
    [double]$HigherTrendAtr = 0,
    [double]$RangePosition = 0.5,
    # -1 = rompimento nao avaliado (mantem a conta antiga intacta).
    [double]$Freshness = -1,
    [double]$VolatilityRatio = 1
  )
  $score = [Math]::Max(-25.0, [Math]::Min(25.0, $TrendAtr * 12.0))
  if ($Rsi -ge 55) { $score += 12 }
  if ($Rsi -le 45) { $score -= 12 }
  if ($Rsi -ge 75) { $score -= 8 }
  if ($Rsi -le 25) { $score += 8 }
  if ($BreakoutUp) { $score += 22 }
  if ($BreakoutDown) { $score -= 22 }
  if ($VolumeRatio -ge 1.3 -and $TrendAtr -ne 0) {
    $score += [Math]::Min(12.0, ($VolumeRatio - 1.0) * 10.0) * [Math]::Sign($TrendAtr)
  }
  if ($ExtensionAtr -gt 2.5 -and $TrendAtr -ne 0) {
    $score -= 10.0 * [Math]::Sign($TrendAtr)
  }
  # Momentum dos ultimos candles, normalizado por ATR: confirma ou contraria
  # a inclinacao das EMAs sem repetir o mesmo peso da tendencia.
  if ($MomentumAtr -ne 0 -and -not [double]::IsNaN($MomentumAtr)) {
    $score += [Math]::Min(14.0, [Math]::Abs($MomentumAtr) * 7.0) * [Math]::Sign($MomentumAtr)
  }
  # EMA 50 contra EMA 21: tendencia de prazo maior so confirma a direcao.
  if ($HigherTrendAtr -ne 0 -and -not [double]::IsNaN($HigherTrendAtr)) {
    $score += [Math]::Min(10.0, [Math]::Abs($HigherTrendAtr) * 6.0) * [Math]::Sign($HigherTrendAtr)
  }
  # Rompimento recem-feito vale mais que rompimento velho; depois de 6 candles
  # o bonus some, porque a continuacao ja foi precificada.
  if (($BreakoutUp -or $BreakoutDown) -and $Freshness -ge 0) {
    $fresh = [Math]::Max(0.0, 1.0 - ($Freshness / 6.0))
    if ($BreakoutUp) { $score += 10.0 * $fresh }
    if ($BreakoutDown) { $score -= 10.0 * $fresh }
  }
  # Preco no extremo da faixa de 20 candles a favor da tendencia = continuacao;
  # no meio da faixa o sinal perde forca.
  if ($TrendAtr -ne 0) {
    $position = [Math]::Max(0.0, [Math]::Min(1.0, $RangePosition))
    $edge = if ($TrendAtr -gt 0) { $position } else { 1.0 - $position }
    $score += ($edge - 0.5) * 12.0 * [Math]::Sign($TrendAtr)
  }
  # Volatilidade muito abaixo da media: movimento sem combustivel.
  if ($VolatilityRatio -gt 0 -and $VolatilityRatio -lt 0.7) { $score *= 0.85 }
  return [Math]::Round([Math]::Max(-100.0, [Math]::Min(100.0, $score)), 1)
}

function Get-ZnxSetupConfidence {
  # Indice de forca do sinal (0-100), NAO probabilidade de acerto: mede
  # quanto os fatores concordam entre si. Sem concordancia fica perto de 50.
  param(
    [double]$Score,
    [double]$MomentumAtr = 0,
    [double]$HigherTrendAtr = 0,
    [double]$ExtensionAtr = 0,
    [double]$VolatilityRatio = 1
  )
  $confidence = 50.0 + ([Math]::Abs($Score) * 0.42)
  $direction = [Math]::Sign($Score)
  if ($direction -ne 0) {
    if ([Math]::Sign($MomentumAtr) -eq $direction) { $confidence += 5.0 }
    if ([Math]::Sign($HigherTrendAtr) -eq $direction) { $confidence += 5.0 }
    if ([Math]::Sign($MomentumAtr) -ne 0 -and [Math]::Sign($MomentumAtr) -ne $direction) { $confidence -= 6.0 }
    if ([Math]::Sign($HigherTrendAtr) -ne 0 -and [Math]::Sign($HigherTrendAtr) -ne $direction) { $confidence -= 6.0 }
  }
  if ($ExtensionAtr -gt 3.0) { $confidence -= 5.0 }
  if ($VolatilityRatio -gt 0 -and $VolatilityRatio -lt 0.7) { $confidence -= 4.0 }
  return [Math]::Round([Math]::Max(5.0, [Math]::Min(95.0, $confidence)), 0)
}

function Get-ZnxBreakoutFreshness {
  # Quantos candles o preco ja esta do lado de fora do nivel (0 = agora).
  # Devolve -1 quando nao ha rompimento.
  param(
    [Parameter(Mandatory = $true)][double[]]$Close,
    [double]$Level,
    [bool]$Up
  )
  $count = $Close.Length
  $bars = -1
  for ($i = $count - 1; $i -ge [Math]::Max(0, $count - 61); $i--) {
    $beyond = if ($Up) { $Close[$i] -gt $Level } else { $Close[$i] -lt $Level }
    if (-not $beyond) { break }
    $bars = $count - 1 - $i
  }
  return $bars
}

function Get-ZnxScanIndicators {
  # Indicadores que nao mudam dentro de um candle de 5 minutos. Ficam em cache
  # por 60 s; o preco ao vivo entra depois, na hora de pontuar.
  param([Parameter(Mandatory = $true)]$Candles)

  $close = $Candles.Close
  $high = $Candles.High
  $low = $Candles.Low
  $volume = $Candles.Volume
  $count = $close.Length
  if ($count -lt 60) { throw "Poucos candles para analisar." }

  $ema9 = Get-ZnxEmaSeries -Values $close -Period 9
  $ema21 = Get-ZnxEmaSeries -Values $close -Period 21
  $ema50 = Get-ZnxEmaSeries -Values $close -Period 50
  $rsiSeries = Get-ZnxRsiSeries -Values $close -Period 14
  $atrSeries = Get-ZnxAtrSeries -High $high -Low $low -Close $close -Period 14

  $last = $count - 1
  $atr = [double]$atrSeries[$last]
  if ($atr -le 0) { throw "ATR invalido." }

  $lookbackStart = [Math]::Max(0, $count - 21)
  $rangeHigh = [double]::MinValue
  $rangeLow = [double]::MaxValue
  for ($i = $lookbackStart; $i -lt $last; $i++) {
    if ($high[$i] -gt $rangeHigh) { $rangeHigh = $high[$i] }
    if ($low[$i] -lt $rangeLow) { $rangeLow = $low[$i] }
  }
  if ($rangeHigh -le $rangeLow) { throw "Faixa de 20 candles invalida." }

  $volumeSum = 0.0
  $volumeCount = 0
  for ($i = [Math]::Max(0, $count - 21); $i -lt $last; $i++) {
    $volumeSum += $volume[$i]
    $volumeCount++
  }
  $avgVolume = 0.0
  if ($volumeCount -gt 0) { $avgVolume = $volumeSum / $volumeCount }
  $volumeRatio = 0.0
  if ($avgVolume -gt 0) { $volumeRatio = [double]$volume[$last] / $avgVolume }

  # Volatilidade relativa: ATR atual contra a media dos ultimos 50 candles.
  $atrSum = 0.0
  $atrCount = 0
  for ($i = [Math]::Max(0, $last - 50); $i -le $last; $i++) {
    $atrSum += [double]$atrSeries[$i]
    $atrCount++
  }
  $volatilityRatio = 1.0
  if ($atrCount -gt 0 -and ($atrSum / $atrCount) -gt 0) {
    $volatilityRatio = $atr / ($atrSum / $atrCount)
  }

  $momentumAtr = 0.0
  if ($last -ge 5) { $momentumAtr = ($close[$last] - $close[$last - 5]) / $atr }

  $higherTrendAtr = ([double]$ema50[$last] - [double]$ema21[$last]) / $atr
  $slopeAtr = 0.0
  if ($last -ge 10) { $slopeAtr = ([double]$ema21[$last] - [double]$ema21[$last - 10]) / $atr }

  $price = [double]$Candles.Price
  $changePercent = 0.0
  if ($Candles.PreviousClose -gt 0) {
    $changePercent = (($price - [double]$Candles.PreviousClose) / [double]$Candles.PreviousClose) * 100.0
  }

  return [ordered]@{
    price          = $price
    previousClose  = [double]$Candles.PreviousClose
    changePercent  = $changePercent
    ema9           = [double]$ema9[$last]
    ema21          = [double]$ema21[$last]
    ema50          = [double]$ema50[$last]
    rsi            = [double]$rsiSeries[$last]
    atr            = $atr
    atrPercent     = ($atr / $price) * 100.0
    rangeHigh      = $rangeHigh
    rangeLow       = $rangeLow
    volumeRatio    = $volumeRatio
    volatilityRatio = $volatilityRatio
    momentumAtr    = $momentumAtr
    higherTrendAtr = $higherTrendAtr
    slopeAtr       = $slopeAtr
    candles        = $count
    # Conta real de pontos de serie calculados (6 indicadores x candles).
    calculations   = $count * 6
    High           = $high
    Low            = $low
    Close          = $close
    Volume         = $volume
  }
}

function Get-ZnxScannerCandlePayloads {
  param([Parameter(Mandatory = $true)][string[]]$Symbols)

  $payloads = @{}
  $failures = @{}
  $batchSize = 4
  $timeoutMs = 20000
  for ($offset = 0; $offset -lt $Symbols.Count; $offset += $batchSize) {
    $jobs = New-Object System.Collections.Generic.List[object]
    $end = [Math]::Min($Symbols.Count - 1, $offset + $batchSize - 1)
    for ($index = $offset; $index -le $end; $index++) {
      $symbol = [string]$Symbols[$index]
      $client = $null
      try {
        $client = New-Object System.Net.WebClient
        $client.Headers.Add("User-Agent", [string]$script:YahooHeaders["User-Agent"])
        $client.Headers.Add("Accept", [string]$script:YahooHeaders["Accept"])
        $encoded = [uri]::EscapeDataString($symbol)
        $uri = "$($script:YahooChartBase)/$($encoded)?range=5d&interval=5m&includePrePost=false"
        $task = $client.DownloadStringTaskAsync($uri)
        $jobs.Add([ordered]@{ Symbol = $symbol; Client = $client; Task = $task })
      }
      catch {
        if ($null -ne $client) { $client.Dispose() }
        $failures[$symbol] = $_.Exception.Message
      }
    }

    $batchStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    foreach ($job in $jobs) {
      try {
        $remainingMs = [Math]::Max(0, $timeoutMs - [int]$batchStopwatch.ElapsedMilliseconds)
        if ($remainingMs -eq 0 -or -not $job.Task.Wait($remainingMs)) {
          $failures[[string]$job.Symbol] = "Tempo limite ao carregar candles do Yahoo Finance."
          continue
        }
        $rawPayload = [string]$job.Task.Result
        if ([string]::IsNullOrWhiteSpace($rawPayload)) {
          throw "Resposta vazia do Yahoo Finance."
        }
        $payloads[[string]$job.Symbol] = $rawPayload
      }
      catch {
        $failures[[string]$job.Symbol] = $_.Exception.Message
      }
      finally {
        $job.Client.Dispose()
      }
    }
  }

  return [pscustomobject]@{
    Payloads = $payloads
    Failures = $failures
  }
}

function Get-ZnxScanner {
  # 2 s: o varredor acompanha o preco ao vivo do TradingView. Os indicadores
  # (candles de 5 min) ficam 60 s em cache por ativo; so a cotacao e relida a
  # cada tique, entao a varredura continua barata para a fonte publica.
  param(
    [int]$CacheTtlSeconds = 2,
    [int]$CacheTtlMs = 2000
  )

  $cached = Get-ZnxCachedValue -Key "scanner" -TtlSeconds $CacheTtlSeconds -TtlMs $CacheTtlMs
  if ($null -ne $cached) { return $cached }

  $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  $items = New-Object System.Collections.Generic.List[object]
  $failed = New-Object System.Collections.Generic.List[string]
  $calculations = 0

  $tvQuotes = @{}
  try { $tvQuotes = Get-ZnxTradingViewQuotes }
  catch { Write-Verbose "TradingView indisponivel no varredor: $($_.Exception.Message)" }

  $scanCandleSymbols = New-Object System.Collections.Generic.List[string]
  foreach ($definition in $script:ScanUniverse) {
    $symbol = [string]$definition.symbol
    $tv = $null
    if ($tvQuotes.ContainsKey($symbol)) { $tv = $tvQuotes[$symbol] }
    if ($null -eq $tv -or $null -eq $tv.delaySeconds -or [int]$tv.delaySeconds -ne 0) {
      continue
    }

    $analysis = Get-ZnxCachedValue -Key "scan-analysis|$symbol" -TtlSeconds 60
    if ($null -eq $analysis) {
      $candles = Get-ZnxCachedValue -Key "candles|$symbol|5d|5m" -TtlSeconds 120
      if ($null -eq $candles) { $scanCandleSymbols.Add($symbol) }
    }
  }

  $scanCandleFailures = @{}
  if ($scanCandleSymbols.Count -gt 0) {
    $prefetched = Get-ZnxScannerCandlePayloads -Symbols $scanCandleSymbols.ToArray()
    foreach ($entry in $prefetched.Payloads.GetEnumerator()) {
      Set-ZnxCachedValue `
        -Key "scanner-candle-payload|$($entry.Key)|5d|5m" `
        -Value ([string]$entry.Value)
    }
    foreach ($entry in $prefetched.Failures.GetEnumerator()) {
      $scanCandleFailures[[string]$entry.Key] = [string]$entry.Value
    }
  }

  foreach ($definition in $script:ScanUniverse) {
    $symbol = [string]$definition.symbol
    $tv = $null
    if ($tvQuotes.ContainsKey($symbol)) { $tv = $tvQuotes[$symbol] }
    if ($null -eq $tv -or [int]$tv.delaySeconds -ne 0) {
      $failed.Add($symbol)
      continue
    }

    try {
      $analysis = Get-ZnxCachedValue -Key "scan-analysis|$symbol" -TtlSeconds 60
      if ($null -eq $analysis) {
        if ($scanCandleFailures.ContainsKey($symbol)) {
          throw "Candles indisponiveis para $symbol."
        }
        $candles = Get-ZnxMarketCandles -Symbol $symbol -Range "5d" -Interval "5m" `
          -CacheTtlSeconds 120
        $analysis = Get-ZnxScanIndicators -Candles $candles
        Set-ZnxCachedValue -Key "scan-analysis|$symbol" -Value $analysis
      }
      $calculations += [int]$analysis.calculations

      $price = [double]$tv.price
      $changePercent = [double]$tv.changePercent
      $quoteSource = "TradingView"
      if ($price -le 0 -or [double]::IsNaN($price) -or [double]::IsInfinity($price)) {
        throw "Preco invalido."
      }

      $atr = [double]$analysis.atr
      $trendAtr = ([double]$analysis.ema9 - [double]$analysis.ema21) / $atr
      $rsi = [double]$analysis.rsi
      $rangeHigh = [double]$analysis.rangeHigh
      $rangeLow = [double]$analysis.rangeLow
      $breakoutUp = $price -gt $rangeHigh
      $breakoutDown = $price -lt $rangeLow
      $rangePosition = ($price - $rangeLow) / ($rangeHigh - $rangeLow)
      $rangePosition = [Math]::Max(0.0, [Math]::Min(1.0, $rangePosition))
      $freshness = 0
      if ($breakoutUp) {
        $freshness = Get-ZnxBreakoutFreshness -Close $analysis.Close -Level $rangeHigh -Up $true
      }
      elseif ($breakoutDown) {
        $freshness = Get-ZnxBreakoutFreshness -Close $analysis.Close -Level $rangeLow -Up $false
      }
      $extension = [Math]::Abs($price - [double]$analysis.ema21) / $atr

      $score = Get-ZnxSetupScore -TrendAtr $trendAtr -Rsi $rsi `
        -BreakoutUp $breakoutUp -BreakoutDown $breakoutDown `
        -VolumeRatio ([double]$analysis.volumeRatio) -ExtensionAtr $extension `
        -MomentumAtr ([double]$analysis.momentumAtr) `
        -HigherTrendAtr ([double]$analysis.higherTrendAtr) `
        -RangePosition $rangePosition -Freshness $freshness `
        -VolatilityRatio ([double]$analysis.volatilityRatio)

      $confidence = Get-ZnxSetupConfidence -Score $score `
        -MomentumAtr ([double]$analysis.momentumAtr) `
        -HigherTrendAtr ([double]$analysis.higherTrendAtr) `
        -ExtensionAtr $extension `
        -VolatilityRatio ([double]$analysis.volatilityRatio)

      $signal = "NEUTRAL"
      if ($score -ge 35) { $signal = "LONG" }
      elseif ($score -le -35) { $signal = "SHORT" }

      $plan = Get-ZnxTradePlan -High $analysis.High -Low $analysis.Low `
        -Close $analysis.Close -Price $price

      $change5m = 0.0
      $closeSeries = $analysis.Close
      if ($closeSeries.Length -ge 6) {
        $reference = [double]$closeSeries[$closeSeries.Length - 6]
        if ($reference -gt 0) { $change5m = (($price - $reference) / $reference) * 100.0 }
      }

      $reasons = New-Object System.Collections.Generic.List[string]
      if ($trendAtr -gt 0.15) { $reasons.Add("EMA 9 acima da EMA 21") }
      elseif ($trendAtr -lt -0.15) { $reasons.Add("EMA 9 abaixo da EMA 21") }
      if ($breakoutUp) {
        if ($freshness -le 1) { $reasons.Add("rompeu a maxima de 20 candles agora") }
        else { $reasons.Add("rompeu a maxima ha $freshness candles") }
      }
      if ($breakoutDown) {
        if ($freshness -le 1) { $reasons.Add("perdeu a minima de 20 candles agora") }
        else { $reasons.Add("perdeu a minima ha $freshness candles") }
      }
      if ($rsi -ge 70) { $reasons.Add("RSI esticado em $([Math]::Round($rsi, 0))") }
      elseif ($rsi -le 30) { $reasons.Add("RSI comprimido em $([Math]::Round($rsi, 0))") }
      if ([double]$analysis.volumeRatio -ge 1.3) {
        $reasons.Add("volume $([Math]::Round([double]$analysis.volumeRatio, 1))x a media")
      }
      if ([Math]::Abs([double]$analysis.momentumAtr) -ge 0.35) {
        $side = if ([double]$analysis.momentumAtr -gt 0) { "acima" } else { "abaixo" }
        $reasons.Add("momentum $side da abertura de 5 candles")
      }
      if ([double]$analysis.higherTrendAtr -ne 0 -and
          [Math]::Sign([double]$analysis.higherTrendAtr) -eq [Math]::Sign($trendAtr)) {
        $reasons.Add("EMA 50 confirma a direcao")
      }
      if ($extension -gt 2.5) { $reasons.Add("preco distante da EMA 21") }
      if ([double]$analysis.volatilityRatio -lt 0.7) { $reasons.Add("volatilidade baixa para o padrao") }
      if ($reasons.Count -eq 0) { $reasons.Add("sem sinal claro no momento") }

      $items.Add([ordered]@{
        symbol        = $symbol
        label         = [string]$definition.label
        group         = [string]$definition.group
        price         = [Math]::Round($price, 6)
        changePercent = [Math]::Round($changePercent, 2)
        change5m      = [Math]::Round($change5m, 2)
        score         = $score
        confidence    = $confidence
        signal        = $signal
        rsi           = [Math]::Round($rsi, 1)
        atrPercent    = [Math]::Round(($atr / $price) * 100.0, 2)
        volumeRatio   = [Math]::Round([double]$analysis.volumeRatio, 2)
        volatilityRatio = [Math]::Round([double]$analysis.volatilityRatio, 2)
        rangePosition = [Math]::Round($rangePosition * 100.0, 0)
        freshness     = $freshness
        quoteSource   = $quoteSource
        entry         = $plan.entry
        stop          = $plan.stop
        target        = $plan.target
        riskReward    = $plan.riskReward
        reasons       = $reasons.ToArray()
      })
    }
    catch {
      $failed.Add($symbol)
    }
  }

  if ($items.Count -eq 0) {
    throw "A varredura nao conseguiu dados de nenhum ativo agora."
  }

  $sorted = @($items | Sort-Object { [Math]::Abs([double]$_.score) } -Descending)
  $payload = [ordered]@{
    at       = [datetime]::UtcNow.ToString("o")
    scanned  = $items.Count
    failed   = $failed.ToArray()
    timeframe = "5m"
    calculations = $calculations
    latencyMs = [int]$stopwatch.ElapsedMilliseconds
    items    = $sorted
  }
  Set-ZnxCachedValue -Key "scanner" -Value $payload
  return $payload
}

# =====================================================================
# MAQUINA DO TEMPO (backtest 60 dias / 5m + 10 mil simulacoes)
# =====================================================================
function Get-ZnxBacktestSignals {
  # Calcula EMAs, ATR e as posicoes de cruzamento UMA vez. O sweep reusa esse
  # resultado em todas as combinacoes de stop/alvo do mesmo ativo, sem repetir
  # 17 mil candles por combinacao.
  param(
    [Parameter(Mandatory = $true)][double[]]$High,
    [Parameter(Mandatory = $true)][double[]]$Low,
    [Parameter(Mandatory = $true)][double[]]$Close
  )
  $ema9 = Get-ZnxEmaSeries -Values $Close -Period 9
  $ema21 = Get-ZnxEmaSeries -Values $Close -Period 21
  $atrSeries = Get-ZnxAtrSeries -High $High -Low $Low -Close $Close -Period 14

  $items = New-Object System.Collections.Generic.List[object]
  $count = $Close.Length
  for ($i = 31; $i -lt $count - 2; $i++) {
    $atr = [double]$atrSeries[$i]
    if ($atr -le 0) { continue }
    $previousUp = $ema9[$i - 1] -le $ema21[$i - 1]
    $currentUp = $ema9[$i] -gt $ema21[$i]
    $previousDown = $ema9[$i - 1] -ge $ema21[$i - 1]
    $currentDown = $ema9[$i] -lt $ema21[$i]
    $crossUp = $previousUp -and $currentUp
    $crossDown = $previousDown -and $currentDown
    if (-not $crossUp -and -not $crossDown) { continue }
    $items.Add([pscustomobject]@{ Index = $i; Long = $crossUp; Atr = $atr })
  }

  return [pscustomobject]@{
    Ema9  = $ema9
    Ema21 = $ema21
    Atr   = $atrSeries
    Items = $items.ToArray()
  }
}

function Invoke-ZnxBacktestCore {
  param(
    [Parameter(Mandatory = $true)][double[]]$OpenPrices,
    [Parameter(Mandatory = $true)][double[]]$High,
    [Parameter(Mandatory = $true)][double[]]$Low,
    [Parameter(Mandatory = $true)][double[]]$Close,
    [double]$StopAtr = 1.5,
    [double]$TargetAtr = 3.0,
    [int]$Simulations = 10000,
    [int]$Seed = 42,
    [int]$MaxBarsPerTrade = 200,
    # Detalhes reais de cada operacao: entrada, saida, motivo e resultado.
    [switch]$CollectTrades,
    [int]$MaxTradeDetails = 60,
    # Series de tempo (segundos) so para rotular a hora de entrada/saida.
    [long[]]$Timestamps,
    # Sinais pre-calculados (Get-ZnxBacktestSignals) reutilizados pelo sweep.
    $Signals = $null,
    # Hashtable sincronizada opcional: recebe o progresso REAL do calculo
    # (candles processados, trades encontrados e reamostragens concluidas).
    [hashtable]$Progress = $null
  )

  if ($Simulations -lt 100) { $Simulations = 100 }
  if ($Simulations -gt 50000) { $Simulations = 50000 }
  if ($StopAtr -le 0) { $StopAtr = 1.5 }
  if ($TargetAtr -le 0) { $TargetAtr = 3.0 }

  $count = $Close.Length
  $base = [ordered]@{
    candles        = $count
    trades         = 0
    wins           = 0
    losses         = 0
    winRate        = 0.0
    avgR           = 0.0
    profitFactor   = 0.0
    maxDrawdownR   = 0.0
    simulations    = $Simulations
    probProfit     = 0.0
    medianR        = 0.0
    p5R            = 0.0
    p95R           = 0.0
    bestR          = 0.0
    worstR         = 0.0
    stopAtr        = $StopAtr
    targetAtr      = $TargetAtr
    maxBarsPerTrade = $MaxBarsPerTrade
    calculations   = $count
    tradeDetails   = @()
  }
  if ($count -lt 60) {
    if ($null -ne $Progress) {
      $Progress["phase"] = "done"
      $Progress["done"] = 0
      $Progress["total"] = 0
      $Progress["trades"] = 0
    }
    return $base
  }

  if ($null -ne $Progress) {
    $Progress["phase"] = "trades"
    $Progress["done"] = 0
    $Progress["total"] = $count
    $Progress["trades"] = 0
  }

  if ($null -eq $Signals) {
    $Signals = Get-ZnxBacktestSignals -High $High -Low $Low -Close $Close
  }

  $tradeResults = New-Object System.Collections.Generic.List[double]
  $tradeDetails = New-Object System.Collections.Generic.List[object]
  $lastExit = 30
  $reward = $TargetAtr / $StopAtr
  $signalItems = @($Signals.Items)
  $signalTotal = $signalItems.Count

  for ($k = 0; $k -lt $signalTotal; $k++) {
    $signal = $signalItems[$k]
    $i = [int]$signal.Index
    if ($null -ne $Progress -and ($k % 25 -eq 0)) {
      $Progress["done"] = $i
      $Progress["trades"] = $tradeResults.Count
    }
    if ($i -le $lastExit) { continue }

    $atr = [double]$signal.Atr
    if ($atr -le 0) { continue }

    $entry = [double]$OpenPrices[$i + 1]
    $isLong = [bool]$signal.Long
    if ($isLong) {
      $stop = $entry - ($StopAtr * $atr)
      $target = $entry + ($TargetAtr * $atr)
    }
    else {
      $stop = $entry + ($StopAtr * $atr)
      $target = $entry - ($TargetAtr * $atr)
    }

    $exitLimit = [Math]::Min($count - 1, $i + $MaxBarsPerTrade)
    $closed = $false
    $exitBar = $exitLimit
    $exitPrice = 0.0
    $reason = "tempo"
    $result = 0.0
    for ($j = $i + 1; $j -le $exitLimit; $j++) {
      if ($isLong) {
        if ($Low[$j] -le $stop) {
          $result = -1.0
          $exitBar = $j
          $exitPrice = $stop
          $reason = "stop"
          $closed = $true
          break
        }
        if ($High[$j] -ge $target) {
          $result = $reward
          $exitBar = $j
          $exitPrice = $target
          $reason = "alvo"
          $closed = $true
          break
        }
      }
      else {
        if ($High[$j] -ge $stop) {
          $result = -1.0
          $exitBar = $j
          $exitPrice = $stop
          $reason = "stop"
          $closed = $true
          break
        }
        if ($Low[$j] -le $target) {
          $result = $reward
          $exitBar = $j
          $exitPrice = $target
          $reason = "alvo"
          $closed = $true
          break
        }
      }
    }
    if (-not $closed) { $lastExit = $exitLimit }
    else {
      $tradeResults.Add($result)
      $lastExit = $exitBar
      if ($CollectTrades) {
        $entryTime = $null
        $exitTime = $null
        if ($null -ne $Timestamps -and $Timestamps.Length -gt $exitBar) {
          if ($i + 1 -lt $Timestamps.Length) {
            $entryTime = [datetimeOffset]::FromUnixTimeSeconds([long]$Timestamps[$i + 1]).UtcDateTime.ToString("o")
          }
          $exitTime = [datetimeOffset]::FromUnixTimeSeconds([long]$Timestamps[$exitBar]).UtcDateTime.ToString("o")
        }
        $tradeDetails.Add([ordered]@{
          direction = if ($isLong) { "LONG" } else { "SHORT" }
          entryBar  = $i + 1
          entryTime = $entryTime
          entry     = [Math]::Round($entry, 6)
          stop      = [Math]::Round($stop, 6)
          target    = [Math]::Round($target, 6)
          exitBar   = $exitBar
          exitTime  = $exitTime
          exit      = [Math]::Round($exitPrice, 6)
          resultR   = [Math]::Round($result, 2)
          reason    = $reason
        })
      }
    }
  }

  if ($null -ne $Progress -and $tradeResults.Count -gt 0) {
    $Progress["phase"] = "simulations"
    $Progress["done"] = 0
    $Progress["total"] = $Simulations
    $Progress["trades"] = $tradeResults.Count
  }

  $tradeCount = $tradeResults.Count
  if ($tradeCount -eq 0) {
    $base.candles = $count
    if ($null -ne $Progress) {
      $Progress["phase"] = "done"
      $Progress["done"] = 0
      $Progress["total"] = 0
    }
    return $base
  }

  $wins = 0
  $losses = 0
  $grossWin = 0.0
  $grossLoss = 0.0
  $sum = 0.0
  $equity = 0.0
  $peak = 0.0
  $maxDd = 0.0
  foreach ($r in $tradeResults) {
    $sum += $r
    if ($r -gt 0) { $wins++; $grossWin += $r } else { $losses++; $grossLoss += [Math]::Abs($r) }
    $equity += $r
    if ($equity -gt $peak) { $peak = $equity }
    $drawdown = $peak - $equity
    if ($drawdown -gt $maxDd) { $maxDd = $drawdown }
  }

  $winRate = ($wins / [double]$tradeCount) * 100.0
  $avgR = $sum / [double]$tradeCount
  $profitFactor = 0.0
  if ($grossLoss -gt 0) { $profitFactor = $grossWin / $grossLoss }

  # Bootstrap: reamostra os trades reais com reposicao para medir a
  # dispersao do resultado, sem inventar operacoes que nao ocorreram.
  $rng = [System.Random]::new($Seed)
  $totals = [double[]]::new($Simulations)
  $profitable = 0
  for ($s = 0; $s -lt $Simulations; $s++) {
    $simEquity = 0.0
    $simPeak = 0.0
    $simDd = 0.0
    for ($t = 0; $t -lt $tradeCount; $t++) {
      $sampled = $tradeResults[$rng.Next($tradeCount)]
      $simEquity += $sampled
      if ($simEquity -gt $simPeak) { $simPeak = $simEquity }
      $dd = $simPeak - $simEquity
      if ($dd -gt $simDd) { $simDd = $dd }
    }
    $totals[$s] = $simEquity
    if ($simEquity -gt 0) { $profitable++ }
    if ($simDd -gt $maxDd) { $maxDd = $simDd }
    if ($null -ne $Progress -and ($s % 100 -eq 0)) {
      $Progress["done"] = $s
    }
  }

  if ($null -ne $Progress) {
    $Progress["done"] = $Simulations
    $Progress["phase"] = "done"
  }

  $orderedTotals = @($totals | Sort-Object)
  $p5Index = [Math]::Max(0, [int][Math]::Floor($Simulations * 0.05))
  $p50Index = [Math]::Max(0, [int][Math]::Floor($Simulations * 0.50))
  $p95Index = [Math]::Min($Simulations - 1, [int][Math]::Floor($Simulations * 0.95))

  return [ordered]@{
    candles         = $count
    trades          = $tradeCount
    wins            = $wins
    losses          = $losses
    winRate         = [Math]::Round($winRate, 1)
    avgR            = [Math]::Round($avgR, 2)
    profitFactor    = [Math]::Round($profitFactor, 2)
    maxDrawdownR    = [Math]::Round($maxDd, 1)
    simulations     = $Simulations
    probProfit      = [Math]::Round(($profitable / [double]$Simulations) * 100.0, 1)
    medianR         = [Math]::Round([double]$orderedTotals[$p50Index], 1)
    p5R             = [Math]::Round([double]$orderedTotals[$p5Index], 1)
    p95R            = [Math]::Round([double]$orderedTotals[$p95Index], 1)
    bestR           = [Math]::Round([double]$orderedTotals[$Simulations - 1], 1)
    worstR          = [Math]::Round([double]$orderedTotals[0], 1)
    stopAtr         = $StopAtr
    targetAtr       = $TargetAtr
    maxBarsPerTrade = $MaxBarsPerTrade
    # Calculos realmente executados: candles lidos + cada reamostragem x
    # trades sorteados + as proprias operacoes fechadas.
    calculations    = $count + ($tradeCount * $Simulations) + $tradeCount
    tradeDetails    = $(if ($CollectTrades) { @($tradeDetails | Select-Object -Last ([Math]::Max(1, $MaxTradeDetails))) } else { @() })
  }
}

function Invoke-ZnxBacktest {
  param(
    [Parameter(Mandatory = $true)][string]$Symbol,
    [double]$StopAtr = 1.5,
    [double]$TargetAtr = 3.0,
    [int]$Simulations = 10000,
    [int]$CacheTtlSeconds = 600,
    [hashtable]$Progress = $null
  )

  $cacheKey = "backtest|$Symbol|$StopAtr|$TargetAtr|$Simulations"
  $cached = Get-ZnxCachedValue -Key $cacheKey -TtlSeconds $CacheTtlSeconds
  if ($null -ne $cached) {
    if ($null -ne $Progress) {
      $Progress["phase"] = "done"
      $Progress["done"] = [int]$cached.stats.simulations
      $Progress["total"] = [int]$cached.stats.simulations
      $Progress["trades"] = [int]$cached.stats.trades
    }
    return $cached
  }

  # O Yahoo limita candles de 5m a 60 dias para tras: e exatamente a janela pedida.
  $candles = Get-ZnxMarketCandles -Symbol $Symbol -Range "60d" -Interval "5m" `
    -CacheTtlSeconds 600
  $stats = Invoke-ZnxBacktestCore -OpenPrices $candles.Open -High $candles.High `
    -Low $candles.Low -Close $candles.Close -StopAtr $StopAtr -TargetAtr $TargetAtr `
    -Simulations $Simulations -Seed 42 -Progress $Progress `
    -Timestamps $candles.Timestamps -CollectTrades

  $payload = [ordered]@{
    symbol     = $Symbol
    label      = [string]$candles.Label
    at         = [datetime]::UtcNow.ToString("o")
    from       = [datetimeOffset]::FromUnixTimeSeconds([long]$candles.Timestamps[0]).UtcDateTime.ToString("o")
    to         = [datetimeOffset]::FromUnixTimeSeconds([long]$candles.Timestamps[$candles.Timestamps.Length - 1]).UtcDateTime.ToString("o")
    timeframe  = "5m"
    strategy   = "cruzamento EMA 9/21 com stop e alvo por ATR"
    stats      = $stats
  }
  Set-ZnxCachedValue -Key $cacheKey -Value $payload
  return $payload
}

function Invoke-ZnxBacktestSweep {
  # Compara varias combinacoes de stop/alvo em TODOS os mercados do radar com
  # os mesmos candles reais. Cada mercado tem seus proprios trades (entrada e
  # saida registradas) e a agregacao mostra quantas combinacoes deram positivo
  # e quantas deram negativo. Nada e sorteado para "dar certo".
  param(
    [string[]]$Symbols = @(),
    [double[]]$StopAtrs = @(1.0, 1.5, 2.0),
    [double[]]$TargetAtrs = @(2.0, 3.0, 4.0),
    # 120 por combinacao x 72 combinacoes = 8.640 reamostragens reais. O custo
    # roda em segundo plano e o progresso e publicado em /api/backtest/progress.
    [int]$Simulations = 120,
    [int]$MaxSamplesPerMarket = 8,
    [int]$CacheTtlSeconds = 600,
    [hashtable]$Progress = $null
  )

  if ($null -eq $Symbols -or $Symbols.Count -eq 0) { $Symbols = Get-ZnxTrackedSymbols }
  if ($StopAtrs.Count -eq 0) { $StopAtrs = @(1.0, 1.5, 2.0) }
  if ($TargetAtrs.Count -eq 0) { $TargetAtrs = @(2.0, 3.0, 4.0) }
  if ($Simulations -lt 100) { $Simulations = 100 }
  if ($Simulations -gt 2000) { $Simulations = 2000 }

  $gridKey = "$($StopAtrs -join ',')" + "|" + "$($TargetAtrs -join ',')"
  $cacheKey = "sweep|$($Symbols -join ',')|$gridKey|$Simulations"
  $cached = Get-ZnxCachedValue -Key $cacheKey -TtlSeconds $CacheTtlSeconds
  if ($null -ne $cached) {
    if ($null -ne $Progress) {
      $Progress["phase"] = "done"
      $Progress["done"] = 1
      $Progress["total"] = 1
      $Progress["trades"] = [int]$cached.aggregate.entries
    }
    return $cached
  }

  $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  $combosPerMarket = $StopAtrs.Count * $TargetAtrs.Count
  $totalRuns = $Symbols.Count * $combosPerMarket
  $run = 0
  if ($null -ne $Progress) {
    $Progress["phase"] = "markets"
    $Progress["done"] = 0
    $Progress["total"] = $totalRuns
    $Progress["trades"] = 0
  }

  $markets = New-Object System.Collections.Generic.List[object]
  $aggEntries = 0
  $aggExits = 0
  $aggWins = 0
  $aggLosses = 0
  $aggGrossWin = 0.0
  $aggGrossLoss = 0.0
  $aggR = 0.0
  $totalCalculations = 0
  $successfulCombos = 0
  $failedCombos = 0
  $fromMs = [long]::MaxValue
  $toMs = [long]::MinValue

  foreach ($symbol in $Symbols) {
    $label = Get-ZnxSymbolLabel -Symbol $symbol
    $candles = $null
    try {
      $candles = Get-ZnxMarketCandles -Symbol $symbol -Range "60d" -Interval "5m" `
        -CacheTtlSeconds 600
    }
    catch {
      Write-Verbose "Sweep sem candles para $symbol`: $($_.Exception.Message)"
      $run += $combosPerMarket
      if ($null -ne $Progress) { $Progress["done"] = $run }
      continue
    }

    if ([long]$candles.Timestamps[0] -lt $fromMs) { $fromMs = [long]$candles.Timestamps[0] }
    $lastStamp = [long]$candles.Timestamps[$candles.Timestamps.Length - 1]
    if ($lastStamp -gt $toMs) { $toMs = $lastStamp }

    $signals = Get-ZnxBacktestSignals -High $candles.High -Low $candles.Low -Close $candles.Close
    $combos = New-Object System.Collections.Generic.List[object]
    $bestStats = $null
    $bestStop = 0.0
    $bestTarget = 0.0
    $bestEligible = $false

    foreach ($stopAtr in $StopAtrs) {
      foreach ($targetAtr in $TargetAtrs) {
        $stats = Invoke-ZnxBacktestCore -OpenPrices $candles.Open -High $candles.High `
          -Low $candles.Low -Close $candles.Close -StopAtr $stopAtr -TargetAtr $targetAtr `
          -Simulations $Simulations -Seed 42 -Signals $signals -CollectTrades `
          -MaxTradeDetails 0 -Timestamps $candles.Timestamps
        $totalCalculations += [int]$stats.calculations
        $run += 1
        if ($null -ne $Progress) {
          $Progress["done"] = $run
          $Progress["trades"] = $aggEntries + $stats.trades
        }

        $combos.Add([ordered]@{
          stopAtr     = $stopAtr
          targetAtr   = $targetAtr
          trades      = [int]$stats.trades
          winRate     = [double]$stats.winRate
          avgR        = [double]$stats.avgR
          profitFactor = [double]$stats.profitFactor
        })

        if ([int]$stats.trades -gt 0) {
          if ([double]$stats.avgR -gt 0) { $successfulCombos++ } else { $failedCombos++ }
          $eligible = [int]$stats.trades -ge 5
          if ($null -eq $bestStats -or ($eligible -and -not $bestEligible) -or
              ($eligible -eq $bestEligible -and [double]$stats.avgR -gt [double]$bestStats.avgR)) {
            $bestStats = $stats
            $bestStop = $stopAtr
            $bestTarget = $targetAtr
            $bestEligible = $eligible
          }
        }
      }
    }

    if ($null -eq $bestStats) {
      $markets.Add([ordered]@{
        symbol = $symbol; label = $label; candles = [int]$candles.Close.Length
        trades = 0; wins = 0; losses = 0; winRate = 0.0; avgR = 0.0
        profitFactor = 0.0; bestStopAtr = 0.0; bestTargetAtr = 0.0
        calculations = 0; combos = @($combos.ToArray()); samples = @()
      })
      continue
    }

    # Melhor combinacao do mercado: refaz a coleta de detalhes so para ela,
    # para trazer amostras reais de entrada e saida sem carregar 9 listas.
    $samples = @()
    try {
      $sampleStats = Invoke-ZnxBacktestCore -OpenPrices $candles.Open -High $candles.High `
        -Low $candles.Low -Close $candles.Close -StopAtr $bestStop -TargetAtr $bestTarget `
        -Simulations 100 -Seed 42 -Signals $signals -CollectTrades `
        -MaxTradeDetails $MaxSamplesPerMarket -Timestamps $candles.Timestamps
      $samples = @($sampleStats.tradeDetails)
    }
    catch { $samples = @() }

    $markets.Add([ordered]@{
      symbol       = $symbol
      label        = $label
      candles      = [int]$bestStats.candles
      trades       = [int]$bestStats.trades
      wins         = [int]$bestStats.wins
      losses       = [int]$bestStats.losses
      winRate      = [double]$bestStats.winRate
      avgR         = [double]$bestStats.avgR
      profitFactor = [double]$bestStats.profitFactor
      bestStopAtr  = $bestStop
      bestTargetAtr = $bestTarget
      calculations = [int]$bestStats.calculations
      combos       = @($combos.ToArray())
      samples      = $samples
    })

    $aggEntries += [int]$bestStats.trades
    $aggExits += [int]$bestStats.trades
    $aggWins += [int]$bestStats.wins
    $aggLosses += [int]$bestStats.losses
    $aggR += ([double]$bestStats.avgR * [int]$bestStats.trades)
    foreach ($combo in $combos) {
      if ([int]$combo.trades -le 0) { continue }
      $totalReturn = [double]$combo.avgR * [int]$combo.trades
      if ($totalReturn -ge 0) { $aggGrossWin += $totalReturn } else { $aggGrossLoss += [Math]::Abs($totalReturn) }
    }
  }

  if ($markets.Count -eq 0) {
    throw "O comparativo nao conseguiu candles de nenhum mercado agora."
  }

  $stopwatch.Stop()
  $sortedMarkets = @($markets | Sort-Object { [double]$_.avgR } -Descending)
  $profitFactor = 0.0
  if ($aggGrossLoss -gt 0) { $profitFactor = $aggGrossWin / $aggGrossLoss }
  $aggregate = [ordered]@{
    markets          = $sortedMarkets.Count
    combos           = $sortedMarkets.Count * $combosPerMarket
    simulationsPerCombo = $Simulations
    simulations      = $sortedMarkets.Count * $combosPerMarket * $Simulations
    entries          = $aggEntries
    exits            = $aggExits
    wins             = $aggWins
    losses           = $aggLosses
    winRate          = $(if ($aggEntries -gt 0) { [Math]::Round(($aggWins / [double]$aggEntries) * 100.0, 1) } else { 0.0 })
    avgR             = $(if ($aggEntries -gt 0) { [Math]::Round($aggR / [double]$aggEntries, 2) } else { 0.0 })
    profitFactor     = [Math]::Round($profitFactor, 2)
    successfulCombos = $successfulCombos
    failedCombos     = $failedCombos
    calculations     = $totalCalculations
    elapsedMs        = [int]$stopwatch.ElapsedMilliseconds
  }

  $payload = [ordered]@{
    mode       = "sweep"
    at         = [datetime]::UtcNow.ToString("o")
    strategy   = "cruzamento EMA 9/21 com stop e alvo por ATR, em 8 mercados"
    timeframe  = "5m"
    from       = $(if ($fromMs -lt [long]::MaxValue) { [datetimeOffset]::FromUnixTimeSeconds($fromMs).UtcDateTime.ToString("o") } else { $null })
    to         = $(if ($toMs -gt [long]::MinValue) { [datetimeOffset]::FromUnixTimeSeconds($toMs).UtcDateTime.ToString("o") } else { $null })
    grid       = [ordered]@{ stopAtrs = $StopAtrs; targetAtrs = $TargetAtrs }
    aggregate  = $aggregate
    markets    = $sortedMarkets
  }

  if ($null -ne $Progress) {
    $Progress["done"] = $totalRuns
    $Progress["phase"] = "done"
    $Progress["trades"] = $aggEntries
  }

  Set-ZnxCachedValue -Key $cacheKey -Value $payload
  return $payload
}

# =====================================================================
# ENTRADA / SAIDA
# =====================================================================
function Get-ZnxTradePlan {
  param(
    [Parameter(Mandatory = $true)][double[]]$High,
    [Parameter(Mandatory = $true)][double[]]$Low,
    [Parameter(Mandatory = $true)][double[]]$Close,
    [double]$Price = 0,
    [double]$StopAtr = 1.2,
    [double]$TargetRatio = 2.0
  )

  $count = $Close.Length
  if ($count -lt 30) { throw "Candles insuficientes para montar o plano." }
  if ($Price -le 0) { $Price = [double]$Close[$count - 1] }

  $ema9 = Get-ZnxEmaSeries -Values $Close -Period 9
  $ema21 = Get-ZnxEmaSeries -Values $Close -Period 21
  $atrSeries = Get-ZnxAtrSeries -High $High -Low $Low -Close $Close -Period 14
  $atr = [double]$atrSeries[$count - 1]
  if ($atr -le 0) { throw "ATR invalido para montar o plano." }

  $bias = "NEUTRAL"
  if ([double]$ema9[$count - 1] -gt [double]$ema21[$count - 1]) { $bias = "LONG" }
  elseif ([double]$ema9[$count - 1] -lt [double]$ema21[$count - 1]) { $bias = "SHORT" }

  $lookback = [Math]::Max(0, $count - 21)
  $swingHigh = [double]::MinValue
  $swingLow = [double]::MaxValue
  for ($i = $lookback; $i -lt $count; $i++) {
    if ($High[$i] -gt $swingHigh) { $swingHigh = $High[$i] }
    if ($Low[$i] -lt $swingLow) { $swingLow = $Low[$i] }
  }

  if ($bias -eq "SHORT") {
    $stop = [Math]::Max($swingHigh, $Price) + (0.25 * $atr)
    $risk = $stop - $Price
    if ($risk -lt (0.6 * $atr)) { $risk = $StopAtr * $atr; $stop = $Price + $risk }
    $target = $Price - ($risk * $TargetRatio)
  }
  else {
    $stop = [Math]::Min($swingLow, $Price) - (0.25 * $atr)
    $risk = $Price - $stop
    if ($risk -lt (0.6 * $atr)) { $risk = $StopAtr * $atr; $stop = $Price - $risk }
    $target = $Price + ($risk * $TargetRatio)
  }

  $risk = [Math]::Abs($Price - $stop)
  $reward = [Math]::Abs($target - $Price)
  $rr = 0.0
  if ($risk -gt 0) { $rr = $reward / $risk }

  return [ordered]@{
    price          = [Math]::Round($Price, 6)
    bias           = $bias
    entry          = [Math]::Round($Price, 6)
    stop           = [Math]::Round($stop, 6)
    target         = [Math]::Round($target, 6)
    riskPerUnit    = [Math]::Round($risk, 6)
    rewardPerUnit  = [Math]::Round($reward, 6)
    riskReward     = [Math]::Round($rr, 2)
    atr            = [Math]::Round($atr, 6)
    atrPercent     = [Math]::Round(($atr / $Price) * 100.0, 2)
    breakEvenWinRate = [Math]::Round((1.0 / (1.0 + $rr)) * 100.0, 1)
  }
}

function Get-ZnxPositionPlan {
  param(
    [double]$Balance,
    [double]$RiskPercent,
    [double]$Entry,
    [double]$Stop,
    [double]$Target = 0
  )
  if ($Balance -le 0) { throw "Informe um saldo maior que zero." }
  if ($RiskPercent -le 0 -or $RiskPercent -gt 100) {
    throw "O risco por operacao precisa ficar entre 0 e 100%."
  }
  $distance = [Math]::Abs($Entry - $Stop)
  if ($distance -le 0) { throw "O stop precisa ser diferente do preco de entrada." }

  $riskAmount = $Balance * ($RiskPercent / 100.0)
  $size = $riskAmount / $distance
  $notional = $size * $Entry

  $rr = 0.0
  if ($Target -gt 0) {
    $rr = [Math]::Abs($Target - $Entry) / $distance
  }
  $breakEven = 0.0
  if ($rr -gt 0) {
    $breakEven = (1.0 / (1.0 + $rr)) * 100.0
  }

  return [ordered]@{
    balance          = [Math]::Round($Balance, 2)
    riskPercent      = [Math]::Round($RiskPercent, 2)
    riskAmount       = [Math]::Round($riskAmount, 2)
    entry            = [Math]::Round($Entry, 6)
    stop             = [Math]::Round($Stop, 6)
    stopDistance     = [Math]::Round($distance, 6)
    positionSize     = [Math]::Round($size, 4)
    notional         = [Math]::Round($notional, 2)
    riskReward       = [Math]::Round($rr, 2)
    breakEvenWinRate = [Math]::Round($breakEven, 1)
  }
}

# =====================================================================
# CONSISTENCIA ENTRE CONFIDENCE E DESFECHO
# ---------------------------------------------------------------------
# O confidence do contrato V8.1 mede forca, clareza e consistencia das
# evidencias tecnicas; NAO e probabilidade de acerto. Esta funcao mede
# apenas a discrepancia numerica entre esse indice e o desfecho real:
#   p = confidence/100, o = 1 (favorable) / 0 (adverse), erro = (p - o)^2
# O resultado e diagnostico e experimental: nao e Brier probabilistico,
# nao e taxa de acerto e nao ajusta nenhuma decisao da IA.
# Sem amostra valida o campo fica nulo: zero nao e "sem amostra".
# Fonte unica da conta: tools/evaluate.ps1 e /api/calibration.
# =====================================================================
function ConvertTo-ZnxConfidenceNumber {
  # Leitura tolerante do campo confidence: ausente, booleano, texto, NaN ou
  # fora de 0..100 devolve $null. Sem isso, [int]$row.confidence transformava
  # registro invalido em zero (faixa 0-54) ou derrubava quem chamava.
  param([object]$Confidence)

  if ($null -eq $Confidence) { return $null }
  if ($Confidence -is [bool] -or $Confidence -is [char]) { return $null }
  if ($Confidence -is [datetime] -or $Confidence -is [datetimeoffset]) { return $null }

  $value = 0.0
  if ($Confidence -is [System.ValueType]) {
    # Numero de verdade: converte direto, sem passar por texto (que usaria a
    # cultura local e leria "80,5" como 805).
    try { $value = [double]$Confidence } catch { return $null }
  }
  else {
    $text = [string]$Confidence
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $parsed = [double]::TryParse(
      $text,
      [System.Globalization.NumberStyles]::Float,
      [System.Globalization.CultureInfo]::InvariantCulture,
      [ref]$value)
    if (-not $parsed) { return $null }
  }
  if ([double]::IsNaN($value) -or [double]::IsInfinity($value)) { return $null }
  if ($value -lt 0 -or $value -gt 100) { return $null }
  return $value
}

function ConvertTo-ZnxNormalizedConfidence {
  param([Parameter(Mandatory = $true)][double]$Confidence)
  # Clamp de protecao matematica em [0,1]. Nao valida o registro: quem
  # decide se a amostra entra e Get-ZnxConfidenceOutcomeError.
  $p = $Confidence / 100.0
  if ($p -lt 0) { return 0.0 }
  if ($p -gt 1) { return 1.0 }
  return $p
}

# Faixas de confidence: definicao unica dos limites.
# O valor entra na faixa pelo inteiro truncado, entao 54,9 fica em 0-54 e 69,5
# fica em 55-69. Inteiro nao muda de faixa. Antes 69,5 nao caia em faixa
# nenhuma no erro quadratico e caia em 70-84 no relatorio, porque cada lugar
# arredondava de um jeito.
$script:ConfidenceBucketRanges = @(
  @{ Label = "0-54";   Min = 0;   Max = 54 },
  @{ Label = "55-69";  Min = 55;  Max = 69 },
  @{ Label = "70-84";  Min = 70;  Max = 84 },
  @{ Label = "85-100"; Min = 85;  Max = 100 }
)

function Get-ZnxConfidenceBucketLabel {
  param([Parameter(Mandatory = $true)][double]$Confidence)
  $value = [Math]::Floor($Confidence)
  foreach ($range in $script:ConfidenceBucketRanges) {
    if ($value -ge $range.Min -and $value -le $range.Max) { return [string]$range.Label }
  }
  return $null
}

function Get-ZnxConfidenceOutcomeError {
  param(
    [object[]]$Outcomes = @(),
    [object[]]$Buckets = @()
  )

  if (-not $Buckets -or $Buckets.Count -eq 0) {
    $Buckets = $script:ConfidenceBucketRanges
  }

  $rows = @()
  $invalidSamples = 0
  foreach ($item in @($Outcomes)) {
    if ($null -eq $item) { continue }
    if ([string]$item.outcome -notin @("favorable", "adverse")) { continue }
    if ([string]$item.direction -notin @("BUY", "SELL")) { continue }
    # Desfecho pontuado sem confidence numerico no dominio 0..100 nao entra
    # na amostra: e contado como invalido em vez de virar numero inventado.
    $rawConfidence = ConvertTo-ZnxConfidenceNumber -Confidence $item.confidence
    if ($null -eq $rawConfidence) {
      $invalidSamples++
      continue
    }
    $p = ConvertTo-ZnxNormalizedConfidence -Confidence $rawConfidence
    $o = 0.0
    if ([string]$item.outcome -eq "favorable") { $o = 1.0 }
    $rows += [pscustomobject]@{
      confidence = $rawConfidence
      p          = $p
      o          = $o
      error      = ($p - $o) * ($p - $o)
    }
  }

  $meanError = $null
  if ($rows.Count -gt 0) {
    $sum = 0.0
    foreach ($row in $rows) { $sum += $row.error }
    $meanError = [Math]::Round($sum / $rows.Count, 4)
  }

  $bands = @()
  foreach ($bucket in $Buckets) {
    $inBand = @($rows | Where-Object {
      (Get-ZnxConfidenceBucketLabel -Confidence $_.confidence) -eq [string]$bucket.Label
    })
    $confidenceMean = $null
    $favorableRate = $null
    $averageSquaredError = $null
    if ($inBand.Count -gt 0) {
      $confidenceSum = 0.0
      $favorableCount = 0
      $errorSum = 0.0
      foreach ($row in $inBand) {
        $confidenceSum += $row.confidence
        if ($row.o -ge 1.0) { $favorableCount++ }
        $errorSum += $row.error
      }
      $confidenceMean = [Math]::Round($confidenceSum / $inBand.Count, 1)
      $favorableRate = [Math]::Round($favorableCount / [double]$inBand.Count, 4)
      $averageSquaredError = [Math]::Round($errorSum / $inBand.Count, 4)
    }
    $bands += [ordered]@{
      bucket              = [string]$bucket.Label
      sampleCount         = $inBand.Count
      confidenceMean      = $confidenceMean
      favorableRate       = $favorableRate
      averageSquaredError = $averageSquaredError
    }
  }

  return [ordered]@{
    sampleCount            = $rows.Count
    confidenceOutcomeError = $meanError
    invalidSampleCount     = $invalidSamples
    bands                  = $bands
  }
}

Export-ModuleMember -Function @(
  "Get-ZnxTrackedSymbols",
  "Get-ZnxSymbolLabel",
  "Get-ZnxMarketCandles",
  "Get-ZnxMarketSnapshot",
  "Get-ZnxTradingViewQuotes",
  "Get-ZnxChartSeries",
  "Get-ZnxRecentNewsItems",
  "Get-ZnxMarketNews",
  "Get-ZnxScanner",
  "Invoke-ZnxBacktest",
  "Invoke-ZnxBacktestCore",
  "Invoke-ZnxBacktestSweep",
  "Get-ZnxBacktestSignals",
  "Get-ZnxTradePlan",
  "Get-ZnxPositionPlan",
  "Get-ZnxSetupScore",
  "Get-ZnxSetupConfidence",
  "Get-ZnxBreakoutFreshness",
  "Get-ZnxScanIndicators",
  "Get-ZnxEmaSeries",
  "Get-ZnxRsiSeries",
  "Get-ZnxAtrSeries",
  "Get-ZnxLastValue",
  "Get-ZnxConfidenceOutcomeError",
  "Get-ZnxConfidenceBucketLabel",
  "ConvertTo-ZnxConfidenceNumber",
  "ConvertTo-ZnxNormalizedConfidence"
)
