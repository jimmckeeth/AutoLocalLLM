#Requires -Version 5.1
<#
.SYNOPSIS
    Finds, downloads, and configures the best local LLM for coding with tool-use support.

.DESCRIPTION
    Installs prerequisites (llama.cpp, llmfit, OpenCode, Python) then delegates to
    llm-setup-helper.py for model selection, download, server launch, and config writing.

    Dependencies installed automatically if absent:
        Scoop    – Windows package manager    (https://scoop.sh)
        Python   – Orchestrator runtime       (https://python.org)
        llama.cpp – Local model runtime       (https://github.com/ggml-org/llama.cpp)
        LlmFit   – Hardware-aware selector    (https://github.com/AlexsJones/llmfit)
        OpenCode – Terminal AI coding agent   (https://opencode.ai)

.PARAMETER TopN
    Cap the number of candidates returned from LlmFit.  Default: unlimited.

.PARAMETER ContextSize
    Context window (-c) passed to llama-server.  Default: 16384.

.PARAMETER Port
    Port llama-server listens on.  Default: 8080.

.PARAMETER HfToken
    HuggingFace token for gated models.

.PARAMETER Manual
    Display the ranked candidate list and prompt you to pick a model.

.PARAMETER Force
    Re-download model even if already cached.

.PARAMETER Update
    Refresh the LlmFit model database before querying.

.EXAMPLE
    .\Setup-OpenCode-LLM.ps1                        # fully automatic
    .\Setup-OpenCode-LLM.ps1 -Manual                # choose from ranked list
    .\Setup-OpenCode-LLM.ps1 -Update -Manual        # refresh DB, then choose
    .\Setup-OpenCode-LLM.ps1 -HfToken hf_xxx        # gated models
#>
[CmdletBinding()]
param (
    [int]$TopN = 0,

    [ValidateSet(4096, 8192, 16384, 32768, 65536)]
    [int]$ContextSize = 16384,

    [ValidateRange(1024, 65535)]
    [int]$Port = 8080,

    [string]$HfToken = '',

    [switch]$Manual,
    [switch]$Force,
    [switch]$Update,

    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$ExtraArgs = @()
)

# Accept GNU-style --double-dash args so bash muscle-memory works in PowerShell
$i = 0
while ($i -lt $ExtraArgs.Count) {
    switch ($ExtraArgs[$i].ToLower()) {
        '--manual'   { $Manual      = [switch]$true         }
        '--force'    { $Force       = [switch]$true         }
        '--update'   { $Update      = [switch]$true         }
        '--top-n'    { $TopN        = [int]$ExtraArgs[++$i] }
        '--context'  { $ContextSize = [int]$ExtraArgs[++$i] }
        '--port'     { $Port        = [int]$ExtraArgs[++$i] }
        '--hf-token' { $HfToken     = $ExtraArgs[++$i]      }
        default      { Write-Warning "Unknown argument: $($ExtraArgs[$i])" }
    }
    $i++
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────────────────────────────────────
# Paths
# ─────────────────────────────────────────────────────────────────────────────

$script:LlamaCppDir  = Join-Path $env:LOCALAPPDATA 'llama.cpp'
$script:LlamaBinDir  = Join-Path $script:LlamaCppDir 'bin'
$script:ShareDir     = Join-Path $script:LlamaCppDir 'autolocalllm'
$script:ScriptDir    = $PSScriptRoot
$script:PythonHelper = Join-Path $script:ScriptDir 'llm-setup-helper.py'

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

function Install-Python {
    if (Test-CommandExists 'python') {
        $v = & python --version 2>&1
        Write-Ok "Python already installed: $v"; return
    }
    Write-Step 'Installing Python'
    if (Test-CommandExists 'scoop') {
        scoop install python
    } else {
        $tmpInstaller = Join-Path $env:TEMP 'python-installer.exe'
        Write-Info 'Downloading Python installer'
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri 'https://www.python.org/ftp/python/3.12.0/python-3.12.0-amd64.exe' `
                          -OutFile $tmpInstaller
        $ProgressPreference = 'Continue'
        Start-Process -FilePath $tmpInstaller `
                      -ArgumentList '/quiet', 'InstallAllUsers=0', 'PrependPath=1' `
                      -Wait
        Remove-Item $tmpInstaller -ErrorAction SilentlyContinue
        $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'User') + ';' +
                    [System.Environment]::GetEnvironmentVariable('PATH', 'Machine')
    }
    if (-not (Test-CommandExists 'python')) {
        throw 'Python installation failed. Install from https://python.org then re-run.'
    }
    Write-Ok "Python installed: $(& python --version 2>&1)"
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
# Entry point
# ─────────────────────────────────────────────────────────────────────────────

try {
    if (-not (Test-Path $script:PythonHelper)) {
        throw "Helper not found: $($script:PythonHelper)  (run from the cloned repo directory)"
    }

    # 1. Install prerequisites
    Write-Step 'Checking prerequisites'
    Install-Scoop
    Install-Python
    Install-LlamaCpp
    Install-LlmFit
    Install-OpenCode

    # 2. Hand off to Python orchestrator
    New-Item -ItemType Directory -Path $script:ShareDir -Force | Out-Null

    $pyArgs = @('setup')
    if ($Manual)      { $pyArgs += '--manual' }
    if ($Force)       { $pyArgs += '--force'  }
    if ($Update)      { $pyArgs += '--update' }
    if ($TopN -gt 0)  { $pyArgs += @('--top-n',    $TopN)        }
    if ($HfToken)     { $pyArgs += @('--hf-token',  $HfToken)    }
    $pyArgs += @('--port',      $Port)
    $pyArgs += @('--context',   $ContextSize)
    $pyArgs += @('--bin-dir',   $script:LlamaBinDir)
    $pyArgs += @('--lib-dir',   $script:LlamaBinDir)
    $pyArgs += @('--share-dir', $script:ShareDir)

    & python $script:PythonHelper @pyArgs
    if ($LASTEXITCODE -ne 0) { throw "llm-setup-helper.py exited with code $LASTEXITCODE" }

} catch {
    Write-Host ''
    Write-Fail "Fatal: $_"
    Write-Host ''
    exit 1
}
