# Versao do contrato. Deve acompanhar o nome do arquivo em prompts\.
$script:ContractVersion = "8.1"

# System.Drawing esta disponivel no Windows PowerShell 5.1. Se o modulo for
# importado em um host sem GDI+, o pre-processamento simplesmente nao age.
$script:DrawingAvailable = $false
try {
  Add-Type -AssemblyName System.Drawing -ErrorAction Stop
  $script:DrawingAvailable = $true
}
catch { }

# System.Net.Http precisa existir antes da resolucao do parametro tipado de
# Invoke-OpenAIChatCompletion. O server.ps1 ja carrega, mas o modulo tambem e
# importado direto por testes e ferramentas.
try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop } catch { }

# Fonte unica da lista de campos do topo do JSON de analise.
$script:ContractFields = @(
  "image_class", "chart_type", "price_axis_readable", "price_axis_min", "price_axis_max",
  "asset_visible", "timeframe_visible",
  "last_candle_status", "visual_quality", "analysis_coverage", "confidence", "direction",
  "directional_assessment",
  "trend", "price_action", "levels", "patterns", "indicators", "volume", "evidence_for",
  "evidence_against", "signal_timing", "conflict_notes", "risk", "summary"
)

function Get-AnalysisContractFields {
  return @($script:ContractFields)
}

function Get-AnalysisContractVersion {
  return $script:ContractVersion
}

function Test-HasExactProperties {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string[]]$ExpectedProperties
    )
    $actualProps = @($Object.PSObject.Properties | ForEach-Object { $_.Name })
    if ($actualProps.Count -ne $ExpectedProperties.Count) { return $false }
    foreach ($ep in $ExpectedProperties) {
        if ($actualProps -cnotcontains $ep) { return $false }
    }
    return $true
}

function New-AnalysisStringArraySchema {
  param([int]$MaxItems = 0)
  $schema = @{
    type  = "array"
    items = @{ type = "string" }
  }
  if ($MaxItems -gt 0) { $schema.maxItems = $MaxItems }
  return $schema
}

function New-AnalysisResponseSchema {
  $stringArray = New-AnalysisStringArraySchema
  $schema = @{
    type = "object"
    additionalProperties = $false
    # Ordem de geracao: identificacao e leitura primeiro, decisao por ultimo. Em
    # structured outputs o modelo emite as chaves na ordem do schema, entao
    # direction/confidence so podem vir depois da evidencia que as sustenta.
    properties = [ordered]@{
      image_class          = @{ type = "string"; enum = @("A", "B", "C", "D") }
      chart_type           = @{ type = @("string", "null") }
      price_axis_readable  = @{ type = "boolean" }
      price_axis_min       = @{ type = @("number", "null") }
      price_axis_max       = @{ type = @("number", "null") }
      asset_visible        = @{ type = @("string", "null") }
      timeframe_visible    = @{ type = @("string", "null") }
      last_candle_status   = @{ type = "string"; enum = @("closed", "possibly_open", "unknown") }
      visual_quality       = @{ type = "integer"; minimum = 0; maximum = 100 }
      analysis_coverage    = @{ type = "integer"; minimum = 0; maximum = 100 }
      trend = @{
        type = "object"; additionalProperties = $false
        properties = @{
          main        = @{ type = "string"; enum = @("alta", "baixa", "lateralização", "indefinida") }
          micro       = @{ type = "string"; enum = @("alta", "baixa", "lateralização", "indefinida") }
          structure   = (New-AnalysisStringArraySchema -MaxItems 5)
          explanation = @{ type = "string" }
        }
        required = @("main", "micro", "structure", "explanation")
      }
      price_action = @{
        type = "object"; additionalProperties = $false
        properties = @{
          observations    = (New-AnalysisStringArraySchema -MaxItems 5)
          interpretations = (New-AnalysisStringArraySchema -MaxItems 5)
          conditions      = (New-AnalysisStringArraySchema -MaxItems 5)
        }
        required = @("observations", "interpretations", "conditions")
      }
      levels = @{
        type = "array"
        maxItems = 5
        items = @{
          type = "object"; additionalProperties = $false
          properties = @{
            type   = @{ type = "string"; enum = @("support", "resistance", "breakout", "retest", "other") }
            value  = @{ type = @("number", "null") }
            region = @{ type = "string" }
            reason = @{ type = "string" }
          }
          required = @("type", "value", "region", "reason")
        }
      }
      patterns = @{
        type = "array"
        maxItems = 2
        items = @{
          type = "object"; additionalProperties = $false
          properties = @{
            name         = @{ type = "string" }
            status       = @{ type = "string"; enum = @("incomplete", "visually_confirmed", "invalidated") }
            evidence     = $stringArray
            confirmation = @{ type = "string" }
            invalidation = @{ type = "string" }
          }
          required = @("name", "status", "evidence", "confirmation", "invalidation")
        }
      }
      indicators = @{
        type = "array"
        maxItems = 4
        items = @{
          type = "object"; additionalProperties = $false
          properties = @{
            name           = @{ type = "string" }
            visible        = @{ type = "boolean" }
            observations   = $stringArray
            interpretation = @{ type = "string" }
            conflict       = @{ type = "string" }
          }
          required = @("name", "visible", "observations", "interpretation", "conflict")
        }
      }
      volume = @{
        type = "object"; additionalProperties = $false
        properties = @{
          visible        = @{ type = "boolean" }
          observations   = $stringArray
          interpretation = @{ type = "string" }
        }
        required = @("visible", "observations", "interpretation")
      }
      directional_assessment = @{
        type = "object"; additionalProperties = $false
        properties = @{
          buy_score      = @{ type = "integer"; minimum = 0; maximum = 100 }
          sell_score     = @{ type = "integer"; minimum = 0; maximum = 100 }
          buy_status     = @{ type = "string"; enum = @("supported", "weak", "contradicted", "unavailable") }
          buy_evidence   = (New-AnalysisStringArraySchema -MaxItems 2)
          sell_status    = @{ type = "string"; enum = @("supported", "weak", "contradicted", "unavailable") }
          sell_evidence  = (New-AnalysisStringArraySchema -MaxItems 2)
          selected_reason = @{ type = "string" }
        }
        required = @(
          "buy_score", "sell_score", "buy_status", "buy_evidence",
          "sell_status", "sell_evidence", "selected_reason"
        )
      }
      evidence_for     = (New-AnalysisStringArraySchema -MaxItems 3)
      evidence_against = (New-AnalysisStringArraySchema -MaxItems 3)
      conflict_notes = (New-AnalysisStringArraySchema -MaxItems 3)
      risk           = (New-AnalysisStringArraySchema -MaxItems 3)
      direction            = @{ type = "string"; enum = @("BUY", "SELL", "NEUTRAL") }
      confidence           = @{ type = "integer"; minimum = 0; maximum = 100 }
      signal_timing = @{
        type = "object"; additionalProperties = $false
        properties = @{
          action                = @{ type = "string"; enum = @("BUY", "SELL", "WAIT") }
          signal_candle         = @{ type = "string"; enum = @("closed", "possibly_open", "unknown") }
          entry_timing          = @{ type = "string" }
          exit_plan             = @{ type = "string" }
          holding_horizon       = @{ type = "string" }
          confirmation_required = (New-AnalysisStringArraySchema -MaxItems 3)
          invalidation          = (New-AnalysisStringArraySchema -MaxItems 3)
        }
        required = @(
          "action", "signal_candle", "entry_timing", "exit_plan",
          "holding_horizon", "confirmation_required", "invalidation"
        )
      }
      summary        = @{ type = "string" }
    }
    required = @(
      "image_class", "chart_type", "price_axis_readable", "price_axis_min", "price_axis_max",
      "asset_visible", "timeframe_visible", "last_candle_status", "visual_quality",
      "analysis_coverage", "trend", "price_action", "levels", "patterns", "indicators",
      "volume", "directional_assessment", "evidence_for", "evidence_against",
      "conflict_notes", "risk", "direction", "confidence", "signal_timing", "summary"
    )
  }
  return $schema
}

function Test-AnalysisNumber {
  param([AllowNull()]$Value)
  if ($null -eq $Value) { return $true }
  return ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int] -or
    $Value -is [long] -or $Value -is [single] -or $Value -is [double] -or
    $Value -is [decimal])
}

function Test-StringArray {
  param([AllowNull()]$Value)
  if ($Value -isnot [array]) { return $false }
  foreach ($item in $Value) {
    if ($item -isnot [string]) { return $false }
  }
  return $true
}

function Join-AnalysisItems {
  param(
    [AllowNull()][string[]]$Items,
    [Parameter(Mandatory = $true)][string]$Fallback,
    [string]$Separator = "; "
  )
  $usableItems = @($Items | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($usableItems.Count -eq 0) { return $Fallback }
  return ($usableItems -join $Separator)
}

function Remove-AnalysisDuplicates {
  param([AllowNull()][string[]]$Items)
  if ($null -eq $Items) { return @() }
  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  $unique = New-Object 'System.Collections.Generic.List[string]'
  foreach ($item in @($Items)) {
    $text = ([string]$item).Trim()
    if (-not $text) { continue }
    if ($seen.Add($text)) { $unique.Add($text) }
  }
  return $unique.ToArray()
}

function New-ValidatedAnalysisSummary {
  param(
    [Parameter(Mandatory = $true)]$Result,
    [AllowNull()][string]$ModelSummary
  )
  $trend = "Tendencia principal: $($Result.trend.main); microtendencia: $($Result.trend.micro)."
  $trendDetails = @($Result.trend.structure) + @($Result.trend.explanation)
  $evidenceFor = Join-AnalysisItems -Items $Result.evidence_for -Fallback "Nenhuma evidencia direcional favoravel foi registrada."
  $evidenceAgainst = Join-AnalysisItems -Items $Result.evidence_against -Fallback "Nenhuma evidencia contraria especifica foi registrada."
  $conditions = Join-AnalysisItems -Items $Result.price_action.conditions -Fallback "Nenhuma condicao adicional foi identificada."
  $confirmation = Join-AnalysisItems -Items $Result.signal_timing.confirmation_required -Fallback "Nao ha confirmacao adicional registrada."
  $invalidation = Join-AnalysisItems -Items $Result.signal_timing.invalidation -Fallback "Nao foi registrada uma condicao especifica de invalidacao."
  $risks = Join-AnalysisItems -Items $Result.risk -Fallback "Nao foi registrada limitacao adicional."
  $levels = @($Result.levels | ForEach-Object {
    $value = if ($null -eq $_.value) { "preco nao quantificado" } else { [string]$_.value }
    "{0}: {1} ({2}) - {3}" -f $_.type, $_.region, $value, $_.reason
  })
  $indicatorNotes = @($Result.indicators | Where-Object { $_.visible } | ForEach-Object {
    $observations = Join-AnalysisItems -Items $_.observations -Fallback $_.interpretation
    "{0}: {1}" -f $_.name, $observations
  })
  if ($Result.volume.visible) {
    $indicatorNotes += Join-AnalysisItems -Items $Result.volume.observations -Fallback $Result.volume.interpretation
  }
  $priceAction = @($Result.price_action.observations) + @($Result.price_action.interpretations) +
    @($Result.price_action.conditions)
  $limitations = @($Result.risk)
  if (-not $Result.price_axis_readable) {
    $limitations += "A escala de precos nao esta legivel; niveis numericos nao sao apresentados."
  }
  if ([string]::IsNullOrWhiteSpace([string]$Result.asset_visible)) {
    $limitations += "O ativo nao pode ser identificado visualmente."
  }
  if ([string]::IsNullOrWhiteSpace([string]$Result.timeframe_visible)) {
    $limitations += "O timeframe nao pode ser identificado visualmente."
  }
  if ($Result.last_candle_status -ne "closed") {
    $limitations += "O fechamento da ultima vela nao foi confirmado."
  }

  # Preserva o texto descritivo produzido pela IA quando o summary nao veio nos titulos canonicos.
  $narrative = ""
  if (-not [string]::IsNullOrWhiteSpace($ModelSummary)) {
    $narrative = $ModelSummary -replace "(?i)(leitura geral|price action|niveis e zonas|indicadores e volumes|cenario e invalidacao|limitacoes)\s*:", " "
    $narrative = ($narrative -replace "\s+", " ").Trim()
    if ($narrative.Length -lt 40) { $narrative = "" }
  }
  $identityNotes = @()
  if (-not [string]::IsNullOrWhiteSpace([string]$Result.asset_visible)) {
    $identityNotes += "Ativo: $($Result.asset_visible)"
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$Result.timeframe_visible)) {
    $identityNotes += "timeframe: $($Result.timeframe_visible)"
  }
  if ($Result.price_axis_readable -and $null -ne $Result.price_axis_min -and $null -ne $Result.price_axis_max) {
    $identityNotes += "escala: $($Result.price_axis_min) a $($Result.price_axis_max)"
  }
  $identity = if ($identityNotes.Count -gt 0) { ($identityNotes -join "; ") + ". " } else { "" }
  $readingBody = if ($narrative) { "$narrative " } else { "" }
  $readingTail = "Classe $($Result.image_class); direcao $($Result.direction). $trend $($trendDetails -join '; ') Confidence: $($Result.confidence)/100, nao representa probabilidade de lucro."
  $levelsFallback = if ($Result.price_axis_readable) {
    "Eixo de precos legivel, mas a leitura nao registrou regioes de reacao com valor confiavel."
  }
  else {
    "A escala de precos nao esta legivel; niveis numericos nao sao apresentados."
  }
  $indicatorsFallback = if ($indicatorNotes.Count -gt 0) {
    "Indicadores e volume registrados sem leitura conclusiva."
  }
  else {
    "Sem paineis de indicadores ou de volume na captura."
  }
  $comparison = ([string]$Result.directional_assessment.selected_reason).Trim()
  $scenario = "Evidencias favoraveis: $evidenceFor Evidencias contrarias: $evidenceAgainst Confirmacao: $confirmation Invalidacao: $invalidation"
  if ($comparison) { $scenario += " Comparacao BUY/SELL: $comparison" }
  return @(
    "Leitura geral:`n$($identity)$($readingBody)$readingTail"
    "price action:`n$(Join-AnalysisItems -Items $priceAction -Fallback 'Nao ha observacoes de Price Action suficientes para detalhar.')"
    "niveis e zonas:`n$(Join-AnalysisItems -Items $levels -Fallback $levelsFallback)"
    "Indicadores e Volumes:`n$(Join-AnalysisItems -Items $indicatorNotes -Fallback $indicatorsFallback)"
    "Cenario e invalidacao:`n$scenario"
    "Limitacoes:`n$(Join-AnalysisItems -Items $limitations -Fallback $risks)"
  ) -join "`n`n"
}

function ConvertTo-ValidatedAnalysisResult {
  param(
    [Parameter(Mandatory = $true)]$Result,
    [AllowNull()]$AxisMin,
    [AllowNull()]$AxisMax
  )

  $expectedProperties = $script:ContractFields
  if ($null -eq $Result -or $Result -is [array] -or
    $Result -isnot [System.Management.Automation.PSCustomObject]) {
    throw "A resposta da IA nao e um objeto JSON."
  }
  if (-not (Test-HasExactProperties -Object $Result -ExpectedProperties $expectedProperties)) {
    throw "A resposta da IA contem campos ausentes ou extras."
  }

  if ($Result.image_class -notin @("A", "B", "C", "D") -or
    $Result.direction -notin @("BUY", "SELL", "NEUTRAL") -or
    $Result.last_candle_status -notin @("closed", "possibly_open", "unknown") -or
    $Result.price_axis_readable -isnot [bool] -or
    -not (Test-AnalysisNumber $Result.price_axis_min) -or
    -not (Test-AnalysisNumber $Result.price_axis_max) -or
    ($null -ne $Result.chart_type -and $Result.chart_type -isnot [string]) -or
    ($null -ne $Result.asset_visible -and $Result.asset_visible -isnot [string]) -or
    ($null -ne $Result.timeframe_visible -and $Result.timeframe_visible -isnot [string])) {
    throw "A resposta contem valores incompativeis com o contrato."
  }
  foreach ($numericField in @("visual_quality", "analysis_coverage", "confidence")) {
    if ($Result.$numericField -isnot [int] -and $Result.$numericField -isnot [long]) {
      throw "O campo $numericField deve ser um inteiro."
    }
    if ($Result.$numericField -lt 0 -or $Result.$numericField -gt 100) {
      throw "O campo $numericField deve estar entre 0 e 100."
    }
  }
  if ($Result.trend -isnot [System.Management.Automation.PSCustomObject] -or
    -not (Test-HasExactProperties -Object $Result.trend -ExpectedProperties @("main", "micro", "structure", "explanation")) -or
    $Result.trend.main -notin @("alta", "baixa", "lateralização", "indefinida") -or
    $Result.trend.micro -notin @("alta", "baixa", "lateralização", "indefinida") -or
    -not (Test-StringArray $Result.trend.structure) -or
    $Result.trend.explanation -isnot [string] -or
    $Result.price_action -isnot [System.Management.Automation.PSCustomObject] -or
    -not (Test-HasExactProperties -Object $Result.price_action -ExpectedProperties @("observations", "interpretations", "conditions")) -or
    -not (Test-StringArray $Result.price_action.observations) -or
    -not (Test-StringArray $Result.price_action.interpretations) -or
    -not (Test-StringArray $Result.price_action.conditions) -or
    -not (Test-StringArray $Result.evidence_for) -or
    -not (Test-StringArray $Result.evidence_against) -or
    -not (Test-StringArray $Result.conflict_notes) -or
    -not (Test-StringArray $Result.risk) -or
    $Result.summary -isnot [string] -or
    [string]::IsNullOrWhiteSpace($Result.summary)) {
    throw "A resposta contem estruturas ou textos invalidos."
  }
  # Cada regra da avaliacao direcional falha com mensagem propria: uma
  # mensagem unica para doze regras nao dizia qual campo o modelo quebrou.
  $assessment = $Result.directional_assessment
  $assessmentFields = @(
    "buy_score", "sell_score", "buy_status", "buy_evidence",
    "sell_status", "sell_evidence", "selected_reason"
  )
  if ($assessment -isnot [System.Management.Automation.PSCustomObject]) {
    throw "A resposta contem uma avaliacao direcional invalida: directional_assessment nao e um objeto."
  }
  $assessmentNames = @($assessment.PSObject.Properties | ForEach-Object { $_.Name })
  $missingFields = @($assessmentFields | Where-Object { $assessmentNames -cnotcontains $_ })
  $extraFields = @($assessmentNames | Where-Object { $assessmentFields -cnotcontains $_ })
  if ($missingFields.Count -gt 0 -or $extraFields.Count -gt 0) {
    $parts = @()
    if ($missingFields.Count -gt 0) { $parts += "campos ausentes: $($missingFields -join ', ')" }
    if ($extraFields.Count -gt 0) { $parts += "campos extras: $($extraFields -join ', ')" }
    throw "A resposta contem uma avaliacao direcional invalida: $($parts -join '; ')."
  }
  # Reparo deterministico dos scores: a analise ja foi paga e um valor decimal
  # (69,5) ou fora da faixa nao muda a leitura visual. Rejeitar aqui custava ao
  # usuario uma nova chamada de API, entao o valor e arredondado e limitado a
  # 0..100. Somente um tipo realmente impossivel de ler continua sendo erro.
  foreach ($scoreField in @("buy_score", "sell_score")) {
    $scoreValue = $assessment.$scoreField
    $parsedScore = 0.0
    $scoreIsNumeric = $scoreValue -is [double] -or $scoreValue -is [single] -or
      $scoreValue -is [decimal] -or $scoreValue -is [int16] -or $scoreValue -is [byte] -or
      $scoreValue -is [int] -or $scoreValue -is [long] -or $scoreValue -is [string]
    if (-not $scoreIsNumeric -or -not [double]::TryParse(
        [string]$scoreValue,
        [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$parsedScore)) {
      $scoreType = if ($null -eq $scoreValue) { "nulo" } else { $scoreValue.GetType().Name }
      throw "A resposta contem uma avaliacao direcional invalida: $scoreField deve ser um numero (recebido $scoreType)."
    }
    $repairedScore = [int][Math]::Round($parsedScore, [System.MidpointRounding]::AwayFromZero)
    if ($repairedScore -lt 0) { $repairedScore = 0 }
    if ($repairedScore -gt 100) { $repairedScore = 100 }
    $assessment.$scoreField = $repairedScore
  }
  foreach ($statusField in @("buy_status", "sell_status")) {
    if ($assessment.$statusField -notin @("supported", "weak", "contradicted", "unavailable")) {
      throw "A resposta contem uma avaliacao direcional invalida: $statusField deve ser supported, weak, contradicted ou unavailable (recebido '$($assessment.$statusField)')."
    }
  }
  foreach ($evidenceField in @("buy_evidence", "sell_evidence")) {
    if (-not (Test-StringArray $assessment.$evidenceField)) {
      throw "A resposta contem uma avaliacao direcional invalida: $evidenceField deve ser uma lista de textos."
    }
  }
  if ($assessment.selected_reason -isnot [string] -or
    [string]::IsNullOrWhiteSpace($assessment.selected_reason)) {
    throw "A resposta contem uma avaliacao direcional invalida: selected_reason deve ser um texto nao vazio."
  }
  # Status 'supported' sem o piso de 70 e rebaixado para 'weak' (a mesma correcao
  # que o prompt manda o modelo fazer) em vez de derrubar a analise inteira. O
  # rebaixamento e conservador: a direcao correspondente perde a trava de BUY/SELL
  # e cai para NEUTRAL/WAIT mais adiante, nunca o contrario.
  foreach ($side in @("buy", "sell")) {
    $statusField = "$($side)_status"
    $scoreField = "$($side)_score"
    if ($assessment.$statusField -eq "supported" -and $assessment.$scoreField -lt 70) {
      $assessment.$statusField = "weak"
    }
  }
  if ($Result.volume -isnot [System.Management.Automation.PSCustomObject] -or
    -not (Test-HasExactProperties -Object $Result.volume -ExpectedProperties @("visible", "observations", "interpretation")) -or
    $Result.volume.visible -isnot [bool] -or
    -not (Test-StringArray $Result.volume.observations) -or
    $Result.volume.interpretation -isnot [string] -or
    $Result.levels -isnot [array] -or $Result.patterns -isnot [array] -or
    $Result.indicators -isnot [array]) {
    throw "A resposta contem listas ou campos de volume invalidos."
  }
  if ($Result.signal_timing -isnot [System.Management.Automation.PSCustomObject] -or
    -not (Test-HasExactProperties -Object $Result.signal_timing -ExpectedProperties @(
      "action", "signal_candle", "entry_timing", "exit_plan", "holding_horizon",
      "confirmation_required", "invalidation"
    )) -or
    $Result.signal_timing.action -notin @("BUY", "SELL", "WAIT") -or
    $Result.signal_timing.signal_candle -notin @("closed", "possibly_open", "unknown") -or
    $Result.signal_timing.entry_timing -isnot [string] -or
    $Result.signal_timing.exit_plan -isnot [string] -or
    $Result.signal_timing.holding_horizon -isnot [string] -or
    -not (Test-StringArray $Result.signal_timing.confirmation_required) -or
    -not (Test-StringArray $Result.signal_timing.invalidation)) {
    throw "A resposta contem um plano temporal invalido."
  }

  foreach ($level in $Result.levels) {
    if ($level -isnot [System.Management.Automation.PSCustomObject] -or
      -not (Test-HasExactProperties -Object $level -ExpectedProperties @("type", "value", "region", "reason")) -or
      $level.type -notin @("support", "resistance", "breakout", "retest", "other") -or
      ($null -ne $level.value -and $level.value -isnot [byte] -and
        $level.value -isnot [int16] -and $level.value -isnot [int] -and
        $level.value -isnot [long] -and $level.value -isnot [single] -and
        $level.value -isnot [double] -and $level.value -isnot [decimal]) -or
      $level.region -isnot [string] -or $level.reason -isnot [string]) {
      throw "A resposta contem um nivel incompativel com o contrato."
    }
  }
  foreach ($pattern in $Result.patterns) {
    if ($pattern -isnot [System.Management.Automation.PSCustomObject] -or
      -not (Test-HasExactProperties -Object $pattern -ExpectedProperties @("name", "status", "evidence", "confirmation", "invalidation")) -or
      $pattern.status -notin @("incomplete", "visually_confirmed", "invalidated") -or
      $pattern.name -isnot [string] -or
      -not (Test-StringArray $pattern.evidence) -or
      $pattern.confirmation -isnot [string] -or $pattern.invalidation -isnot [string]) {
      throw "A resposta contem um padrao incompativel com o contrato."
    }
  }
  foreach ($indicator in $Result.indicators) {
    if ($indicator -isnot [System.Management.Automation.PSCustomObject] -or
      -not (Test-HasExactProperties -Object $indicator -ExpectedProperties @("name", "visible", "observations", "interpretation", "conflict")) -or
      $indicator.name -isnot [string] -or $indicator.visible -isnot [bool] -or
      -not (Test-StringArray $indicator.observations) -or
      $indicator.interpretation -isnot [string] -or $indicator.conflict -isnot [string]) {
      throw "A resposta contem um indicador incompativel com o contrato."
    }
  }

  foreach ($indicator in $Result.indicators) {
    if (-not $indicator.visible) {
      $indicator.observations = @()
      $indicator.interpretation = ""
      $indicator.conflict = ""
    }
  }

  # A mesma observacao nao pode contar duas vezes so por aparecer em campos
  # diferentes ou repetida no mesmo campo.
  # @() e obrigatorio: uma funcao PowerShell desenrola array de um item e o
  # campo viraria string no JSON, quebrando o contrato com o navegador.
  $Result.evidence_for = @(Remove-AnalysisDuplicates -Items $Result.evidence_for)
  $Result.evidence_against = @(Remove-AnalysisDuplicates -Items $Result.evidence_against)
  $Result.directional_assessment.buy_evidence =
    @(Remove-AnalysisDuplicates -Items $Result.directional_assessment.buy_evidence)
  $Result.directional_assessment.sell_evidence =
    @(Remove-AnalysisDuplicates -Items $Result.directional_assessment.sell_evidence)

  $coverage = [int]$Result.analysis_coverage
  $confidence = [int]$Result.confidence
  foreach ($visibleField in @("asset_visible", "timeframe_visible")) {
    if ([string]::IsNullOrWhiteSpace([string]$Result.$visibleField) -or
      [string]$Result.$visibleField -match "^(?i:unknown|nao identificado|nao identificavel)$") {
      $Result.$visibleField = $null
    }
  }
  $coverageCap = if ($coverage -lt 40) { 45 }
    elseif ($coverage -lt 60) { 60 }
    elseif ($coverage -lt 80) { 80 }
    else { 95 }
  $confidence = [int]([Math]::Floor($confidence / 5.0) * 5)
  $confidence = [Math]::Min($confidence, $coverageCap)
  if ($coverage -eq 0) { $confidence = 0 }

  # Trava de eixo verificavel: quando o operador informa a faixa impressa no
  # eixo, ela substitui a leitura do modelo. Antes, a IA declarava o limite que
  # os proprios numeros precisavam respeitar; agora o limite vem do usuario.
  $userAxisInformed = $null -ne $AxisMin -or $null -ne $AxisMax
  if ($userAxisInformed) {
    if ($null -eq $AxisMin -or $null -eq $AxisMax -or
      -not (Test-AnalysisNumber $AxisMin) -or -not (Test-AnalysisNumber $AxisMax)) {
      throw "A escala informada precisa ter preco minimo e maximo."
    }
    $userAxisMin = [double]$AxisMin
    $userAxisMax = [double]$AxisMax
    if ($userAxisMin -ge $userAxisMax) {
      throw "A escala informada precisa ter o minimo abaixo do maximo."
    }
    $userAxisSpan = $userAxisMax - $userAxisMin
    if ($Result.price_axis_readable -and $null -ne $Result.price_axis_min -and
      $null -ne $Result.price_axis_max) {
      $declaredMin = [double]$Result.price_axis_min
      $declaredMax = [double]$Result.price_axis_max
      $axisTolerance = [Math]::Abs($userAxisSpan) * 0.02
      if ([Math]::Abs($declaredMin - $userAxisMin) -gt $axisTolerance -or
        [Math]::Abs($declaredMax - $userAxisMax) -gt $axisTolerance) {
        $Result.risk = @($Result.risk) + (
          "Escala declarada pela IA ({0} a {1}) diverge da escala informada ({2} a {3}); a faixa informada foi usada como referencia." -f
          $declaredMin, $declaredMax, $userAxisMin, $userAxisMax
        )
      }
    }
    else {
      $Result.risk = @($Result.risk) + (
        "A IA nao declarou uma escala legivel; a faixa informada ({0} a {1}) foi usada como referencia." -f
        $userAxisMin, $userAxisMax
      )
    }
    $Result.price_axis_readable = $true
    $Result.price_axis_min = $userAxisMin
    $Result.price_axis_max = $userAxisMax
  }

  if (-not $Result.price_axis_readable) { $Result.levels = @() }

  # Trava anti-invencao: a faixa da escala e declarada pelo modelo e todo nivel
  # numerico precisa caber nela. Valor fora da faixa visivel e descartado.
  if (-not $Result.price_axis_readable) {
    $Result.price_axis_min = $null
    $Result.price_axis_max = $null
  }
  elseif ($null -eq $Result.price_axis_min -or $null -eq $Result.price_axis_max -or
    [double]$Result.price_axis_min -ge [double]$Result.price_axis_max) {
    $Result.price_axis_readable = $false
    $Result.price_axis_min = $null
    $Result.price_axis_max = $null
    $Result.levels = @()
  }
  else {
    $axisMin = [double]$Result.price_axis_min
    $axisMax = [double]$Result.price_axis_max
    $keptLevels = @()
    $discardedLevels = @()
    foreach ($level in $Result.levels) {
      if ($null -eq $level.value) {
        $keptLevels += $level
        continue
      }
      $levelValue = [double]$level.value
      if ($levelValue -lt $axisMin -or $levelValue -gt $axisMax) {
        $discardedLevels += ("{0} ({1})" -f $level.region, $levelValue)
      }
      else {
        $keptLevels += $level
      }
    }
    $Result.levels = @($keptLevels)
    if ($discardedLevels.Count -gt 0) {
      $Result.risk = @($Result.risk) + (
        "Nivel descartado por estar fora da escala visivel ({0} a {1}): {2}." -f
        $axisMin, $axisMax, ($discardedLevels -join "; ")
      )
    }
  }

  # Trava de evidencia direcional: em A/B legivel, todo lado avaliado precisa de
  # fato observado. Lista vazia com status supported/weak/contradicted e rejeitada.
  if ($Result.image_class -in @("A", "B")) {
    foreach ($directionalSide in @(
      @{
        Name = "BUY"
        Status = $Result.directional_assessment.buy_status
        Evidence = $Result.directional_assessment.buy_evidence
      },
      @{
        Name = "SELL"
        Status = $Result.directional_assessment.sell_status
        Evidence = $Result.directional_assessment.sell_evidence
      }
    )) {
      $usableEvidence = @($directionalSide.Evidence |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      # Sem evidencia listada o servidor nao descarta a analise: registra a
      # ausencia no proprio campo e nas limitacoes, para o painel nao exibir um
      # lado "avaliado" sem justificativa visivel.
      if ($directionalSide.Status -ne "unavailable" -and $usableEvidence.Count -eq 0) {
        $absenceNote = "Nenhuma evidencia visual especifica foi registrada para o lado $($directionalSide.Name)."
        if ($directionalSide.Name -eq "BUY") {
          $Result.directional_assessment.buy_evidence = @($absenceNote)
        }
        else {
          $Result.directional_assessment.sell_evidence = @($absenceNote)
        }
        $Result.risk = @($Result.risk) + @(
          "O lado $($directionalSide.Name) foi classificado como $($directionalSide.Status) sem evidencia visual registrada; trate a leitura desse lado como incompleta."
        )
      }
    }

    # Quando risk vem vazio, derive apenas limitacoes objetivas de campos
    # visuais ausentes; sem uma limitacao observavel, mantenha a lista vazia.
    $usableRisks = @($Result.risk | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($usableRisks.Count -eq 0) {
      $derivedLimitations = @()
      if (-not $Result.price_axis_readable) {
        $derivedLimitations += "A escala de precos nao esta legivel; niveis numericos nao sao apresentados."
      }
      if ([string]::IsNullOrWhiteSpace([string]$Result.asset_visible)) {
        $derivedLimitations += "O ativo nao pode ser identificado visualmente na captura."
      }
      if ([string]::IsNullOrWhiteSpace([string]$Result.timeframe_visible)) {
        $derivedLimitations += "O timeframe nao pode ser identificado visualmente na captura."
      }
      if ($Result.last_candle_status -ne "closed") {
        $derivedLimitations += "O fechamento da ultima vela nao foi confirmado na imagem."
      }
      if (-not $Result.volume.visible) {
        $derivedLimitations += "A captura nao mostra volume; a participacao no movimento nao pode ser medida."
      }
      if (@($Result.indicators | Where-Object { $_.visible }).Count -eq 0) {
        $derivedLimitations += "Nenhum painel de indicador esta visivel; momentum e exaustao nao foram avaliados."
      }
      $Result.risk = @($derivedLimitations | Select-Object -First 3)
    }
  }

  $directionalOverrideReason = $null
  if ($Result.image_class -eq "B") {
    $Result.direction = "NEUTRAL"
    $Result.signal_timing.action = "WAIT"
    $confidence = [Math]::Min($confidence, 60)
    $directionalOverrideReason = "Imagem classe B exige NEUTRAL/WAIT e limita a confiança."
  }
  if ($Result.conflict_notes.Count -gt 0) {
    $Result.direction = "NEUTRAL"
    $Result.signal_timing.action = "WAIT"
    $directionalOverrideReason = "Há conflito relevante não resolvido; nenhum lado pode prevalecer."
  }
  # Trava de lateralizacao: no meio do range nenhum lado tem rejeicao confirmada
  # em um extremo, entao nenhum vies direcional se sustenta. A regra existe no
  # prompt; esta trava garante o mesmo resultado quando o modelo a ignora.
  if ($Result.direction -ne "NEUTRAL" -and
    $Result.trend.main -eq "lateralização" -and
    $Result.directional_assessment.buy_score -lt 70 -and
    $Result.directional_assessment.sell_score -lt 70) {
    $Result.direction = "NEUTRAL"
    $Result.signal_timing.action = "WAIT"
    $directionalOverrideReason = "Lateralização sem score suficiente em nenhum dos lados; sinal no meio do range não é válido."
  }
  # Vies direcional e execucao sao independentes: falta de confirmacao temporal
  # rebaixa apenas a acao para WAIT. A direcao lida continua registrada.
  $executionConfirmed = $Result.signal_timing.signal_candle -eq "closed" -and
    $Result.last_candle_status -eq "closed" -and
    $Result.signal_timing.confirmation_required.Count -eq 0
  if ($Result.direction -eq "NEUTRAL") {
    $Result.signal_timing.action = "WAIT"
  }
  elseif ($Result.signal_timing.action -ne $Result.direction -or -not $executionConfirmed) {
    $Result.signal_timing.action = "WAIT"
  }
  if ($Result.direction -ne "NEUTRAL" -and
    $Result.directional_assessment.buy_score -ge 70 -and
    $Result.directional_assessment.sell_score -ge 70 -and
    [Math]::Abs($Result.directional_assessment.buy_score - $Result.directional_assessment.sell_score) -lt 10) {
    $Result.direction = "NEUTRAL"
    $Result.signal_timing.action = "WAIT"
    $directionalOverrideReason = "BUY e SELL são plausíveis, mas a diferença entre scores é inferior a 10 pontos."
  }
  if ($Result.direction -eq "BUY" -and
    ($Result.directional_assessment.buy_status -ne "supported" -or
      $Result.directional_assessment.buy_score -lt 70 -or
      ($Result.directional_assessment.buy_score - $Result.directional_assessment.sell_score) -lt 10 -or
      $Result.signal_timing.invalidation.Count -eq 0)) {
    $Result.direction = "NEUTRAL"
    $Result.signal_timing.action = "WAIT"
    $directionalOverrideReason = "BUY não atingiu score, margem, invalidação e status supported exigidos."
  }
  if ($Result.direction -eq "SELL" -and
    ($Result.directional_assessment.sell_status -ne "supported" -or
      $Result.directional_assessment.sell_score -lt 70 -or
      ($Result.directional_assessment.sell_score - $Result.directional_assessment.buy_score) -lt 10 -or
      $Result.signal_timing.invalidation.Count -eq 0)) {
    $Result.direction = "NEUTRAL"
    $Result.signal_timing.action = "WAIT"
    $directionalOverrideReason = "SELL não atingiu score, margem, invalidação e status supported exigidos."
  }
  # Coerencia da invalidacao: a condicao registrada precisa apontar contra a
  # hipotese escolhida. Uma invalidacao que descreve a propria hipotese suspende
  # o vies em vez de sustentar a decisao.
  if ($Result.direction -in @("BUY", "SELL")) {
    $hypothesis = $Result.direction
    $invalidationText = (@($Result.signal_timing.invalidation) -join " ").ToLowerInvariant()
    $invalidationPattern = if ($hypothesis -eq "BUY") {
      "abaixo|perda|perder|suporte|fundo|venda|vendedor"
    }
    else {
      "acima|perda|perder|resist|topo|compra|comprador"
    }
    if ($invalidationText -notmatch $invalidationPattern) {
      $Result.direction = "NEUTRAL"
      $Result.signal_timing.action = "WAIT"
      $directionalOverrideReason =
        "A invalidacao registrada nao contradiz a hipotese $hypothesis; o vies foi suspenso."
    }
  }

  if ($Result.image_class -in @("C", "D")) {
    $Result.direction = "NEUTRAL"
    $Result.trend.main = "indefinida"
    $Result.trend.micro = "indefinida"
    $Result.trend.structure = @()
    $Result.levels = @()
    $Result.patterns = @()
    $Result.indicators = @()
    $Result.evidence_for = @()
    $Result.evidence_against = @()
    $Result.price_action.observations = @()
    $Result.price_action.interpretations = @()
    $Result.price_action.conditions = @()
    $Result.volume.visible = $false
    $Result.volume.observations = @()
    $Result.volume.interpretation = ""
    $Result.asset_visible = $null
    $Result.timeframe_visible = $null
    $Result.signal_timing.action = "WAIT"
    $directionalOverrideReason = if ($Result.image_class -eq "C") {
      "Imagem insuficiente para sustentar uma hipótese direcional."
    }
    else {
      "Não foi identificado um gráfico financeiro; nenhuma hipótese direcional pode ser avaliada."
    }
    $Result.directional_assessment.buy_score = 0
    $Result.directional_assessment.sell_score = 0
    $Result.directional_assessment.buy_status = "unavailable"
    $Result.directional_assessment.sell_status = "unavailable"
    $Result.directional_assessment.buy_evidence = @()
    $Result.directional_assessment.sell_evidence = @()
    $Result.signal_timing.entry_timing = "Nao ha entrada; a imagem nao permite confirmar um cenario."
    $Result.signal_timing.exit_plan = "Nao aplicavel sem um sinal confirmado."
    $Result.signal_timing.holding_horizon = "Nao avaliavel nesta imagem."
    $confidence = 0
    if ($Result.image_class -eq "C") {
      $Result.summary = "Leitura geral:`nImagem ilegivel ou incompleta para uma leitura confiavel.`n`nprice action:`nCandles e sequencia nao podem ser avaliados com seguranca.`n`nniveis e zonas:`nNao identificaveis nesta captura.`n`nIndicadores e Volumes:`nNao avaliaveis.`n`nCenario e invalidacao:`nNao ha evidencias suficientes para formar um cenario.`n`nLimitacoes:`nEnvie uma captura mais nitida e completa."
      $Result.risk = @("Dados visuais insuficientes para analise tecnica.")
    }
    else {
      $Result.summary = "Leitura geral:`nNao foi possivel identificar um grafico financeiro nesta imagem.`n`nprice action:`nNao analisada.`n`nniveis e zonas:`nNao identificados.`n`nIndicadores e Volumes:`nNao avaliados.`n`nCenario e invalidacao:`nNenhum cenario pode ser estabelecido.`n`nLimitacoes:`nEnvie a captura de um grafico financeiro."
      $Result.risk = @("Imagem sem grafico financeiro identificavel.")
    }
  }
  if ($Result.direction -eq "NEUTRAL") {
    $Result.signal_timing.action = "WAIT"
    if ($directionalOverrideReason) {
      $existingReason = ([string]$Result.directional_assessment.selected_reason).Trim()
      if ([string]::IsNullOrWhiteSpace($existingReason)) {
        $Result.directional_assessment.selected_reason = $directionalOverrideReason
      }
      elseif ($existingReason -notmatch [regex]::Escape($directionalOverrideReason)) {
        $Result.directional_assessment.selected_reason =
          "$existingReason $directionalOverrideReason"
      }
    }
    if ($Result.signal_timing.signal_candle -ne "closed" -or
      $Result.last_candle_status -ne "closed" -or
      $Result.signal_timing.confirmation_required.Count -gt 0 -or
      $Result.conflict_notes.Count -gt 0 -or
      $Result.image_class -ne "A") {
      if ($Result.directional_assessment.buy_status -eq "supported") {
        $Result.directional_assessment.buy_status = "weak"
      }
      if ($Result.directional_assessment.sell_status -eq "supported") {
        $Result.directional_assessment.sell_status = "weak"
      }
    }
  }
  if ($Result.direction -eq "NEUTRAL" -or $Result.signal_timing.action -eq "WAIT") {
    $isDirectionalBias = $Result.direction -ne "NEUTRAL"
    foreach ($timingField in @("entry_timing", "exit_plan", "holding_horizon")) {
      if ([string]::IsNullOrWhiteSpace($Result.signal_timing.$timingField) -or
        $Result.signal_timing.$timingField -match "^(?i:none|unknown)$") {
        switch ($timingField) {
          "entry_timing" {
            $Result.signal_timing.$timingField = if ($isDirectionalBias) {
              "Vies definido; aguardar o fechamento da vela atual antes de considerar a entrada."
            }
            else {
              "Aguardar confirmacao antes de considerar uma entrada."
            }
          }
          "exit_plan" {
            $Result.signal_timing.$timingField = if ($isDirectionalBias) {
              "Saida planejada ao final da vela seguinte a confirmacao."
            }
            else {
              "Nao aplicavel enquanto nao houver sinal confirmado."
            }
          }
          "holding_horizon" {
            $Result.signal_timing.$timingField = "Condicional: uma vela apos um sinal valido."
          }
        }
      }
    }
  }
  $Result.confidence = $confidence
  if ($Result.image_class -in @("A", "B")) {
    $requiredSections = @(
      "Leitura geral:", "price action:", "niveis e zonas:",
      "Indicadores e Volumes:", "Cenario e invalidacao:", "Limitacoes:"
    )
    $normalizedSummary = $Result.summary.Normalize([System.Text.NormalizationForm]::FormD)
    $normalizedSummary = [regex]::Replace($normalizedSummary, "\p{Mn}", "")
    $sectionPositions = @($requiredSections | ForEach-Object {
      $normalizedSummary.IndexOf($_, [System.StringComparison]::OrdinalIgnoreCase)
    })
    $sectionsAreValid = @($sectionPositions | Where-Object { $_ -lt 0 }).Count -eq 0
    if ($sectionsAreValid) {
      for ($index = 1; $index -lt $sectionPositions.Count; $index++) {
        if ($sectionPositions[$index] -le $sectionPositions[$index - 1]) {
          $sectionsAreValid = $false
          break
        }
      }
    }
    if (-not $sectionsAreValid) {
      $Result.summary = New-ValidatedAnalysisSummary -Result $Result -ModelSummary $Result.summary
    }
  }
  return $Result
}

function Get-AnalysisFailureMessage {
  param(
    [int]$StatusCode,
    [string]$Diagnostic,
    [bool]$ResponseReceived,
    [string]$FinishReason
  )
  if ($StatusCode -eq 401) {
    return "A chave da API OpenAI foi recusada. Confira a chave e reinicie o servidor."
  }
  if ($StatusCode -eq 403) {
    return "A OpenAI negou o acesso. Confira se a chave esta ativa e se sua conta tem acesso a API."
  }
  if ($StatusCode -eq 429) {
    return "A API OpenAI atingiu o limite de uso ou nao tem creditos disponiveis. Confira faturamento e limites da conta."
  }
  if ($StatusCode -eq 404) {
    return "O modelo configurado nao foi encontrado na OpenAI. Confira OPENAI_MODEL e escolha um modelo compativel com imagens."
  }
  if ($StatusCode -eq 400) {
    return "A OpenAI recusou a solicitacao. Confira o modelo e o formato da imagem. Detalhe: $Diagnostic"
  }
  if ($StatusCode -eq 413) {
    return "A imagem e grande demais para o limite da API. Envie um print menor."
  }
  if ($FinishReason -eq "length") {
    return "A analise ficou incompleta porque a resposta atingiu o limite de tamanho. Tente novamente."
  }
  if ($ResponseReceived) {
    if (-not [string]::IsNullOrWhiteSpace($Diagnostic)) {
      return "A OpenAI respondeu, mas a analise nao passou pela validacao. Detalhe: $Diagnostic"
    }
    return "A OpenAI respondeu, mas a analise veio em formato invalido. Tente novamente ou confira o modelo visual configurado."
  }
  if ($Diagnostic -match "(?i)timeout|timed out|tarefa foi cancelada|operationcanceled") {
    return "A OpenAI demorou demais para responder. Tente novamente ou confira sua conexao."
  }
  if ($StatusCode -ge 500) {
    return "A API OpenAI esta temporariamente indisponivel (HTTP $StatusCode). Aguarde e tente novamente."
  }
  return "Nao foi possivel conectar a OpenAI. Confira a internet, a conexao com a API e tente novamente."
}

function Remove-ModelReasoningBlock {
  # A resposta do modelo entra como JSON puro. Se vier um bloco de raciocinio
  # antes dele (ou cercas de codigo), o conteudo e descartado aqui para nao
  # quebrar o parse nem chegar ao usuario.
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
  $cleaned = [regex]::Replace($Text, '(?is)<thinking>.*?</thinking>', '')
  $cleaned = $cleaned.Trim()
  $fenced = [regex]::Match($cleaned, '(?s)^```(?:json)?\s*(?<body>.*?)\s*```$')
  if ($fenced.Success) {
    $cleaned = $fenced.Groups['body'].Value.Trim()
  }
  return $cleaned
}

function Get-AnalysisCacheKey {
  # Chave estavel para reaproveitar uma analise identica: mesma imagem, mesmo
  # contexto, mesmo modelo e mesma versao do contrato. Serve para nao gastar uma
  # nova chamada de API quando o usuario reenvia a mesma captura.
  param(
    [Parameter(Mandatory = $true)][string]$ImageData,
    [string]$Market = "",
    [string]$Asset = "",
    [string]$Timeframe = "",
    [AllowNull()]$AxisMin,
    [AllowNull()]$AxisMax,
    [string]$Model = "",
    [string]$ContractVersion = "",
    # Marca o pre-processamento aplicado (ex.: contrast-v1). Sem isso a mesma
    # imagem enviada com e sem realce cairia na mesma entrada de cache.
    [string]$Preprocess = ""
  )
  if ([string]::IsNullOrWhiteSpace($ContractVersion)) {
    $ContractVersion = $script:ContractVersion
  }
  $culture = [System.Globalization.CultureInfo]::InvariantCulture
  $axisMinText = if ($null -eq $AxisMin) { "" } else { ([double]$AxisMin).ToString("0.#####", $culture) }
  $axisMaxText = if ($null -eq $AxisMax) { "" } else { ([double]$AxisMax).ToString("0.#####", $culture) }
  $material = @(
    $ContractVersion, $Model, $Market, $Asset, $Timeframe, $axisMinText, $axisMaxText,
    $Preprocess, $ImageData
  ) -join ([string][char]31)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hashBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($material))
  }
  finally {
    $sha.Dispose()
  }
  return ([System.BitConverter]::ToString($hashBytes) -replace "-", "").ToLowerInvariant()
}

function Test-ImageSignature {
  # O MIME declarado pelo cliente e a base64 sintatica nao provam que os bytes
  # sao uma imagem. A assinatura real do arquivo (magic bytes) e conferida aqui.
  param(
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes,
    [Parameter(Mandatory = $true)][string]$MimeType
  )
  if ($null -eq $Bytes -or $Bytes.Length -lt 3) { return $false }
  switch ($MimeType) {
    "image/png" {
      if ($Bytes.Length -lt 8) { return $false }
      return ($Bytes[0] -eq 0x89 -and $Bytes[1] -eq 0x50 -and $Bytes[2] -eq 0x4E -and $Bytes[3] -eq 0x47 -and $Bytes[4] -eq 0x0D -and $Bytes[5] -eq 0x0A -and $Bytes[6] -eq 0x1A -and $Bytes[7] -eq 0x0A)
    }
    "image/jpeg" {
      return ($Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xD8 -and $Bytes[2] -eq 0xFF)
    }
    "image/webp" {
      if ($Bytes.Length -lt 12) { return $false }
      return ([char]$Bytes[0] -eq 'R' -and [char]$Bytes[1] -eq 'I' -and [char]$Bytes[2] -eq 'F' -and [char]$Bytes[3] -eq 'F' -and [char]$Bytes[8] -eq 'W' -and [char]$Bytes[9] -eq 'E' -and [char]$Bytes[10] -eq 'B' -and [char]$Bytes[11] -eq 'P')
    }
  }
  return $false
}

function Get-ImageContrastProfile {
  # Amostra a luminancia em grade para estimar o contraste real da captura. Nao
  # percorre todos os pixels: em print de 1600 px a grade de ~160x160 ja separa
  # grafico de baixo contraste de grafico normal com custo desprezivel.
  param([Parameter(Mandatory = $true)][System.Drawing.Bitmap]$Bitmap)
  $width = $Bitmap.Width
  $height = $Bitmap.Height
  if ($width -lt 32 -or $height -lt 32) {
    return [pscustomobject]@{ Mean = 0.0; StdDev = 0.0; Samples = 0 }
  }
  $step = [int][Math]::Max(1, [Math]::Floor([Math]::Min($width, $height) / 160))
  $sum = 0.0
  $sumSquares = 0.0
  $count = 0
  for ($y = 0; $y -lt $height; $y += $step) {
    for ($x = 0; $x -lt $width; $x += $step) {
      $pixel = $Bitmap.GetPixel($x, $y)
      $luminance = (0.299 * $pixel.R) + (0.587 * $pixel.G) + (0.114 * $pixel.B)
      $sum += $luminance
      $sumSquares += $luminance * $luminance
      $count++
    }
  }
  if ($count -eq 0) {
    return [pscustomobject]@{ Mean = 0.0; StdDev = 0.0; Samples = 0 }
  }
  $mean = $sum / $count
  $variance = [Math]::Max(0.0, ($sumSquares / $count) - ($mean * $mean))
  return [pscustomobject]@{
    Mean    = $mean
    StdDev  = [Math]::Sqrt($variance)
    Samples = $count
  }
}

function ConvertTo-EnhancedImageBytes {
  # Pre-processamento adaptativo: so mexe na imagem quando o contraste medido e
  # baixo (grafico apagado, print com overlay, fundo lavado). Devolve $null
  # quando o original ja tem contraste suficiente, quando o formato nao e
  # suportado (WEBP nao decodifica no GDI+) ou quando o GDI+ nao esta presente.
  # O servidor usa o retorno para montar a chave de cache, entao a mesma
  # imagem sempre passa pelo mesmo caminho.
  param(
    [Parameter(Mandatory = $true)][byte[]]$Bytes,
    [Parameter(Mandatory = $true)][string]$MimeType,
    [double]$ContrastFactor = 1.25,
    [double]$MinStdDev = 38.0
  )
  if (-not $script:DrawingAvailable) { return $null }
  if ($MimeType -notin @("image/png", "image/jpeg")) { return $null }
  if ($null -eq $Bytes -or $Bytes.Length -lt 8) { return $null }

  $stream = $null
  $bitmap = $null
  $output = $null
  $graphics = $null
  $attributes = $null
  $outputStream = $null
  try {
    $stream = [System.IO.MemoryStream]::new($Bytes)
    $bitmap = [System.Drawing.Bitmap]::new($stream)
    if ($bitmap.Width -lt 32 -or $bitmap.Height -lt 32) { return $null }

    $profile = Get-ImageContrastProfile -Bitmap $bitmap
    if ($profile.StdDev -ge $MinStdDev) { return $null }

    $factor = [single]$ContrastFactor
    $offset = [single](128.0 * (1.0 - $ContrastFactor))
    $matrix = [System.Drawing.Imaging.ColorMatrix]::new()
    $matrix.Matrix00 = $factor
    $matrix.Matrix11 = $factor
    $matrix.Matrix22 = $factor
    $matrix.Matrix33 = 1.0
    $matrix.Matrix40 = $offset
    $matrix.Matrix41 = $offset
    $matrix.Matrix42 = $offset
    $attributes = [System.Drawing.Imaging.ImageAttributes]::new()
    $attributes.SetColorMatrix($matrix)

    $output = [System.Drawing.Bitmap]::new(
      $bitmap.Width,
      $bitmap.Height,
      [System.Drawing.Imaging.PixelFormat]::Format24bppRgb
    )
    $graphics = [System.Drawing.Graphics]::FromImage($output)
    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $destination = [System.Drawing.Rectangle]::new(0, 0, $bitmap.Width, $bitmap.Height)
    $graphics.DrawImage(
      $bitmap, $destination, 0, 0, $bitmap.Width, $bitmap.Height,
      [System.Drawing.GraphicsUnit]::Pixel, $attributes
    )

    $outputStream = [System.IO.MemoryStream]::new()
    if ($MimeType -eq "image/png") {
      $output.Save($outputStream, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    else {
      $jpegCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
        Where-Object { $_.MimeType -eq "image/jpeg" } | Select-Object -First 1
      if ($null -eq $jpegCodec) { return $null }
      $encoderParameters = [System.Drawing.Imaging.EncoderParameters]::new(1)
      $encoderParameters.Param[0] = [System.Drawing.Imaging.EncoderParameter]::new(
        [System.Drawing.Imaging.Encoder]::Quality, [long]90
      )
      $output.Save($outputStream, $jpegCodec, $encoderParameters)
    }
    return $outputStream.ToArray()
  }
  catch {
    # Imagem que o GDI+ nao consegue reprocessar segue para a API sem alteracao.
    return $null
  }
  finally {
    if ($outputStream) { $outputStream.Dispose() }
    if ($graphics)     { $graphics.Dispose() }
    if ($attributes)   { $attributes.Dispose() }
    if ($output)       { $output.Dispose() }
    if ($bitmap)       { $bitmap.Dispose() }
    if ($stream)       { $stream.Dispose() }
  }
}

function Get-ImageClassRank {
  # Ordem de legibilidade das classes do contrato. O servidor so aceita a
  # releitura de uma imagem quando ela melhora a classe; ranks iguais ou piores
  # mantem a primeira leitura.
  param([AllowEmptyString()][string]$ImageClass)
  switch ($ImageClass) {
    "A" { return 3 }
    "B" { return 2 }
    "C" { return 1 }
    "D" { return 0 }
  }
  return -1
}

function Get-ImageUniformBorder {
  # Mede o quanto das bordas da captura e apenas preenchimento uniforme (fundo
  # liso de screenshot, faixa vazia, moldura). So recorta o que e comprovadamente
  # uniforme, com limite de 12% por lado: conteudo do grafico nunca e cortado.
  param(
    [Parameter(Mandatory = $true)][System.Drawing.Bitmap]$Bitmap,
    [double]$Tolerance = 10.0,
    [double]$MaxRatio = 0.12
  )
  $width = $Bitmap.Width
  $height = $Bitmap.Height
  $empty = [pscustomobject]@{ Left = 0; Top = 0; Right = 0; Bottom = 0; Uniform = $false }
  if ($width -lt 32 -or $height -lt 32) { return $empty }

  # Cor de referencia: media dos quatro cantos (3x3 cada).
  $red = 0.0; $green = 0.0; $blue = 0.0; $samples = 0
  foreach ($cornerX in @(1, ($width - 2))) {
    foreach ($cornerY in @(1, ($height - 2))) {
      for ($dx = -1; $dx -le 1; $dx++) {
        for ($dy = -1; $dy -le 1; $dy++) {
          $pixel = $Bitmap.GetPixel($cornerX + $dx, $cornerY + $dy)
          $red += $pixel.R; $green += $pixel.G; $blue += $pixel.B; $samples++
        }
      }
    }
  }
  if ($samples -eq 0) { return $empty }
  $red = $red / $samples; $green = $green / $samples; $blue = $blue / $samples

  $step = [int][Math]::Max(1, [Math]::Floor([Math]::Min($width, $height) / 120))
  $maxVertical = [int][Math]::Floor($height * $MaxRatio)
  $maxHorizontal = [int][Math]::Floor($width * $MaxRatio)

  $rowUniform = {
    param([int]$y)
    $total = 0.0; $count = 0
    for ($x = 0; $x -lt $width; $x += $step) {
      $pixel = $Bitmap.GetPixel($x, $y)
      $total += ([Math]::Abs($pixel.R - $red) + [Math]::Abs($pixel.G - $green) +
        [Math]::Abs($pixel.B - $blue)) / 3.0
      $count++
    }
    if ($count -eq 0) { return $false }
    return ($total / $count) -le $Tolerance
  }
  $columnUniform = {
    param([int]$x)
    $total = 0.0; $count = 0
    for ($y = 0; $y -lt $height; $y += $step) {
      $pixel = $Bitmap.GetPixel($x, $y)
      $total += ([Math]::Abs($pixel.R - $red) + [Math]::Abs($pixel.G - $green) +
        [Math]::Abs($pixel.B - $blue)) / 3.0
      $count++
    }
    if ($count -eq 0) { return $false }
    return ($total / $count) -le $Tolerance
  }

  $top = 0
  while ($top -lt $maxVertical -and (& $rowUniform $top)) { $top++ }
  $bottom = 0
  while ($bottom -lt $maxVertical -and (& $rowUniform ($height - 1 - $bottom))) { $bottom++ }
  $left = 0
  while ($left -lt $maxHorizontal -and (& $columnUniform $left)) { $left++ }
  $right = 0
  while ($right -lt $maxHorizontal -and (& $columnUniform ($width - 1 - $right))) { $right++ }

  # Guarda de seguranca: nunca sobrar menos de 60% da imagem original.
  if (($width - $left - $right) -lt [Math]::Floor($width * 0.6)) { $left = 0; $right = 0 }
  if (($height - $top - $bottom) -lt [Math]::Floor($height * 0.6)) { $top = 0; $bottom = 0 }
  if (($width - $left - $right) -lt 32 -or ($height - $top - $bottom) -lt 32) {
    $left = 0; $top = 0; $right = 0; $bottom = 0
  }

  return [pscustomobject]@{
    Left = $left; Top = $top; Right = $right; Bottom = $bottom
    Uniform = (($left + $top + $right + $bottom) -gt 0)
  }
}

function ConvertTo-PreparedImageBytes {
  # Pre-processamento mais inteligente que o realce puro: recorta bordas vazias
  # (sem tocar no grafico), mede o contraste do miolo e so realca quando ele e
  # baixo. Devolve Bytes + Tag para o servidor registrar no log e na chave de
  # cache. Retorna $null quando nada seria ganho (imagem ja pronta).
  param(
    [Parameter(Mandatory = $true)][byte[]]$Bytes,
    [Parameter(Mandatory = $true)][string]$MimeType,
    [double]$ContrastFactor = 1.25,
    [double]$MinStdDev = 38.0,
    [double]$MaxTrimRatio = 0.12
  )
  if (-not $script:DrawingAvailable) { return $null }
  if ($MimeType -notin @("image/png", "image/jpeg")) { return $null }
  if ($null -eq $Bytes -or $Bytes.Length -lt 8) { return $null }

  $stream = $null
  $bitmap = $null
  $prepared = $null
  $output = $null
  $graphics = $null
  $attributes = $null
  $outputStream = $null
  try {
    $stream = [System.IO.MemoryStream]::new($Bytes)
    $bitmap = [System.Drawing.Bitmap]::new($stream)
    if ($bitmap.Width -lt 32 -or $bitmap.Height -lt 32) { return $null }

    $border = Get-ImageUniformBorder -Bitmap $bitmap -MaxRatio $MaxTrimRatio
    $cropped = $false
    if ($border.Uniform) {
      $rect = [System.Drawing.Rectangle]::new(
        $border.Left, $border.Top,
        $bitmap.Width - $border.Left - $border.Right,
        $bitmap.Height - $border.Top - $border.Bottom
      )
      if ($rect.Width -ge 32 -and $rect.Height -ge 32) {
        $prepared = $bitmap.Clone($rect, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $cropped = $true
      }
    }
    if ($null -eq $prepared) {
      $prepared = [System.Drawing.Bitmap]::new(
        $bitmap.Width, $bitmap.Height, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb
      )
      $graphics = [System.Drawing.Graphics]::FromImage($prepared)
      $graphics.DrawImage($bitmap, 0, 0, $bitmap.Width, $bitmap.Height)
      $graphics.Dispose()
      $graphics = $null
    }

    $profile = Get-ImageContrastProfile -Bitmap $prepared
    $needsContrast = $profile.StdDev -lt $MinStdDev
    if (-not $cropped -and -not $needsContrast) { return $null }

    if ($needsContrast) {
      $factor = [single]$ContrastFactor
      $offset = [single](128.0 * (1.0 - $ContrastFactor))
      $matrix = [System.Drawing.Imaging.ColorMatrix]::new()
      $matrix.Matrix00 = $factor
      $matrix.Matrix11 = $factor
      $matrix.Matrix22 = $factor
      $matrix.Matrix33 = 1.0
      $matrix.Matrix40 = $offset
      $matrix.Matrix41 = $offset
      $matrix.Matrix42 = $offset
      $attributes = [System.Drawing.Imaging.ImageAttributes]::new()
      $attributes.SetColorMatrix($matrix)
      $output = [System.Drawing.Bitmap]::new(
        $prepared.Width, $prepared.Height, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb
      )
      $graphics = [System.Drawing.Graphics]::FromImage($output)
      $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
      $destination = [System.Drawing.Rectangle]::new(0, 0, $prepared.Width, $prepared.Height)
      $graphics.DrawImage(
        $prepared, $destination, 0, 0, $prepared.Width, $prepared.Height,
        [System.Drawing.GraphicsUnit]::Pixel, $attributes
      )
    }
    else {
      $output = $prepared.Clone()
    }

    $outputStream = [System.IO.MemoryStream]::new()
    if ($MimeType -eq "image/png") {
      $output.Save($outputStream, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    else {
      $jpegCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
        Where-Object { $_.MimeType -eq "image/jpeg" } | Select-Object -First 1
      if ($null -eq $jpegCodec) { return $null }
      $encoderParameters = [System.Drawing.Imaging.EncoderParameters]::new(1)
      $encoderParameters.Param[0] = [System.Drawing.Imaging.EncoderParameter]::new(
        [System.Drawing.Imaging.Encoder]::Quality, [long]90
      )
      $output.Save($outputStream, $jpegCodec, $encoderParameters)
    }

    $tagParts = New-Object System.Collections.Generic.List[string]
    if ($cropped) { $tagParts.Add("crop") }
    if ($needsContrast) { $tagParts.Add("contrast") }
    return [pscustomobject]@{
      Bytes = $outputStream.ToArray()
      Tag   = ($tagParts -join "+")
      Width = $output.Width
      Height = $output.Height
    }
  }
  catch {
    return $null
  }
  finally {
    if ($outputStream) { $outputStream.Dispose() }
    if ($graphics)     { $graphics.Dispose() }
    if ($attributes)   { $attributes.Dispose() }
    if ($output)       { $output.Dispose() }
    if ($prepared)     { $prepared.Dispose() }
    if ($bitmap)       { $bitmap.Dispose() }
    if ($stream)       { $stream.Dispose() }
  }
}

function Test-AnalysisRereadNeeded {
  # Classe C (grafico ilegivel) e D (sem grafico) sao as duas respostas em que
  # vale gastar UMA chamada extra antes de devolver recusa ao usuario.
  param([AllowNull()]$Result)
  if ($null -eq $Result) { return $false }
  return ([string]$Result.image_class) -in @("C", "D")
}

function New-ImageRereadInstruction {
  # Instrucao anexada ao prompt na releitura. Pede verificacao item por item sem
  # autorizar invencao: se os elementos nao estiverem visiveis, a resposta
  # correta continua sendo C/D.
  param([Parameter(Mandatory = $true)][string]$ImageClass)
  $previousRead = if ($ImageClass -eq "D") {
    "que nao havia grafico financeiro identificavel"
  }
  else {
    "que o grafico estava ilegivel ou incompleto"
  }
  return @"
Releitura da mesma imagem: a primeira passada concluiu $previousRead (image_class=$ImageClass). Antes de repetir essa conclusao, verifique a imagem inteira, nao apenas o centro:
1) eixos de preco com numeros legiveis;
2) candles, barras ou linha de preco formando serie temporal;
3) painel de volume ou de indicador tecnico;
4) nome do ativo e timeframe visiveis.
Se qualquer um desses elementos estiver visivel, a imagem contem grafico financeiro e image_class deve ser A, B ou C conforme a legibilidade real. Responda image_class=D somente se nao houver grafico financeiro algum. Nao invente dados que nao estejam visiveis.
"@
}

function Test-AnalysisRateLimit {
  # Janela deslizante local: devolve se a tentativa pode seguir e a lista de
  # horarios que o chamador deve guardar. Funcao pura para ser testada sem HTTP.
  param(
    [Parameter(Mandatory = $true)][datetime]$Now,
    [AllowNull()][AllowEmptyCollection()][datetime[]]$Timestamps,
    [Parameter(Mandatory = $true)][int]$Limit,
    [Parameter(Mandatory = $true)][int]$WindowSeconds
  )
  if ($Limit -le 0) {
    return [pscustomobject]@{ Allowed = $true; Timestamps = @(); RetryAfterSeconds = 0 }
  }
  $windowStart = $Now.AddSeconds(-$WindowSeconds)
  $recent = @($Timestamps | Where-Object { $_ -gt $windowStart } | Sort-Object)
  if ($recent.Count -ge $Limit) {
    $retryAfter = [int][Math]::Ceiling(
      ($recent[0].AddSeconds($WindowSeconds) - $Now).TotalSeconds)
    if ($retryAfter -lt 1) { $retryAfter = 1 }
    return [pscustomobject]@{
      Allowed = $false
      Timestamps = $recent
      RetryAfterSeconds = $retryAfter
    }
  }
  $updated = @($recent) + @($Now)
  return [pscustomobject]@{ Allowed = $true; Timestamps = $updated; RetryAfterSeconds = 0 }
}

# =====================================================================
# COMPATIBILIDADE DE MODELOS OPENAI
# ---------------------------------------------------------------------
# Os modelos de raciocinio da familia GPT-5/6 e o-series usam
# max_completion_tokens e recusam temperature/top_p/penalidades. Os modelos
# anteriores (gpt-4o-mini, gpt-4.1) aceitam temperature e max_tokens. O perfil
# abaixo e derivado do id do modelo, sem supor que ele existe na conta: a
# disponibilidade real continua sendo checada em GET /v1/models/<id>.
# =====================================================================
$script:OpenAIReasoningEfforts = @("none", "low", "medium", "high", "xhigh", "max")
$script:OpenAIReasoningEffortDefault = "low"

function Test-OpenAIReasoningModel {
  param([AllowEmptyString()][string]$Model)
  $id = ([string]$Model).Trim().ToLowerInvariant()
  if (-not $id) { return $false }
  # gpt-5, gpt-5.6-luna, gpt-6-astra, o1/o3/o4-mini...
  if ($id -match '^gpt-[5-9](\.|-|$)') { return $true }
  if ($id -match '^o[1-9](\.|-|$)') { return $true }
  return $false
}

function Get-OpenAIReasoningEfforts {
  return @($script:OpenAIReasoningEfforts)
}

function Get-OpenAIModelProfile {
  param(
    [Parameter(Mandatory = $true)][string]$Model,
    [int]$OutputTokens = 4000,
    [AllowEmptyString()][string]$ReasoningEffort = ""
  )
  $id = ([string]$Model).Trim()
  if (-not $id) { throw "Informe o modelo OpenAI (ex.: gpt-5.6-luna)." }
  $maxOutput = [Math]::Max(256, [Math]::Min(128000, $OutputTokens))
  if (Test-OpenAIReasoningModel -Model $id) {
    $requested = ([string]$ReasoningEffort).Trim().ToLowerInvariant()
    $effort = $requested
    $valid = $true
    if (-not $effort) { $effort = $script:OpenAIReasoningEffortDefault; $valid = $true }
    elseif ($effort -notin $script:OpenAIReasoningEfforts) {
      $effort = $script:OpenAIReasoningEffortDefault
      $valid = $false
    }
    return [ordered]@{
      model                     = $id
      family                    = "reasoning"
      tokenParameter            = "max_completion_tokens"
      maxOutputTokens           = $maxOutput
      temperature               = $null
      supportsTemperature       = $false
      reasoningEffort           = $effort
      reasoningEffortRequested  = $requested
      reasoningEffortValid      = $valid
      supportsStructuredOutputs = $true
    }
  }
  return [ordered]@{
    model                     = $id
    family                    = "classic"
    tokenParameter            = "max_tokens"
    maxOutputTokens           = $maxOutput
    temperature               = 0.0
    supportsTemperature       = $true
    reasoningEffort           = $null
    reasoningEffortRequested  = ""
    reasoningEffortValid      = $true
    supportsStructuredOutputs = $true
  }
}

function New-OpenAIChatRequestBody {
  # Monta o corpo de /v1/chat/completions de acordo com o perfil do modelo:
  # sem temperature e com max_completion_tokens em modelos de raciocinio,
  # mantendo temperature 0.0 + max_tokens nos modelos anteriores. O schema
  # estrito do contrato e o mesmo nos dois casos.
  param(
    [Parameter(Mandatory = $true)][string]$Model,
    [Parameter(Mandatory = $true)][string]$SystemPrompt,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$UserPrompt,
    [Parameter(Mandatory = $true)][string]$MimeType,
    [Parameter(Mandatory = $true)][string]$ImageData,
    [string]$ImageDetail = "high",
    [int]$OutputTokens = 4000,
    [AllowEmptyString()][string]$ReasoningEffort = ""
  )
  $profile = Get-OpenAIModelProfile -Model $Model -OutputTokens $OutputTokens `
    -ReasoningEffort $ReasoningEffort
  $body = [ordered]@{
    model = $profile.model
    store = $false
  }
  if ($profile.supportsTemperature) { $body["temperature"] = [double]$profile.temperature }
  $body[$profile.tokenParameter] = [int]$profile.maxOutputTokens
  if ($profile.reasoningEffort) { $body["reasoning_effort"] = [string]$profile.reasoningEffort }
  $body["response_format"] = [ordered]@{
    type        = "json_schema"
    json_schema = [ordered]@{
      name   = "chart_analysis"
      strict = $true
      schema = (New-AnalysisResponseSchema)
    }
  }
  $body["messages"] = @(
    [ordered]@{ role = "system"; content = $SystemPrompt },
    [ordered]@{
      role    = "user"
      content = @(
        [ordered]@{ type = "text"; text = $UserPrompt },
        [ordered]@{
          type      = "image_url"
          image_url = [ordered]@{ url = "data:$MimeType;base64,$ImageData"; detail = $ImageDetail }
        }
      )
    }
  )
  return [pscustomobject]@{ Profile = $profile; Body = $body }
}

function Set-OpenAIChatRequestBodyTokenLimit {
  # A repeticao por resposta cortada precisa gravar no nome de parametro certo
  # (max_tokens ou max_completion_tokens). Devolve o limite aplicado.
  param(
    [Parameter(Mandatory = $true)]$Body,
    [Parameter(Mandatory = $true)]$Profile,
    [Parameter(Mandatory = $true)][int]$Limit
  )
  $applied = [Math]::Max(256, [Math]::Min(128000, $Limit))
  $Body[[string]$Profile.tokenParameter] = $applied
  return $applied
}

function Test-OpenAIModelMissingError {
  # Detecta somente "modelo inexistente/sem acesso". Um 400 de imagem ou de
  # parametro nao pode disparar troca de modelo: isso esconderia erro real.
  param(
    [int]$StatusCode,
    [AllowEmptyString()][string]$Body = ""
  )
  if ($StatusCode -eq 404) { return $true }
  if ($StatusCode -ne 400) { return $false }
  if ([string]::IsNullOrWhiteSpace($Body)) { return $false }
  return [bool]($Body -match '(?i)model_not_found|does not exist|not have access|no access to model')
}

function Hide-SensitiveDiagnostic {
  # Nenhuma mensagem de erro pode carregar a chave. O diagnostic vem do corpo
  # do provedor ou da excecao local; aqui ele e limpo antes de ir para o log,
  # para a resposta HTTP ou para a tela do usuario.
  param(
    [AllowEmptyString()][AllowNull()][string]$Text,
    [AllowEmptyString()][string]$ApiKey = ""
  )
  if ([string]::IsNullOrEmpty($Text)) { return "" }
  $clean = $Text
  if ($ApiKey) { $clean = $clean -replace [regex]::Escape($ApiKey), "[chave oculta]" }
  $clean = $clean -replace '(?i)Bearer\s+\S+', 'Bearer [oculto]'
  $clean = $clean -replace '(?i)\bsk-[A-Za-z0-9_\-]{8,}', '[chave oculta]'
  return $clean
}

function Invoke-OpenAIChatCompletion {
  # Chamada HTTP + retry de 429/5xx. A resposta volta como hashtable
  # (Success/StatusCode/Body/ElapsedMs/Attempts/Error) e nunca inclui a chave.
  # -Transport permite testar 400/401/429/500/503/timeout sem rede e sem
  # creditos: o scriptblock recebe (JsonBody, tentativa) e devolve StatusCode
  # e Body, ou lanca excecao para simular falha de transporte.
  param(
    [Parameter(Mandatory = $true)][string]$JsonBody,
    [string]$Endpoint = "https://api.openai.com/v1/chat/completions",
    [AllowEmptyString()][string]$ApiKey = "",
    [int]$TimeoutSeconds = 180,
    [int]$MaxRetries = 1,
    [System.Net.Http.HttpClient]$Client = $null,
    [scriptblock]$Transport = $null,
    [int]$RetryBackoffBaseMs = 2000
  )
  $attempt       = 0
  $lastStatus    = 0
  $lastBody      = ""
  $lastException = $null
  $totalMs       = 0
  $ownsClient    = $false
  $httpClient    = $Client

  if (-not $Transport -and -not $httpClient) {
    $httpClient = [System.Net.Http.HttpClient]::new()
    $ownsClient = $true
  }
  # HttpClient.Timeout so pode ser atribuido antes da primeira requisicao. O
  # cliente injetado e reutilizado pelo servidor (que ja o cria com o timeout
  # configurado); sobrescrever aqui quebraria a segunda chamada.
  if ($httpClient -and $ownsClient) {
    $httpClient.Timeout = [TimeSpan]::FromSeconds([Math]::Max(1, $TimeoutSeconds))
  }

  try {
    while ($attempt -le $MaxRetries) {
      $attempt++
      $sw = [System.Diagnostics.Stopwatch]::StartNew()
      try {
        if ($Transport) {
          $mocked = & $Transport $JsonBody $attempt
          $lastStatus = [int]$mocked.StatusCode
          $lastBody   = [string]$mocked.Body
        }
        else {
          $req = $null
          $resp = $null
          try {
            $req = [System.Net.Http.HttpRequestMessage]::new(
              [System.Net.Http.HttpMethod]::Post, $Endpoint)
            $req.Headers.Authorization =
              [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $ApiKey)
            $req.Content = [System.Net.Http.StringContent]::new(
              $JsonBody, [System.Text.Encoding]::UTF8, "application/json")
            $resp = $httpClient.SendAsync($req).GetAwaiter().GetResult()
            $lastStatus = [int]$resp.StatusCode
            $respBytes  = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
            $lastBody   = [System.Text.Encoding]::UTF8.GetString($respBytes)
          }
          finally {
            if ($resp) { $resp.Dispose() }
            if ($req)  { $req.Dispose() }
          }
        }
        $sw.Stop()
        $totalMs += $sw.ElapsedMilliseconds

        if ($lastStatus -ge 200 -and $lastStatus -lt 300) {
          return @{
            Success = $true; StatusCode = $lastStatus; Body = $lastBody
            ElapsedMs = $totalMs; Attempts = $attempt
          }
        }
        if ($lastStatus -ne 429 -and $lastStatus -lt 500) {
          return @{
            Success = $false; StatusCode = $lastStatus; Body = $lastBody
            ElapsedMs = $totalMs; Attempts = $attempt
          }
        }
      }
      catch {
        $sw.Stop()
        $totalMs += $sw.ElapsedMilliseconds
        $lastException = Hide-SensitiveDiagnostic -Text $_.Exception.Message -ApiKey $ApiKey
        $lastStatus    = 0
        $lastBody      = $lastException
      }

      if ($attempt -le $MaxRetries) {
        $backoffMs = [int]([Math]::Pow(2, $attempt - 1) * $RetryBackoffBaseMs)
        Write-Warning "OpenAI indisponivel (tentativa $attempt/$($MaxRetries + 1)). Retentando em $([Math]::Round($backoffMs / 1000, 1))s..."
        if ($backoffMs -gt 0) { Start-Sleep -Milliseconds $backoffMs }
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
  finally {
    if ($ownsClient -and $httpClient) { $httpClient.Dispose() }
  }
}

Export-ModuleMember -Function `
  New-AnalysisResponseSchema, `
  New-AnalysisStringArraySchema, `
  Test-ImageSignature, `
  Test-AnalysisRateLimit, `
  Get-AnalysisCacheKey, `
  ConvertTo-EnhancedImageBytes, `
  ConvertTo-PreparedImageBytes, `
  Get-ImageUniformBorder, `
  Get-ImageClassRank, `
  Test-AnalysisRereadNeeded, `
  New-ImageRereadInstruction, `
  ConvertTo-ValidatedAnalysisResult, `
  Test-StringArray, `
  Get-AnalysisContractFields, `
  Get-AnalysisContractVersion, `
  Get-AnalysisFailureMessage, `
  Remove-ModelReasoningBlock,
  Test-OpenAIReasoningModel,
  Get-OpenAIReasoningEfforts,
  Get-OpenAIModelProfile,
  New-OpenAIChatRequestBody,
  Set-OpenAIChatRequestBodyTokenLimit,
  Test-OpenAIModelMissingError,
  Hide-SensitiveDiagnostic,
  Invoke-OpenAIChatCompletion