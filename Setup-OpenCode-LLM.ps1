#Requires -Version 5.1
<#
.SYNOPSIS
    Finds, downloads, and configures the best local LLM for coding with tool-use support.

.DESCRIPTION
    Uses LlmFit to select the top coding + tool-use capable LLM that fits your hardware.

    Without -Manual the top-ranked candidate is downloaded automatically.
    With -Manual a ranked table is displayed and you choose which model to use.

    Primary runtime is llama.cpp (llama-server with --hf-repo for HuggingFace download).
    If a model has no GGUF mapping, Ollama is used as a fallback runner.

    Dependencies installed automatically if absent:
        Scoop    – Windows package manager    (https://scoop.sh)
        llama.cpp – Local model runtime       (https://github.com/ggml-org/llama.cpp)
        Ollama   – Fallback runtime           (https://ollama.com)  [only if needed]
        LlmFit   – Hardware-aware selector    (https://github.com/AlexsJones/llmfit)
        OpenCode – Terminal AI coding agent   (https://opencode.ai)

.PARAMETER TopN
    How many top coding models to query from LlmFit.  Default: 20.

.PARAMETER ContextSize
    Context window (-c) passed to llama-server, or num_ctx for Ollama.  Default: 16384.

.PARAMETER Port
    Port llama-server listens on (ignored when using Ollama runner).  Default: 8080.

.PARAMETER HfToken
    HuggingFace token for gated models (e.g. Meta Llama).

.PARAMETER Manual
    Display the ranked candidate list and prompt you to pick a model before downloading.

.PARAMETER Force
    Re-launch the server and overwrite the OpenCode config entry even if already set.

.EXAMPLE
    .\Setup-OpenCode-LLM.ps1                        # fully automatic
    .\Setup-OpenCode-LLM.ps1 -Manual                # choose from ranked list
    .\Setup-OpenCode-LLM.ps1 -Manual -TopN 20       # wider candidate list
    .\Setup-OpenCode-LLM.ps1 -HfToken hf_xxx        # gated models
#>
[CmdletBinding()]
param (
    [ValidateRange(1, 50)]
    [int]$TopN = 20,

    [ValidateSet(4096, 8192, 16384, 32768, 65536)]
    [int]$ContextSize = 16384,

    [ValidateRange(1024, 65535)]
    [int]$Port = 8080,

    [string]$HfToken = '',

    [switch]$Manual,

    [switch]$Force,

    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$ExtraArgs = @()
)

# Accept GNU-style --double-dash args so bash muscle-memory works in PowerShell
$i = 0
while ($i -lt $ExtraArgs.Count) {
    switch ($ExtraArgs[$i].ToLower()) {
        '--manual'   { $Manual      = [switch]$true              }
        '--force'    { $Force       = [switch]$true              }
        '--top-n'    { $TopN        = [int]$ExtraArgs[++$i]      }
        '--context'  { $ContextSize = [int]$ExtraArgs[++$i]      }
        '--port'     { $Port        = [int]$ExtraArgs[++$i]      }
        '--hf-token' { $HfToken     = $ExtraArgs[++$i]           }
        default      { Write-Warning "Unknown argument: $($ExtraArgs[$i])" }
    }
    $i++
}

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
# GPU detection
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
    return 'vulkan'
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
    if (Test-Path $localExe) { $env:PATH += ";$script:LlamaBinDir"; Write-Ok "llama-server: $localExe"; return }

    Write-Step 'Installing llama.cpp'
    $installed = $false
    if (Test-CommandExists 'scoop') {
        try { scoop install llama; $installed = Test-CommandExists 'llama-server' } catch {}
    }
    if (-not $installed) {
        $backend    = Get-GpuBackend
        Write-Info "GPU backend: $backend"
        $releaseApi = 'https://api.github.com/repos/ggml-org/llama.cpp/releases/latest'
        $release    = Invoke-RestMethod -Uri $releaseApi -Headers @{ 'User-Agent' = 'AutoLocalLLM' }
        $pattern    = if ($backend -eq 'cuda') { 'win-cuda-12\.4-x64\.zip$' } else { 'win-vulkan-x64\.zip$' }
        $asset      = $release.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
        if (-not $asset) {
            $asset = $release.assets | Where-Object { $_.name -match 'win.*x64\.zip$' } | Select-Object -First 1
        }
        if (-not $asset) { throw "No Windows llama.cpp binary found in release $($release.tag_name)." }

        New-Item -ItemType Directory -Path $script:LlamaBinDir -Force | Out-Null
        $tmpZip = Join-Path $env:TEMP "llama-cpp-$($release.tag_name).zip"
        Write-Info "Downloading $($asset.name)  ($([math]::Round($asset.size/1MB,0)) MB)"
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmpZip
        $ProgressPreference = 'Continue'
        Expand-Archive -Path $tmpZip -DestinationPath $script:LlamaBinDir -Force
        Remove-Item $tmpZip -ErrorAction SilentlyContinue

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
    if (-not (Test-CommandExists 'llama-server')) {
        throw 'llama-server not found. See https://github.com/ggml-org/llama.cpp/releases'
    }
    Write-Ok 'llama.cpp installed'
}

function Install-Ollama {
    if (Test-CommandExists 'ollama') { Write-Ok 'Ollama already installed'; return }
    Write-Step 'Installing Ollama (fallback runner)'
    if (Test-CommandExists 'scoop') {
        scoop install ollama
    } else {
        $tmpInstaller = Join-Path $env:TEMP 'OllamaSetup.exe'
        Write-Info 'Downloading Ollama installer'
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri 'https://ollama.com/download/OllamaSetup.exe' -OutFile $tmpInstaller
        $ProgressPreference = 'Continue'
        Start-Process -FilePath $tmpInstaller -ArgumentList '/S' -Wait
        Remove-Item $tmpInstaller -ErrorAction SilentlyContinue
        $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'User') + ';' +
                    [System.Environment]::GetEnvironmentVariable('PATH', 'Machine')
    }
    if (-not (Test-CommandExists 'ollama')) {
        throw 'Ollama installation failed. Install manually from https://ollama.com/download'
    }
    Write-Ok 'Ollama installed'
}

function Start-OllamaDaemon {
    $apiUrl = 'http://localhost:11434/api/tags'
    try { $null = Invoke-RestMethod -Uri $apiUrl -TimeoutSec 3; Write-Ok 'Ollama daemon running'; return }
    catch {}
    Write-Info 'Starting Ollama daemon...'
    Start-Process -FilePath 'ollama' -ArgumentList 'serve' -WindowStyle Hidden
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Seconds 1
        try { $null = Invoke-RestMethod -Uri $apiUrl -TimeoutSec 2; Write-Ok 'Ollama daemon started'; return } catch {}
    }
    throw 'Ollama did not start within 20 s. Run `ollama serve` manually and retry.'
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
        if (-not $asset) { throw 'No Windows LlmFit release asset found.' }
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
        if (-not $isAdmin) { Write-Warn 'npm global install may need an elevated prompt.' }
        npm install --global opencode-ai@latest
    } elseif (Test-CommandExists 'scoop') {
        scoop install opencode
    } else {
        throw 'Neither npm (Node.js) nor Scoop found. Install one then re-run.'
    }
    if (-not (Test-CommandExists 'opencode')) {
        throw 'OpenCode installation failed. Install manually: npm i -g opencode-ai'
    }
    Write-Ok 'OpenCode installed'
}

# ─────────────────────────────────────────────────────────────────────────────
# LlmFit: query and build candidate list
# ─────────────────────────────────────────────────────────────────────────────

function Get-CodingCandidates {
    param([int]$Limit)
    Write-Step "Querying LlmFit: top $Limit coding models for this hardware"

    $errFile = [System.IO.Path]::GetTempFileName()
    $raw = & llmfit recommend --json --use-case coding --capability tool_use --runtime llamacpp --min-fit good --limit $Limit 2>$errFile
    $stderr = Get-Content $errFile -Raw; Remove-Item $errFile -Force
    if ($LASTEXITCODE -ne 0) { throw "LlmFit exited with code ${LASTEXITCODE}:`n$stderr" }

    $jsonText = ($raw -join "`n")

    try {
        $parsed = $jsonText | ConvertFrom-Json
        $models = if ($parsed.PSObject.Properties['models']) { $parsed.models } else { $parsed }
    }
    catch { throw "Could not parse LlmFit JSON output.`nRaw:`n$raw" }
    if (-not $models -or $models.Count -eq 0) { throw 'LlmFit returned an empty model list.' }

    Write-Info "LlmFit returned $($models.Count) result(s)"

    $prefProviders = @('bartowski', 'unsloth', 'mradermacher')
    $candidates = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($m in $models) {
        $hfId    = $m.name
        $sources = @($m.gguf_sources)

        if (-not $sources -or $sources.Count -eq 0) {
            Write-Info "  Skip (no GGUF source): $hfId"
            continue
        }

        $source = $null
        foreach ($prov in $prefProviders) {
            $source = $sources | Where-Object { $_.provider -eq $prov } | Select-Object -First 1
            if ($source) { break }
        }
        if (-not $source) { $source = $sources[0] }

        $repo     = $source.repo
        $basename = ($repo -split '/')[-1] -replace '-GGUF$', ''

        $candidates.Add([PSCustomObject]@{
            Index        = $candidates.Count + 1
            HfId         = $hfId
            Runner       = 'llamacpp'
            GgufRepo     = $repo
            GgufBasename = $basename
            Template     = ''
            OllamaTag    = ''
            Quantization = if ($m.best_quant) { $m.best_quant } else { 'Q4_K_M' }
            Score        = $m.score
            Params       = $m.params_b
            Fit          = $m.fit_level
            MemPct       = $m.utilization_pct
        })
    }

    return $candidates
}

# ─────────────────────────────────────────────────────────────────────────────
# Model selection: auto or interactive
# ─────────────────────────────────────────────────────────────────────────────

function Show-CandidateTable {
    param([System.Collections.Generic.List[PSCustomObject]]$Candidates)

    $colWidths = @{ N=3; Model=38; Params=7; Score=7; VRAM=6; Runner=10 }

    $header  = " {0,-$($colWidths.N)} | {1,-$($colWidths.Model)} | {2,-$($colWidths.Params)} | {3,-$($colWidths.Score)} | {4,-$($colWidths.VRAM)} | {5,-$($colWidths.Runner)}" -f
               '#', 'Model', 'Params', 'Score', 'VRAM%', 'Runner'
    $divider = '-' * ($header.Length)

    Write-Host ''
    Write-Host "  $divider" -ForegroundColor DarkGray
    Write-Host "  $header"  -ForegroundColor White
    Write-Host "  $divider" -ForegroundColor DarkGray

    foreach ($c in $Candidates) {
        $modelLabel = if ($c.Runner -eq 'llamacpp') {
            "$($c.GgufBasename) ($($c.Quantization))"
        } else {
            "$($c.OllamaTag)"
        }
        if ($modelLabel.Length -gt $colWidths.Model) {
            $modelLabel = $modelLabel.Substring(0, $colWidths.Model - 1) + [char]0x2026
        }
        $runnerLabel = if ($c.Runner -eq 'llamacpp') { 'llama.cpp' } else { 'Ollama' }
        $paramsStr = if ($null -ne $c.Params) { "$([math]::Round([double]$c.Params, 1))B" } else { '?' }
        $row = " {0,-$($colWidths.N)} | {1,-$($colWidths.Model)} | {2,-$($colWidths.Params)} | {3,-$($colWidths.Score)} | {4,-$($colWidths.VRAM)} | {5,-$($colWidths.Runner)}" -f
               $c.Index,
               $modelLabel,
               $paramsStr,
               ([math]::Round([double]$c.Score, 1)),
               "$($c.MemPct)%",
               $runnerLabel
        $color = if ($c.Index -eq 1) { 'Yellow' } else { 'Gray' }
        Write-Host "  $row" -ForegroundColor $color
    }

    Write-Host "  $divider" -ForegroundColor DarkGray
    Write-Host ''
}

function Select-Model {
    param(
        [System.Collections.Generic.List[PSCustomObject]]$Candidates,
        [bool]$IsManual
    )

    if ($Candidates.Count -eq 0) {
        throw 'No usable candidates found. Try increasing -TopN (e.g. -TopN 30).'
    }

    Show-CandidateTable -Candidates $Candidates

    if (-not $IsManual) {
        Write-Info "Auto-selecting #1: $($Candidates[0].HfId)"
        return $Candidates[0]
    }

    # Interactive prompt
    while ($true) {
        $raw = Read-Host "  Enter number [1-$($Candidates.Count)] or press Enter for #1"
        if ([string]::IsNullOrWhiteSpace($raw)) { return $Candidates[0] }
        $n = 0
        if ([int]::TryParse($raw.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $Candidates.Count) {
            return $Candidates[$n - 1]
        }
        Write-Warn "  Please enter a number between 1 and $($Candidates.Count)."
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# llama-server runner
# ─────────────────────────────────────────────────────────────────────────────

function Build-LlamaServerArgs {
    param([PSCustomObject]$Model, [string]$Token, [int]$Ctx, [int]$SrvPort)

    $hfFile = "$($Model.GgufBasename)-$($Model.Quantization).gguf"
    $a = [System.Collections.Generic.List[string]]::new()
    $a.AddRange([string[]]@('--hf-repo', $Model.GgufRepo))
    $a.AddRange([string[]]@('--hf-file', $hfFile))
    $a.AddRange([string[]]@('-c', $Ctx))
    $a.AddRange([string[]]@('--host', '127.0.0.1'))
    $a.AddRange([string[]]@('--port', $SrvPort))
    $a.Add('--jinja')
    if ($Model.Template -and $Model.Template -ne '') {
        $a.AddRange([string[]]@('--chat-template', $Model.Template))
    }
    if ($Token -and $Token -ne '') { $env:HF_TOKEN = $Token }
    return $a.ToArray()
}

function Start-LlamaServer {
    param([PSCustomObject]$Model, [string]$Token, [int]$Ctx, [int]$SrvPort)

    $apiRoot    = "http://127.0.0.1:$SrvPort"
    $healthUrl  = "$apiRoot/health"
    $hfFile     = "$($Model.GgufBasename)-$($Model.Quantization).gguf"

    try {
        $r = Invoke-RestMethod -Uri $healthUrl -TimeoutSec 3 -ErrorAction Stop
        if ($r.status -eq 'ok') { Write-Ok "llama-server already running on $apiRoot"; return $apiRoot }
    } catch {}

    Write-Step "Starting llama-server  ($($Model.GgufRepo) / $hfFile)"
    Write-Info 'The GGUF will be downloaded from HuggingFace if not cached (may take a few minutes).'

    $serverArgs = Build-LlamaServerArgs -Model $Model -Token $Token -Ctx $Ctx -SrvPort $SrvPort
    Write-Info "  llama-server $($serverArgs -join ' ')"

    Start-Process -FilePath 'llama-server' -ArgumentList $serverArgs -WindowStyle Minimized

    $timeout = 600; $interval = 5; $elapsed = 0; $ready = $false
    Write-Host '     Waiting' -NoNewline -ForegroundColor Gray
    while ($elapsed -lt $timeout) {
        Start-Sleep -Seconds $interval; $elapsed += $interval
        Write-Host '.' -NoNewline -ForegroundColor Gray
        try {
            $r = Invoke-RestMethod -Uri $healthUrl -TimeoutSec 2 -ErrorAction Stop
            if ($r.status -eq 'ok') { $ready = $true; break }
        } catch {}
    }
    Write-Host ''

    if (-not $ready) { throw "llama-server did not become ready within ${timeout}s. Check the minimised window." }
    Write-Ok "llama-server ready  ($apiRoot)"
    return $apiRoot
}

# ─────────────────────────────────────────────────────────────────────────────
# Ollama runner
# ─────────────────────────────────────────────────────────────────────────────

function Start-OllamaModel {
    param([PSCustomObject]$Model, [int]$Ctx)

    $tag        = $Model.OllamaTag
    $apiRoot    = 'http://localhost:11434'
    $variantTag = ($tag -replace ':', '-') + "-ctx$([int]($Ctx/1024))k"

    # Pull base model if not present
    $listOut = & ollama list 2>&1
    if ($listOut -notmatch [regex]::Escape($tag)) {
        Write-Step "Pulling '$tag' via Ollama"
        & ollama pull $tag
        if ($LASTEXITCODE -ne 0) { throw "ollama pull $tag failed." }
        Write-Ok "Model '$tag' pulled"
    } else {
        Write-Ok "Base model '$tag' already present"
    }

    # Create context-extended variant
    $listOut = & ollama list 2>&1
    if ($listOut -notmatch [regex]::Escape($variantTag)) {
        Write-Step "Creating context-extended variant '$variantTag'  (num_ctx=$Ctx)"
        $modelfile = "FROM $tag`nPARAMETER num_ctx $Ctx"
        $tmpFile   = Join-Path $env:TEMP 'AutoLocalLLM.Modelfile'
        Set-Content -Path $tmpFile -Value $modelfile -Encoding utf8
        & ollama create $variantTag --file $tmpFile
        if ($LASTEXITCODE -ne 0) { throw "ollama create $variantTag failed." }
        Remove-Item $tmpFile -ErrorAction SilentlyContinue
        Write-Ok "Variant '$variantTag' created"
    } else {
        Write-Ok "Context variant '$variantTag' already exists"
    }

    return @{ apiRoot = $apiRoot; modelTag = $variantTag }
}

# ─────────────────────────────────────────────────────────────────────────────
# OpenCode configuration
# ─────────────────────────────────────────────────────────────────────────────

function Update-OpenCodeConfig {
    param([string]$ModelId, [string]$DisplayName, [string]$ApiBase, [string]$Runner)

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

    $providerKey  = if ($Runner -eq 'llamacpp') { 'llama-cpp' } else { 'ollama' }
    $providerName = if ($Runner -eq 'llamacpp') { 'llama.cpp Local' } else { 'Ollama Local' }

    if (-not $cfg['provider'].ContainsKey($providerKey)) {
        $cfg['provider'][$providerKey] = @{
            npm     = '@ai-sdk/openai-compatible'
            name    = $providerName
            options = @{ baseURL = "$ApiBase/v1" }
            models  = @{}
        }
    }

    $provider = $cfg['provider'][$providerKey]
    if (-not $provider.ContainsKey('models')) { $provider['models'] = @{} }
    $provider['models'][$ModelId] = @{ name = $DisplayName; tools = $true }

    $cfg | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath -Encoding utf8
    Write-Ok "OpenCode config written: $configPath"
    return $configPath
}

# ─────────────────────────────────────────────────────────────────────────────
# Startup helper script
# ─────────────────────────────────────────────────────────────────────────────

function Write-StartupScript {
    param([PSCustomObject]$Model, [string]$Token, [int]$Ctx, [int]$SrvPort)

    $scriptPath = Join-Path $script:LlamaCppDir 'Start-LlamaServer.ps1'

    if ($Model.Runner -eq 'llamacpp') {
        $serverArgs = Build-LlamaServerArgs -Model $Model -Token $Token -Ctx $Ctx -SrvPort $SrvPort
        $argsLine   = ($serverArgs | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '
        $tokenLine  = if ($Token) { "`$env:HF_TOKEN = '$Token'" } else {
            '# $env:HF_TOKEN = "hf_xxx"   # uncomment if model requires auth'
        }
        $content = @"
# Auto-generated by Setup-OpenCode-LLM.ps1  (runner: llama.cpp)
# Run this before using OpenCode when llama-server is not already running.

Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'

$tokenLine

`$healthUrl = "http://127.0.0.1:$SrvPort/health"
try {
    if ((Invoke-RestMethod -Uri `$healthUrl -TimeoutSec 2).status -eq 'ok') {
        Write-Host "llama-server already running."; exit 0
    }
} catch {}

Write-Host "Starting llama-server on http://127.0.0.1:$SrvPort ..."
llama-server $argsLine
"@
    } else {
        $tag        = $Model.OllamaTag
        $variantTag = ($tag -replace ':', '-') + "-ctx$([int]($Ctx/1024))k"
        $content = @"
# Auto-generated by Setup-OpenCode-LLM.ps1  (runner: Ollama)
# Run this before using OpenCode when Ollama is not already running.

Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'

try {
    if (Invoke-RestMethod -Uri 'http://localhost:11434/api/tags' -TimeoutSec 2) {
        Write-Host "Ollama already running."; exit 0
    }
} catch {}

Write-Host "Starting Ollama..."
Start-Process -FilePath 'ollama' -ArgumentList 'serve' -WindowStyle Hidden
Start-Sleep -Seconds 3
Write-Host "Ollama model: $variantTag"
ollama run $variantTag --keepalive -1
"@
    }

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
if ($Manual) {
Write-Host '  Mode: manual selection' -ForegroundColor DarkCyan
} else {
Write-Host '  Mode: auto  (use -Manual to pick from a list)' -ForegroundColor DarkGray
}
Write-Host ''

try {
    # 1. Core prerequisites (always needed)
    Write-Step 'Checking prerequisites'
    Install-Scoop
    Install-LlamaCpp
    Install-LlmFit
    Install-OpenCode

    # 2. Build ranked candidate list from LlmFit
    $candidates = Get-CodingCandidates -Limit $TopN

    # 3. Let user pick (or auto-select #1)
    $model = Select-Model -Candidates $candidates -IsManual $Manual.IsPresent

    Write-Host ''
    Write-Host '  Chosen model' -ForegroundColor White
    Write-Info "HuggingFace : $($model.HfId)"
    Write-Info "Runner      : $($model.Runner)"
    if ($model.Runner -eq 'llamacpp') {
        Write-Info "GGUF repo   : $($model.GgufRepo)"
        Write-Info "File        : $($model.GgufBasename)-$($model.Quantization).gguf"
    } else {
        Write-Info "Ollama tag  : $($model.OllamaTag)"
    }
    Write-Info "Score       : $($model.Score)   Params: $($model.Params)B   VRAM: $($model.MemPct)%"

    # 4. Launch model server (installs Ollama if needed)
    $apiBase = ''; $modelId = ''; $displayName = ''

    if ($model.Runner -eq 'llamacpp') {
        $apiBase     = Start-LlamaServer -Model $model -Token $HfToken -Ctx $ContextSize -SrvPort $Port
        $modelId     = "$($model.GgufBasename)-$($model.Quantization)".ToLower()
        $displayName = "$($model.GgufBasename) ($($model.Quantization), ctx=$ContextSize)"
    } else {
        Install-Ollama
        Start-OllamaDaemon
        $result      = Start-OllamaModel -Model $model -Ctx $ContextSize
        $apiBase     = $result.apiRoot
        $modelId     = $result.modelTag
        $displayName = "$($model.OllamaTag) (ctx=$ContextSize)"
    }

    # 5. Write OpenCode config
    $cfgPath = Update-OpenCodeConfig -ModelId $modelId -DisplayName $displayName `
                                      -ApiBase $apiBase -Runner $model.Runner

    # 6. Write startup helper
    $startScript = Write-StartupScript -Model $model -Token $HfToken -Ctx $ContextSize -SrvPort $Port

    # 7. Done
    Write-Host ''
    Write-Host '  +------------------------------------------------------------+' -ForegroundColor Green
    Write-Host '  |                    Setup Complete!                         |' -ForegroundColor Green
    Write-Host '  +------------------------------------------------------------+' -ForegroundColor Green
    Write-Host ''
    Write-Host "  Model    : $modelId"    -ForegroundColor Yellow
    Write-Host "  Server   : $apiBase"    -ForegroundColor Yellow
    Write-Host "  Config   : $cfgPath"    -ForegroundColor Yellow
    Write-Host "  Relaunch : $startScript" -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Start coding now:' -ForegroundColor White
    Write-Host '    opencode' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Press Ctrl+K inside OpenCode to open the model picker, then select:' -ForegroundColor White
    $providerLabel = if ($model.Runner -eq 'llamacpp') { 'llama-cpp' } else { 'ollama' }
    Write-Host "    $providerLabel > $modelId" -ForegroundColor Cyan
    Write-Host ''
    Write-Host "  After a reboot, restart the model server with:" -ForegroundColor Gray
    Write-Host "    $startScript" -ForegroundColor Gray
    Write-Host ''

} catch {
    Write-Host ''
    Write-Fail "Fatal: $_"
    Write-Host ''
    exit 1
}
