# Servidor falso da OpenAI para verificacao local da integracao.
#
# NAO simula sucesso de analise: o modo padrao devolve 404 model_not_found,
# que e o erro real de "modelo indisponivel para esta chave". Serve para
# conferir, sem rede e sem creditos, QUAL corpo o servidor monta em cada
# familia de modelo e se o fallback dispara.
#
#   powershell -File tests/fixtures/mock-openai.ps1 -Port 8795 -Mode model-missing -RecordPath req.jsonl

param(
  [int]$Port = 8795,
  [ValidateSet("model-missing", "truncated", "models-ok")]
  [string]$Mode = "model-missing",
  [string]$RecordPath = ""
)

Add-Type -AssemblyName System.Net.Http
$utf8 = [System.Text.Encoding]::UTF8
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
try {
  while ($listener.IsListening) {
    $context = $listener.GetContext()
    $request = $context.Request
    $body = ""
    try {
      if ($request.HasEntityBody) {
        $reader = [System.IO.StreamReader]::new($request.InputStream, $utf8)
        $body = $reader.ReadToEnd()
        $reader.Dispose()
      }
      if ($RecordPath) {
        $entry = [ordered]@{
          method = $request.HttpMethod
          path   = $request.Url.AbsolutePath
          auth   = [string]$request.Headers["Authorization"]
          body   = $body
        }
        Add-Content -LiteralPath $RecordPath `
          -Value (ConvertTo-Json -InputObject $entry -Depth 6 -Compress) -Encoding UTF8
      }

      $status = 200
      $payload = '{"object":"list","data":[]}'
      if ($request.Url.AbsolutePath -like "*/chat/completions") {
        switch ($Mode) {
          "model-missing" {
            $status = 404
            $payload = '{"error":{"message":"The model `x` does not exist","type":"invalid_request_error","param":"model","code":"model_not_found"}}'
          }
          "truncated" {
            # Resposta cortada, conteudo vazio: e o caso real de um modelo de
            # raciocinio que gastou o orcamento pensando. Nao e analise valida.
            $status = 200
            $payload = '{"id":"mock","object":"chat.completion","choices":[{"index":0,"finish_reason":"length","message":{"role":"assistant","content":""}}],"usage":{"prompt_tokens":10,"completion_tokens":2}}'
          }
          default {
            $status = 500
            $payload = '{"error":{"message":"mock sem resposta de analise"}}'
          }
        }
      }
      $bytes = $utf8.GetBytes($payload)
      $context.Response.StatusCode = $status
      $context.Response.ContentType = "application/json"
      $context.Response.ContentLength64 = $bytes.Length
      $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    }
    catch { }
    finally { try { $context.Response.Close() } catch { } }
  }
}
finally {
  $listener.Stop()
  $listener.Close()
}
