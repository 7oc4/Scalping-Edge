$ErrorActionPreference = "Stop"

$secureKey = $null
$keyPointer = [IntPtr]::Zero
if (-not $env:OPENAI_API_KEY) {
  Write-Host "O servidor esta aguardando sua chave da API OpenAI."
  Write-Host "Cole a chave e pressione Enter. Os caracteres nao aparecem na tela por seguranca."
  Write-Host "Crie uma chave em https://platform.openai.com/api-keys."
  while (-not $env:OPENAI_API_KEY) {
    $secureKey = Read-Host "Chave OpenAI (entrada oculta)" -AsSecureString
    try {
      if ($secureKey.Length -eq 0) {
        Write-Warning "Nenhuma chave foi informada. Cole a chave da OpenAI para continuar."
        continue
      }

      $keyPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
      $env:OPENAI_API_KEY = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($keyPointer).Trim()
      if (-not $env:OPENAI_API_KEY) {
        Write-Warning "A chave informada está vazia. Tente novamente."
      }
    }
    finally {
      if ($keyPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($keyPointer)
        $keyPointer = [IntPtr]::Zero
      }
      if ($secureKey) {
        $secureKey.Dispose()
        $secureKey = $null
      }
    }
  }
}

$scriptPath = Join-Path $PSScriptRoot "server.ps1"
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
  throw "Não foi possível encontrar server.ps1 em $PSScriptRoot."
}

$global:RestartRequested = $false
$global:OpenBrowserOnStart = $true
$cancelKeyHandler = [System.ConsoleCancelEventHandler]{
  param($sender, $eventArgs)
  $eventArgs.Cancel = $true
}
[Console]::add_CancelKeyPress($cancelKeyHandler)

try {
  do {
    $global:RestartRequested = $false
    & $scriptPath
  } while ($global:RestartRequested)
}
finally {
  [Console]::remove_CancelKeyPress($cancelKeyHandler)
}
