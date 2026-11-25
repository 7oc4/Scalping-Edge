<#
    Testes da integracao OpenAI do Scalping Edge.
    Compativel com Pester 3.4.

    Tres niveis, sem misturar:
      27.x  unitarios      - perfil do modelo, corpo da requisicao, schema,
                             deteccao de erro e redacao de chave. Nao usam rede.
      28.x  com mock       - transporte simulado devolve 200/400/401/429/5xx e
                             timeout. Sem rede, sem chave real, sem creditos.
      A chamada real (integracao) fica fora do npm test: use
      `./tools/check-openai.ps1` com a sua OPENAI_API_KEY.
#>

$modulePath = Join-Path $PSScriptRoot "..\src\analysis-contract.psm1"
Import-Module $modulePath -Force -WarningAction SilentlyContinue

function New-TestChatBody {
    param(
        [string]$Model = "gpt-5.6-luna",
        [string]$Effort = "low",
        [int]$Tokens = 4000
    )
    return New-OpenAIChatRequestBody -Model $Model -SystemPrompt "prompt de sistema" `
        -UserPrompt "prompt do usuario" -MimeType "image/png" -ImageData "QUJD" `
        -ImageDetail "high" -OutputTokens $Tokens -ReasoningEffort $Effort
}

function New-MockTransport {
    # $Responses e uma lista de @{ Status = 429; Body = "..." } ou
    # @{ Throw = "mensagem" }. Cada tentativa consome a proxima entrada; a
    # ultima se repete quando houver mais tentativas que respostas.
    param([object[]]$Responses)
    $responses = @($Responses)
    $transport = {
        param($JsonBody, $Attempt)
        $entry = $responses[[Math]::Min($Attempt - 1, $responses.Count - 1)]
        if ($entry.ContainsKey("Throw")) { throw $entry["Throw"] }
        return @{ StatusCode = [int]$entry["Status"]; Body = [string]$entry["Body"] }
    }
    # GetNewClosure congela $responses no scriptblock; sem isso a variavel some
    # quando a funcao retorna e o transporte devolve vazio.
    return $transport.GetNewClosure()
}

Describe "27. Compatibilidade da integracao OpenAI (unitarios)" {

    It "27.1 reconhece modelos de raciocinio pelo id, sem lista fixa" {
        (Test-OpenAIReasoningModel -Model "gpt-5.6-luna") | Should Be $true
        (Test-OpenAIReasoningModel -Model "gpt-5.5") | Should Be $true
        (Test-OpenAIReasoningModel -Model "gpt-6-astra") | Should Be $true
        (Test-OpenAIReasoningModel -Model "o3-mini") | Should Be $true
        (Test-OpenAIReasoningModel -Model "gpt-4o-mini") | Should Be $false
        (Test-OpenAIReasoningModel -Model "gpt-4.1") | Should Be $false
        (Test-OpenAIReasoningModel -Model "") | Should Be $false
    }

    It "27.2 perfil do gpt-5.6-luna: max_completion_tokens, sem temperature" {
        $profile = Get-OpenAIModelProfile -Model "gpt-5.6-luna" -OutputTokens 4000 `
            -ReasoningEffort "low"
        $profile.tokenParameter | Should Be "max_completion_tokens"
        $profile.family | Should Be "reasoning"
        $profile.supportsTemperature | Should Be $false
        ($null -eq $profile.temperature) | Should Be $true
        $profile.reasoningEffort | Should Be "low"
        $profile.supportsStructuredOutputs | Should Be $true
        $profile.maxOutputTokens | Should Be 4000
    }

    It "27.3 perfil do gpt-4o-mini mantem temperature 0 e max_tokens" {
        $profile = Get-OpenAIModelProfile -Model "gpt-4o-mini" -OutputTokens 4000
        $profile.tokenParameter | Should Be "max_tokens"
        $profile.family | Should Be "classic"
        $profile.supportsTemperature | Should Be $true
        [double]$profile.temperature | Should Be 0.0
        ($null -eq $profile.reasoningEffort) | Should Be $true
    }

    It "27.4 esforco invalido cai no padrao e fica sinalizado" {
        $invalid = Get-OpenAIModelProfile -Model "gpt-5.6-luna" -ReasoningEffort "turbo"
        $invalid.reasoningEffort | Should Be "low"
        $invalid.reasoningEffortValid | Should Be $false
        $invalid.reasoningEffortRequested | Should Be "turbo"

        $valid = Get-OpenAIModelProfile -Model "gpt-5.6-luna" -ReasoningEffort "high"
        $valid.reasoningEffort | Should Be "high"
        $valid.reasoningEffortValid | Should Be $true

        @(Get-OpenAIReasoningEfforts) -contains "xhigh" | Should Be $true
        @(Get-OpenAIReasoningEfforts) -contains "turbo" | Should Be $false
    }

    It "27.5 corpo do gpt-5.6-luna nao envia parametro recusado" {
        $built = New-TestChatBody
        $body = $built.Body
        ($body.Contains("temperature")) | Should Be $false
        ($body.Contains("max_tokens")) | Should Be $false
        ($body.Contains("max_completion_tokens")) | Should Be $true
        $body["max_completion_tokens"] | Should Be 4000
        $body["reasoning_effort"] | Should Be "low"
        $body["model"] | Should Be "gpt-5.6-luna"
        $body["store"] | Should Be $false
        $body["response_format"]["type"] | Should Be "json_schema"
        $body["response_format"]["json_schema"]["strict"] | Should Be $true
        $body["messages"][0]["role"] | Should Be "system"
        $body["messages"][1]["content"][0]["type"] | Should Be "text"
        $body["messages"][1]["content"][1]["image_url"]["detail"] | Should Be "high"
        $body["messages"][1]["content"][1]["image_url"]["url"] | Should Match "^data:image/png;base64,QUJD$"
    }

    It "27.6 corpo do gpt-4o-mini mantem exatamente o formato anterior" {
        $built = New-TestChatBody -Model "gpt-4o-mini"
        $body = $built.Body
        $body.Contains("temperature") | Should Be $true
        [double]$body["temperature"] | Should Be 0.0
        $body["max_tokens"] | Should Be 4000
        ($body.Contains("max_completion_tokens")) | Should Be $false
        ($body.Contains("reasoning_effort")) | Should Be $false
        $body["response_format"]["json_schema"]["strict"] | Should Be $true
    }

    It "27.7 o schema enviado e o do contrato, fechado e completo" {
        $built = New-TestChatBody
        $schema = $built.Body["response_format"]["json_schema"]["schema"]
        $fields = @(Get-AnalysisContractFields)
        $schema.additionalProperties | Should Be $false
        @($schema.required).Count | Should Be $fields.Count
        foreach ($field in $fields) {
            (@($schema.required) -contains $field) | Should Be $true
            ($null -eq $schema.properties[$field]) | Should Be $false
        }
    }

    It "27.8 resposta cortada grava o parametro de tokens certo em cada familia" {
        $luna = New-TestChatBody
        $applied = Set-OpenAIChatRequestBodyTokenLimit -Body $luna.Body `
            -Profile $luna.Profile -Limit 16000
        $applied | Should Be 16000
        $luna.Body["max_completion_tokens"] | Should Be 16000
        ($luna.Body.Contains("max_tokens")) | Should Be $false

        $mini = New-TestChatBody -Model "gpt-4o-mini"
        [void](Set-OpenAIChatRequestBodyTokenLimit -Body $mini.Body `
            -Profile $mini.Profile -Limit 9000)
        $mini.Body["max_tokens"] | Should Be 9000
        ($mini.Body.Contains("max_completion_tokens")) | Should Be $false

        # O limite nunca passa do maximo do modelo nem some abaixo do minimo.
        $clamped = New-TestChatBody
        (Set-OpenAIChatRequestBodyTokenLimit -Body $clamped.Body `
            -Profile $clamped.Profile -Limit 500000) | Should Be 128000
    }

    It "27.9 corpo da requisicao nao carrega chave nem cabecalho de autenticacao" {
        $json = ConvertTo-Json -InputObject (New-TestChatBody).Body -Depth 20 -Compress
        ($json -match "sk-[A-Za-z0-9]") | Should Be $false
        ($json -match "(?i)authorization|bearer") | Should Be $false
    }

    It "27.10 so erro de modelo inexistente libera a troca de modelo" {
        (Test-OpenAIModelMissingError -StatusCode 404 -Body "") | Should Be $true
        (Test-OpenAIModelMissingError -StatusCode 400 -Body '{"error":{"code":"model_not_found"}}') | Should Be $true
        (Test-OpenAIModelMissingError -StatusCode 400 -Body '{"error":{"message":"The model `x` does not exist"}}') | Should Be $true
        (Test-OpenAIModelMissingError -StatusCode 400 -Body '{"error":{"message":"Invalid image"}}') | Should Be $false
        (Test-OpenAIModelMissingError -StatusCode 401 -Body "model_not_found") | Should Be $false
        (Test-OpenAIModelMissingError -StatusCode 429 -Body "model_not_found") | Should Be $false
        (Test-OpenAIModelMissingError -StatusCode 500 -Body "model_not_found") | Should Be $false
    }

    It "27.11 a chave e removida de qualquer diagnostico" {
        $key = "sk-teste-1234567890abcdef"
        (Hide-SensitiveDiagnostic -Text "chave $key recusada" -ApiKey $key) | Should Not Match "sk-teste"
        (Hide-SensitiveDiagnostic -Text "outra $key solta" -ApiKey "") | Should Not Match "sk-teste"
        (Hide-SensitiveDiagnostic -Text "Authorization: Bearer abc.def" -ApiKey "") |
            Should Match "Bearer \[oculto\]"
        (Hide-SensitiveDiagnostic -Text $null -ApiKey "") | Should Be ""
    }
}

Describe "28. Chamada OpenAI com transporte simulado (sem rede e sem creditos)" {

    It "28.1 200 devolve sucesso na primeira tentativa" {
        $transport = New-MockTransport -Responses @(
            @{ Status = 200; Body = '{"choices":[{"message":{"content":"{}"}}]}' }
        )
        $result = Invoke-OpenAIChatCompletion -JsonBody "{}" -ApiKey "sk-teste" `
            -MaxRetries 1 -Transport $transport -RetryBackoffBaseMs 0 3>$null
        $result.Success | Should Be $true
        $result.StatusCode | Should Be 200
        $result.Attempts | Should Be 1
    }

    It "28.2 400 de parametro nao e repetido" {
        $transport = New-MockTransport -Responses @(
            @{ Status = 400; Body = '{"error":{"message":"Unsupported parameter"}}' }
        )
        $result = Invoke-OpenAIChatCompletion -JsonBody "{}" -ApiKey "sk-teste" `
            -MaxRetries 2 -Transport $transport -RetryBackoffBaseMs 0 3>$null
        $result.Success | Should Be $false
        $result.StatusCode | Should Be 400
        $result.Attempts | Should Be 1
    }

    It "28.3 401 nao e repetido" {
        $transport = New-MockTransport -Responses @(
            @{ Status = 401; Body = '{"error":{"message":"Incorrect API key"}}' }
        )
        $result = Invoke-OpenAIChatCompletion -JsonBody "{}" -ApiKey "sk-teste" `
            -MaxRetries 2 -Transport $transport -RetryBackoffBaseMs 0 3>$null
        $result.Success | Should Be $false
        $result.StatusCode | Should Be 401
        $result.Attempts | Should Be 1
    }

    It "28.4 429 e repetido uma vez e desiste" {
        $transport = New-MockTransport -Responses @(
            @{ Status = 429; Body = '{"error":{"message":"rate limit"}}' }
        )
        $result = Invoke-OpenAIChatCompletion -JsonBody "{}" -ApiKey "sk-teste" `
            -MaxRetries 1 -Transport $transport -RetryBackoffBaseMs 0 3>$null
        $result.Success | Should Be $false
        $result.StatusCode | Should Be 429
        $result.Attempts | Should Be 2
    }

    It "28.5 500 transitorio se recupera na terceira tentativa" {
        $transport = New-MockTransport -Responses @(
            @{ Status = 500; Body = "erro interno" },
            @{ Status = 500; Body = "erro interno" },
            @{ Status = 200; Body = '{"choices":[]}' }
        )
        $result = Invoke-OpenAIChatCompletion -JsonBody "{}" -ApiKey "sk-teste" `
            -MaxRetries 2 -Transport $transport -RetryBackoffBaseMs 0 3>$null
        $result.Success | Should Be $true
        $result.StatusCode | Should Be 200
        $result.Attempts | Should Be 3
    }

    It "28.6 503 persiste e volta como falha explicita" {
        $transport = New-MockTransport -Responses @(
            @{ Status = 503; Body = '{"error":{"message":"overloaded"}}' }
        )
        $result = Invoke-OpenAIChatCompletion -JsonBody "{}" -ApiKey "sk-teste" `
            -MaxRetries 1 -Transport $transport -RetryBackoffBaseMs 0 3>$null
        $result.Success | Should Be $false
        $result.StatusCode | Should Be 503
        $result.Attempts | Should Be 2
    }

    It "28.7 timeout vira status 0 e nao vaza a chave" {
        $transport = New-MockTransport -Responses @(
            @{ Throw = "A tarefa foi cancelada (timeout). chave sk-teste-secreta" }
        )
        $result = Invoke-OpenAIChatCompletion -JsonBody "{}" -ApiKey "sk-teste-secreta" `
            -MaxRetries 0 -Transport $transport -RetryBackoffBaseMs 0 3>$null
        $result.Success | Should Be $false
        $result.StatusCode | Should Be 0
        ($result.Body -match "timeout") | Should Be $true
        ($result.Body -match "sk-teste-secreta") | Should Be $false
        ($result.Error -match "sk-teste-secreta") | Should Be $false
    }

    It "28.9 o cliente HttpClient injetado sobrevive a duas chamadas seguidas" {
        # Regressao real: HttpClient.Timeout nao pode ser atribuido depois da
        # primeira requisicao. Atribuir a cada chamada quebrava a segunda
        # analise (e a releitura) no servidor, que reutiliza o cliente.
        $client = [System.Net.Http.HttpClient]::new()
        $client.Timeout = [TimeSpan]::FromSeconds(5)
        try {
            $first = Invoke-OpenAIChatCompletion -JsonBody "{}" `
                -Endpoint "http://127.0.0.1:1/v1/chat/completions" -ApiKey "sk-teste" `
                -MaxRetries 0 -Client $client -TimeoutSeconds 5 3>$null
            $second = Invoke-OpenAIChatCompletion -JsonBody "{}" `
                -Endpoint "http://127.0.0.1:1/v1/chat/completions" -ApiKey "sk-teste" `
                -MaxRetries 0 -Client $client -TimeoutSeconds 5 3>$null
            $first.Success | Should Be $false
            $second.Success | Should Be $false
            $second.StatusCode | Should Be 0
        }
        finally { $client.Dispose() }
    }

    It "28.8 troca para o modelo alternativo muda o corpo e a chave de cache" {
        $primary = New-OpenAIChatRequestBody -Model "gpt-5.6-luna" `
            -SystemPrompt "s" -UserPrompt "u" -MimeType "image/png" -ImageData "QUJD"
        $fallback = New-OpenAIChatRequestBody -Model "gpt-4o-mini" `
            -SystemPrompt "s" -UserPrompt "u" -MimeType "image/png" -ImageData "QUJD"
        ($primary.Body.Contains("max_completion_tokens")) | Should Be $true
        ($primary.Body.Contains("temperature")) | Should Be $false
        ($fallback.Body.Contains("max_tokens")) | Should Be $true
        ($fallback.Body.Contains("max_completion_tokens")) | Should Be $false

        $keyPrimary = Get-AnalysisCacheKey -ImageData "QUJD" -Market "crypto" -Asset "BTC" `
            -Timeframe "5m" -Model "gpt-5.6-luna"
        $keyFallback = Get-AnalysisCacheKey -ImageData "QUJD" -Market "crypto" -Asset "BTC" `
            -Timeframe "5m" -Model "gpt-4o-mini"
        ($keyPrimary -eq $keyFallback) | Should Be $false
    }
}
