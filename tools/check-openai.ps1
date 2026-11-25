# Verifica a conexao e o modelo da OpenAI SEM gastar creditos: consulta
# GET /v1/models/<modelo>, que nao gera tokens. Nao imprime a chave.
#
#   ./tools/check-openai.ps1
#   ./tools/check-openai.ps1 -Model gpt-4o-mini
#   ./tools/check-openai.ps1 -ListModels
#
# Codigo de saida 0 = modelo disponivel; 1 = qualquer outro estado.

param(
  [string]$Model = $env:OPENAI_MODEL,
  [string]$BaseUrl = $env:OPENAI_BASE_URL,
  [switch]$ListModels
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "..\src\analysis-contract.psm1") -Force

if (-not $Model) { $Model = "gpt-5.6-luna" }
if (-not $BaseUrl) { $BaseUrl = "https://api.openai.com/v1" }
$BaseUrl = $BaseUrl.TrimEnd("/")

if (-not $env:OPENAI_API_KEY) {
  Write-Host "OPENAI_API_KEY nao esta definida. Defina a variavel e rode de novo." -ForegroundColor Yellow
  exit 1
}

$profile = Get-OpenAIModelProfile -Model $Model `
  -OutputTokens $(if ($env:OPENAI_MAX_TOKENS) { [int]$env:OPENAI_MAX_TOKENS } else { 4000 }) `
  -ReasoningEffort $(if ($env:OPENAI_REASONING_EFFORT) { $env:OPENAI_REASONING_EFFORT } else { "low" })

Write-Host "Modelo:            $($profile.model)"
Write-Host "Familia:           $($profile.family)"
Write-Host "Limite de saida:   $($profile.tokenParameter) = $($profile.maxOutputTokens)"
Write-Host "Temperature:       $(if ($profile.supportsTemperature) { '0.0' } else { 'nao enviada (modelo de raciocinio)' })"
Write-Host "Esforco:           $(if ($profile.reasoningEffort) { $profile.reasoningEffort } else { 'nao se aplica' })"
Write-Host "Structured output: $(if ($profile.supportsStructuredOutputs) { 'json_schema strict' } else { 'nao suportado' })"
if (-not $profile.reasoningEffortValid) {
  Write-Host "Aviso: OPENAI_REASONING_EFFORT='$($profile.reasoningEffortRequested)' nao e aceito; sera usado '$($profile.reasoningEffort)'." -ForegroundColor Yellow
}

Add-Type -AssemblyName System.Net.Http
$client = [System.Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromSeconds(15)
$request = $null
$response = $null
try {
  $request = [System.Net.Http.HttpRequestMessage]::new(
    [System.Net.Http.HttpMethod]::Get, "$BaseUrl/models/$($profile.model)")
  $request.Headers.Authorization =
    [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $env:OPENAI_API_KEY)
  $response = $client.SendAsync($request).GetAwaiter().GetResult()
  $status = [int]$response.StatusCode
  $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()

  if ($status -ge 200 -and $status -lt 300) {
    Write-Host "OK: o modelo responde na sua conta (HTTP $status)." -ForegroundColor Green
    exit 0
  }
  if ($status -eq 401) {
    Write-Host "Chave recusada (HTTP 401). Confira OPENAI_API_KEY." -ForegroundColor Red
    exit 1
  }
  if ($status -eq 404) {
    Write-Host "Modelo indisponivel para esta chave (HTTP 404)." -ForegroundColor Red
    Write-Host "Use OPENAI_MODEL=gpt-4o-mini ou peca acesso a $($profile.model)."
  }
  elseif ($status -eq 429 -or $status -ge 500) {
    Write-Host "OpenAI instavel ou com limite temporario (HTTP $status)." -ForegroundColor Yellow
  }
  else {
    $detail = (Hide-SensitiveDiagnostic -Text $body -ApiKey $env:OPENAI_API_KEY)
    if ($detail.Length -gt 200) { $detail = $detail.Substring(0, 200) + "..." }
    Write-Host "Falha HTTP $status. Detalhe: $detail" -ForegroundColor Red
  }

  if ($ListModels) {
    Write-Host ""
    Write-Host "Modelos visiveis para esta chave:"
    $listRequest = $null
    $listResponse = $null
    try {
      $listRequest = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::Get, "$BaseUrl/models")
      $listRequest.Headers.Authorization =
        [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $env:OPENAI_API_KEY)
      $listResponse = $client.SendAsync($listRequest).GetAwaiter().GetResult()
      if ([int]$listResponse.StatusCode -eq 200) {
        $payload = $listResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
        foreach ($entry in @($payload.data | Sort-Object id | Select-Object -First 40)) {
          Write-Host "  $($entry.id)"
        }
      }
      else {
        Write-Host "  (a lista de modelos respondeu HTTP $([int]$listResponse.StatusCode))"
      }
    }
    finally {
      if ($listResponse) { $listResponse.Dispose() }
      if ($listRequest) { $listRequest.Dispose() }
    }
  }
  exit 1
}
catch {
  $message = Hide-SensitiveDiagnostic -Text $_.Exception.Message -ApiKey $env:OPENAI_API_KEY
  Write-Host "Sem resposta da OpenAI: $message" -ForegroundColor Red
  exit 1
}
finally {
  if ($response) { $response.Dispose() }
  if ($request) { $request.Dispose() }
  $client.Dispose()
}
