<#
    Testes do contrato de analise do Scalping Edge.
    Compativel com Pester 3.4. Testes locais, SEM chamar OpenAI.
#>

$modulePath = Join-Path $PSScriptRoot "..\src\analysis-contract.psm1"
Import-Module $modulePath -Force -WarningAction SilentlyContinue

function New-ValidAnalysisObject {
    return [pscustomobject]@{
        image_class         = "A"
        chart_type          = "candles"
        price_axis_readable = $true
        price_axis_min      = 1.0950
        price_axis_max      = 1.1050
        asset_visible       = "EUR/USD"
        timeframe_visible   = "M5"
        last_candle_status  = "closed"
        visual_quality      = 85
        analysis_coverage   = 90
        confidence          = 75
        direction           = "BUY"
        directional_assessment = [pscustomobject]@{
            buy_score       = 82
            sell_score      = 50
            buy_status      = "supported"
            buy_evidence    = @("Estrutura de alta confirmada")
            sell_status     = "weak"
            sell_evidence   = @("Sem rompimento vendedor confirmado")
            selected_reason = "BUY supera SELL e cumpre os critérios de confirmação."
        }
        trend = [pscustomobject]@{
            main        = "alta"
            micro       = "alta"
            structure   = @("HH em 1.1020", "HL em 1.0985", "HH em 1.1040")
            explanation = "Sequencia consistente de topos e fundos ascendentes."
        }
        price_action = [pscustomobject]@{
            observations    = @("Pullback para EMA20", "Martelo de fundo no suporte")
            interpretations = @("Continuacao da tendencia de alta")
            conditions      = @("Fechamento acima do topo anterior")
        }
        levels = @(
            [pscustomobject]@{
                type   = "support"
                value  = 1.0985
                region = "topo anterior"
                reason = "nivel respeitado 3x"
            }
        )
        patterns = @()
        indicators = @(
            [pscustomobject]@{
                name           = "EMA20"
                visible        = $true
                observations   = @("Preco acima da EMA")
                interpretation = "Tendencia de alta confirmada"
                conflict       = ""
            }
        )
        volume = [pscustomobject]@{
            visible        = $true
            observations   = @("Volume crescente no rompimento")
            interpretation = "Confirmacao do movimento"
        }
        evidence_for     = @("Estrutura de alta intacta", "Pullback respeitou EMA20")
        evidence_against = @()
        signal_timing = [pscustomobject]@{
            action                = "BUY"
            signal_candle         = "closed"
            entry_timing          = "Entrada no fechamento do candle de confirmacao"
            exit_plan             = "Alvo no proximo nivel; stop abaixo do pullback"
            holding_horizon       = "3 a 5 velas"
            confirmation_required = @()
            invalidation          = @("Perda do suporte em 1.0985")
        }
        conflict_notes = @()
        risk = @("Volatilidade media pode gerar ruido")
        summary = "Leitura geral:`nImagem classe A, direcao BUY.`n`nprice action:`nPullback para EMA20.`n`nniveis e zonas:`nSuporte em 1.0985.`n`nIndicadores e Volumes:`nEMA20 abaixo do preco.`n`nCenario e invalidacao:`nEntrada no fechamento.`n`nLimitacoes:`nVolatilidade media."
    }
}

Describe "1. Estrutura do objeto" {

    It "1.1 aceita objeto BUY completo e mantem direcao" {
        $result = ConvertTo-ValidatedAnalysisResult -Result (New-ValidAnalysisObject)
        $result.direction | Should Be "BUY"
        $result.signal_timing.action | Should Be "BUY"
    }

    It "1.2 rejeita objeto nulo" {
        { ConvertTo-ValidatedAnalysisResult -Result $null } | Should Throw
    }

    It "1.3 rejeita array no lugar de objeto" {
        { ConvertTo-ValidatedAnalysisResult -Result @(1, 2, 3) } | Should Throw
    }

    It "1.4 rejeita objeto com propriedade ausente" {
        $obj = New-ValidAnalysisObject
        $obj.PSObject.Properties.Remove("summary")
        { ConvertTo-ValidatedAnalysisResult -Result $obj } | Should Throw
    }

    It "1.5 rejeita objeto com propriedade extra" {
        $obj = New-ValidAnalysisObject
        $obj.PSObject.Properties.Add(
            [System.Management.Automation.PSNoteProperty]::new("campo_extra", "x")
        )
        $names = @($obj.PSObject.Properties | ForEach-Object { $_.Name })
        Write-Host "        [DEBUG 1.5] total=$($names.Count) tem_campo_extra=$($names -contains 'campo_extra')"
        ($names -contains "campo_extra") | Should Be $true
        { ConvertTo-ValidatedAnalysisResult -Result $obj } | Should Throw
    }

    It "1.6 preserva confidence dentro do cap" {
        $result = ConvertTo-ValidatedAnalysisResult -Result (New-ValidAnalysisObject)
        ($result.confidence -le 95) | Should Be $true
    }

    It "1.7 rejeita directional_assessment ausente" {
        $obj = New-ValidAnalysisObject
        $obj.PSObject.Properties.Remove("directional_assessment")
        { ConvertTo-ValidatedAnalysisResult -Result $obj } | Should Throw
    }
}

Describe "2. Validacao de valores" {

    It "2.1 rejeita image_class invalido" {
        $obj = New-ValidAnalysisObject
        $obj.image_class = "Z"
        { ConvertTo-ValidatedAnalysisResult -Result $obj } | Should Throw
    }

    It "2.2 rejeita direction invalida" {
        $obj = New-ValidAnalysisObject
        $obj.direction = "HOLD"
        { ConvertTo-ValidatedAnalysisResult -Result $obj } | Should Throw
    }

    It "2.3 rejeita last_candle_status invalido" {
        $obj = New-ValidAnalysisObject
        $obj.last_candle_status = "definitely_open"
        { ConvertTo-ValidatedAnalysisResult -Result $obj } | Should Throw
    }

    It "2.4 rejeita confidence acima de 100" {
        $obj = New-ValidAnalysisObject
        $obj.confidence = 150
        { ConvertTo-ValidatedAnalysisResult -Result $obj } | Should Throw
    }

    It "2.5 rejeita confidence negativa" {
        $obj = New-ValidAnalysisObject
        $obj.confidence = -5
        { ConvertTo-ValidatedAnalysisResult -Result $obj } | Should Throw
    }

    It "2.6 rejeita trend.main invalido" {
        $obj = New-ValidAnalysisObject
        $obj.trend.main = "subindo_forte"
        { ConvertTo-ValidatedAnalysisResult -Result $obj } | Should Throw
    }

    It "2.7 rejeita signal_timing.action invalido" {
        $obj = New-ValidAnalysisObject
        $obj.signal_timing.action = "HOLD"
        { ConvertTo-ValidatedAnalysisResult -Result $obj } | Should Throw
    }

    It "2.8 rejeita level.type invalido" {
        $obj = New-ValidAnalysisObject
        $obj.levels = @(
            [pscustomobject]@{ type = "magia"; value = 1.0; region = "x"; reason = "y" }
        )
        { ConvertTo-ValidatedAnalysisResult -Result $obj } | Should Throw
    }

    It "2.9 rebaixa status supported abaixo do score minimo em vez de falhar" {
        $obj = New-ValidAnalysisObject
        $obj.directional_assessment.buy_score = 69
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.directional_assessment.buy_score | Should Be 69
        $result.directional_assessment.buy_status | Should Be "weak"
        $result.direction | Should Be "NEUTRAL"
        $result.signal_timing.action | Should Be "WAIT"
    }

    It "2.10 limita score direcional acima de 100 em vez de falhar" {
        $obj = New-ValidAnalysisObject
        $obj.directional_assessment.sell_score = 101
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.directional_assessment.sell_score | Should Be 100
    }

    It "2.11 arredonda score decimal para inteiro" {
        $obj = New-ValidAnalysisObject
        $obj.directional_assessment.buy_score = 69.5
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.directional_assessment.buy_score | Should Be 70
        $result.directional_assessment.buy_status | Should Be "supported"
    }

    It "2.12 arredonda para baixo e rebaixa o status sem falhar" {
        $obj = New-ValidAnalysisObject
        $obj.directional_assessment.buy_score = 69.4
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.directional_assessment.buy_score | Should Be 69
        $result.directional_assessment.buy_status | Should Be "weak"
    }

    It "2.14 aceita score numerico em texto e converte para inteiro" {
        $obj = New-ValidAnalysisObject
        $obj.directional_assessment.buy_score = "75"
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.directional_assessment.buy_score | Should Be 75
    }

    It "2.15 score que nao e numero continua sendo erro nomeado" {
        $obj = New-ValidAnalysisObject
        $obj.directional_assessment.buy_score = $null
        { ConvertTo-ValidatedAnalysisResult -Result $obj } |
            Should Throw "buy_score deve ser um numero"
    }

    It "2.13 diagnostico nomeia campo ausente na avaliacao direcional" {
        $obj = New-ValidAnalysisObject
        $obj.directional_assessment.PSObject.Properties.Remove("selected_reason")
        { ConvertTo-ValidatedAnalysisResult -Result $obj } |
            Should Throw "campos ausentes: selected_reason"
    }
}

Describe "3. Travas de decisao" {

    It "3.1 classe C forca NEUTRAL e zera tudo" {
        $obj = New-ValidAnalysisObject
        $obj.image_class = "C"
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.direction            | Should Be "NEUTRAL"
        $result.signal_timing.action | Should Be "WAIT"
        $result.confidence           | Should Be 0
        $result.trend.main           | Should Be "indefinida"
        $result.levels.Count         | Should Be 0
        $result.patterns.Count       | Should Be 0
        $result.indicators.Count     | Should Be 0
        $result.evidence_for.Count   | Should Be 0
        $result.volume.visible       | Should Be $false
    }

    It "3.2 classe D forca NEUTRAL e zera tudo" {
        $obj = New-ValidAnalysisObject
        $obj.image_class = "D"
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.direction    | Should Be "NEUTRAL"
        $result.confidence   | Should Be 0
        $result.trend.main   | Should Be "indefinida"
        $result.directional_assessment.buy_status | Should Be "unavailable"
        $result.directional_assessment.sell_status | Should Be "unavailable"
    }

    It "3.3 classe B forca NEUTRAL e cap 60" {
        $obj = New-ValidAnalysisObject
        $obj.image_class = "B"
        $obj.analysis_coverage = 65
        $obj.confidence = 85
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.direction            | Should Be "NEUTRAL"
        $result.confidence           | Should Be 60
        $result.signal_timing.action | Should Be "WAIT"
    }

    It "3.4 conflict_notes forca NEUTRAL/WAIT" {
        $obj = New-ValidAnalysisObject
        $obj.conflict_notes = @("Indicador contradiz price action")
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.direction            | Should Be "NEUTRAL"
        $result.signal_timing.action | Should Be "WAIT"
    }

    It "3.5 last_candle_status nao closed mantem o vies e forca WAIT" {
        $obj = New-ValidAnalysisObject
        $obj.last_candle_status = "possibly_open"
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.direction            | Should Be "BUY"
        $result.signal_timing.action | Should Be "WAIT"
    }

    It "3.6 signal_candle nao closed mantem o vies e forca WAIT" {
        $obj = New-ValidAnalysisObject
        $obj.signal_timing.signal_candle = "possibly_open"
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.direction            | Should Be "BUY"
        $result.signal_timing.action | Should Be "WAIT"
    }

    It "3.7 confirmation_required pendente mantem o vies e forca WAIT" {
        $obj = New-ValidAnalysisObject
        $obj.signal_timing.confirmation_required = @("Rompimento nao confirmado")
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.direction            | Should Be "BUY"
        $result.signal_timing.action | Should Be "WAIT"
    }

    It "3.8 viés BUY com action WAIT e permitido" {
        $obj = New-ValidAnalysisObject
        $obj.signal_timing.action = "WAIT"
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.direction            | Should Be "BUY"
        $result.signal_timing.action | Should Be "WAIT"
    }

    It "3.9 action oposta a direction e rebaixada para WAIT" {
        $obj = New-ValidAnalysisObject
        $obj.signal_timing.action = "SELL"
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.direction            | Should Be "BUY"
        $result.signal_timing.action | Should Be "WAIT"
    }

    It "3.10 empate entre hipoteses suportadas força NEUTRAL" {
        $obj = New-ValidAnalysisObject
        $obj.directional_assessment.buy_score = 78
        $obj.directional_assessment.sell_score = 74
        $obj.directional_assessment.sell_status = "supported"
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.direction | Should Be "NEUTRAL"
        $result.signal_timing.action | Should Be "WAIT"
        $result.directional_assessment.selected_reason | Should Match "inferior a 10"
    }

    It "3.12 direction NEUTRAL forca action WAIT" {
        $obj = New-ValidAnalysisObject
        $obj.direction = "NEUTRAL"
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.direction            | Should Be "NEUTRAL"
        $result.signal_timing.action | Should Be "WAIT"
    }

    It "3.11 preserva a leitura do modelo ao manter o vies com WAIT" {
        $obj = New-ValidAnalysisObject
        $obj.directional_assessment.selected_reason = "Estrutura ascendente, mas a vela esta aberta."
        $obj.last_candle_status = "possibly_open"
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.direction | Should Be "BUY"
        $result.signal_timing.action | Should Be "WAIT"
        $result.directional_assessment.selected_reason | Should Be "Estrutura ascendente, mas a vela esta aberta."
    }

    It "3.13 lateralizacao sem score suficiente em nenhum lado força NEUTRAL/WAIT" {
        $obj = New-ValidAnalysisObject
        $obj.trend.main = "lateralização"
        $obj.directional_assessment.buy_score = 60
        $obj.directional_assessment.sell_score = 55
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.direction            | Should Be "NEUTRAL"
        $result.signal_timing.action | Should Be "WAIT"
        $result.directional_assessment.selected_reason |
            Should Match "Lateralização sem score suficiente"
    }

    It "3.14 lateralizacao com rejeicao confirmada em um extremo mantem o vies" {
        $obj = New-ValidAnalysisObject
        $obj.trend.main = "lateralização"
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.direction            | Should Be "BUY"
        $result.signal_timing.action | Should Be "BUY"
    }

}

Describe "4. Cap de confidence" {

    It "4.1 coverage < 40 limita a 45" {
        $obj = New-ValidAnalysisObject
        $obj.analysis_coverage = 30
        $obj.confidence = 90
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        ($result.confidence -le 45) | Should Be $true
    }

    It "4.2 40 <= coverage < 60 limita a 60" {
        $obj = New-ValidAnalysisObject
        $obj.analysis_coverage = 50
        $obj.confidence = 90
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        ($result.confidence -le 60) | Should Be $true
    }

    It "4.3 60 <= coverage < 80 limita a 80" {
        $obj = New-ValidAnalysisObject
        $obj.analysis_coverage = 70
        $obj.confidence = 95
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        ($result.confidence -le 80) | Should Be $true
    }

    It "4.4 coverage >= 80 permite ate 95" {
        $obj = New-ValidAnalysisObject
        $obj.analysis_coverage = 90
        $obj.confidence = 95
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        ($result.confidence -le 95) | Should Be $true
    }

    It "4.5 coverage = 0 zera confidence" {
        $obj = New-ValidAnalysisObject
        $obj.analysis_coverage = 0
        $obj.confidence = 100
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.confidence | Should Be 0
    }

    It "4.6 arredonda confidence para multiplo de 5" {
        $obj = New-ValidAnalysisObject
        $obj.confidence = 73
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        ($result.confidence % 5) | Should Be 0
        $result.confidence | Should Be 70
    }

    It "4.7 preserva summary com titulos acentuados normalizados" {
        $obj = New-ValidAnalysisObject
        $obj.summary = "Leitura geral:`nA.`n`nprice action:`nB.`n`nNíveis e zonas:`nC.`n`nIndicadores e Volumes:`nD.`n`nCenário e invalidação:`nE.`n`nLimitações:`nF."
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.summary | Should Be $obj.summary
    }

    It "4.8 resumo sem titulos e reconstruido preservando o texto descritivo" {
        $obj = New-ValidAnalysisObject
        $obj.summary = "Preco abriu em 1.3100, caiu ate 1.3090 e recuperou para 1.3126 antes de devolver parte do movimento."
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.summary | Should Match "Leitura geral:"
        $result.summary | Should Match "Preco abriu em 1.3100"
        $result.summary | Should Match "Cenario e invalidacao:"
    }

    It "4.9 eixo legivel sem niveis explica a ausencia sem frase vazia" {
        $obj = New-ValidAnalysisObject
        $obj.levels = @()
        $obj.summary = "Analise concluida."
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.summary | Should Match "Eixo de precos legivel"
        $result.summary | Should Not Match "Nenhum nivel verificavel"
    }

    It "4.10 cenario neutro sem indicadores usa texto concreto" {
        $obj = New-ValidAnalysisObject
        $obj.image_class = "B"
        $obj.confidence = 60
        $obj.levels = @()
        $obj.indicators = @()
        $obj.volume = [pscustomobject]@{ visible = $false; observations = @(); interpretation = "" }
        $obj.directional_assessment = [pscustomobject]@{
            buy_score = 0; sell_score = 0
            buy_status = "unavailable"; buy_evidence = @()
            sell_status = "unavailable"; sell_evidence = @()
            selected_reason = "Nenhum lado tem confirmacao visual suficiente."
        }
        $obj.summary = "Analise concluida."
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.summary | Should Match "timeframe: M5"
        $result.summary | Should Match "Sem paineis de indicadores ou de volume na captura"
        $result.summary | Should Match "Comparacao BUY/SELL"
        $result.summary | Should Not Match "Nenhum indicador ou volume legivel"
    }
}

Describe "9. Replay de fixtures" {

    It "9.1 fixture neutra mantém resumo canônico e avalia os dois lados" {
        $raw = [System.IO.File]::ReadAllText(
            (Join-Path $PSScriptRoot "fixtures/synthetic-analysis-b-neutral.json"),
            [System.Text.Encoding]::UTF8
        )
        $obj = ConvertFrom-Json -InputObject $raw
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.direction | Should Be "NEUTRAL"
        $result.signal_timing.action | Should Be "WAIT"
        ($result.confidence -le 60) | Should Be $true
        $result.summary | Should Match "Leitura geral:"
        $result.summary | Should Match "comparação entre BUY e SELL"
        $result.summary | Should Match "1\.31211"
        $result.summary | Should Match "Limitacoes:"
        $result.summary | Should Not Match "Analise concluida"
        $result.summary | Should Not Match "Nenhum indicador ou volume legivel"
    }

    It "9.2 fixture completa preserva resumo e niveis" {
        $raw = [System.IO.File]::ReadAllText(
            (Join-Path $PSScriptRoot "fixtures\synthetic-analysis-a-buy.json"),
            [System.Text.Encoding]::UTF8
        )
        $obj = ConvertFrom-Json -InputObject $raw
        $originalSummary = [string]$obj.summary
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.direction | Should Be "BUY"
        $result.levels.Count | Should Be 3
        $result.summary | Should Be $originalSummary
        $result.summary | Should Match "1\.31211"
    }

    It "9.3 fixture de viés comprador mantém BUY com ação WAIT" {
        $raw = [System.IO.File]::ReadAllText(
            (Join-Path $PSScriptRoot "fixtures/synthetic-analysis-c-buy-wait.json"),
            [System.Text.Encoding]::UTF8
        )
        $obj = ConvertFrom-Json -InputObject $raw
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.direction | Should Be "BUY"
        $result.signal_timing.action | Should Be "WAIT"
        $result.directional_assessment.buy_status | Should Be "supported"
        $result.summary | Should Match "Leitura geral:"
        $result.summary | Should Match "1\.31211"
    }

    It "9.4 fixture de lateralizacao com preco no meio do range fica NEUTRAL" {
        $raw = [System.IO.File]::ReadAllText(
            (Join-Path $PSScriptRoot "fixtures/synthetic-analysis-d-range-mid.json"),
            [System.Text.Encoding]::UTF8
        )
        $obj = ConvertFrom-Json -InputObject $raw
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.direction | Should Be "NEUTRAL"
        $result.signal_timing.action | Should Be "WAIT"
        $result.trend.main | Should Be "lateralização"
        $result.levels.Count | Should Be 2
    }

    It "9.5 fixture com conflict_notes preenchido forca NEUTRAL/WAIT" {
        $raw = [System.IO.File]::ReadAllText(
            (Join-Path $PSScriptRoot "fixtures/synthetic-analysis-e-conflict-neutral.json"),
            [System.Text.Encoding]::UTF8
        )
        $obj = ConvertFrom-Json -InputObject $raw
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.conflict_notes.Count | Should Be 1
        $result.direction | Should Be "NEUTRAL"
        $result.signal_timing.action | Should Be "WAIT"
    }

    It "9.6 fixture classe D sem grafico zera a leitura" {
        $raw = [System.IO.File]::ReadAllText(
            (Join-Path $PSScriptRoot "fixtures/synthetic-analysis-f-non-chart.json"),
            [System.Text.Encoding]::UTF8
        )
        $obj = ConvertFrom-Json -InputObject $raw
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.image_class | Should Be "D"
        $result.confidence | Should Be 0
        $result.levels.Count | Should Be 0
        $result.directional_assessment.buy_status | Should Be "unavailable"
    }

    It "9.7 fixture de vies BUY com vela possivelmente aberta mantem WAIT" {
        $raw = [System.IO.File]::ReadAllText(
            (Join-Path $PSScriptRoot "fixtures/synthetic-analysis-g-buy-possibly-open.json"),
            [System.Text.Encoding]::UTF8
        )
        $obj = ConvertFrom-Json -InputObject $raw
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.direction | Should Be "BUY"
        $result.signal_timing.action | Should Be "WAIT"
        $result.last_candle_status | Should Be "possibly_open"
    }
}

Describe "5. Estruturas internas" {

    It "5.1 price_axis_readable false limpa levels" {
        $obj = New-ValidAnalysisObject
        $obj.price_axis_readable = $false
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.levels.Count | Should Be 0
    }

    It "5.2 indicator invisible limpa observacoes" {
        $obj = New-ValidAnalysisObject
        $obj.indicators = @(
            [pscustomobject]@{
                name = "RSI"; visible = $false
                observations = @("x"); interpretation = "y"; conflict = "z"
            }
        )
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.indicators[0].observations.Count | Should Be 0
        $result.indicators[0].interpretation     | Should Be ""
    }

    It "5.3 pattern status invalido rejeitado" {
        $obj = New-ValidAnalysisObject
        $obj.patterns = @(
            [pscustomobject]@{
                name = "Engolfo"; status = "talvez"
                evidence = @("e"); confirmation = "c"; invalidation = "i"
            }
        )
        { ConvertTo-ValidatedAnalysisResult -Result $obj } | Should Throw
    }

    It "5.4 pattern status invalidated aceito" {
        $obj = New-ValidAnalysisObject
        $obj.patterns = @(
            [pscustomobject]@{
                name = "Engolfo"; status = "invalidated"
                evidence = @("falhou"); confirmation = "n/a"; invalidation = "ja invalidado"
            }
        )
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.patterns.Count | Should Be 1
    }

    It "5.5 volume visible true mantem observacoes" {
        $result = ConvertTo-ValidatedAnalysisResult -Result (New-ValidAnalysisObject)
        $result.volume.visible | Should Be $true
        $result.volume.observations.Count | Should Be 1
    }
}

Describe "11. Anti-invencao de precos" {

    It "11.1 nivel fora da escala declarada e descartado" {
        $obj = New-ValidAnalysisObject
        $obj.price_axis_min = 1.0900
        $obj.price_axis_max = 1.1000
        $obj.levels = @(
            [pscustomobject]@{ type = "support"; value = 1.0985; region = "fundo"; reason = "reacao" },
            [pscustomobject]@{ type = "resistance"; value = 1.5000; region = "inventado"; reason = "sem reacao" }
        )
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.levels.Count | Should Be 1
        $result.levels[0].value | Should Be 1.0985
        ($result.risk -join " ") | Should Match "fora da escala visivel"
    }

    It "11.2 eixo legivel sem faixa declarada desliga niveis numericos" {
        $obj = New-ValidAnalysisObject
        $obj.price_axis_min = $null
        $obj.price_axis_max = $null
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.price_axis_readable | Should Be $false
        $result.levels.Count | Should Be 0
        $result.price_axis_min | Should Be $null
        $result.price_axis_max | Should Be $null
    }

    It "11.3 eixo ilegivel anula faixa e niveis" {
        $obj = New-ValidAnalysisObject
        $obj.price_axis_readable = $false
        $obj.price_axis_min = 1.0900
        $obj.price_axis_max = 1.1000
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.levels.Count | Should Be 0
        $result.price_axis_min | Should Be $null
        $result.price_axis_max | Should Be $null
    }

    It "11.4 nivel sem valor numerico continua permitido dentro da faixa" {
        $obj = New-ValidAnalysisObject
        $obj.levels = @(
            [pscustomobject]@{ type = "support"; value = $null; region = "faixa larga"; reason = "reacao visivel" }
        )
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.levels.Count | Should Be 1
        $result.levels[0].value | Should Be $null
    }
}

Describe "6. Test-StringArray" {

    It "6.1 array de strings retorna true" {
        Test-StringArray -Value @("a", "b", "c") | Should Be $true
    }

    It "6.2 array vazio retorna true" {
        Test-StringArray -Value @() | Should Be $true
    }

    It "6.3 string solta retorna false" {
        Test-StringArray -Value "apenas uma string" | Should Be $false
    }

    It "6.4 array misto retorna false" {
        Test-StringArray -Value @("a", 1, "c") | Should Be $false
    }

    It "6.5 null retorna false" {
        Test-StringArray -Value $null | Should Be $false
    }
}

Describe "7. Get-AnalysisFailureMessage" {

    It "7.1 HTTP 401 menciona chave recusada" {
        (Get-AnalysisFailureMessage -StatusCode 401 -Diagnostic "" -ResponseReceived $false -FinishReason "") | Should Match "recusada"
    }

    It "7.2 HTTP 403 menciona acesso negado" {
        (Get-AnalysisFailureMessage -StatusCode 403 -Diagnostic "" -ResponseReceived $false -FinishReason "") | Should Match "negou"
    }

    It "7.3 HTTP 404 menciona modelo" {
        (Get-AnalysisFailureMessage -StatusCode 404 -Diagnostic "" -ResponseReceived $false -FinishReason "") | Should Match "modelo"
    }

    It "7.4 HTTP 429 menciona limite" {
        (Get-AnalysisFailureMessage -StatusCode 429 -Diagnostic "" -ResponseReceived $false -FinishReason "") | Should Match "limite"
    }

    It "7.5 HTTP 413 menciona tamanho" {
        (Get-AnalysisFailureMessage -StatusCode 413 -Diagnostic "" -ResponseReceived $false -FinishReason "") | Should Match "grande"
    }

    It "7.6 finish_reason=length menciona incompleta" {
        (Get-AnalysisFailureMessage -StatusCode 0 -Diagnostic "" -ResponseReceived $true -FinishReason "length") | Should Match "incompleta"
    }

    It "7.7 HTTP 500+ menciona indisponivel" {
        (Get-AnalysisFailureMessage -StatusCode 503 -Diagnostic "" -ResponseReceived $false -FinishReason "") | Should Match "indispon"
    }
}

Describe "8. Contrato e prompt" {

    It "8.1 schema exige exatamente os mesmos campos do validador" {
        $schema = New-AnalysisResponseSchema
        $expected = @(Get-AnalysisContractFields | Sort-Object) -join ","
        $actual = @($schema.required | Sort-Object) -join ","
        $actual | Should Be $expected
    }

    It "8.2 todo campo obrigatorio tem definicao em properties" {
        $schema = New-AnalysisResponseSchema
        $missing = @($schema.required | Where-Object { -not $schema.properties.Contains($_) })
        ($missing -join ",") | Should Be ""
    }

    It "8.3 nenhuma propriedade do schema ficou fora de required" {
        $schema = New-AnalysisResponseSchema
        $extra = @($schema.properties.Keys | Where-Object { $_ -notin $schema.required })
        ($extra -join ",") | Should Be ""
    }

    It "8.4 schema nao aceita campos extras" {
        (New-AnalysisResponseSchema).additionalProperties | Should Be $false
    }

    It "8.5 versao do contrato acompanha o arquivo de prompt" {
        $promptDir = Join-Path $PSScriptRoot "..\prompts"
        $prompt = Get-ChildItem -Path $promptDir -Filter "chart-analysis-*.txt" |
            Sort-Object Name -Descending | Select-Object -First 1
        $prompt | Should Not BeNullOrEmpty
        $prompt.Name | Should Be ("chart-analysis-v" + (Get-AnalysisContractVersion) + ".txt")
    }

    It "8.6 schema limita as listas nos mesmos tetos do prompt" {
        $schema = New-AnalysisResponseSchema
        $schema.properties.trend.properties.structure.maxItems | Should Be 5
        $schema.properties.price_action.properties.observations.maxItems | Should Be 5
        $schema.properties.evidence_for.maxItems | Should Be 3
        $schema.properties.evidence_against.maxItems | Should Be 3
        $schema.properties.directional_assessment.properties.buy_evidence.maxItems | Should Be 2
        $schema.properties.directional_assessment.properties.sell_evidence.maxItems | Should Be 2
        $schema.properties.levels.maxItems | Should Be 5
        $schema.properties.indicators.maxItems | Should Be 4
        $schema.properties.patterns.maxItems | Should Be 2
    }
}
Describe "12. Eixo verificado pelo usuario" {

    It "12.1 escala informada substitui a escala declarada pela IA" {
        $obj = New-ValidAnalysisObject
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj -AxisMin 1.3095 -AxisMax 1.3130
        $result.price_axis_readable | Should Be $true
        $result.price_axis_min | Should Be 1.3095
        $result.price_axis_max | Should Be 1.3130
    }

    It "12.2 nivel fora da escala informada e descartado" {
        $obj = New-ValidAnalysisObject
        $obj.price_axis_min = 1.0900
        $obj.price_axis_max = 1.1000
        $obj.levels = @(
            [pscustomobject]@{ type = "support"; value = 1.0985; region = "fundo"; reason = "reacao" },
            [pscustomobject]@{ type = "resistance"; value = 1.5000; region = "inventado"; reason = "sem reacao" }
        )
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj -AxisMin 1.0950 -AxisMax 1.1050
        $result.price_axis_min | Should Be 1.0950
        $result.price_axis_max | Should Be 1.1050
        $result.levels.Count | Should Be 1
        $result.levels[0].value | Should Be 1.0985
        ($result.risk -join " ") | Should Match "fora da escala visivel"
    }

    It "12.3 eixo ilegivel e substituido pela escala informada" {
        $obj = New-ValidAnalysisObject
        $obj.price_axis_readable = $false
        $obj.price_axis_min = $null
        $obj.price_axis_max = $null
        $obj.levels = @(
            [pscustomobject]@{ type = "support"; value = 1.0985; region = "fundo"; reason = "reacao" }
        )
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj -AxisMin 1.0900 -AxisMax 1.1000
        $result.price_axis_readable | Should Be $true
        $result.levels.Count | Should Be 1
        ($result.risk -join " ") | Should Match "faixa informada"
    }

    It "12.4 divergencia entre a escala da IA e a escala informada fica registrada" {
        $obj = New-ValidAnalysisObject
        $obj.price_axis_min = 1.0950
        $obj.price_axis_max = 1.1050
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj -AxisMin 1.3095 -AxisMax 1.3130
        ($result.risk -join " ") | Should Match "diverge da escala informada"
        $result.price_axis_min | Should Be 1.3095
        $result.price_axis_max | Should Be 1.3130
    }

    It "12.5 escala fora de ordem e rejeitada" {
        {
            ConvertTo-ValidatedAnalysisResult -Result (New-ValidAnalysisObject) -AxisMin 1.1000 -AxisMax 1.0900
        } | Should Throw
    }

    It "12.6 escala incompleta e rejeitada" {
        {
            ConvertTo-ValidatedAnalysisResult -Result (New-ValidAnalysisObject) -AxisMin 1.0900
        } | Should Throw
    }
}

Describe "13. Travas de evidencia e coerencia" {

    It "13.1 classe A com lado avaliado sem evidencia registra a ausencia" {
        $obj = New-ValidAnalysisObject
        $obj.directional_assessment.sell_evidence = @()
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.directional_assessment.sell_evidence.Count | Should Be 1
        ($result.directional_assessment.sell_evidence -join " ") | Should Match "Nenhuma evidencia visual"
        ($result.risk -join " ") | Should Match "lado SELL"
    }

    It "13.2 classe B com lado fraco sem evidencia tambem e reparada" {
        $obj = New-ValidAnalysisObject
        $obj.image_class = "B"
        $obj.confidence = 60
        $obj.directional_assessment.buy_status = "weak"
        $obj.directional_assessment.buy_evidence = @()
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.directional_assessment.buy_evidence.Count | Should Be 1
        ($result.directional_assessment.buy_evidence -join " ") | Should Match "Nenhuma evidencia visual"
    }

    It "13.3 lado indisponivel continua sem evidencia obrigatoria" {
        $obj = New-ValidAnalysisObject
        $obj.directional_assessment.sell_status = "unavailable"
        $obj.directional_assessment.sell_evidence = @()
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.direction | Should Be "BUY"
    }

    It "13.4 imagem legivel sem limitacoes recebe limitacao visual derivada" {
        $obj = New-ValidAnalysisObject
        $obj.risk = @()
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.risk.Count | Should BeGreaterThan 0
        ($result.risk -join " ") | Should Match "recorte visivel"
        $result.summary | Should Match "Limitacoes:"
        $result.direction | Should Be "BUY"
    }

    It "13.4b limitacao derivada usa o que falta na captura" {
        $obj = New-ValidAnalysisObject
        $obj.risk = @()
        $obj.volume.visible = $false
        $obj.indicators = @()
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        ($result.risk -join " ") | Should Match "volume"
        ($result.risk -join " ") | Should Match "indicador"
    }

    It "13.5 invalidacao que nao contradiz a hipotese suspende o vies" {
        $obj = New-ValidAnalysisObject
        $obj.signal_timing.invalidation = @("Fechamento acima de 1.1040 confirma continuacao")
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.direction | Should Be "NEUTRAL"
        $result.signal_timing.action | Should Be "WAIT"
        $result.directional_assessment.selected_reason | Should Match "nao contradiz a hipotese"
    }

    It "13.6 invalidacao coerente mantem o vies" {
        $obj = New-ValidAnalysisObject
        $obj.signal_timing.invalidation = @("Fechamento abaixo de 1.0985 anula a estrutura")
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.direction | Should Be "BUY"
    }

    It "13.7 resumo curto fica registrado nas limitacoes" {
        $obj = New-ValidAnalysisObject
        $obj.summary = "Leitura geral: A. price action: B. niveis e zonas: C. Indicadores e Volumes: D. Cenario e invalidacao: E. Limitacoes: F."
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        ($result.risk -join " ") | Should Match "abaixo do piso de 160"
    }

    It "13.8 rebaixamento nao injeta jargao interno no selected_reason" {
        $obj = New-ValidAnalysisObject
        $obj.image_class = "B"
        $obj.confidence = 60
        $obj.directional_assessment.selected_reason = "Estrutura ascendente, mas a vela esta aberta."
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        $result.directional_assessment.selected_reason | Should Match "Estrutura ascendente"
        $result.directional_assessment.selected_reason | Should Not Match "Bloqueio"
    }
}

Describe "14. Deduplicacao de evidencias" {

    It "14.1 evidencia repetida em evidence_for fica uma unica vez" {
        $obj = New-ValidAnalysisObject
        $obj.evidence_for = @("Rompimento de 1.0985", "Rompimento de 1.0985")
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        @($result.evidence_for).Count | Should Be 1
    }

    It "14.2 caixa e espacos nao duplicam buy_evidence" {
        $obj = New-ValidAnalysisObject
        $obj.directional_assessment.buy_evidence = @("Fundo ascendente", "  fundo ASCENDENTE  ")
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        @($result.directional_assessment.buy_evidence).Count | Should Be 1
        @($result.directional_assessment.buy_evidence)[0] | Should Be "Fundo ascendente"
    }

    It "14.3 evidencias distintas sao preservadas na ordem" {
        $obj = New-ValidAnalysisObject
        $obj.evidence_against = @("Resistencia em 1.1000", "Volume caindo")
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        @($result.evidence_against).Count | Should Be 2
        $result.evidence_against[1] | Should Be "Volume caindo"
    }
}

Describe "15. Forma do JSON depois da deduplicacao" {

    It "15.1 evidencia unica continua array no JSON" {
        $obj = New-ValidAnalysisObject
        $obj.evidence_for = @("Rompimento de 1.0985")
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        ($result.evidence_for -is [array]) | Should Be $true
        $json = ConvertTo-Json -InputObject $result -Depth 12 -Compress
        $json.Contains('"evidence_for":["Rompimento de 1.0985"]') | Should Be $true
    }

    It "15.2 buy_evidence e risk com um item continuam arrays" {
        $obj = New-ValidAnalysisObject
        $obj.directional_assessment.buy_evidence = @("Fundo ascendente")
        $obj.risk = @("Escala parcialmente cortada")
        $result = ConvertTo-ValidatedAnalysisResult -Result $obj
        ($result.directional_assessment.buy_evidence -is [array]) | Should Be $true
        ($result.risk -is [array]) | Should Be $true
        $json = ConvertTo-Json -InputObject $result -Depth 12 -Compress
        $json.Contains('"buy_evidence":["Fundo ascendente"]') | Should Be $true
        $result.risk[0] | Should Be "Escala parcialmente cortada"
    }
}

Describe "16. Saneamento da resposta do modelo" {

    It "16.1 remove bloco de raciocinio antes do JSON" {
        $raw = '<thinking>inventario e decisao</thinking>{"a":1}'
        (Remove-ModelReasoningBlock -Text $raw) | Should Be '{"a":1}'
    }

    It "16.2 remove cercas de codigo em volta do JSON" {
        $fence = ([string][char]96) * 3
        $raw = $fence + "json`n" + '{"a":1}' + "`n" + $fence
        (Remove-ModelReasoningBlock -Text $raw) | Should Be '{"a":1}'
    }

    It "16.3 JSON puro permanece intacto" {
        $raw = '{"a":1}'
        (Remove-ModelReasoningBlock -Text $raw) | Should Be $raw
    }

    It "16.4 resposta so com raciocinio vira texto vazio" {
        (Remove-ModelReasoningBlock -Text '<thinking>apenas raciocinio</thinking>') | Should Be ""
    }
}

Describe "17. Protecoes locais do servidor" {

    It "17.1 assinatura PNG valida" {
        $png = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00)
        (Test-ImageSignature -Bytes $png -MimeType "image/png") | Should Be $true
    }

    It "17.2 assinatura JPEG valida" {
        $jpeg = [byte[]](0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10)
        (Test-ImageSignature -Bytes $jpeg -MimeType "image/jpeg") | Should Be $true
    }

    It "17.3 assinatura WEBP valida" {
        $webp = [System.Text.Encoding]::ASCII.GetBytes("RIFF0000WEBPVP8 ")
        (Test-ImageSignature -Bytes $webp -MimeType "image/webp") | Should Be $true
    }

    It "17.4 conteudo que nao e imagem e rejeitado" {
        $fake = [System.Text.Encoding]::UTF8.GetBytes("<html>nao e imagem</html>")
        (Test-ImageSignature -Bytes $fake -MimeType "image/png") | Should Be $false
    }

    It "17.5 MIME divergente da assinatura e rejeitado" {
        $png = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00)
        (Test-ImageSignature -Bytes $png -MimeType "image/jpeg") | Should Be $false
    }

    It "17.6 rate limit bloqueia a decima primeira tentativa" {
        $now = [datetime]::UtcNow
        $stamps = @()
        for ($i = 0; $i -lt 10; $i++) {
            $check = Test-AnalysisRateLimit -Now $now.AddSeconds($i) -Timestamps $stamps -Limit 10 -WindowSeconds 60
            $check.Allowed | Should Be $true
            $stamps = $check.Timestamps
        }
        $blocked = Test-AnalysisRateLimit -Now $now.AddSeconds(11) -Timestamps $stamps -Limit 10 -WindowSeconds 60
        $blocked.Allowed | Should Be $false
        ($blocked.RetryAfterSeconds -gt 0) | Should Be $true
    }

    It "17.7 janela deslizante libera apos o intervalo" {
        $now = [datetime]::UtcNow
        $stamps = @()
        for ($i = 0; $i -lt 10; $i++) {
            $stamps = (Test-AnalysisRateLimit -Now $now.AddSeconds($i) -Timestamps $stamps -Limit 10 -WindowSeconds 60).Timestamps
        }
        $after = Test-AnalysisRateLimit -Now $now.AddSeconds(61) -Timestamps $stamps -Limit 10 -WindowSeconds 60
        $after.Allowed | Should Be $true
    }
}

Describe "18. Cache local de analises" {

    It "18.1 mesma imagem e mesmo contexto geram a mesma chave" {
        $image = "QUJDREVGRw=="
        $first = Get-AnalysisCacheKey -ImageData $image -Market "crypto" -Asset "ETH" `
            -Timeframe "5m" -AxisMin 1670 -AxisMax 1710 -Model "gpt-4o-mini"
        $second = Get-AnalysisCacheKey -ImageData $image -Market "crypto" -Asset "ETH" `
            -Timeframe "5m" -AxisMin 1670 -AxisMax 1710 -Model "gpt-4o-mini"
        $first | Should Be $second
        $first.Length | Should Be 64
    }

    It "18.2 imagem diferente gera chave diferente" {
        $first = Get-AnalysisCacheKey -ImageData "QUJDREVGRw==" -Market "crypto" -Asset "ETH" -Timeframe "5m"
        $second = Get-AnalysisCacheKey -ImageData "QUJDREVGSA==" -Market "crypto" -Asset "ETH" -Timeframe "5m"
        ($first -ne $second) | Should Be $true
    }

    It "18.3 timeframe, modelo e ativo mudam a chave" {
        $base = Get-AnalysisCacheKey -ImageData "QUJD" -Market "crypto" -Asset "ETH" -Timeframe "5m" -Model "gpt-4o-mini"
        $otherTimeframe = Get-AnalysisCacheKey -ImageData "QUJD" -Market "crypto" -Asset "ETH" -Timeframe "15m" -Model "gpt-4o-mini"
        $otherModel = Get-AnalysisCacheKey -ImageData "QUJD" -Market "crypto" -Asset "ETH" -Timeframe "5m" -Model "gpt-4o"
        $otherAsset = Get-AnalysisCacheKey -ImageData "QUJD" -Market "crypto" -Asset "SOL" -Timeframe "5m" -Model "gpt-4o-mini"
        ($base -ne $otherTimeframe) | Should Be $true
        ($base -ne $otherModel) | Should Be $true
        ($base -ne $otherAsset) | Should Be $true
    }

    It "18.4 eixo informado participa da chave" {
        $withoutAxis = Get-AnalysisCacheKey -ImageData "QUJD" -Market "crypto" -Asset "ETH" -Timeframe "5m"
        $withAxis = Get-AnalysisCacheKey -ImageData "QUJD" -Market "crypto" -Asset "ETH" -Timeframe "5m" -AxisMin 1.0 -AxisMax 2.0
        ($withoutAxis -ne $withAxis) | Should Be $true
    }

    It "18.5 pre-processamento participa da chave" {
        $original = Get-AnalysisCacheKey -ImageData "QUJD" -Market "crypto" -Asset "ETH" -Timeframe "5m" -Preprocess ""
        $enhanced = Get-AnalysisCacheKey -ImageData "QUJD" -Market "crypto" -Asset "ETH" -Timeframe "5m" -Preprocess "contrast-v1"
        ($original -ne $enhanced) | Should Be $true
    }
}

Describe "19. Pre-processamento de imagem" {

    Add-Type -AssemblyName System.Drawing

    function New-TestChartImage {
        param(
            [int]$Left,
            [int]$Right,
            [int]$Width = 64,
            [int]$Height = 64,
            [string]$Format = "Png"
        )
        $bitmap = New-Object System.Drawing.Bitmap $Width, $Height
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $background = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($Left, $Left, $Left))
            $foreground = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($Right, $Right, $Right))
            try {
                $graphics.FillRectangle($background, 0, 0, $Width, $Height)
                $graphics.FillRectangle($foreground, 0, 0, [int]($Width / 2), $Height)
            }
            finally {
                $background.Dispose()
                $foreground.Dispose()
            }
        }
        finally {
            $graphics.Dispose()
        }
        $stream = New-Object System.IO.MemoryStream
        try {
            $imageFormat = if ($Format -eq "Jpeg") {
                [System.Drawing.Imaging.ImageFormat]::Jpeg
            }
            else {
                [System.Drawing.Imaging.ImageFormat]::Png
            }
            $bitmap.Save($stream, $imageFormat)
            $bytes = $stream.ToArray()
        }
        finally {
            $stream.Dispose()
            $bitmap.Dispose()
        }
        return ,$bytes
    }

    It "19.1 realca captura de baixo contraste mantendo formato e dimensoes" {
        $bytes = New-TestChartImage -Left 90 -Right 100
        $enhanced = ConvertTo-EnhancedImageBytes -Bytes $bytes -MimeType "image/png"
        ($null -ne $enhanced) | Should Be $true
        $enhanced[0] -eq 0x89 | Should Be $true
        $stream = [System.IO.MemoryStream]::new([byte[]]$enhanced)
        try {
            $decoded = [System.Drawing.Image]::FromStream($stream)
            try {
                $decoded.Width | Should Be 64
                $decoded.Height | Should Be 64
            }
            finally { $decoded.Dispose() }
        }
        finally { $stream.Dispose() }
    }

    It "19.2 imagem com contraste suficiente segue intacta" {
        $bytes = New-TestChartImage -Left 10 -Right 240
        $enhanced = ConvertTo-EnhancedImageBytes -Bytes $bytes -MimeType "image/png"
        ($null -eq $enhanced) | Should Be $true
    }

    It "19.3 JPEG de baixo contraste continua JPEG" {
        $bytes = New-TestChartImage -Left 80 -Right 88 -Format "Jpeg"
        $enhanced = ConvertTo-EnhancedImageBytes -Bytes $bytes -MimeType "image/jpeg"
        ($null -ne $enhanced) | Should Be $true
        $enhanced[0] -eq 0xFF -and $enhanced[1] -eq 0xD8 -and $enhanced[2] -eq 0xFF | Should Be $true
    }

    It "19.4 WEBP nao e reprocessado" {
        $webp = [System.Text.Encoding]::ASCII.GetBytes("RIFF0000WEBPVP8 ")
        ($null -eq (ConvertTo-EnhancedImageBytes -Bytes $webp -MimeType "image/webp")) | Should Be $true
    }

    It "19.5 imagem pequena demais nao e reprocessada" {
        $bytes = New-TestChartImage -Left 90 -Right 95 -Width 16 -Height 16
        ($null -eq (ConvertTo-EnhancedImageBytes -Bytes $bytes -MimeType "image/png")) | Should Be $true
    }

    It "19.6 preparo recorta borda vazia e preserva o miolo do grafico" {
        $bitmap = New-Object System.Drawing.Bitmap 160, 120
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $background = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(6, 8, 11))
        $light = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(235, 240, 245))
        $dark = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(18, 22, 28))
        try {
            $graphics.FillRectangle($background, 0, 0, 160, 120)
            $stripe = 0
            for ($x = 20; $x -lt 140; $x += 8) {
                $brush = if ($stripe % 2 -eq 0) { $light } else { $dark }
                $graphics.FillRectangle($brush, $x, 12, 8, 96)
                $stripe++
            }
        }
        finally {
            $background.Dispose(); $light.Dispose(); $dark.Dispose(); $graphics.Dispose()
        }
        $stream = New-Object System.IO.MemoryStream
        try {
            $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
            $bytes = $stream.ToArray()
        }
        finally {
            $stream.Dispose(); $bitmap.Dispose()
        }

        $prepared = ConvertTo-PreparedImageBytes -Bytes $bytes -MimeType "image/png"
        ($null -ne $prepared) | Should Be $true
        ($prepared.Tag -match "crop") | Should Be $true
        ($prepared.Width -lt 160 -and $prepared.Width -ge 100) | Should Be $true
        ($prepared.Height -lt 120 -and $prepared.Height -ge 80) | Should Be $true
    }

    It "19.7 imagem sem borda vazia e com contraste suficiente nao e alterada" {
        $bitmap = New-Object System.Drawing.Bitmap 160, 120
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $light = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(235, 240, 245))
        $dark = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(18, 22, 28))
        try {
            $stripe = 0
            for ($x = 0; $x -lt 160; $x += 8) {
                $brush = if ($stripe % 2 -eq 0) { $light } else { $dark }
                $graphics.FillRectangle($brush, $x, 0, 8, 120)
                $stripe++
            }
        }
        finally {
            $light.Dispose(); $dark.Dispose(); $graphics.Dispose()
        }
        $stream = New-Object System.IO.MemoryStream
        try {
            $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
            $bytes = $stream.ToArray()
        }
        finally {
            $stream.Dispose(); $bitmap.Dispose()
        }

        ($null -eq (ConvertTo-PreparedImageBytes -Bytes $bytes -MimeType "image/png")) | Should Be $true
    }
}

Describe "20. Releitura automatica de imagem" {
    It "20.1 ordena as classes A > B > C > D" {
        (Get-ImageClassRank -ImageClass "A") -gt (Get-ImageClassRank -ImageClass "B") | Should Be $true
        (Get-ImageClassRank -ImageClass "B") -gt (Get-ImageClassRank -ImageClass "C") | Should Be $true
        (Get-ImageClassRank -ImageClass "C") -gt (Get-ImageClassRank -ImageClass "D") | Should Be $true
        (Get-ImageClassRank -ImageClass "Z") | Should Be -1
    }

    It "20.2 releitura so e pedida para classe C ou D" {
        (Test-AnalysisRereadNeeded -Result ([pscustomobject]@{ image_class = "A" })) | Should Be $false
        (Test-AnalysisRereadNeeded -Result ([pscustomobject]@{ image_class = "B" })) | Should Be $false
        (Test-AnalysisRereadNeeded -Result ([pscustomobject]@{ image_class = "C" })) | Should Be $true
        (Test-AnalysisRereadNeeded -Result ([pscustomobject]@{ image_class = "D" })) | Should Be $true
    }

    It "20.3 instrucao de releitura cita a classe anterior e proibe invencao" {
        $instructionD = New-ImageRereadInstruction -ImageClass "D"
        $instructionD | Should Match "image_class=D"
        $instructionD | Should Match "Nao invente"
        $instructionC = New-ImageRereadInstruction -ImageClass "C"
        $instructionC | Should Match "image_class=C"
        $instructionC | Should Match "ilegivel"
    }
}
