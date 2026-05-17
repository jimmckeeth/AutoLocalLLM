# AutoLocalLLM

> One command to find, download, and configure the best local AI coding assistant for your hardware.

AutoLocalLLM chains three open-source tools to give you a fully offline, private AI coding agent in a single step:

1. **[LlmFit](https://github.com/AlexsJones/llmfit)** — scans your RAM, VRAM, and CPU to rank which LLMs will run well on your hardware, filtered for _coding_ and _tool-use_ capability.
2. **[llama.cpp](https://github.com/ggml-org/llama.cpp)** _(primary)_ / **[Ollama](https://ollama.com)** _(fallback)_ — downloads the GGUF and serves an OpenAI-compatible local API.
3. **[OpenCode](https://opencode.ai)** — a terminal AI coding agent that connects to that local API.

| Script                                             | Platform                         |
| -------------------------------------------------- | -------------------------------- |
| [`Setup-OpenCode-LLM.ps1`](Setup-OpenCode-LLM.ps1) | Windows 10/11 (PowerShell 5.1+)  |
| [`setup-opencode-llm.sh`](setup-opencode-llm.sh)   | Debian · Ubuntu · Fedora · NixOS |

All missing dependencies are installed automatically.

---

## Contents

- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Parameters](#parameters)
- [Interactive Model Picker](#interactive-model-picker---manual)
- [How Runners Are Chosen](#how-runners-are-chosen)
- [After a Reboot](#after-a-reboot)
- [Generated Files](#generated-files)
- [Supported Models](#supported-models)
- [Manual Setup](#manual-setup)
- [Troubleshooting](#troubleshooting)
- [Resources](#resources)

---

## Requirements

|              | Minimum                                     | Notes                                                            |
| ------------ | ------------------------------------------- | ---------------------------------------------------------------- |
| **OS**       | Windows 10/11 or Debian/Ubuntu/Fedora/NixOS |                                                                  |
| **RAM**      | 8 GB                                        | 16 GB+ recommended for 7–8B models                               |
| **Disk**     | 5–50 GB                                     | Depends on model size and quantization                           |
| **GPU**      | Optional                                    | NVIDIA CUDA · AMD ROCm/Vulkan · Intel Vulkan · CPU-only all work |
| **Internet** | Required on first run                       | Model is cached locally after the initial download               |

---

## Quick Start

### Windows

```powershell
# Elevated PowerShell is required for the global npm install
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser   # one-time
.\Setup-OpenCode-LLM.ps1
```

### Linux

```bash
chmod +x setup-opencode-llm.sh
./setup-opencode-llm.sh
```

Both scripts:

1. Install any missing tools (llama.cpp, LlmFit, OpenCode — and Scoop on Windows)
2. Query LlmFit for the best coding + tool-use models your hardware can run
3. Select the top result; `llama-server` downloads its GGUF from HuggingFace automatically
4. Start `llama-server` with `--jinja` (OpenAI-style tool calling)
5. Write `~/.config/opencode/config.json` pointing at the local API
6. Generate a startup script for relaunching after a reboot

Then open a new terminal and run:

```
opencode
```

Press **Ctrl+K** inside OpenCode and select the model under **llama-cpp** (or **ollama** if Ollama was used as the fallback runner).

---

## Parameters

Both scripts accept the same logical options:

| PowerShell       | Bash                   | Default  | Description                                               |
| ---------------- | ---------------------- | -------- | --------------------------------------------------------- |
| `-Manual`        | `--manual` / `-m`      | off      | Show ranked candidate table; pick a model interactively   |
| `-TopN N`        | `--top-n N` / `-n N`   | `20`     | Number of LlmFit candidates to fetch before filtering     |
| `-ContextSize N` | `--context N` / `-c N` | `16384`  | Context window (tokens) passed to the model server        |
| `-Port N`        | `--port N` / `-p N`    | `8080`   | llama-server port (unused when Ollama is the runner)      |
| `-HfToken TOKEN` | `--hf-token TOKEN`     | _(none)_ | HuggingFace access token for gated models                 |
| `-Force`         | `--force` / `-f`       | off      | Re-download model and overwrite the OpenCode config entry |

> **PowerShell note:** Parameters use PowerShell's single-dash style (`-Manual`, `-TopN 20`, `-ContextSize 32768`). The script also accepts GNU-style double-dash flags (`--manual`, `--top-n 20`) for convenience.

### Examples

**Windows (PowerShell)**

```powershell
.\Setup-OpenCode-LLM.ps1                                      # fully automatic
.\Setup-OpenCode-LLM.ps1 -Manual                              # pick from a list
.\Setup-OpenCode-LLM.ps1 -Manual -TopN 20 -ContextSize 32768  # wider pool, bigger context
.\Setup-OpenCode-LLM.ps1 -HfToken hf_xxxxxxxxxxxxxxxxxxxx     # gated model (e.g. Llama)
.\Setup-OpenCode-LLM.ps1 -Force                               # fresh download + config
```

**Linux (Bash)**

```bash
./setup-opencode-llm.sh
./setup-opencode-llm.sh --manual
./setup-opencode-llm.sh --manual --top-n 20 --context 32768
./setup-opencode-llm.sh --hf-token hf_xxxxxxxxxxxxxxxxxxxx
./setup-opencode-llm.sh --force
```

---

## Interactive Model Picker (`--manual`)

Pass `-Manual` (Windows) or `--manual` (Linux) to see all filtered candidates before anything downloads:

```
  ──────────────────────────────────────────────────────────────────────
  #   | Model                                | Params  | Score | VRAM% | Runner
  ──────────────────────────────────────────────────────────────────────
  1   | Qwen3-8B (Q4_K_M)                    | 8B      | 92.3  | 68%   | llama.cpp
  2   | Qwen2.5-Coder-7B-Instruct (Q4_K_M)   | 7B      | 89.1  | 62%   | llama.cpp
  3   | Llama-3.1-8B-Instruct (Q4_K_M)       | 8B      | 87.4  | 65%   | llama.cpp
  4   | deepseek-r1:8b                        | 8B      | 84.2  | 64%   | Ollama
  ──────────────────────────────────────────────────────────────────────

  Enter number [1-4] or press Enter for #1:
```

- The list is sorted by LlmFit's composite coding score (quality · speed · memory fit).
- **Runner** shows `llama.cpp` for models with a known bartowski GGUF repo, or `Ollama` for fallbacks.
- Press **Enter** to accept the top-ranked model without typing anything.

---

## How Runners Are Chosen

| Condition                                                                                    | Runner                      |
| -------------------------------------------------------------------------------------------- | --------------------------- |
| Model has a [bartowski](https://huggingface.co/bartowski) GGUF repo in the built-in database | **llama.cpp** _(preferred)_ |
| No GGUF mapping, but model has an Ollama registry tag                                        | **Ollama** _(fallback)_     |

**llama.cpp runner** — starts `llama-server` with `--hf-repo`/`--hf-file` (automatic GGUF download) and `--jinja` for OpenAI-style tool/function calling.

**Ollama runner** — runs `ollama pull`, then creates a context-extended variant via a Modelfile (e.g. `qwen3-8b-ctx16k`) so tool calls work reliably at larger context sizes.

The OpenCode `config.json` provider key and API base URL are set correctly for whichever runner is used.

---

## After a Reboot

Neither `llama-server` nor Ollama auto-starts on login. Before opening OpenCode after a reboot, run the generated startup script:

**Windows:**

```powershell
& "$env:LOCALAPPDATA\llama.cpp\Start-LlamaServer.ps1"
```

**Linux:**

```bash
bash ~/.local/share/autolocalllm/start-llama-server.sh
```

Leave that terminal open while you use `opencode`. The script skips startup if the server is already running.

---

## Generated Files

| Path                                                | Platform | Purpose                                      |
| --------------------------------------------------- | -------- | -------------------------------------------- |
| `~/.config/opencode/config.json`                    | Both     | OpenCode provider config (created or merged) |
| `%LOCALAPPDATA%\llama.cpp\bin\`                     | Windows  | llama-server and companion binaries          |
| `%LOCALAPPDATA%\llama.cpp\Start-LlamaServer.ps1`    | Windows  | Reboot startup helper                        |
| `~/.local/bin/llama-server`                         | Linux    | llama-server binary                          |
| `~/.local/share/autolocalllm/start-llama-server.sh` | Linux    | Reboot startup helper                        |
| `~/.cache/huggingface/hub/`                         | Both     | GGUF model cache (managed by llama-server)   |

### Example — llama.cpp provider config

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "llama-cpp": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "llama.cpp Local",
      "options": { "baseURL": "http://127.0.0.1:8080/v1" },
      "models": {
        "qwen3-8b-q4_k_m": {
          "name": "Qwen3-8B (Q4_K_M, ctx=16384)",
          "tools": true
        }
      }
    }
  }
}
```

### Example — Ollama provider config

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama Local",
      "options": { "baseURL": "http://localhost:11434/v1" },
      "models": {
        "qwen3-8b-ctx16k": {
          "name": "qwen3:8b (ctx=16384)",
          "tools": true
        }
      }
    }
  }
}
```

> **`"tools": true` is required.** Without it OpenCode cannot use agentic features (file editing, running commands, etc.).

---

## Supported Models

The built-in database covers these tool-use capable coding models. Models outside this list are skipped during filtering. To add a model, append an entry to the `$ModelDb` table (PowerShell) or `MODEL_DB` dict (bash) in the respective script.

| Family                    | Sizes      | Notes                                            |
| ------------------------- | ---------- | ------------------------------------------------ |
| **Qwen3**                 | 0.6B – 32B | Top coding scores; MoE 30B-A3B is VRAM-efficient |
| **Qwen2.5-Coder**         | 1.5B – 32B | Coding-specialized fine-tune of Qwen2.5          |
| **QwQ-32B**               | 32B        | Reasoning + coding; strong tool use              |
| **Llama 3.1 / 3.2 / 3.3** | 1B – 70B   | Gated — requires `--hf-token`                    |
| **Mistral 7B / Nemo 12B** | 7B, 12B    | Fast; reliable tool calling                      |
| **Devstral Small**        | 24B        | Mistral's coding-focused model                   |
| **Phi-4 / Phi-4-mini**    | 3.8B, 14B  | Microsoft; strong at reasoning and code          |
| **Gemma 3**               | 1B – 27B   | Google; good instruction following               |
| **Command-R 7B**          | 7B         | Cohere; strong native tool use                   |
| **DeepSeek-R1 distills**  | 7B – 32B   | Requires `--chat-template deepseek-r1`           |

All models are paired with both a [bartowski](https://huggingface.co/bartowski) GGUF repo (llama.cpp) and an [Ollama](https://ollama.com/library) registry tag (fallback).

---

## Manual Setup

Follow these steps to install and configure each component without running the scripts.

### 1 — Package manager

**Windows — install Scoop:**

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
Invoke-RestMethod -Uri https://get.scoop.sh | Invoke-Expression
```

**Linux** — use the native package manager (`apt` / `dnf` / `nix`). No extra step required.

---

### 2 — LlmFit

**Windows:**

```powershell
scoop install llmfit
```

**Linux:**

```bash
# Grab the latest x86_64 release and drop it in ~/.local/bin
LLMFIT_URL=$(curl -fsSL https://api.github.com/repos/AlexsJones/llmfit/releases/latest \
  | python3 -c "
import json, sys
for a in json.load(sys.stdin)['assets']:
    if 'x86_64' in a['name'] and 'linux' in a['name']:
        print(a['browser_download_url']); break
")
curl -fsSL "$LLMFIT_URL" | tar -xz --wildcards --strip-components=1 -C ~/.local/bin 'llmfit'
chmod +x ~/.local/bin/llmfit
```

**Usage:**

```bash
llmfit                                               # interactive TUI
llmfit fit --use-case coding --cli -n 10             # CLI ranked table
llmfit recommend --json --use-case coding --limit 10 # machine-readable JSON
```

Docs: [README](https://github.com/AlexsJones/llmfit/blob/main/README.md) · [llmfit.org](https://www.llmfit.org/)

---

### 3 — llama.cpp

**Windows:**

```powershell
scoop install llama
```

**Linux — Fedora:**

```bash
sudo dnf install llama-cpp
```

**Linux — NixOS / Nix:**

```bash
nix profile install nixpkgs#llama-cpp
```

**Linux — Debian/Ubuntu (pre-built binary from GitHub Releases):**

| GPU          | Asset                                         |
| ------------ | --------------------------------------------- |
| NVIDIA CUDA  | `llama-bXXXX-bin-ubuntu-cuda-12.4-x64.tar.gz` |
| AMD ROCm     | `llama-bXXXX-bin-ubuntu-rocm-7.2-x64.tar.gz`  |
| Vulkan / CPU | `llama-bXXXX-bin-ubuntu-vulkan-x64.tar.gz`    |

Download from [github.com/ggml-org/llama.cpp/releases](https://github.com/ggml-org/llama.cpp/releases), then:

```bash
tar -xzf llama-bXXXX-bin-ubuntu-*.tar.gz -C ~/.local/bin/
chmod +x ~/.local/bin/llama-server
```

**Windows (manual download):**

| GPU         | Asset                                   |
| ----------- | --------------------------------------- |
| NVIDIA      | `llama-bXXXX-bin-win-cuda-12.4-x64.zip` |
| AMD / Intel | `llama-bXXXX-bin-win-vulkan-x64.zip`    |
| CPU only    | `llama-bXXXX-bin-win-cpu-x64.zip`       |

Extract and add the folder to your `PATH`.

**Start llama-server** — it downloads the GGUF automatically on first run:

```bash
# Linux / macOS
llama-server \
  --hf-repo bartowski/Qwen_Qwen3-8B-GGUF \
  --hf-file Qwen3-8B-Q4_K_M.gguf \
  --jinja \
  -c 16384 \
  --host 127.0.0.1 \
  --port 8080

# Windows PowerShell (backtick for line continuation)
llama-server `
  --hf-repo bartowski/Qwen_Qwen3-8B-GGUF `
  --hf-file Qwen3-8B-Q4_K_M.gguf `
  --jinja `
  -c 16384 `
  --host 127.0.0.1 `
  --port 8080
```

| Flag                   | Purpose                                                   |
| ---------------------- | --------------------------------------------------------- |
| `--hf-repo`            | HuggingFace GGUF repo to download from                    |
| `--hf-file`            | Specific quantization file within that repo               |
| `--jinja`              | **Required** — enables OpenAI-style tool/function calling |
| `-c N`                 | Context window size in tokens                             |
| `--chat-template NAME` | Override chat template (DeepSeek R1 needs `deepseek-r1`)  |

Docs: [llama-server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md) · [Function calling guide](https://github.com/ggml-org/llama.cpp/blob/master/docs/function-calling.md)

---

### 4 — Ollama (optional fallback runner)

**Windows:**

```powershell
scoop install ollama
# or: download OllamaSetup.exe from https://ollama.com/download
```

**Linux:**

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

**NixOS / Nix:**

```bash
nix profile install nixpkgs#ollama
```

**Pull a model and create a context-extended variant:**

```bash
ollama pull qwen3:8b

# Create a variant with a larger context window for reliable tool calls
printf 'FROM qwen3:8b\nPARAMETER num_ctx 16384\n' | ollama create qwen3-8b-ctx16k -f -

ollama serve   # start the daemon
```

Docs: [Ollama docs](https://github.com/ollama/ollama/blob/main/docs/README.md) · [OpenCode + Ollama](https://docs.ollama.com/integrations/opencode)

---

### 5 — OpenCode

**Windows:**

```powershell
npm install --global opencode-ai@latest   # recommended
scoop install opencode                     # alternative
```

**Linux — Debian/Ubuntu:**

```bash
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs
npm install --global opencode-ai@latest
```

**Linux — Fedora:**

```bash
curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo bash -
sudo dnf install -y nodejs
npm install --global opencode-ai@latest
```

**Linux — NixOS / Nix:**

```bash
nix profile install nixpkgs#nodejs_20
npm install --global opencode-ai@latest
```

Docs: [opencode.ai](https://opencode.ai) · [GitHub](https://github.com/sst/opencode) · [Providers](https://opencode.ai/docs/providers/)

---

### 6 — Configure OpenCode manually

Edit `~/.config/opencode/config.json` (create it if it doesn't exist):

**llama.cpp:**

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "llama-cpp": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "llama.cpp Local",
      "options": { "baseURL": "http://127.0.0.1:8080/v1" },
      "models": {
        "your-model-id": { "name": "Display Name", "tools": true }
      }
    }
  }
}
```

**Ollama:**

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama Local",
      "options": { "baseURL": "http://localhost:11434/v1" },
      "models": {
        "qwen3-8b-ctx16k": { "name": "Qwen3 8B (ctx=16384)", "tools": true }
      }
    }
  }
}
```

> **`"tools": true` is required** for OpenCode to use agentic features (file editing, terminal commands, search, etc.).

---

## Troubleshooting

**llama-server exits immediately after starting**
Run the command manually in a terminal to see the error. Common causes: insufficient VRAM, missing CUDA libraries, or a corrupt partial download. Delete the cached file under `~/.cache/huggingface/hub/` and retry.

**OpenCode shows no models or tool calls fail**

- Check the server is up: `curl http://127.0.0.1:8080/health`
- Verify `"tools": true` is in `config.json`
- Verify `--jinja` was passed to `llama-server`

**Model download is very slow**
The GGUF is streamed and cached to `~/.cache/huggingface/hub/` on first run. Subsequent launches skip the download. Progress is visible in the llama-server log or terminal.

**Gated model — 403 from HuggingFace**
Meta Llama and a few others require license acceptance:

1. Log in at [huggingface.co](https://huggingface.co)
2. Open the model page and click **Accept** on the license agreement
3. Create a token at [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens)
4. Re-run with `--hf-token hf_xxx` (Linux) or `-HfToken hf_xxx` (Windows)

**Out of memory — model won't load**
Run `llmfit fit --use-case coding --cli` and choose a model where the **Fit** column shows **Good** or **Perfect**. Alternatively lower the context window to reduce KV-cache memory use: `--context 8192` (Linux) or `-ContextSize 8192` (Windows).

**Linux: `llama-server` or `llmfit` not found after install**
Binaries are placed in `~/.local/bin/`. Ensure it's on your `PATH`:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc
```

**Linux: `opencode` not found after `npm install --global`**

```bash
echo 'export PATH="$(npm prefix -g)/bin:$PATH"' >> ~/.bashrc && source ~/.bashrc
```

**NixOS: `nix profile install` fails**
Try the legacy interface: `nix-env -iA nixpkgs.llama-cpp`. On a managed NixOS system you may prefer declaring packages in `configuration.nix` or `home.nix` instead.

**Linux: permission denied when running the script**

```bash
chmod +x setup-opencode-llm.sh && ./setup-opencode-llm.sh
```

---

## Resources

| Resource                       | URL                                                                          |
| ------------------------------ | ---------------------------------------------------------------------------- |
| LlmFit GitHub                  | <https://github.com/AlexsJones/llmfit>                                       |
| LlmFit website                 | <https://www.llmfit.org/>                                                    |
| llama.cpp GitHub               | <https://github.com/ggml-org/llama.cpp>                                      |
| llama.cpp releases             | <https://github.com/ggml-org/llama.cpp/releases>                             |
| llama-server docs              | <https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md>   |
| llama.cpp function calling     | <https://github.com/ggml-org/llama.cpp/blob/master/docs/function-calling.md> |
| Ollama                         | <https://ollama.com>                                                         |
| Ollama model library           | <https://ollama.com/library>                                                 |
| Ollama + OpenCode              | <https://docs.ollama.com/integrations/opencode>                              |
| OpenCode                       | <https://opencode.ai>                                                        |
| OpenCode GitHub                | <https://github.com/sst/opencode>                                            |
| OpenCode provider config       | <https://opencode.ai/docs/providers/>                                        |
| bartowski GGUF repos           | <https://huggingface.co/bartowski>                                           |
| Scoop (Windows)                | <https://scoop.sh>                                                           |
| NodeSource (Node.js for Linux) | <https://github.com/nodesource/distributions>                                |
| HuggingFace access tokens      | <https://huggingface.co/settings/tokens>                                     |

---

## License

[AGPL-3.0](LICENSE)
