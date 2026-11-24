$modulePath = Join-Path $PSScriptRoot "..\src\market.psm1"
Import-Module $modulePath -Force -WarningAction SilentlyContinue

function New-OscillatingSeries {
    param([int]$Count = 300, [double]$Base = 100, [double]$Amplitude = 8)
    $open = [double[]]::new($Count)
    $high = [double[]]::new($Count)
    $low = [double[]]::new($Count)
    $close = [double[]]::new($Count)
    for ($i = 0; $i -lt $Count; $i++) {
        $price = $Base + $Amplitude * [Math]::Sin($i / 9.0)
        $close[$i] = $price
        $open[$i] = $price - 0.05
        $high[$i] = $price + 0.40
        $low[$i] = $price - 0.40
    }
    return [pscustomobject]@{ Open = $open; High = $high; Low = $low; Close = $close }
}

Describe "21. Indicadores de mercado" {
    It "21.1 EMA de valores constantes permanece no mesmo valor" {
        $values = [double[]]@(10, 10, 10, 10, 10)
        $ema = Get-ZnxEmaSeries -Values $values -Period 3
        (Get-ZnxLastValue -Values $ema) | Should Be 10
    }

    It "21.2 EMA acompanha alta e fica entre o primeiro e o ultimo preco" {
        $values = [double[]]@(1, 2, 3, 4, 5, 6, 7, 8)
        $ema = Get-ZnxEmaSeries -Values $values -Period 4
        $last = Get-ZnxLastValue -Values $ema
        ($last -gt 1 -and $last -lt 8) | Should Be $true
    }

    It "21.3 RSI fica em 100 numa sequencia que so sobe" {
        $values = [double[]]::new(40)
        for ($i = 0; $i -lt 40; $i++) { $values[$i] = 100 + $i }
        $rsi = Get-ZnxRsiSeries -Values $values -Period 14
        [Math]::Round((Get-ZnxLastValue -Values $rsi), 0) | Should Be 100
    }

    It "21.4 RSI fica em 0 numa sequencia que so cai" {
        $values = [double[]]::new(40)
        for ($i = 0; $i -lt 40; $i++) { $values[$i] = 200 - $i }
        $rsi = Get-ZnxRsiSeries -Values $values -Period 14
        [Math]::Round((Get-ZnxLastValue -Values $rsi), 0) | Should Be 0
    }

    It "21.5 ATR de candles com amplitude fixa de 2 pontos resulta em 2" {
        $high = [double[]]@(101, 101, 101, 101, 101, 101)
        $low = [double[]]@(99, 99, 99, 99, 99, 99)
        $close = [double[]]@(100, 100, 100, 100, 100, 100)
        $atr = Get-ZnxAtrSeries -High $high -Low $low -Close $close -Period 3
        [Math]::Round((Get-ZnxLastValue -Values $atr), 4) | Should Be 2
    }
}

Describe "22. Varredor e plano" {
    It "22.1 score positivo premia tendencia de alta com rompimento" {
        $score = Get-ZnxSetupScore -TrendAtr 1.2 -Rsi 62 -BreakoutUp $true `
            -BreakoutDown $false -VolumeRatio 1.8 -ExtensionAtr 1.1
        ($score -ge 35) | Should Be $true
    }

    It "22.2 score negativo pune tendencia de baixa com rompimento para baixo" {
        $score = Get-ZnxSetupScore -TrendAtr -1.2 -Rsi 38 -BreakoutUp $false `
            -BreakoutDown $true -VolumeRatio 1.8 -ExtensionAtr 1.1
        ($score -le -35) | Should Be $true
    }

    It "22.3 lista de ativos acompanhados so tem feed em tempo real (cripto e forex)" {
        $symbols = Get-ZnxTrackedSymbols
        ($symbols -contains "BTC-USD") | Should Be $true
        ($symbols -contains "EURUSD=X") | Should Be $true
        # Indices e acoes vem com 10/15 min de atraso na fonte publica: ficam fora.
        ($symbols -contains "^GSPC") | Should Be $false
        ($symbols -contains "AAPL") | Should Be $false
    }

    It "22.4 plano de alta coloca stop abaixo e alvo acima da entrada" {
        $count = 200
        $close = [double[]]::new($count)
        $high = [double[]]::new($count)
        $low = [double[]]::new($count)
        for ($i = 0; $i -lt $count; $i++) {
            $close[$i] = 100 + ($i * 0.35)
            $high[$i] = $close[$i] + 0.30
            $low[$i] = $close[$i] - 0.30
        }
        $plan = Get-ZnxTradePlan -High $high -Low $low -Close $close
        $plan.bias | Should Be "LONG"
        ($plan.stop -lt $plan.entry) | Should Be $true
        ($plan.target -gt $plan.entry) | Should Be $true
        ($plan.riskReward -gt 0) | Should Be $true
    }

    It "22.5 risco calcula tamanho da posicao a partir do stop" {
        $plan = Get-ZnxPositionPlan -Balance 1000 -RiskPercent 1 -Entry 100 -Stop 95 -Target 110
        $plan.riskAmount | Should Be 10
        $plan.positionSize | Should Be 2
        $plan.riskReward | Should Be 2
        $plan.breakEvenWinRate | Should Be 33.3
    }
}

Describe "23. Maquina do tempo" {
    It "23.1 backtest reamostra os trades e devolve estatisticas completas" {
        $series = New-OscillatingSeries -Count 400
        $stats = Invoke-ZnxBacktestCore -OpenPrices $series.Open -High $series.High `
            -Low $series.Low -Close $series.Close -Simulations 1000 -Seed 7
        ($stats.trades -gt 0) | Should Be $true
        $stats.simulations | Should Be 1000
        ($stats.probProfit -ge 0 -and $stats.probProfit -le 100) | Should Be $true
        ($stats.p5R -le $stats.p95R) | Should Be $true
    }

    It "23.2 mesma semente devolve o mesmo resultado (reprodutivel)" {
        $series = New-OscillatingSeries -Count 400
        $first = Invoke-ZnxBacktestCore -OpenPrices $series.Open -High $series.High `
            -Low $series.Low -Close $series.Close -Simulations 500 -Seed 11
        $second = Invoke-ZnxBacktestCore -OpenPrices $series.Open -High $series.High `
            -Low $series.Low -Close $series.Close -Simulations 500 -Seed 11
        $first.medianR | Should Be $second.medianR
        $first.maxDrawdownR | Should Be $second.maxDrawdownR
    }

    It "23.3 serie curta nao inventa operacoes" {
        $count = 30
        $close = [double[]]::new($count)
        $open = [double[]]::new($count)
        $high = [double[]]::new($count)
        $low = [double[]]::new($count)
        for ($i = 0; $i -lt $count; $i++) {
            $close[$i] = 100 + $i
            $open[$i] = $close[$i] - 0.1
            $high[$i] = $close[$i] + 0.2
            $low[$i] = $close[$i] - 0.2
        }
        $stats = Invoke-ZnxBacktestCore -OpenPrices $open -High $high -Low $low -Close $close
        $stats.trades | Should Be 0
        $stats.simulations | Should Be 10000
    }
}

Describe "24. Erro quadratico de consistencia entre confidence e desfecho" {
    It "24.1 sem desfecho nao inventa numero" {
        $summary = Get-ZnxConfidenceOutcomeError -Outcomes @()
        $summary.sampleCount | Should Be 0
        ($null -eq $summary.confidenceOutcomeError) | Should Be $true
        $summary.invalidSampleCount | Should Be 0
        $summary.bands.Count | Should Be 4
        ($null -eq $summary.bands[0].confidenceMean) | Should Be $true
        ($null -eq $summary.bands[0].favorableRate) | Should Be $true
        ($null -eq $summary.bands[0].averageSquaredError) | Should Be $true
    }

    It "24.2 um favorable com confidence 80 tem erro 0.04" {
        $summary = Get-ZnxConfidenceOutcomeError -Outcomes @(
            [pscustomobject]@{ direction = "BUY"; outcome = "favorable"; confidence = 80 }
        )
        $summary.sampleCount | Should Be 1
        $summary.confidenceOutcomeError | Should Be 0.04
    }

    It "24.3 um adverse com confidence 80 tem erro 0.64" {
        $summary = Get-ZnxConfidenceOutcomeError -Outcomes @(
            [pscustomobject]@{ direction = "SELL"; outcome = "adverse"; confidence = 80 }
        )
        $summary.sampleCount | Should Be 1
        $summary.confidenceOutcomeError | Should Be 0.64
    }

    It "24.4 um favorable e um adverse com 80 dao media 0.34" {
        $summary = Get-ZnxConfidenceOutcomeError -Outcomes @(
            [pscustomobject]@{ direction = "BUY"; outcome = "favorable"; confidence = 80 },
            [pscustomobject]@{ direction = "BUY"; outcome = "adverse"; confidence = 80 }
        )
        $summary.sampleCount | Should Be 2
        $summary.confidenceOutcomeError | Should Be 0.34
    }

    It "24.5 NEUTRAL, WAIT e outcome neutral ficam fora da amostra" {
        $summary = Get-ZnxConfidenceOutcomeError -Outcomes @(
            [pscustomobject]@{ direction = "NEUTRAL"; outcome = "favorable"; confidence = 90 },
            [pscustomobject]@{ direction = "BUY"; outcome = "neutral"; confidence = 90 },
            [pscustomobject]@{ direction = "WAIT"; outcome = "adverse"; confidence = 90 },
            [pscustomobject]@{ direction = "SELL"; outcome = "adverse"; confidence = 60 }
        )
        $summary.sampleCount | Should Be 1
        $summary.confidenceOutcomeError | Should Be 0.36
        $summary.invalidSampleCount | Should Be 0
    }

    It "24.6 confidence ausente, nulo, texto ou fora de 0..100 e invalido, nao amostra" {
        $missing = [pscustomobject]@{ direction = "BUY"; outcome = "favorable" }
        $summary = Get-ZnxConfidenceOutcomeError -Outcomes @(
            $missing,
            [pscustomobject]@{ direction = "BUY"; outcome = "favorable"; confidence = $null },
            [pscustomobject]@{ direction = "BUY"; outcome = "favorable"; confidence = "oitenta" },
            [pscustomobject]@{ direction = "BUY"; outcome = "favorable"; confidence = 180 },
            [pscustomobject]@{ direction = "BUY"; outcome = "favorable"; confidence = -20 }
        )
        $summary.sampleCount | Should Be 0
        ($null -eq $summary.confidenceOutcomeError) | Should Be $true
        $summary.invalidSampleCount | Should Be 5
    }

    It "24.7 o clamp da funcao pura limita p em 0..1" {
        (ConvertTo-ZnxNormalizedConfidence -Confidence 180) | Should Be 1
        (ConvertTo-ZnxNormalizedConfidence -Confidence -20) | Should Be 0
        (ConvertTo-ZnxNormalizedConfidence -Confidence 80) | Should Be 0.8
    }

    It "24.9 a leitura do confidence devolve nulo em vez de zero" {
        ($null -eq (ConvertTo-ZnxConfidenceNumber -Confidence $null)) | Should Be $true
        ($null -eq (ConvertTo-ZnxConfidenceNumber -Confidence "")) | Should Be $true
        ($null -eq (ConvertTo-ZnxConfidenceNumber -Confidence "oitenta")) | Should Be $true
        ($null -eq (ConvertTo-ZnxConfidenceNumber -Confidence 180)) | Should Be $true
        ($null -eq (ConvertTo-ZnxConfidenceNumber -Confidence -1)) | Should Be $true
        ($null -eq (ConvertTo-ZnxConfidenceNumber -Confidence $true)) | Should Be $true
        (ConvertTo-ZnxConfidenceNumber -Confidence 0) | Should Be 0
        (ConvertTo-ZnxConfidenceNumber -Confidence 80) | Should Be 80
        (ConvertTo-ZnxConfidenceNumber -Confidence "80") | Should Be 80
        (ConvertTo-ZnxConfidenceNumber -Confidence 80.5) | Should Be 80.5
    }

    It "24.10 extremos 0, 0.5, 99.5 e 100 entram na amostra certa" {
        $summary = Get-ZnxConfidenceOutcomeError -Outcomes @(
            [pscustomobject]@{ direction = "BUY"; outcome = "favorable"; confidence = 0 },
            [pscustomobject]@{ direction = "BUY"; outcome = "favorable"; confidence = 0.5 },
            [pscustomobject]@{ direction = "BUY"; outcome = "favorable"; confidence = 99.5 },
            [pscustomobject]@{ direction = "BUY"; outcome = "favorable"; confidence = 100 }
        )
        $summary.sampleCount | Should Be 4
        $summary.invalidSampleCount | Should Be 0
        $low = @($summary.bands | Where-Object { $_.bucket -eq "0-54" })[0]
        $low.sampleCount | Should Be 2
        $low.confidenceMean | Should Be 0.2
        $low.averageSquaredError | Should Be 0.995
        $high = @($summary.bands | Where-Object { $_.bucket -eq "85-100" })[0]
        $high.sampleCount | Should Be 2
        $high.confidenceMean | Should Be 99.8
        $high.averageSquaredError | Should Be 0
    }

    It "24.11 fracionario e inteiro caem na mesma unica faixa" {
        $cases = @(
            @{ Value = 0;    Bucket = "0-54" },
            @{ Value = 54;   Bucket = "0-54" },
            @{ Value = 54.5; Bucket = "0-54" },
            @{ Value = 55;   Bucket = "55-69" },
            @{ Value = 69;   Bucket = "55-69" },
            @{ Value = 69.5; Bucket = "55-69" },
            @{ Value = 70;   Bucket = "70-84" },
            @{ Value = 84.5; Bucket = "70-84" },
            @{ Value = 85;   Bucket = "85-100" },
            @{ Value = 100;  Bucket = "85-100" }
        )
        foreach ($case in $cases) {
            (Get-ZnxConfidenceBucketLabel -Confidence $case.Value) | Should Be $case.Bucket
            $summary = Get-ZnxConfidenceOutcomeError -Outcomes @(
                [pscustomobject]@{ direction = "BUY"; outcome = "favorable"; confidence = $case.Value }
            )
            $filled = @($summary.bands | Where-Object { $_.sampleCount -gt 0 })
            $filled.Count | Should Be 1
            $filled[0].bucket | Should Be $case.Bucket
            $summary.sampleCount | Should Be 1
        }
    }

    It "24.12 NaN e infinito sao invalidos, nao amostra" {
        $summary = Get-ZnxConfidenceOutcomeError -Outcomes @(
            [pscustomobject]@{ direction = "BUY"; outcome = "favorable"; confidence = [double]::NaN },
            [pscustomobject]@{ direction = "BUY"; outcome = "favorable"; confidence = [double]::PositiveInfinity },
            [pscustomobject]@{ direction = "BUY"; outcome = "favorable"; confidence = [double]::NegativeInfinity }
        )
        $summary.sampleCount | Should Be 0
        $summary.invalidSampleCount | Should Be 3
        ($null -eq $summary.confidenceOutcomeError) | Should Be $true
    }

    It "24.8 cada faixa usa apenas a propria amostra" {
        $summary = Get-ZnxConfidenceOutcomeError -Outcomes @(
            [pscustomobject]@{ direction = "BUY"; outcome = "favorable"; confidence = 30 },
            [pscustomobject]@{ direction = "BUY"; outcome = "adverse"; confidence = 60 },
            [pscustomobject]@{ direction = "SELL"; outcome = "adverse"; confidence = 90 }
        )
        $low = @($summary.bands | Where-Object { $_.bucket -eq "0-54" })[0]
        $low.sampleCount | Should Be 1
        $low.confidenceMean | Should Be 30
        $low.favorableRate | Should Be 1
        $low.averageSquaredError | Should Be 0.49
        $mid = @($summary.bands | Where-Object { $_.bucket -eq "55-69" })[0]
        $mid.sampleCount | Should Be 1
        $mid.confidenceMean | Should Be 60
        $mid.favorableRate | Should Be 0
        $mid.averageSquaredError | Should Be 0.36
        $high = @($summary.bands | Where-Object { $_.bucket -eq "85-100" })[0]
        $high.sampleCount | Should Be 1
        $high.averageSquaredError | Should Be 0.81
        $empty = @($summary.bands | Where-Object { $_.bucket -eq "70-84" })[0]
        $empty.sampleCount | Should Be 0
        ($null -eq $empty.averageSquaredError) | Should Be $true
        $summary.sampleCount | Should Be 3
        $summary.confidenceOutcomeError | Should Be 0.5533
    }
}

Describe "25. Avaliacao com desfechos de confidence invalido" {
    $evaluateScript = Join-Path $PSScriptRoot "..\tools\evaluate.ps1"
    $script:ZnxEvalTempRoot = Join-Path $env:TEMP ("znx-eval-" + [guid]::NewGuid().ToString("N"))

    function New-EvaluateFixture {
        param([string]$Name, [string[]]$Lines)
        $dir = Join-Path $script:ZnxEvalTempRoot $Name
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $outcomesPath = Join-Path $dir "outcomes.jsonl"
        [System.IO.File]::WriteAllLines(
            $outcomesPath, $Lines, (New-Object System.Text.UTF8Encoding($false)))
        return [pscustomobject]@{
            Dir      = $dir
            Outcomes = $outcomesPath
            Report   = (Join-Path $dir "report\report.json")
        }
    }

    function Invoke-EvaluateFixture {
        param($Fixture)
        & $evaluateScript -AnalysesPath (Join-Path $Fixture.Dir "analyses.jsonl") `
            -FeedbackPath (Join-Path $Fixture.Dir "feedback.jsonl") `
            -OutcomesPath $Fixture.Outcomes `
            -OutDir (Join-Path $Fixture.Dir "report") 3>$null 6>$null
        return [System.IO.File]::ReadAllText($Fixture.Report) | ConvertFrom-Json
    }

    AfterAll {
        $root = $script:ZnxEvalTempRoot
        if ($root -and (Test-Path -LiteralPath $root)) {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It "25.1 confidence nulo ou textual nao quebra e nao cai na faixa 0-54" {
        $fixture = New-EvaluateFixture -Name "invalid" -Lines @(
            '{"analysisId":"a","direction":"BUY","outcome":"favorable","confidence":null}',
            '{"analysisId":"b","direction":"SELL","outcome":"adverse","confidence":"oitenta"}',
            '{"analysisId":"c","direction":"BUY","outcome":"favorable","confidence":"80"}'
        )
        $report = Invoke-EvaluateFixture -Fixture $fixture

        $report.desfechos.sampleCount | Should Be 1
        $report.desfechos.invalidSampleCount | Should Be 2
        $report.desfechos.confidenceOutcomeError | Should Be 0.04
        $bands = @($report.desfechos.confidenceOutcomeBands)
        $bands.Count | Should Be 4
        $low = @($bands | Where-Object { $_.bucket -eq "0-54" })[0]
        $low.sampleCount | Should Be 0
        ($null -eq $low.confidenceMean) | Should Be $true
        $calibration = @($report.desfechos.calibracao)
        (@($calibration | Where-Object { $_.faixa -eq "0-54" })[0].amostras) | Should Be 0
        (@($calibration | Where-Object { $_.faixa -eq "70-84" })[0].amostras) | Should Be 1
    }

    It "25.2 sem desfechos o erro continua nulo, nao zero" {
        $fixture = New-EvaluateFixture -Name "empty" -Lines @()
        $report = Invoke-EvaluateFixture -Fixture $fixture

        $report.desfechos.sampleCount | Should Be 0
        ($null -eq $report.desfechos.confidenceOutcomeError) | Should Be $true
        $bands = @($report.desfechos.confidenceOutcomeBands)
        $bands.Count | Should Be 4
        ($null -eq $bands[0].averageSquaredError) | Should Be $true
    }

    It "25.3 amostras validas continuam produzindo os mesmos numeros" {
        $fixture = New-EvaluateFixture -Name "valid" -Lines @(
            '{"analysisId":"d","direction":"BUY","outcome":"favorable","confidence":80}',
            '{"analysisId":"e","direction":"SELL","outcome":"adverse","confidence":60}'
        )
        $report = Invoke-EvaluateFixture -Fixture $fixture

        $report.desfechos.sampleCount | Should Be 2
        $report.desfechos.invalidSampleCount | Should Be 0
        $report.desfechos.confidenceOutcomeError | Should Be 0.2
        $bands = @($report.desfechos.confidenceOutcomeBands)
        (@($bands | Where-Object { $_.bucket -eq "55-69" })[0].averageSquaredError) | Should Be 0.36
        (@($bands | Where-Object { $_.bucket -eq "70-84" })[0].averageSquaredError) | Should Be 0.04
    }

    It "25.4 JSONL com linhas invalidas e vazias nao quebra" {
        $fixture = New-EvaluateFixture -Name "broken" -Lines @(
            '{isto nao e json}',
            '',
            '{"analysisId":"f","direction":"BUY","outcome":"favorable","confidence":80}'
        )
        $report = Invoke-EvaluateFixture -Fixture $fixture

        $report.desfechos.sampleCount | Should Be 1
        $report.desfechos.invalidSampleCount | Should Be 0
        $report.desfechos.confidenceOutcomeError | Should Be 0.04
    }

    It "25.5 arquivo de desfechos inexistente fica sem amostra, nao quebra" {
        $dir = Join-Path $script:ZnxEvalTempRoot "missing"
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $fixture = [pscustomobject]@{
            Dir      = $dir
            Outcomes = (Join-Path $dir "nao-existe.jsonl")
            Report   = (Join-Path $dir "report\report.json")
        }
        $report = Invoke-EvaluateFixture -Fixture $fixture

        $report.desfechos.total | Should Be 0
        $report.desfechos.sampleCount | Should Be 0
        ($null -eq $report.desfechos.confidenceOutcomeError) | Should Be $true
        $bands = @($report.desfechos.confidenceOutcomeBands)
        $bands.Count | Should Be 4
        ($null -eq $bands[0].confidenceMean) | Should Be $true
        $calibration = @($report.desfechos.calibracao)
        (@($calibration | Where-Object { $_.faixa -eq "0-54" })[0].amostras) | Should Be 0
    }

    It "25.6 extremos 0, 0.5, 99.5 e 100 caem nas faixas certas pelo JSONL" {
        $fixture = New-EvaluateFixture -Name "extremes" -Lines @(
            '{"analysisId":"g","direction":"BUY","outcome":"favorable","confidence":0}',
            '{"analysisId":"h","direction":"BUY","outcome":"favorable","confidence":0.5}',
            '{"analysisId":"i","direction":"BUY","outcome":"favorable","confidence":99.5}',
            '{"analysisId":"j","direction":"BUY","outcome":"favorable","confidence":100}',
            '{"analysisId":"k","direction":"BUY","outcome":"favorable","confidence":null}',
            '{"analysisId":"l","direction":"BUY","outcome":"favorable","confidence":"oitenta"}'
        )
        $report = Invoke-EvaluateFixture -Fixture $fixture

        $report.desfechos.sampleCount | Should Be 4
        $report.desfechos.invalidSampleCount | Should Be 2
        $report.desfechos.confidenceOutcomeError | Should Be 0.4975
        $bands = @($report.desfechos.confidenceOutcomeBands)
        (@($bands | Where-Object { $_.bucket -eq "0-54" })[0].sampleCount) | Should Be 2
        (@($bands | Where-Object { $_.bucket -eq "85-100" })[0].sampleCount) | Should Be 2
        $empty = @($bands | Where-Object { $_.bucket -eq "70-84" })[0]
        $empty.sampleCount | Should Be 0
        ($null -eq $empty.averageSquaredError) | Should Be $true
        $calibration = @($report.desfechos.calibracao)
        (@($calibration | Where-Object { $_.faixa -eq "55-69" })[0].amostras) | Should Be 0
    }
}
