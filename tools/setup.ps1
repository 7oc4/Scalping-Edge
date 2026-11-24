#Requires -Version 5.1
<#
.SYNOPSIS
    Setup automatizado e validação do Scalping Edge.
.DESCRIPTION
    Verifica pré-requisitos, corrige problemas comuns e roda todos os testes.
    Sem intervenção manual.
#>

$ErrorActionPreference = "Stop"
# setup.ps1 fica em tools
$script:Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$script:HasIssues  = $false
$script:HasFixes   = $false
$script:TestPassed = 0
$script:TestFailed = 0

# =====================================================================
# OUTPUT HELPERS (com fallback para console sem cor)
# =====================================================================
function Write-Header([string]$Text) {
    Write-Host ""
    Write-Host "================================================" -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host "================================================" -ForegroundColor Cyan
}

function Write-OK([string]$Text) {
    Write-Host "  [OK] $Text" -ForegroundColor Green
}

function Write-Warn([string]$Text) {
    Write-Host "  [!]  $Text" -ForegroundColor Yellow
    $script:HasIssues = $true
}

function Write-Err([string]$Text) {
    Write-Host "  [X]  $Text" -ForegroundColor Red
    $script:HasIssues = $true
}

function Write-Fix([string]$Text) {
    Write-Host "  [*]  $Text" -ForegroundColor Magenta
    $script:HasFixes = $true
}

# =====================================================================
# CHECKS
# =====================================================================
function Test-Prerequisites {
    Write-Header "1. PRE-REQUISITOS"

    # PowerShell version
    $psVer = $PSVersionTable.PSVersion
    if ($psVer.Major -ge 5) {
        Write-OK "PowerShell $psVer"
    } else {
        Write-Err "PowerShell muito antigo ($psVer). Precisa 5.1+."
    }

    # ExecutionPolicy
    $policy = Get-ExecutionPolicy -Scope CurrentUser
    if ($policy -in @("Restricted", "AllSigned", "Undefined")) {
        Write-Warn "ExecutionPolicy atual: $policy (scripts bloqueados)"
        try {
            Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
            Write-Fix "ExecutionPolicy corrigida para RemoteSigned (apenas seu usuario)"
        } catch {
            Write-Err "Nao foi possivel corrigir ExecutionPolicy. Rode: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned"
        }
    } else {
        Write-OK "ExecutionPolicy: $policy"
    }

    # Pester
    $pester = Get-Module -ListAvailable Pester | Sort-Object Version -Descending | Select-Object -First 1
    if ($pester) {
        Write-OK "Pester $($pester.Version)"
    } else {
        Write-Err "Pester nao encontrado. Instale: Install-Module Pester -Force -Scope CurrentUser"
    }
}

function Test-ProjectFiles {
    Write-Header "2. ARQUIVOS DO PROJETO"

    $requiredFiles = @(
        "pages\index.html",
        "src\server.ps1",
        "src\start.ps1",
        "start.bat",
        "src\analysis-contract.psm1",
        "package.json",
        "docs\README.md"
    )

    foreach ($file in $requiredFiles) {
        $full = Join-Path $script:Root $file
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            $size = (Get-Item $full).Length
            Write-OK "$file ($([Math]::Round($size / 1024, 1)) KB)"
        } else {
            Write-Err "AUSENTE: $file"
        }
    }

    # Pasta assets
    $assets = Join-Path $script:Root "assets"
    if ((Test-Path "$assets\css\style.css") -and (Test-Path "$assets\js\app.js")) {
        Write-OK "assets\css\style.css + assets\js\app.js"
    } else {
        Write-Err "Pasta assets incompleta (falta css/style.css ou js/app.js)"
    }

    # Pasta tests
    $tests = Join-Path $script:Root "tests"
    if (-not (Test-Path $tests)) {
        New-Item -ItemType Directory -Path $tests -Force | Out-Null
        Write-Fix "Pasta tests\ criada"
    } else {
        Write-OK "Pasta tests\ existe"
    }
}

function Test-PromptContent {
    Write-Header "3. CONTEUDO DO PROMPT"

    $promptFile = Get-ChildItem -Path (Join-Path $script:Root "prompts") -Filter "chart-analysis-*.txt" -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        Select-Object -First 1
    if (-not $promptFile) {
        Write-Err "Prompt nao existe — servidor nao sobe sem ele."
        return
    }
    $promptPath = $promptFile.FullName
    Write-OK ("Prompt em uso: {0}" -f $promptFile.Name)

    $content = [System.IO.File]::ReadAllText($promptPath, [System.Text.Encoding]::UTF8)

    if ($content.Length -lt 3000) {
        Write-Err ("Prompt muito curto ({0} chars). Esperado 10000+. Recopie." -f $content.Length)
        return
    } else {
        Write-OK ("Tamanho: {0} chars" -f $content.Length)
    }

    $keywords = @(
        "VERIFICAÇÃO SISTEMÁTICA",
        "ETAPA 1 — PERCEPÇÃO E QUALIDADE DA IMAGEM",
        "ETAPA 10 — MOTOR DE DECISÃO",
        "ETAPA 11 — SISTEMA INTELIGENTE DE CONFIDENCE",
        "FORMATO DE SAÍDA — JSON OBRIGATÓRIO",
        "VERIFICAÇÃO FINAL"
    )
    $missing = @()
    foreach ($kw in $keywords) {
        if ($content -notmatch [regex]::Escape($kw)) {
            $missing += $kw
        }
    }
    if ($missing.Count -eq 0) {
        Write-OK "Todas as secoes obrigatorias presentes"
    } else {
        Write-Warn "Secoes ausentes no prompt: $($missing -join ', ')"
    }
}

function Test-NodeJs {
    Write-Header "4. NODE.JS (opcional)"

    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) {
        Write-Warn "Node.js nao encontrado (teste JS sera pulado). Instale em https://nodejs.org"
        return
    }
    $ver = & node --version 2>$null
    Write-OK "Node.js $ver"

    $appJs = Join-Path $script:Root "assets\js\app.js"
    if (Test-Path $appJs) {
        Push-Location $script:Root
        try {
            $result = & node --check "assets/js/app.js" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-OK "Sintaxe de assets/js/app.js valida"
            } else {
                Write-Err "Erro de sintaxe em app.js: $result"
            }
        } finally {
            Pop-Location
        }
    }
}

# =====================================================================
# TESTES AUTOMATIZADOS
# =====================================================================
function Invoke-AllTests {
    Write-Header "5. TESTES AUTOMATIZADOS"

    $testFile = Join-Path $script:Root "tests\AnalysisContract.Tests.ps1"
    if (-not (Test-Path $testFile)) {
        Write-Err "Arquivo de testes ausente: tests\AnalysisContract.Tests.ps1"
        return
    }

    Import-Module Pester -Force -ErrorAction Stop
    $result = Invoke-Pester -Path $testFile -PassThru -Quiet

    $script:TestPassed = $result.PassedCount
    $script:TestFailed = $result.FailedCount

    if ($script:TestFailed -eq 0) {
        Write-OK "Todos os $($script:TestPassed) testes passaram"
    } else {
        Write-Err "$($script:TestFailed) teste(s) falhou/falharam de $($script:TestPassed + $script:TestFailed)"
        foreach ($t in $result.TestResult) {
            if (-not $t.Passed) {
                Write-Host "       FAIL: $($t.Describe) > $($t.Context) > $($t.Name)" -ForegroundColor Red
            }
        }
    }
}

# =====================================================================
# RELATORIO FINAL
# =====================================================================
function Write-FinalReport {
    Write-Header "RELATORIO FINAL"

    if ($script:HasFixes) {
        Write-Host "  Correcoes aplicadas automaticamente:" -ForegroundColor Magenta
        Write-Host "    - Ver mensagens [*] acima" -ForegroundColor Magenta
    }

    if ($script:TestFailed -gt 0) {
        Write-Host ""
        Write-Host "  STATUS: ATENCAO" -ForegroundColor Yellow
        Write-Host "  - $($script:TestFailed) teste(s) falhou/falharam" -ForegroundColor Yellow
        Write-Host "  - Corrija antes de usar o servidor" -ForegroundColor Yellow
        exit 1
    }

    if ($script:HasIssues) {
        Write-Host ""
        Write-Host "  STATUS: AVISOS" -ForegroundColor Yellow
        Write-Host "  - Sistema vai funcionar, mas revise os [!] acima" -ForegroundColor Yellow
        exit 0
    }

    Write-Host ""
    Write-Host "  STATUS: PRONTO PARA USO" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Proximos passos:" -ForegroundColor White
    Write-Host "    1. Duplo-clique em start.bat" -ForegroundColor White
    Write-Host "    2. Cole sua chave OpenAI quando pedido" -ForegroundColor White
    Write-Host "    3. Acesse http://127.0.0.1:8765/" -ForegroundColor White
    Write-Host ""
}

# =====================================================================
# EXECUCAO PRINCIPAL
# =====================================================================
Write-Header "SCALPING EDGE - SETUP E VALIDACAO"
Write-Host "  Pasta do projeto: $script:Root" -ForegroundColor DarkGray

Test-Prerequisites
Test-ProjectFiles
Test-PromptContent
Test-NodeJs
Invoke-AllTests

Write-FinalReport