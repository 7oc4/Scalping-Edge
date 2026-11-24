$modulePath = Join-Path $PSScriptRoot "..\src\analysis-contract.psm1"
Import-Module $modulePath -Force -WarningAction SilentlyContinue
Add-Type -AssemblyName System.Net.Http

function New-TestHttpClient {
    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromSeconds(10)
    return $client
}

function Invoke-TestHttp {
    param(
        [string]$Uri,
        [string]$Method = "GET",
        [string]$Origin = $null,
        [string]$Body = $null,
        [string]$ContentType = "application/json",
        $Client = $null
    )
    $ownsClient = $null -eq $Client
    if ($ownsClient) { $Client = New-TestHttpClient }
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), $Uri)
    $response = $null
    try {
        if ($Origin) { [void]$request.Headers.TryAddWithoutValidation("Origin", $Origin) }
        if (-not [string]::IsNullOrWhiteSpace($Body)) {
            $request.Content = [System.Net.Http.StringContent]::new(
                $Body, [System.Text.Encoding]::UTF8, $ContentType
            )
        }
        $response = $Client.SendAsync($request).GetAwaiter().GetResult()
        $bodyText = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $contentType = if ($response.Content.Headers.ContentType) {
            $response.Content.Headers.ContentType.ToString()
        }
        else { "" }
        return [pscustomobject]@{
            Status      = [int]$response.StatusCode
            Body        = [string]$bodyText
            ContentType = [string]$contentType
        }
    }
    finally {
        if ($response) { $response.Dispose() }
        $request.Dispose()
        if ($ownsClient) { $Client.Dispose() }
    }
}

Describe "10. Rotas HTTP" {
    $script:ZnxBaseUrl = "http://127.0.0.1:8799"
    $savedKey = $env:OPENAI_API_KEY
    $savedPort = $env:ZNX_PORT
    $savedNoBrowser = $env:ZNX_NO_BROWSER
    $savedLogDir = $env:ZNX_LOG_DIR
    $savedOutcomesPath = $env:ZNX_OUTCOMES_PATH
    $serverProcess = $null
    $client = $null
    $tempLogDir = Join-Path $env:TEMP ("znx-logs-" + [guid]::NewGuid().ToString("N"))

    try {
        $env:OPENAI_API_KEY = $null
        $env:ZNX_PORT = "8799"
        $env:ZNX_NO_BROWSER = "1"
        New-Item -ItemType Directory -Path $tempLogDir -Force | Out-Null
        $env:ZNX_LOG_DIR = $tempLogDir
        # Desfechos de fixture: a API nao pode quebrar com confidence invalido
        # nem classificar registro invalido na faixa 0-54.
        $tempOutcomesPath = Join-Path $tempLogDir "outcomes.jsonl"
        [System.IO.File]::WriteAllLines(
            $tempOutcomesPath,
            @(
                '{"analysisId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","direction":"BUY","outcome":"favorable","confidence":null}',
                '{"analysisId":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","direction":"SELL","outcome":"adverse","confidence":"oitenta"}',
                '{"analysisId":"cccccccccccccccccccccccccccccccc","direction":"BUY","outcome":"favorable","confidence":80}',
                '{"analysisId":"dddddddddddddddddddddddddddddddd","direction":"BUY","outcome":"neutral","confidence":80}',
                '{"analysisId":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","direction":"SELL","outcome":"favorable","confidence":69.5}',
                '{"analysisId":"ffffffffffffffffffffffffffffffff","direction":"BUY","outcome":"adverse","confidence":0}',
                '{"analysisId":"11111111111111111111111111111111","direction":"BUY","outcome":"favorable","confidence":100}',
                '{"analysisId":"22222222222222222222222222222222","direction":"SELL","outcome":"adverse","confidence":0.5}'
            ),
            (New-Object System.Text.UTF8Encoding($false)))
        $env:ZNX_OUTCOMES_PATH = $tempOutcomesPath
        $serverScript = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\src\server.ps1")).Path
        $logOut = Join-Path $env:TEMP ("znx-server-" + [guid]::NewGuid().ToString("N") + ".out.log")
        $logErr = Join-Path $env:TEMP ("znx-server-" + [guid]::NewGuid().ToString("N") + ".err.log")
        $serverProcess = Start-Process -FilePath "powershell.exe" `
            -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$serverScript`"") `
            -PassThru -WindowStyle Hidden -RedirectStandardOutput $logOut -RedirectStandardError $logErr

        $client = New-TestHttpClient
        $ready = $false
        $lastProbeError = ""
        $lastProbeStatus = ""
        for ($attempt = 0; $attempt -lt 40; $attempt++) {
            try {
                $probe = Invoke-TestHttp -Uri "$script:ZnxBaseUrl/api/status" -Client $client
                $lastProbeStatus = [string]$probe.Status
                if ($probe.Status -eq 200) { $ready = $true; break }
            }
            catch {
                $lastProbeError = $_.Exception.Message
                Start-Sleep -Milliseconds 500
            }
        }
        if (-not $ready) {
            $outText = if (Test-Path $logOut) { Get-Content -Raw $logOut } else { "" }
            $errText = if (Test-Path $logErr) { Get-Content -Raw $logErr } else { "" }
            throw "Servidor de teste nao respondeu em $script:ZnxBaseUrl.`nSTDOUT: $outText`nSTDERR: $errText`nUltimo status: $lastProbeStatus`nUltimo erro: $lastProbeError"
        }

        It "10.1 /api/status responde 200 com o estado do servidor" {
            $response = Invoke-TestHttp -Uri "$script:ZnxBaseUrl/api/status" -Client $client
            $response.Status | Should Be 200
            $response.Body | Should Match '"running":true'
            $response.Body | Should Match '"modelAvailable":false'
        }

        It "10.2 index.html e servido com o formatador carregado antes do app" {
            $response = Invoke-TestHttp -Uri "$script:ZnxBaseUrl/" -Client $client
            $response.Status | Should Be 200
            $response.ContentType | Should Match "text/html"
            $response.Body | Should Match "assets/js/analysis-format.js"
            $response.Body.IndexOf("analysis-format.js") -lt $response.Body.IndexOf("assets/js/app.js") | Should Be $true
        }

        It "10.3 o formatador e servido como arquivo estatico" {
            $response = Invoke-TestHttp -Uri "$script:ZnxBaseUrl/assets/js/analysis-format.js" -Client $client
            $response.Status | Should Be 200
            $response.Body | Should Match "normalizeAnalysisPayload"
        }

        It "10.4 GET /api/analyze responde 405" {
            $response = Invoke-TestHttp -Uri "$script:ZnxBaseUrl/api/analyze" -Client $client
            $response.Status | Should Be 405
        }

        It "10.5 POST de origem estrangeira responde 403" {
            $response = Invoke-TestHttp -Uri "$script:ZnxBaseUrl/api/analyze" -Method "POST" `
                -Origin "http://evil.local" -Body "{}" -Client $client
            $response.Status | Should Be 403
        }

        It "10.6 POST sem JSON responde 415" {
            $response = Invoke-TestHttp -Uri "$script:ZnxBaseUrl/api/analyze" -Method "POST" `
                -Origin $script:ZnxBaseUrl -Body "{}" -ContentType "text/plain" -Client $client
            $response.Status | Should Be 415
        }

        It "10.7 POST valido sem chave responde 503 com mensagem clara" {
            $response = Invoke-TestHttp -Uri "$script:ZnxBaseUrl/api/analyze" -Method "POST" `
                -Origin $script:ZnxBaseUrl -Body "{}" -Client $client
            $response.Status | Should Be 503
            $response.Body | Should Match "chave"
        }

        It "10.8 servidor nao expoe arquivos fora da lista estatica" {
            $response = Invoke-TestHttp -Uri "$script:ZnxBaseUrl/server.ps1" -Client $client
            $response.Status | Should Be 404
        }

        It "10.9 corpo declarado acima do limite responde 413 sem ler a imagem" {
            $client413 = New-Object System.Net.Sockets.TcpClient
            try {
                $client413.Connect("127.0.0.1", 8799)
                $stream = $client413.GetStream()
                $writer = New-Object System.IO.StreamWriter($stream, [System.Text.Encoding]::ASCII)
                $writer.NewLine = "`r`n"
                $writer.WriteLine("POST /api/analyze HTTP/1.1")
                $writer.WriteLine("Host: 127.0.0.1:8799")
                $writer.WriteLine("Origin: http://127.0.0.1:8799")
                $writer.WriteLine("Content-Type: application/json")
                $writer.WriteLine("Content-Length: 20000000")
                $writer.WriteLine("Connection: close")
                $writer.WriteLine("")
                $writer.Flush()
                $reader = New-Object System.IO.StreamReader($stream)
                $rawResponse = $reader.ReadToEnd()
            }
            finally {
                $client413.Close()
            }
            $rawResponse | Should Match "413"
        }

        It "10.10 GET /api/feedback responde 405" {
            $response = Invoke-TestHttp -Uri "$script:ZnxBaseUrl/api/feedback" -Client $client
            $response.Status | Should Be 405
        }

        It "10.11 feedback de origem estrangeira responde 403" {
            $response = Invoke-TestHttp -Uri "$script:ZnxBaseUrl/api/feedback" -Method "POST" `
                -Origin "http://evil.local" -Body '{"analysisId":"0123456789abcdef0123456789abcdef","verdict":"hit"}' -Client $client
            $response.Status | Should Be 403
        }

        It "10.12 feedback com veredito invalido responde 400" {
            $body = ConvertTo-Json -Compress -InputObject @{
                analysisId = "0123456789abcdef0123456789abcdef"
                verdict    = "talvez"
            }
            $response = Invoke-TestHttp -Uri "$script:ZnxBaseUrl/api/feedback" -Method "POST" `
                -Origin $script:ZnxBaseUrl -Body $body -Client $client
            $response.Status | Should Be 400
            $response.Body | Should Match "Veredito invalido"
        }

        It "10.13 feedback valido responde 200 e grava em JSONL" {
            $body = ConvertTo-Json -Compress -InputObject @{
                analysisId = "0123456789abcdef0123456789abcdef"
                verdict    = "invented_level"
            }
            $response = Invoke-TestHttp -Uri "$script:ZnxBaseUrl/api/feedback" -Method "POST" `
                -Origin $script:ZnxBaseUrl -Body $body -Client $client
            $response.Status | Should Be 200
            $response.Body | Should Match '"ok":true'
            $feedbackPath = Join-Path $tempLogDir "feedback.jsonl"
            (Test-Path -LiteralPath $feedbackPath) | Should Be $true
            $written = [System.IO.File]::ReadAllText($feedbackPath)
            $written | Should Match '"verdict":"invented_level"'
            $written | Should Match '"analysisId":"0123456789abcdef0123456789abcdef"'
        }

        It "10.14 /api/backtest sem ativo responde 400" {
            $response = Invoke-TestHttp -Uri "$script:ZnxBaseUrl/api/backtest" -Client $client
            $response.Status | Should Be 400
            $response.Body | Should Match "Informe o ativo"
        }

        It "10.15 /api/plan com ativo fora da lista responde 400" {
            $response = Invoke-TestHttp -Uri "$script:ZnxBaseUrl/api/plan?symbol=NAOEXISTE" -Client $client
            $response.Status | Should Be 400
            $response.Body | Should Match "fora da lista"
        }

        It "10.16 POST /api/market responde 405" {
            $response = Invoke-TestHttp -Uri "$script:ZnxBaseUrl/api/market" -Method "POST" `
                -Body "{}" -Client $client
            $response.Status | Should Be 405
        }

        It "10.17 radar.js e servido como arquivo estatico" {
            $response = Invoke-TestHttp -Uri "$script:ZnxBaseUrl/assets/js/radar.js" -Client $client
            $response.Status | Should Be 200
            $response.Body | Should Match "Radar de mercado"
        }

        It "10.18 conexao abortada pelo cliente nao derruba o servidor" {
            # Preconnect do navegador e aba fechada no meio do polling abrem e
            # matam o socket. Antes isso propagava a excecao de escrita e
            # encerrava o servidor inteiro.
            for ($i = 0; $i -lt 8; $i++) {
                $tcp = [System.Net.Sockets.TcpClient]::new()
                try {
                    $tcp.Connect("127.0.0.1", 8799)
                    if ($i % 2 -eq 0) {
                        $stream = $tcp.GetStream()
                        $bytes = [System.Text.Encoding]::ASCII.GetBytes(
                            "GET /api/status HTTP/1.1`r`nHost: 127.0.0.1:8799`r`n"
                        )
                        $stream.Write($bytes, 0, $bytes.Length)
                        $stream.Flush()
                    }
                    $tcp.Client.LingerState = [System.Net.Sockets.LingerOption]::new($true, 0)
                }
                finally {
                    $tcp.Close()
                }
            }
            Start-Sleep -Milliseconds 400
            $response = Invoke-TestHttp -Uri "$script:ZnxBaseUrl/api/status" -Client $client
            $response.Status | Should Be 200
            $response = Invoke-TestHttp -Uri "$script:ZnxBaseUrl/pages/radar.html" -Client $client
            $response.Status | Should Be 200
        }

        It "10.19 /api/calibration expoe o erro de consistencia sem inventar amostra" {
            $response = Invoke-TestHttp -Uri "$script:ZnxBaseUrl/api/calibration" -Client $client
            $response.Status | Should Be 200
            $data = $response.Body | ConvertFrom-Json
            ($null -eq $data.sampleCount) | Should Be $false
            ([int]$data.sampleCount -ge 0) | Should Be $true
            $data.confidenceOutcomeBands.Count | Should Be 4
            ($null -eq $data.brierScore) | Should Be $true
            if ([int]$data.sampleCount -eq 0) {
                ($null -eq $data.confidenceOutcomeError) | Should Be $true
            }
        }

        It "10.20 /api/calibration ignora invalido e poe 69,5 na mesma faixa do relatorio" {
            $response = Invoke-TestHttp -Uri "$script:ZnxBaseUrl/api/calibration" -Client $client
            $response.Status | Should Be 200
            $data = $response.Body | ConvertFrom-Json
            [int]$data.sampleCount | Should Be 5
            [int]$data.invalidSampleCount | Should Be 2
            [double]$data.confidenceOutcomeError | Should Be 0.0266
            $bands = @($data.confidenceOutcomeBands)
            $bands.Count | Should Be 4
            $low = @($bands | Where-Object { $_.bucket -eq "0-54" })[0]
            [int]$low.sampleCount | Should Be 2
            ($null -eq $low.favorableRate) | Should Be $false
            $mid = @($bands | Where-Object { $_.bucket -eq "55-69" })[0]
            [int]$mid.sampleCount | Should Be 1
            [double]$mid.confidenceMean | Should Be 69.5
            $high = @($bands | Where-Object { $_.bucket -eq "85-100" })[0]
            [int]$high.sampleCount | Should Be 1
            [double]$high.confidenceMean | Should Be 100
            [int](@($data.buckets | Where-Object { $_.bucket -eq "0-54" })[0].outcomeSamples) | Should Be 2
            [int](@($data.buckets | Where-Object { $_.bucket -eq "55-69" })[0].outcomeSamples) | Should Be 1
            [int](@($data.buckets | Where-Object { $_.bucket -eq "85-100" })[0].outcomeSamples) | Should Be 1
        }

        It "10.21 evaluate e /api/calibration concordam na mesma fixture temporaria" {
            $evaluateScript = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\tools\evaluate.ps1")).Path
            $reportPath = Join-Path $tempLogDir "eval\report.json"
            & $evaluateScript -AnalysesPath (Join-Path $tempLogDir "analyses.jsonl") `
                -FeedbackPath (Join-Path $tempLogDir "feedback.jsonl") `
                -OutcomesPath $tempOutcomesPath `
                -OutDir (Join-Path $tempLogDir "eval") 3>$null 6>$null
            (Test-Path -LiteralPath $reportPath) | Should Be $true
            $report = [System.IO.File]::ReadAllText($reportPath) | ConvertFrom-Json
            $response = Invoke-TestHttp -Uri "$script:ZnxBaseUrl/api/calibration" -Client $client
            $response.Status | Should Be 200
            $data = $response.Body | ConvertFrom-Json

            [int]$report.desfechos.sampleCount | Should Be ([int]$data.sampleCount)
            [int]$report.desfechos.invalidSampleCount | Should Be ([int]$data.invalidSampleCount)
            "$($report.desfechos.confidenceOutcomeError)" | Should Be "$($data.confidenceOutcomeError)"

            $evalBands = @($report.desfechos.confidenceOutcomeBands)
            $apiBands = @($data.confidenceOutcomeBands)
            $evalBands.Count | Should Be $apiBands.Count
            foreach ($band in $apiBands) {
                $mine = @($evalBands | Where-Object { $_.bucket -eq $band.bucket })[0]
                [int]$mine.sampleCount | Should Be ([int]$band.sampleCount)
                "$($mine.confidenceMean)" | Should Be "$($band.confidenceMean)"
                "$($mine.favorableRate)" | Should Be "$($band.favorableRate)"
                "$($mine.averageSquaredError)" | Should Be "$($band.averageSquaredError)"
            }

            foreach ($bucket in @($data.buckets)) {
                $mine = @($report.desfechos.calibracao | Where-Object { $_.faixa -eq $bucket.bucket })[0]
                [int]$mine.amostras | Should Be ([int]$bucket.outcomeSamples)
            }
        }
    }
    finally {
        if ($client) { $client.Dispose() }
        if ($serverProcess -and -not $serverProcess.HasExited) {
            Stop-Process -Id $serverProcess.Id -Force -ErrorAction SilentlyContinue
            $serverProcess.WaitForExit(5000) | Out-Null
        }
        foreach ($logFile in @($logOut, $logErr)) {
            if ($logFile -and (Test-Path $logFile)) { Remove-Item -LiteralPath $logFile -ErrorAction SilentlyContinue }
        }
        $env:OPENAI_API_KEY = $savedKey
        if ($null -eq $savedPort) { Remove-Item Env:\ZNX_PORT -ErrorAction SilentlyContinue } else { $env:ZNX_PORT = $savedPort }
        if ($null -eq $savedNoBrowser) { Remove-Item Env:\ZNX_NO_BROWSER -ErrorAction SilentlyContinue } else { $env:ZNX_NO_BROWSER = $savedNoBrowser }
        if ($null -eq $savedLogDir) { Remove-Item Env:\ZNX_LOG_DIR -ErrorAction SilentlyContinue } else { $env:ZNX_LOG_DIR = $savedLogDir }
        if ($null -eq $savedOutcomesPath) { Remove-Item Env:\ZNX_OUTCOMES_PATH -ErrorAction SilentlyContinue } else { $env:ZNX_OUTCOMES_PATH = $savedOutcomesPath }
        if ($tempLogDir -and (Test-Path -LiteralPath $tempLogDir)) {
            Remove-Item -LiteralPath $tempLogDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
