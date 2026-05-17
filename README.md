# AutoLocalLLM

> One PowerShell script to find, download, and configure the best local AI coding assistant for your hardware.

`Setup-OpenCode-LLM.ps1` chains three tools together:

1. **[LlmFit](https://github.com/AlexsJones/llmfit)** — scans your RAM, VRAM, and CPU and ranks which LLMs will actually run well on your machine, filtered specifically for *coding* and *tool-use* capability.
2. **[llama.cpp](https://github.com/ggml-org/llama.cpp)** (primary) / **[Ollama](https://ollama.com)** (fallback) — downloads the GGUF model and serves an OpenAI-compatible API locally.
3. **[OpenCode](https://opencode.ai)** — a terminal AI coding agent that connects to that local API, giving you a fully offline, private coding assistant.

---

## Requirements

| Tool | Minimum | Notes |
|------|---------|-------|
| Windows | 10 / 11 | PowerShell 5.1+ (built-in) |
| RAM | 8 GB | 16 GB+ recommended for 7–8 B models |
| Disk | 5–50 GB | Depends on model size |
| GPU | optional | NVIDIA / AMD / Intel; CPU-only also works |

The script installs missing dependencies automatically. You can also install them manually first — see [Manual Setup](#manual-setup) below.

---

## Quick Start

```powershell
# Run from an elevated PowerShell window (required for global npm installs)
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser   # once, if needed
.\Setup-OpenCode-LLM.ps1
```

That's it. The script will:

- Install [Scoop](https://scoop.sh), [llama.cpp](https://github.com/ggml-org/llama.cpp/releases), [LlmFit](https://github.com/AlexsJones/llmfit), and [OpenCode](https://opencode.ai) if any are missing
- Ask LlmFit which coding + tool-use models fit your hardware
- Auto-select the highest-ranked model and download its GGUF via llama-server
- Start `llama-server` with Jinja tool-calling enabled
- Write `~/.config/opencode/config.json` with the local provider
- Generate `%LOCALAPPDATA%\llama.cpp\Start-LlamaServer.ps1` for future restarts

Once finished, open a new terminal and run:

```
opencode
```

Press **Ctrl+K** inside OpenCode, then select the model under **llama-cpp** (or **ollama** if the fallback runner was used).

---

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-Manual` | off | Show a ranked table of candidates and pick a model interactively |
| `-TopN` | `10` | Number of models to request from LlmFit before filtering |
| `-ContextSize` | `16384` | Context window size (tokens) passed to the model server |
| `-Port` | `8080` | Port llama-server listens on (ignored when using Ollama) |
| `-HfToken` | _(none)_ | HuggingFace token for gated models (e.g. Meta Llama) |
| `-Force` | off | Re-download and overwrite config even if already present |

### Examples

```powershell
# Automatic — best model for your hardware, no prompts
.\Setup-OpenCode-LLM.ps1

# Interactive — show ranked list, pick a model yourself
.\Setup-OpenCode-LLM.ps1 -Manual

# Wider candidate pool + larger context window
.\Setup-OpenCode-LLM.ps1 -Manual -TopN 20 -ContextSize 32768

# Gated Meta Llama models (requires HuggingFace account and model access)
.\Setup-OpenCode-LLM.ps1 -HfToken hf_xxxxxxxxxxxxxxxxxxxxxxxx

# Force a fresh download and config overwrite
.\Setup-OpenCode-LLM.ps1 -Force
```

---

## Interactive Model Picker (`-Manual`)

When `-Manual` is set, a ranked table is printed before any download begins:

```
  -------------------------------------------------------------------
   #  | Model                                  | Params | Score | VRAM% | Runner
  -------------------------------------------------------------------
   1  | Qwen3-8B (Q4_K_M)                      | 8B     | 92.3  | 68%   | llama.cpp
   2  | Qwen2.5-Coder-7B-Instruct (Q4_K_M)     | 7B     | 89.1  | 62%   | llama.cpp
   3  | Llama-3.1-8B-Instruct (Q4_K_M)         | 8B     | 87.4  | 65%   | llama.cpp
   4  | deepseek-r1:8b                          | 8B     | 84.2  | 64%   | Ollama
  -------------------------------------------------------------------

  Enter number [1-4] or press Enter for #1:
```

- Models are ranked by LlmFit's composite coding score (quality × speed × memory fit).
- The **Runner** column shows `llama.cpp` for models with a GGUF mapping and `Ollama` for fallbacks.
- Pressing Enter without a number selects #1.

---

## How Runners Are Chosen

| Condition | Runner used |
|-----------|-------------|
| Model has a known [bartowski](https://huggingface.co/bartowski) GGUF repo | **llama.cpp** (preferred) |
| No GGUF mapping, but model is in Ollama registry | **Ollama** (fallback) |

**llama.cpp** uses `llama-server --hf-repo ... --hf-file ... --jinja` — the `--jinja` flag enables OpenAI-style function/tool calling required by OpenCode.

**Ollama** pulls the base model and creates a context-extended variant (e.g. `qwen3-8b-ctx16k`) via a Modelfile so tool calls work reliably at larger context sizes.

---

## Generated Files

| Path | Purpose |
|------|---------|
| `~/.config/opencode/config.json` | OpenCode provider config (created/merged) |
| `%LOCALAPPDATA%\llama.cpp\bin\` | llama-server and supporting binaries |
| `%LOCALAPPDATA%\llama.cpp\Start-LlamaServer.ps1` | Startup helper — run this after a reboot |
| `~/.cache/huggingface\hub\` | HuggingFace model cache (managed by llama-server) |

### OpenCode config (`llama.cpp` runner)

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "llama-cpp": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "llama.cpp Local",
      "options": {
        "baseURL": "http://127.0.0.1:8080/v1"
      },
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

### OpenCode config (`Ollama` runner)

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama Local",
      "options": {
        "baseURL": "http://localhost:11434/v1"
      },
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

---

## After a Reboot

`llama-server` and Ollama are not set to auto-start. Before using OpenCode after a reboot, run the generated startup script:

```powershell
& "$env:LOCALAPPDATA\llama.cpp\Start-LlamaServer.ps1"
```

Leave that window open while you use `opencode`.

---

## Manual Setup

If you prefer to install and configure each tool yourself, follow the steps below.

### 1 — Install Scoop (Windows package manager)

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
Invoke-RestMethod -Uri https://get.scoop.sh | Invoke-Expression
```

Docs: [scoop.sh](https://scoop.sh) · [GitHub](https://github.com/ScoopInstaller/Scoop)

---

### 2 — Install LlmFit

```powershell
scoop install llmfit
```

Or download the latest Windows binary from the [Releases page](https://github.com/AlexsJones/llmfit/releases), extract the zip, and add the folder to your `PATH`.

**Find the best coding models for your hardware:**

```powershell
# Interactive TUI (default)
llmfit

# CLI table — top 10 coding models
llmfit fit --use-case coding --cli -n 10

# JSON output for scripting
llmfit recommend --json --use-case coding --limit 10
```

Docs: [llmfit README](https://github.com/AlexsJones/llmfit/blob/main/README.md) · [llmfit.org](https://www.llmfit.org/)

---

### 3 — Install llama.cpp

```powershell
scoop install llama
```

Or download a pre-built Windows binary from [Releases](https://github.com/ggml-org/llama.cpp/releases):

| Your GPU | Asset to download |
|----------|-------------------|
| NVIDIA | `llama-bXXXX-bin-win-cuda-12.4-x64.zip` |
| AMD / Intel | `llama-bXXXX-bin-win-vulkan-x64.zip` |
| CPU only | `llama-bXXXX-bin-win-cpu-x64.zip` |

Extract and add the folder to your `PATH`.

**Start llama-server (downloads GGUF automatically from HuggingFace):**

```powershell
llama-server `
  --hf-repo bartowski/Qwen_Qwen3-8B-GGUF `
  --hf-file Qwen3-8B-Q4_K_M.gguf `
  --jinja `
  -c 16384 `
  --host 127.0.0.1 `
  --port 8080
```

Key flags:

| Flag | Purpose |
|------|---------|
| `--hf-repo` | HuggingFace repo to download the GGUF from |
| `--hf-file` | Specific GGUF file within that repo |
| `--jinja` | **Required** for OpenAI-style tool/function calling |
| `-c` | Context window size (tokens) |
| `--chat-template` | Override template (needed for DeepSeek R1: `deepseek-r1`) |

Docs: [llama-server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md) · [Function calling guide](https://github.com/ggml-org/llama.cpp/blob/master/docs/function-calling.md)

---

### 4 — Install Ollama (optional fallback)

```powershell
scoop install ollama
# or download from https://ollama.com/download
```

**Pull a model and create a context-extended variant:**

```powershell
ollama pull qwen3:8b

# Increase context window for better tool-call reliability
$modelfile = "FROM qwen3:8b`nPARAMETER num_ctx 16384"
$modelfile | ollama create qwen3-8b-ctx16k -f -
```

**Start the daemon:**

```powershell
ollama serve
```

Docs: [ollama.com/docs](https://github.com/ollama/ollama/blob/main/docs/README.md) · [OpenCode + Ollama integration](https://docs.ollama.com/integrations/opencode)

---

### 5 — Install OpenCode

```powershell
# via npm (recommended)
npm install --global opencode-ai@latest

# or via Scoop
scoop install opencode
```

Docs: [opencode.ai](https://opencode.ai) · [GitHub](https://github.com/sst/opencode)

---

### 6 — Configure OpenCode manually

Create (or edit) `~/.config/opencode/config.json`:

**llama.cpp provider:**

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "llama-cpp": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "llama.cpp Local",
      "options": {
        "baseURL": "http://127.0.0.1:8080/v1"
      },
      "models": {
        "your-model-id": {
          "name": "Display Name",
          "tools": true
        }
      }
    }
  }
}
```

**Ollama provider:**

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama Local",
      "options": {
        "baseURL": "http://localhost:11434/v1"
      },
      "models": {
        "qwen3-8b-ctx16k": {
          "name": "Qwen3 8B (ctx=16384)",
          "tools": true
        }
      }
    }
  }
}
```

> **`"tools": true` is required.** Without it, OpenCode cannot use agentic features (file editing, shell commands, etc.).

---

## Supported Models

The script knows about these tool-use capable coding models out of the box. Any model not in this list is skipped during filtering (you can add entries to `$ModelDb` in the script).

| Model family | Sizes | Tool use | Notes |
|---|---|---|---|
| **Qwen3** | 0.6B – 32B | ✅ | Excellent for coding; MoE 30B-A3B is very efficient |
| **Qwen2.5-Coder** | 1.5B – 32B | ✅ | Coding-specialized fine-tune |
| **QwQ-32B** | 32B | ✅ | Reasoning + coding |
| **Llama 3.1 / 3.2 / 3.3** | 1B – 70B | ✅ | Gated on HuggingFace — needs `-HfToken` |
| **Mistral 7B / Nemo** | 7B, 12B | ✅ | Fast; good general coding |
| **Devstral Small** | 24B | ✅ | Mistral's coding-focused model |
| **Phi-4 / Phi-4-mini** | 3.8B, 14B | ✅ | Microsoft; strong at reasoning |
| **Gemma 3** | 1B – 27B | ✅ | Google; good instruction following |
| **Command-R 7B** | 7B | ✅ | Cohere; strong tool use |
| **DeepSeek-R1 distills** | 7B – 32B | ✅ | Requires `deepseek-r1` chat template |

---

## Troubleshooting

**`llama-server` window closes immediately**
The model file may not have been found or the HuggingFace download failed. Run the server command manually in a terminal to see the error output.

**OpenCode shows "No models" or tool calls fail**
- Confirm `llama-server` is running: `curl http://127.0.0.1:8080/health`
- Confirm `"tools": true` is set in `config.json`
- Confirm `--jinja` was passed to `llama-server`

**Model download is very slow**
The initial download caches to `~/.cache/huggingface/hub/`. Subsequent runs use the cache. To monitor progress, watch the `llama-server` window.

**Gated model (403 error from HuggingFace)**
Meta Llama and some others require accepting a license on HuggingFace first:
1. Log in at [huggingface.co](https://huggingface.co)
2. Visit the model page and click **Accept** on the license
3. Create an access token at [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens)
4. Pass it with: `.\Setup-OpenCode-LLM.ps1 -HfToken hf_xxx`

**Out of memory / model won't load**
Run `llmfit fit --use-case coding --cli` and look at the **Fit** column. Choose a model rated **Good** or **Perfect**, or reduce `-ContextSize`.

---

## Resources

| Resource | Link |
|----------|------|
| LlmFit GitHub | https://github.com/AlexsJones/llmfit |
| LlmFit website | https://www.llmfit.org/ |
| llama.cpp GitHub | https://github.com/ggml-org/llama.cpp |
| llama.cpp releases | https://github.com/ggml-org/llama.cpp/releases |
| llama-server README | https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md |
| Function calling guide | https://github.com/ggml-org/llama.cpp/blob/master/docs/function-calling.md |
| Ollama | https://ollama.com |
| Ollama model library | https://ollama.com/library |
| Ollama + OpenCode | https://docs.ollama.com/integrations/opencode |
| OpenCode website | https://opencode.ai |
| OpenCode GitHub | https://github.com/sst/opencode |
| OpenCode providers docs | https://opencode.ai/docs/providers/ |
| bartowski GGUF repos | https://huggingface.co/bartowski |
| Scoop | https://scoop.sh |
| HuggingFace tokens | https://huggingface.co/settings/tokens |

---

## License

[AGPL-3.0](LICENSE)
