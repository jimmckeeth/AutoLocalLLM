#Requires -Version 5.1
<#
.SYNOPSIS
    Finds, downloads, and configures the best local LLM for coding with tool-use support.

.DESCRIPTION
    Uses LlmFit to select the top coding + tool-use capable LLM that fits your hardware.
    LlmFit and llama-server together handle the GGUF download from HuggingFace; the script
    then launches llama-server with Jinja tool-calling enabled and writes an OpenCode
    provider config so you can start coding immediately.

    Dependencies installed automatically if absent:
        Scoop    – Windows package manager    (https://scoop.sh)
        llama.cpp – Local model runtime       (https://github.com/ggml-org/llama.cpp)
        LlmFit   – Hardware-aware selector    (https://github.com/AlexsJones/llmfit)
        OpenCode – Terminal AI coding agent   (https://opencode.ai)

.PARAMETER TopN
    How many top coding models to query from LlmFit before filtering.  Default: 10.

.PARAMETER ContextSize
    Context window (-c) passed to llama-server.
    Higher values improve agentic accuracy but consume more VRAM/RAM.  Default: 16384.

.PARAMETER Port
    Port llama-server listens on.  Default: 8080.

.PARAMETER HfToken
    HuggingFace token for gated models (e.g. Meta Llama).
    If omitted and the model is gated, llama-server will prompt or fail.

.PARAMETER Force
    Re-launch llama-server and overwrite the OpenCode config entry even if already set.

.EXAMPLE
    .\Setup-OpenCode-LLM.ps1
    .\Setup-OpenCode-LLM.ps1 -TopN 15 -ContextSize 32768
    .\Setup-OpenCode-LLM.ps1 -HfToken hf_xxxx -Force
#>
[CmdletBinding()]
param (
    [ValidateRange(1, 50)]
    [int]$TopN = 10,

    [ValidateSet(4096, 8192, 16384, 32768, 65536)]
    [int]$ContextSize = 16384,

    [ValidateRange(1024, 65535)]
    [int]$Port = 8080,

    [string]$HfToken = '',

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────────────────────────────────────
# Paths
# ─────────────────────────────────────────────────────────────────────────────

$script:LlamaCppDir = Join-Path $env:LOCALAPPDATA 'llama.cpp'
$script:LlamaBinDir = Join-Path $script:LlamaCppDir 'bin'

# ─────────────────────────────────────────────────────────────────────────────
# Output helpers
# ─────────────────────────────────────────────────────────────────────────────

function Write-Step { param([string]$Msg) Write-Host "`n  >> $Msg" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Msg) Write-Host "     OK  $Msg" -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "     **  $Msg" -ForegroundColor Yellow }
function Write-Info { param([string]$Msg) Write-Host "     ..  $Msg" -ForegroundColor Gray }
function Write-Fail { param([string]$Msg) Write-Host "     !!  $Msg" -ForegroundColor Red }

function Test-CommandExists {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

# ─────────────────────────────────────────────────────────────────────────────
# Model knowledge-base
# ─────────────────────────────────────────────────────────────────────────────

# Substring patterns in HF model IDs that indicate function-calling / tool-use support.
$script:ToolCapableFamilies = @(
    'Qwen3', 'Qwen2.5-Coder', 'QwQ',
    'Llama-3.1', 'Llama-3.2', 'Llama-3.3',
    'Mistral', 'Devstral',
    'Phi-4',
    'gemma-3',
    'Command-R',
    'DeepSeek-R1'
)

# HuggingFace model ID -> GGUF download info used by llama-server --hf-repo / --hf-file.
# 'repo'     : bartowski (or official) GGUF repo on HuggingFace
# 'basename' : model name stem; GGUF filename = "{basename}-{quant}.gguf"
# 'template' : chat template hint for --chat-template (empty = auto-detect)
$script:HfToGguf = [ordered]@{
    # Qwen3
    'Qwen/Qwen3-0.6B'                           = @{ repo='bartowski/Qwen_Qwen3-0.6B-GGUF';                   basename='Qwen3-0.6B';                  template='' }
    'Qwen/Qwen3-1.7B'                           = @{ repo='bartowski/Qwen_Qwen3-1.7B-GGUF';                   basename='Qwen3-1.7B';                  template='' }
    'Qwen/Qwen3-4B'                             = @{ repo='bartowski/Qwen_Qwen3-4B-GGUF';                     basename='Qwen3-4B';                    template='' }
    'Qwen/Qwen3-8B'                             = @{ repo='bartowski/Qwen_Qwen3-8B-GGUF';                     basename='Qwen3-8B';                    template='' }
    'Qwen/Qwen3-14B'                            = @{ repo='bartowski/Qwen_Qwen3-14B-GGUF';                    basename='Qwen3-14B';                   template='' }
    'Qwen/Qwen3-30B-A3B'                        = @{ repo='bartowski/Qwen_Qwen3-30B-A3B-GGUF';                basename='Qwen3-30B-A3B';               template='' }
    'Qwen/Qwen3-32B'                            = @{ repo='bartowski/Qwen_Qwen3-32B-GGUF';                    basename='Qwen3-32B';                   template='' }
    # Qwen2.5 Coder
    'Qwen/Qwen2.5-Coder-1.5B-Instruct'         = @{ repo='bartowski/Qwen2.5-Coder-1.5B-Instruct-GGUF';       basename='Qwen2.5-Coder-1.5B-Instruct'; template='' }
    'Qwen/Qwen2.5-Coder-3B-Instruct'           = @{ repo='bartowski/Qwen2.5-Coder-3B-Instruct-GGUF';         basename='Qwen2.5-Coder-3B-Instruct';   template='' }
    'Qwen/Qwen2.5-Coder-7B-Instruct'           = @{ repo='bartowski/Qwen2.5-Coder-7B-Instruct-GGUF';         basename='Qwen2.5-Coder-7B-Instruct';   template='' }
    'Qwen/Qwen2.5-Coder-14B-Instruct'          = @{ repo='bartowski/Qwen2.5-Coder-14B-Instruct-GGUF';        basename='Qwen2.5-Coder-14B-Instruct';  template='' }
    'Qwen/Qwen2.5-Coder-32B-Instruct'          = @{ repo='bartowski/Qwen2.5-Coder-32B-Instruct-GGUF';        basename='Qwen2.5-Coder-32B-Instruct';  template='' }
    # QwQ
    'Qwen/QwQ-32B'                              = @{ repo='bartowski/QwQ-32B-GGUF';                           basename='QwQ-32B';                     template='' }
    # Llama 3.x
    'meta-llama/Llama-3.2-1B-Instruct'         = @{ repo='bartowski/Llama-3.2-1B-Instruct-GGUF';             basename='Llama-3.2-1B-Instruct';       template='' }
    'meta-llama/Llama-3.2-3B-Instruct'         = @{ repo='bartowski/Llama-3.2-3B-Instruct-GGUF';             basename='Llama-3.2-3B-Instruct';       template='' }
    'meta-llama/Llama-3.1-8B-Instruct'         = @{ repo='bartowski/Meta-Llama-3.1-8B-Instruct-GGUF';        basename='Meta-Llama-3.1-8B-Instruct';  template='' }
    'meta-llama/Llama-3.1-70B-Instruct'        = @{ repo='bartowski/Meta-Llama-3.1-70B-Instruct-GGUF';       basename='Meta-Llama-3.1-70B-Instruct'; template='' }
    'meta-llama/Llama-3.3-70B-Instruct'        = @{ repo='bartowski/Llama-3.3-70B-Instruct-GGUF';            basename='Llama-3.3-70B-Instruct';      template='' }
    # Mistral / Devstral
    'mistralai/Mistral-7B-Instruct-v0.3'       = @{ repo='bartowski/Mistral-7B-Instruct-v0.3-GGUF';          basename='Mistral-7B-Instruct-v0.3';    template='' }
    'mistralai/Mistral-Nemo-Instruct-2407'     = @{ repo='bartowski/Mistral-Nemo-Instruct-2407-GGUF';        basename='Mistral-Nemo-Instruct-2407';  template='' }
    'mistralai/Devstral-Small-2505'            = @{ repo='bartowski/Devstral-Small-2505-GGUF';               basename='Devstral-Small-2505';         template='' }
    # Microsoft Phi-4
    'microsoft/Phi-4'                           = @{ repo='bartowski/Phi-4-GGUF';                             basename='Phi-4';                       template='' }
    'microsoft/phi-4-mini-instruct'            = @{ repo='bartowski/phi-4-mini-instruct-GGUF';               basename='phi-4-mini-instruct';         template='' }
    # Google Gemma 3
    'google/gemma-3-1b-it'                     = @{ repo='bartowski/gemma-3-1b-it-GGUF';                     basename='gemma-3-1b-it';               template='' }
    'google/gemma-3-4b-it'                     = @{ repo='bartowski/gemma-3-4b-it-GGUF';                     basename='gemma-3-4b-it';               template='' }
    'google/gemma-3-9b-it'                     = @{ repo='bartowski/gemma-3-9b-it-GGUF';                     basename='gemma-3-9b-it';               template='' }
    'google/gemma-3-12b-it'                    = @{ repo='bartowski/gemma-3-12b-it-GGUF';                    basename='gemma-3-12b-it';              template='' }
    'google/gemma-3-27b-it'                    = @{ repo='bartowski/gemma-3-27b-it-GGUF';                    basename='gemma-3-27b-it';              template='' }
    # Cohere
    'CohereForAI/c4ai-command-r7b-12-2024'    = @{ repo='bartowski/c4ai-command-r7b-12-2024-GGUF';          basename='c4ai-command-r7b-12-2024';    template='' }
    # DeepSeek R1 distills (require explicit chat template for reliable tool calls)
    'deepseek-ai/DeepSeek-R1-Distill-Llama-8B'  = @{ repo='bartowski/DeepSeek-R1-Distill-Llama-8B-GGUF';   basename='DeepSeek-R1-Distill-Llama-8B';  template='deepseek-r1' }
    'deepseek-ai/DeepSeek-R1-Distill-Qwen-7B'   = @{ repo='bartowski/DeepSeek-R1-Distill-Qwen-7B-GGUF';    basename='DeepSeek-R1-Distill-Qwen-7B';   template='deepseek-r1' }
    'deepseek-ai/DeepSeek-R1-Distill-Qwen-14B'  = @{ repo='bartowski/DeepSeek-R1-Distill-Qwen-14B-GGUF';   basename='DeepSeek-R1-Distill-Qwen-14B';  template='deepseek-r1' }
    'deepseek-ai/DeepSeek-R1-Distill-Qwen-32B'  = @{ repo='bartowski/DeepSeek-R1-Distill-Qwen-32B-GGUF';   basename='DeepSeek-R1-Distill-Qwen-32B';  template='deepseek-r1' }
}

function Get-GgufInfo {
    param([string]$HfId)
    if ($script:HfToGguf.Contains($HfId)) { return $script:HfToGguf[$HfId] }
    $stripped = $HfId -replace '-GGUF$', '' -replace '-Q\d.*$', ''
    if ($script:HfToGguf.Contains($stripped)) { return $script:HfToGguf[$stripped] }
    return $null
}

function Test-ToolCapable {
    param([string]$HfId)
    foreach ($f in $script:ToolCapableFamilies) {
        if ($HfId -match [regex]::Escape($f)) { return $true }
    }
    return $false
}

# ─────────────────────────────────────────────────────────────────────────────
# GPU detection (for choosing the right llama.cpp binary)
# ─────────────────────────────────────────────────────────────────────────────

function Get-GpuBackend {
    try {
        $gpus = Get-WmiObject Win32_VideoController -ErrorAction Stop |
            Where-Object { $_.AdapterCompatibility -notmatch 'Microsoft' }
        foreach ($gpu in $gpus) {
            $label = "$($gpu.Name) $($gpu.AdapterCompatibility)"
            if ($label -match 'NVIDIA') { return 'cuda' }
            if ($label -match 'AMD|Radeon') { return 'vulkan' }
        }
    } catch {}
    return 'vulkan'   # Vulkan works for Intel iGPU and CPU-only fallback
}

# ─────────────────────────────────────────────────────────────────────────────
# Prerequisite installers
# ─────────────────────────────────────────────────────────────────────────────

function Install-Scoop {
    if (Test-CommandExists 'scoop') { Write-Ok 'Scoop already installed'; return }
    Write-Step 'Installing Scoop'
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
    Invoke-RestMethod -Uri 'https://get.scoop.sh' | Invoke-Expression
    $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'User') + ';' +
                [System.Environment]::GetEnvironmentVariable('PATH', 'Machine')
    if (-not (Test-CommandExists 'scoop')) {
        throw 'Scoop installation failed. Install manually from https://scoop.sh then re-run.'
    }
    Write-Ok 'Scoop installed'
}

function Install-LlamaCpp {
    if (Test-CommandExists 'llama-server') { Write-Ok 'llama-server already on PATH'; return }
    $localExe = Join-Path $script:LlamaBinDir 'llama-server.exe'
    if (Test-Path $localExe) {
        $env:PATH += ";$script:LlamaBinDir"
        Write-Ok "llama-server found: $localExe"
        return
    }

    Write-Step 'Installing llama.cpp'
    $installed = $false

    if (Test-CommandExists 'scoop') {
        try {
            scoop install llama
            if (Test-CommandExists 'llama-server') { $installed = $true }
        } catch {}
    }

    if (-not $installed) { Install-LlamaCppFromGitHub }

    if (-not (Test-CommandExists 'llama-server')) {
        throw 'llama-server not found after installation. See https://github.com/ggml-org/llama.cpp/releases'
    }
    Write-Ok 'llama.cpp installed'
}

function Install-LlamaCppFromGitHub {
    $backend = Get-GpuBackend
    Write-Info "GPU backend detected: $backend"

    $releaseApi = 'https://api.github.com/repos/ggml-org/llama.cpp/releases/latest'
    $release    = Invoke-RestMethod -Uri $releaseApi -Headers @{ 'User-Agent' = 'AutoLocalLLM' }

    $pattern = switch ($backend) {
        'cuda'  { 'win-cuda-12\.4-x64\.zip$' }
        default { 'win-vulkan-x64\.zip$' }
    }
    $asset = $release.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
    if (-not $asset) {
        $asset = $release.assets | Where-Object { $_.name -match 'win.*x64\.zip$' } | Select-Object -First 1
    }
    if (-not $asset) { throw "No Windows llama.cpp binary found in release $($release.tag_name)." }

    New-Item -ItemType Directory -Path $script:LlamaBinDir -Force | Out-Null
    $tmpZip = Join-Path $env:TEMP "llama-cpp-$($release.tag_name).zip"

    Write-Info "Downloading $($asset.name)  ($([math]::Round($asset.size / 1MB, 0)) MB)"
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmpZip
    $ProgressPreference = 'Continue'

    Expand-Archive -Path $tmpZip -DestinationPath $script:LlamaBinDir -Force
    Remove-Item $tmpZip -ErrorAction SilentlyContinue

    # If binaries landed in a sub-folder, move them up one level
    $subDir = Get-ChildItem -Path $script:LlamaBinDir -Filter 'llama-server.exe' -Recurse |
        Select-Object -First 1 -ExpandProperty DirectoryName
    if ($subDir -and $subDir -ne $script:LlamaBinDir) {
        Get-ChildItem -Path $subDir | Move-Item -Destination $script:LlamaBinDir -Force
        Remove-Item $subDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    $userPath = [System.Environment]::GetEnvironmentVariable('PATH', 'User')
    if ($userPath -notmatch [regex]::Escape($script:LlamaBinDir)) {
        [System.Environment]::SetEnvironmentVariable('PATH', "$userPath;$script:LlamaBinDir", 'User')
    }
    $env:PATH += ";$script:LlamaBinDir"
}

function Install-LlmFit {
    if (Test-CommandExists 'llmfit') { Write-Ok 'LlmFit already installed'; return }
    Write-Step 'Installing LlmFit'
    $installed = $false

    if (Test-CommandExists 'scoop') {
        try { scoop install llmfit; $installed = Test-CommandExists 'llmfit' } catch {}
    }
    if (-not $installed) {
        $releaseApi = 'https://api.github.com/repos/AlexsJones/llmfit/releases/latest'
        $release    = Invoke-RestMethod -Uri $releaseApi -Headers @{ 'User-Agent' = 'AutoLocalLLM' }
        $asset = $release.assets | Where-Object { $_.name -match 'windows.*\.zip$' } | Select-Object -First 1
        if (-not $asset) {
            $asset = $release.assets | Where-Object { $_.name -match '\.exe$' } | Select-Object -First 1
        }
        if (-not $asset) { throw 'No Windows LlmFit release asset found on GitHub.' }

        $dest   = Join-Path $env:LOCALAPPDATA 'llmfit'
        New-Item -ItemType Directory -Path $dest -Force | Out-Null

        $tmpZip = Join-Path $env:TEMP 'llmfit-windows.zip'
        Write-Info "Downloading $($asset.name)"
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmpZip
        $ProgressPreference = 'Continue'
        Expand-Archive -Path $tmpZip -DestinationPath $dest -Force
        Remove-Item $tmpZip -ErrorAction SilentlyContinue

        $exe = Get-ChildItem -Path $dest -Filter 'llmfit*.exe' -Recurse | Select-Object -First 1
        if (-not $exe) { throw 'llmfit.exe not found after extraction.' }

        $userPath = [System.Environment]::GetEnvironmentVariable('PATH', 'User')
        if ($userPath -notmatch [regex]::Escape($dest)) {
            [System.Environment]::SetEnvironmentVariable('PATH', "$userPath;$dest", 'User')
            $env:PATH += ";$dest"
        }
    }

    if (-not (Test-CommandExists 'llmfit')) {
        throw 'LlmFit installation failed. Install manually from https://github.com/AlexsJones/llmfit'
    }
    Write-Ok 'LlmFit installed'
}

function Install-OpenCode {
    if (Test-CommandExists 'opencode') { Write-Ok 'OpenCode already installed'; return }
    Write-Step 'Installing OpenCode'
    if (Test-CommandExists 'npm') {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin) { Write-Warn 'npm global install may need an elevated prompt. Trying anyway...' }
        npm install --global opencode-ai@latest
    } elseif (Test-CommandExists 'scoop') {
        scoop install opencode
    } else {
        throw 'Neither npm (Node.js) nor Scoop found. Install one of them then re-run this script.'
    }
    if (-not (Test-CommandExists 'opencode')) {
        throw 'OpenCode installation failed. Install manually: npm i -g opencode-ai'
    }
    Write-Ok 'OpenCode installed'
}

# ─────────────────────────────────────────────────────────────────────────────
# LlmFit: find best coding + tool-use model
# ─────────────────────────────────────────────────────────────────────────────

function Get-BestCodingModel {
    param([int]$Limit)
    Write-Step "Querying LlmFit: top $Limit coding models for this hardware"

    $raw = & llmfit recommend --json --use-case coding --limit $Limit 2>&1
    if ($LASTEXITCODE -ne 0) { throw "LlmFit exited with code $LASTEXITCODE:`n$raw" }

    # Extract the first JSON array in the output (strip any ANSI/TUI preamble lines)
    $jsonText = ($raw -join "`n")
    if ($jsonText -match '(?s)(\[.*?\])') { $jsonText = $Matches[1] }

    try   { $models = $jsonText | ConvertFrom-Json }
    catch { throw "Could not parse LlmFit JSON output.`nRaw output:`n$raw" }
    if (-not $models -or $models.Count -eq 0) { throw 'LlmFit returned an empty model list.' }

    Write-Info "LlmFit found $($models.Count) candidate(s); filtering for coding + tool-use"

    $candidates = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($m in $models) {
        $hfId    = $m.name
        $gguf    = Get-GgufInfo -HfId $hfId
        $canTool = Test-ToolCapable -HfId $hfId
        if ($gguf -and $canTool) {
            $candidates.Add([PSCustomObject]@{
                HfId         = $hfId
                GgufRepo     = $gguf.repo
                GgufBasename = $gguf.basename
                Template     = $gguf.template
                Quantization = if ($m.quantization) { $m.quantization } else { 'Q4_K_M' }
                Score        = $m.score
                Params       = $m.params
                Fit          = $m.fit
                MemPct       = $m.memory_percent
            })
        } else {
            $reason = if (-not $gguf) { 'no GGUF mapping' } else { 'not tool-capable' }
            Write-Info "  Skip: $hfId  ($reason)"
        }
    }

    if ($candidates.Count -eq 0) {
        Write-Warn 'No tool-capable models with a GGUF mapping in results. Using top LlmFit result.'
        $first = $models | Select-Object -First 1
        $gguf  = Get-GgufInfo -HfId $first.name
        if (-not $gguf) {
            throw @"
Cannot map '$($first.name)' to a GGUF repo.
Add an entry to the `$HfToGguf table in this script and re-run.
"@
        }
        return [PSCustomObject]@{
            HfId         = $first.name
            GgufRepo     = $gguf.repo
            GgufBasename = $gguf.basename
            Template     = $gguf.template
            Quantization = if ($first.quantization) { $first.quantization } else { 'Q4_K_M' }
            Score        = $first.score
            Params       = $first.params
            Fit          = $first.fit
            MemPct       = $first.memory_percent
        }
    }

    return $candidates[0]   # LlmFit already ranks by composite score
}

# ─────────────────────────────────────────────────────────────────────────────
# llama-server: build args, launch, wait for readiness
# llama-server downloads the GGUF from HuggingFace on first run via --hf-repo.
# ─────────────────────────────────────────────────────────────────────────────

function Build-LlamaServerArgs {
    param(
        [string]$HfRepo,
        [string]$HfFile,
        [string]$Template,
        [string]$Token,
        [int]$Ctx,
        [int]$SrvPort
    )

    $a = [System.Collections.Generic.List[string]]::new()
    $a.AddRange([string[]]@('--hf-repo', $HfRepo))
    $a.AddRange([string[]]@('--hf-file', $HfFile))
    $a.AddRange([string[]]@('-c', $Ctx))
    $a.AddRange([string[]]@('--host', '127.0.0.1'))
    $a.AddRange([string[]]@('--port', $SrvPort))
    $a.Add('--jinja')   # enables OpenAI-style tool/function calling

    if ($Template -and $Template -ne '') {
        $a.AddRange([string[]]@('--chat-template', $Template))
    }
    if ($Token -and $Token -ne '') {
        # Pass HF token via environment so it doesn't appear in process list
        $env:HF_TOKEN = $Token
    }

    return $a.ToArray()
}

function Start-LlamaServer {
    param([PSCustomObject]$Model, [string]$Token, [int]$Ctx, [int]$SrvPort)

    $apiRoot   = "http://127.0.0.1:$SrvPort"
    $healthUrl = "$apiRoot/health"
    $hfFile    = "$($Model.GgufBasename)-$($Model.Quantization).gguf"

    # If a server is already responding on this port, reuse it
    try {
        $r = Invoke-RestMethod -Uri $healthUrl -TimeoutSec 3 -ErrorAction Stop
        if ($r.status -eq 'ok') { Write-Ok "llama-server already running on $apiRoot"; return $apiRoot }
    } catch {}

    Write-Step "Starting llama-server  ($($Model.GgufRepo) / $hfFile)"
    Write-Info 'llama-server will download the GGUF from HuggingFace if not cached.'
    Write-Warn 'First run may take several minutes while the model downloads...'

    $serverArgs = Build-LlamaServerArgs `
        -HfRepo   $Model.GgufRepo `
        -HfFile   $hfFile `
        -Template $Model.Template `
        -Token    $Token `
        -Ctx      $Ctx `
        -SrvPort  $SrvPort

    Write-Info "  llama-server $($serverArgs -join ' ')"

    Start-Process -FilePath 'llama-server' `
                  -ArgumentList $serverArgs `
                  -WindowStyle Minimized

    # Poll /health until the model is loaded and the server is ready
    $timeout  = 600   # up to 10 min for large model downloads + load
    $interval = 5
    $elapsed  = 0
    $ready    = $false

    Write-Host '     Waiting' -NoNewline -ForegroundColor Gray
    while ($elapsed -lt $timeout) {
        Start-Sleep -Seconds $interval
        $elapsed += $interval
        Write-Host '.' -NoNewline -ForegroundColor Gray
        try {
            $r = Invoke-RestMethod -Uri $healthUrl -TimeoutSec 2 -ErrorAction Stop
            if ($r.status -eq 'ok') { $ready = $true; break }
        } catch {}
    }
    Write-Host ''

    if (-not $ready) {
        throw "llama-server did not become ready within ${timeout}s. Check the minimised window for errors."
    }
    Write-Ok "llama-server ready  ($apiRoot)"
    return $apiRoot
}

# ─────────────────────────────────────────────────────────────────────────────
# OpenCode configuration
# ─────────────────────────────────────────────────────────────────────────────

function Update-OpenCodeConfig {
    param([string]$ModelId, [string]$DisplayName, [string]$ApiBase)

    $configDir  = Join-Path $env:USERPROFILE '.config\opencode'
    $configPath = Join-Path $configDir 'config.json'
    New-Item -ItemType Directory -Path $configDir -Force | Out-Null

    $cfg = @{}
    if (Test-Path $configPath) {
        try { $cfg = Get-Content $configPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable }
        catch { $cfg = @{} }
    }

    if (-not $cfg.ContainsKey('$schema'))  { $cfg['$schema']  = 'https://opencode.ai/config.json' }
    if (-not $cfg.ContainsKey('provider')) { $cfg['provider'] = @{} }

    $providerKey = 'llama-cpp'
    if (-not $cfg['provider'].ContainsKey($providerKey)) {
        $cfg['provider'][$providerKey] = @{
            npm     = '@ai-sdk/openai-compatible'
            name    = 'llama.cpp Local'
            options = @{ baseURL = "$ApiBase/v1" }
            models  = @{}
        }
    }

    $provider = $cfg['provider'][$providerKey]
    if (-not $provider.ContainsKey('models')) { $provider['models'] = @{} }

    $provider['models'][$ModelId] = @{
        name  = $DisplayName
        tools = $true
    }

    $cfg | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath -Encoding utf8
    Write-Ok "OpenCode config written: $configPath"
    return $configPath
}

# ─────────────────────────────────────────────────────────────────────────────
# Startup helper (re-launch llama-server after a reboot)
# ─────────────────────────────────────────────────────────────────────────────

function Write-StartupScript {
    param([PSCustomObject]$Model, [string]$Token, [int]$Ctx, [int]$SrvPort)

    $hfFile     = "$($Model.GgufBasename)-$($Model.Quantization).gguf"
    $scriptPath = Join-Path $script:LlamaCppDir 'Start-LlamaServer.ps1'

    $serverArgs = Build-LlamaServerArgs `
        -HfRepo   $Model.GgufRepo `
        -HfFile   $hfFile `
        -Template $Model.Template `
        -Token    $Token `
        -Ctx      $Ctx `
        -SrvPort  $SrvPort

    $argsLine = ($serverArgs | ForEach-Object {
        if ($_ -match '\s') { "`"$_`"" } else { $_ }
    }) -join ' '

    $tokenLine = if ($Token -and $Token -ne '') {
        "`$env:HF_TOKEN = '$Token'"
    } else {
        '# $env:HF_TOKEN = "hf_xxx"   # uncomment and fill if model requires auth'
    }

    $content = @"
# Auto-generated by Setup-OpenCode-LLM.ps1
# Run this script before using OpenCode if llama-server is not already running.

Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'

$tokenLine

`$apiRoot   = "http://127.0.0.1:$SrvPort"
`$healthUrl = "`$apiRoot/health"

try {
    `$r = Invoke-RestMethod -Uri `$healthUrl -TimeoutSec 2 -ErrorAction Stop
    if (`$r.status -eq 'ok') { Write-Host "llama-server already running on `$apiRoot"; exit 0 }
} catch {}

Write-Host "Starting llama-server on `$apiRoot ..."
llama-server $argsLine
"@
    Set-Content -Path $scriptPath -Value $content -Encoding utf8
    Write-Ok "Startup script: $scriptPath"
    return $scriptPath
}

# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '  +------------------------------------------------------------+' -ForegroundColor Magenta
Write-Host '  |    AutoLocalLLM  --  LlmFit -> llama.cpp -> OpenCode      |' -ForegroundColor Magenta
Write-Host '  +------------------------------------------------------------+' -ForegroundColor Magenta
Write-Host ''

try {
    # 1. Prerequisites
    Write-Step 'Checking prerequisites'
    Install-Scoop
    Install-LlamaCpp
    Install-LlmFit
    Install-OpenCode

    # 2. Hardware-aware model selection
    $best = Get-BestCodingModel -Limit $TopN

    Write-Host ''
    Write-Host '  Selected model' -ForegroundColor White
    Write-Info "HuggingFace  : $($best.HfId)"
    Write-Info "GGUF repo    : $($best.GgufRepo)"
    Write-Info "File         : $($best.GgufBasename)-$($best.Quantization).gguf"
    Write-Info "Score        : $($best.Score)"
    Write-Info "Parameters   : $($best.Params)B"
    Write-Info "VRAM used    : $($best.MemPct)%"

    # 3. Start llama-server (downloads GGUF via --hf-repo if not cached)
    $apiBase = Start-LlamaServer -Model $best -Token $HfToken -Ctx $ContextSize -SrvPort $Port

    # 4. Configure OpenCode
    $modelId     = "$($best.GgufBasename)-$($best.Quantization)".ToLower()
    $displayName = "$($best.GgufBasename) ($($best.Quantization), ctx=$ContextSize)"
    $cfgPath     = Update-OpenCodeConfig -ModelId $modelId -DisplayName $displayName -ApiBase $apiBase

    # 5. Write re-launch helper
    $startScript = Write-StartupScript -Model $best -Token $HfToken -Ctx $ContextSize -SrvPort $Port

    # 6. Done
    Write-Host ''
    Write-Host '  +------------------------------------------------------------+' -ForegroundColor Green
    Write-Host '  |                    Setup Complete!                         |' -ForegroundColor Green
    Write-Host '  +------------------------------------------------------------+' -ForegroundColor Green
    Write-Host ''
    Write-Host "  Model    : $modelId" -ForegroundColor Yellow
    Write-Host "  Server   : $apiBase" -ForegroundColor Yellow
    Write-Host "  Config   : $cfgPath"  -ForegroundColor Yellow
    Write-Host "  Relaunch : $startScript" -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Start coding now:' -ForegroundColor White
    Write-Host '    opencode' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Inside OpenCode, press Ctrl+K to open the model picker, then choose:' -ForegroundColor White
    Write-Host "    llama-cpp > $modelId" -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Note: llama-server must be running while you use OpenCode.' -ForegroundColor Gray
    Write-Host "  After a reboot, start it again with: $startScript" -ForegroundColor Gray
    Write-Host ''

} catch {
    Write-Host ''
    Write-Fail "Fatal: $_"
    Write-Host ''
    exit 1
}
