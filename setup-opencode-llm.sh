#!/usr/bin/env bash
# setup-opencode-llm.sh
#
# Finds the best local LLM for coding with tool-use support, downloads it via
# llama.cpp (or Ollama as a fallback), and configures OpenCode.
#
# Supported distros: Debian, Ubuntu, Fedora (and RHEL-likes), NixOS,
#                    and any Linux with the Nix package manager.
#
# Usage:
#   ./setup-opencode-llm.sh [OPTIONS]
#
# Options:
#   --manual  | -manual | -m          Show ranked candidate list; pick a model interactively
#   --top-n N | -top-n N | -n N       Candidates to request from LlmFit   (default: 20)
#   --context N | -context N | -c N   Context window size in tokens        (default: 16384)
#   --port N  | -port N  | -p N       llama-server port                    (default: 8080)
#   --hf-token TOKEN | -hf-token TOKEN  HuggingFace token for gated models
#   --force   | -force  | -f          Re-download and overwrite config
#   --help    | -h                    Show this message

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Defaults
# ─────────────────────────────────────────────────────────────────────────────

TOP_N=20
CONTEXT_SIZE=16384
PORT=8080
HF_TOKEN=""
MANUAL=false
FORCE=false

BIN_DIR="${HOME}/.local/bin"
SHARE_DIR="${HOME}/.local/share/autolocalllm"

# ─────────────────────────────────────────────────────────────────────────────
# Argument parsing
# ─────────────────────────────────────────────────────────────────────────────

usage() { grep '^#' "$0" | head -25 | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --manual|-manual|-m)        MANUAL=true;          shift   ;;
        --force|-force|-f)          FORCE=true;            shift   ;;
        --help|-help|-h)            usage                          ;;
        --top-n|-top-n|-n)          TOP_N="$2";            shift 2 ;;
        --context|-context|-c)      CONTEXT_SIZE="$2";     shift 2 ;;
        --port|-port|-p)            PORT="$2";             shift 2 ;;
        --hf-token|-hf-token)       HF_TOKEN="$2";         shift 2 ;;
        *)                          echo "Unknown option: $1"; usage ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────────────
# Colors / output helpers
# ─────────────────────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
    RED='\033[31m' GREEN='\033[32m' YELLOW='\033[33m'
    CYAN='\033[36m' GRAY='\033[90m' MAGENTA='\033[35m' RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' CYAN='' GRAY='' MAGENTA='' RESET=''
fi

step() { printf "\n  ${CYAN}>> %s${RESET}\n"  "$*"; }
ok()   { printf "     ${GREEN}OK  %s${RESET}\n" "$*"; }
warn() { printf "     ${YELLOW}**  %s${RESET}\n" "$*"; }
info() { printf "     ${GRAY}..  %s${RESET}\n"  "$*"; }
die()  { printf "\n     ${RED}!!  Fatal: %s${RESET}\n\n" "$*" >&2; exit 1; }
have() { command -v "$1" &>/dev/null; }

# ─────────────────────────────────────────────────────────────────────────────
# Temp-file cleanup
# ─────────────────────────────────────────────────────────────────────────────

TMP_FILES=()
cleanup() { for f in "${TMP_FILES[@]:-}"; do [[ -f "$f" ]] && rm -f "$f"; done; }
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Distro detection
# ─────────────────────────────────────────────────────────────────────────────

DISTRO=""
HAS_NIX=false
ARCH="$(uname -m)"   # x86_64 | aarch64

detect_distro() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        case "${ID:-}" in
            debian|ubuntu|linuxmint|pop|elementary|kali|raspbian)
                DISTRO="debian" ;;
            fedora|nobara)
                DISTRO="fedora" ;;
            rhel|centos|almalinux|rocky|ol|amzn)
                DISTRO="fedora" ;;   # dnf-compatible
            nixos)
                DISTRO="nixos" ;;
            arch|manjaro|endeavouros|garuda|cachyos)
                DISTRO="arch" ;;
            steamos)
                DISTRO="arch" ;;    # Steam Deck
            *)
                case "${ID_LIKE:-}" in
                    *debian*|*ubuntu*)  DISTRO="debian" ;;
                    *fedora*|*rhel*)    DISTRO="fedora" ;;
                    *nixos*)            DISTRO="nixos"  ;;
                    *arch*)             DISTRO="arch"   ;;
                esac ;;
        esac
    fi

    have nix && HAS_NIX=true
    [[ -z "$DISTRO" && "$HAS_NIX" == true ]] && DISTRO="nixos"
    [[ -z "$DISTRO" ]] && { warn "Could not detect distro — assuming Debian/Ubuntu"; DISTRO="debian"; }

    ok "Distro: ${DISTRO}  arch: ${ARCH}  nix: ${HAS_NIX}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Package manager helpers
# ─────────────────────────────────────────────────────────────────────────────

apt_install()  { sudo apt-get install -y "$@"; }
dnf_install()  { sudo dnf install -y "$@"; }
nix_install()  {
    for pkg in "$@"; do
        nix profile install "nixpkgs#${pkg}" 2>/dev/null \
            || nix-env -iA "nixpkgs.${pkg}" \
            || warn "nix: could not install ${pkg} — install manually"
    done
}
pacman_install() { sudo pacman -S --noconfirm "$@"; }

# ─────────────────────────────────────────────────────────────────────────────
# Python helper script (model DB + JSON ops)
# Written once to a temp file; called for filtering, table display, and config.
# ─────────────────────────────────────────────────────────────────────────────

PYTHON_HELPER=$(mktemp /tmp/autolocalllm_XXXXXX.py)
TMP_FILES+=("$PYTHON_HELPER")

cat > "$PYTHON_HELPER" << 'PYEOF'
#!/usr/bin/env python3
"""AutoLocalLLM helper — LlmFit filtering, table display, config writer."""
import json, sys, os

PREF_PROVIDERS = ['bartowski', 'unsloth', 'mradermacher']

def build_candidates(models):
    candidates = []
    for m in models:
        hf_id   = m.get('name', '')
        sources = m.get('gguf_sources') or []
        if not sources:
            print(f'  Skip (no GGUF source): {hf_id}', file=sys.stderr)
            continue
        source = None
        for prov in PREF_PROVIDERS:
            source = next((s for s in sources if s.get('provider') == prov), None)
            if source:
                break
        if not source:
            source = sources[0]
        repo     = source['repo']
        basename = repo.split('/')[-1].removesuffix('-GGUF')
        quant    = m.get('best_quant') or 'Q4_K_M'
        candidates.append({
            'index':         len(candidates) + 1,
            'hf_id':         hf_id,
            'runner':        'llamacpp',
            'gguf_repo':     repo,
            'gguf_basename': basename,
            'template':      '',
            'ollama_tag':    '',
            'quantization':  quant,
            'score':         round(float(m.get('score') or 0), 1),
            'params':        m.get('params_b'),
            'mem_pct':       m.get('utilization_pct', '?'),
        })
    return candidates

def cmd_filter():
    raw = sys.stdin.read()
    try:
        data = json.loads(raw)
        models = data['models'] if isinstance(data, dict) and 'models' in data else data
    except json.JSONDecodeError:
        print('[]'); return
    print(json.dumps(build_candidates(models), indent=2))

def cmd_table():
    candidates = json.load(sys.stdin)
    W = 36
    div = '─' * 70
    print(f'\n  {div}')
    print(f"  {'#':<3} | {'Model':<{W}} | {'Params':<7} | {'Score':<5} | {'VRAM%':<5} | {'Runner':<9}")
    print(f'  {div}')
    for c in candidates:
        if c['runner'] == 'llamacpp':
            label  = f"{c['gguf_basename']} ({c['quantization']})"
            runner = 'llama.cpp'
        else:
            label  = c['ollama_tag']
            runner = 'Ollama'
        if len(label) > W:
            label = label[:W - 1] + '…'
        color = '\033[33m' if c['index'] == 1 else '\033[90m'
        reset = '\033[0m'
        try:
            params = f"{round(float(str(c['params']).rstrip('B').strip()), 1)}B" if c['params'] is not None else '?'
        except (ValueError, TypeError):
            params = str(c['params'])
        mem    = f"{c['mem_pct']}%" if c['mem_pct'] is not None else '?'
        print(f'  {color}{c["index"]:<3} | {label:<{W}} | {params:<7} | {c["score"]:<5} | {mem:<5} | {runner:<9}{reset}')
    print(f'  {div}\n')

def cmd_get():
    idx        = int(sys.argv[2]) - 1
    candidates = json.load(sys.stdin)
    if idx < 0 or idx >= len(candidates):
        sys.exit(f'Index {idx+1} out of range (1-{len(candidates)})')
    print(json.dumps(candidates[idx]))

def cmd_len():
    candidates = json.load(sys.stdin)
    print(len(candidates))

def cmd_field():
    field      = sys.argv[2]
    candidates = json.load(sys.stdin)
    idx        = int(sys.argv[3]) - 1 if len(sys.argv) > 3 else 0
    print(candidates[idx].get(field, ''))

def cmd_config():
    config_path  = sys.argv[2]
    model_id     = sys.argv[3]
    display_name = sys.argv[4]
    api_base     = sys.argv[5]
    runner       = sys.argv[6]

    os.makedirs(os.path.dirname(config_path), exist_ok=True)
    try:
        with open(config_path) as f:
            cfg = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        cfg = {}

    cfg.setdefault('$schema', 'https://opencode.ai/config.json')
    cfg.setdefault('provider', {})

    provider_key  = 'llama-cpp' if runner == 'llamacpp' else 'ollama'
    provider_name = 'llama.cpp Local' if runner == 'llamacpp' else 'Ollama Local'

    cfg['provider'].setdefault(provider_key, {
        'npm':     '@ai-sdk/openai-compatible',
        'name':    provider_name,
        'options': {'baseURL': f'{api_base}/v1'},
        'models':  {},
    })

    provider = cfg['provider'][provider_key]
    provider.setdefault('models', {})
    provider['models'][model_id] = {'name': display_name, 'tools': True}

    with open(config_path, 'w') as f:
        json.dump(cfg, f, indent=2)
    print(config_path)

dispatch = {
    'filter': cmd_filter, 'table': cmd_table, 'get': cmd_get,
    'len': cmd_len, 'field': cmd_field, 'config': cmd_config,
}
cmd = sys.argv[1] if len(sys.argv) > 1 else ''
fn  = dispatch.get(cmd)
if fn:
    fn()
else:
    sys.exit(f'Unknown subcommand: {cmd}  (available: {", ".join(dispatch)})')
PYEOF

py() { python3 "$PYTHON_HELPER" "$@"; }   # shorthand

# ─────────────────────────────────────────────────────────────────────────────
# GPU detection
# ─────────────────────────────────────────────────────────────────────────────

detect_gpu() {
    if have nvidia-smi && nvidia-smi &>/dev/null 2>&1; then
        echo "cuda"
    elif ls /sys/class/drm/*/device/driver 2>/dev/null | grep -qi 'amdgpu'; then
        echo "rocm"
    else
        echo "cpu"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Prerequisite installers
# ─────────────────────────────────────────────────────────────────────────────

install_base_tools() {
    step "Installing base tools (curl, python3, tar)"
    case "$DISTRO" in
        debian)
            have curl    || apt_install curl
            have python3 || apt_install python3
            ;;
        fedora)
            have curl    || dnf_install curl
            have python3 || dnf_install python3
            ;;
        nixos)
            have curl    || nix_install curl
            have python3 || nix_install python3
            ;;
        arch)
            have curl    || pacman_install curl
            have python3 || pacman_install python
            ;;
    esac
    have curl    || die "curl is required but could not be installed."
    have python3 || die "python3 is required but could not be installed."
    ok "Base tools ready"
}

install_llama_cpp() {
    if have llama-server; then ok "llama-server already installed"; return; fi

    step "Installing llama.cpp"

    case "$DISTRO" in
        fedora)
            dnf_install llama-cpp
            have llama-server && { ok "llama.cpp installed via dnf"; return; }
            ;;
        nixos)
            nix_install llama-cpp
            have llama-server && { ok "llama.cpp installed via Nix"; return; }
            ;;
    esac

    # Fallback: download pre-built binary from GitHub releases
    install_llama_cpp_from_github
}

install_llama_cpp_from_github() {
    local gpu
    gpu=$(detect_gpu)
    info "GPU backend: ${gpu}  arch: ${ARCH}"

    local api_url="https://api.github.com/repos/ggml-org/llama.cpp/releases/latest"
    local release_json
    release_json=$(curl -fsSL -H "User-Agent: AutoLocalLLM" "$api_url") \
        || die "Could not fetch llama.cpp release info from GitHub."

    # Pick asset: prefer cuda/rocm build if GPU detected, else cpu/plain ubuntu
    local asset_url
    asset_url=$(python3 - << PYEOF
import json, re, sys
data  = json.loads('''${release_json}'''.replace("'", "\\'"))
arch  = '${ARCH}'.replace('x86_64', 'x64').replace('aarch64', 'arm64')
gpu   = '${gpu}'

prefs = []
if gpu == 'cuda':
    prefs += [r'ubuntu.*cuda.*' + arch, r'ubuntu.*' + arch]
elif gpu == 'rocm':
    prefs += [r'ubuntu.*rocm.*' + arch, r'ubuntu.*vulkan.*' + arch, r'ubuntu.*' + arch]
else:
    prefs += [r'ubuntu.*vulkan.*' + arch, r'ubuntu.*' + arch, r'ubuntu.*x64']

for pat in prefs:
    for a in data.get('assets', []):
        if re.search(pat, a['name'], re.IGNORECASE) and a['name'].endswith('.tar.gz'):
            print(a['browser_download_url'])
            sys.exit(0)
sys.exit(1)
PYEOF
) || die "No suitable llama.cpp Linux binary found. Check https://github.com/ggml-org/llama.cpp/releases"

    local archive
    archive=$(basename "$asset_url")
    local tmp_dir
    tmp_dir=$(mktemp -d /tmp/autolocalllm_llamacpp_XXXXXX)
    TMP_FILES+=("${tmp_dir}/.")

    info "Downloading ${archive}"
    curl -fsSL --progress-bar -o "${tmp_dir}/${archive}" "$asset_url" \
        || die "Download failed: $asset_url"

    mkdir -p "$BIN_DIR"
    tar -xzf "${tmp_dir}/${archive}" -C "${tmp_dir}"

    # Copy llama-server (and companion libs) into BIN_DIR
    find "${tmp_dir}" -name 'llama-server' -type f | while read -r bin; do
        cp "$bin" "$BIN_DIR/llama-server"
        chmod +x "$BIN_DIR/llama-server"
    done

    # Copy any .so files needed at runtime into BIN_DIR
    find "${tmp_dir}" -name '*.so*' -type f | while read -r lib; do
        cp "$lib" "$BIN_DIR/" 2>/dev/null || true
    done

    rm -rf "${tmp_dir}"

    [[ ":$PATH:" != *":${BIN_DIR}:"* ]] && export PATH="${BIN_DIR}:${PATH}"
    if ! have llama-server; then
        printf "\n     ${YELLOW}**  llama-server not found after extraction.${RESET}\n"
        printf   "     ${YELLOW}**  Check ${BIN_DIR} or install llama.cpp manually:${RESET}\n"
        printf   "     ${YELLOW}**    https://github.com/ggml-org/llama.cpp/releases${RESET}\n\n"
        exit 1
    fi
    ok "llama.cpp installed to ${BIN_DIR}"
}

install_llmfit() {
    if have llmfit; then ok "LlmFit already installed"; return; fi

    step "Installing LlmFit"

    local api_url="https://api.github.com/repos/AlexsJones/llmfit/releases/latest"
    local release_json
    release_json=$(curl -fsSL -H "User-Agent: AutoLocalLLM" "$api_url") \
        || die "Could not fetch LlmFit release info."

    local asset_url
    asset_url=$(python3 - << PYEOF
import json, re, sys
data = json.loads('''${release_json}'''.replace("'", "\\'"))
arch = '${ARCH}'   # x86_64 | aarch64
for a in data.get('assets', []):
    n = a['name'].lower()
    if arch in n and 'linux' in n and (n.endswith('.tar.gz') or n.endswith('.zip')):
        print(a['browser_download_url'])
        sys.exit(0)
# Fallback: any linux asset
for a in data.get('assets', []):
    n = a['name'].lower()
    if 'linux' in n and (n.endswith('.tar.gz') or n.endswith('.zip')):
        print(a['browser_download_url'])
        sys.exit(0)
sys.exit(1)
PYEOF
) || die "No Linux LlmFit binary found. Check https://github.com/AlexsJones/llmfit/releases"

    local archive
    archive=$(basename "$asset_url")
    local tmp_dir
    tmp_dir=$(mktemp -d /tmp/autolocalllm_llmfit_XXXXXX)
    TMP_FILES+=("${tmp_dir}/.")

    info "Downloading ${archive}"
    curl -fsSL --progress-bar -o "${tmp_dir}/${archive}" "$asset_url" \
        || die "Download failed: $asset_url"

    mkdir -p "$BIN_DIR"
    if [[ "$archive" == *.tar.gz ]]; then
        tar -xzf "${tmp_dir}/${archive}" -C "${tmp_dir}"
    else
        unzip -q "${tmp_dir}/${archive}" -d "${tmp_dir}"
    fi

    find "${tmp_dir}" -name 'llmfit' -type f | head -1 | while read -r bin; do
        cp "$bin" "$BIN_DIR/llmfit"
        chmod +x "$BIN_DIR/llmfit"
    done

    rm -rf "${tmp_dir}"

    [[ ":$PATH:" != *":${BIN_DIR}:"* ]] && export PATH="${BIN_DIR}:${PATH}"
    have llmfit || die "llmfit not found after extraction. Check ${BIN_DIR}"
    ok "LlmFit installed to ${BIN_DIR}"
}

install_node_via_nvm() {
    info "Installing Node.js via nvm (no root required)..."
    local nvm_dir="${HOME}/.nvm"
    if [[ ! -s "${nvm_dir}/nvm.sh" ]]; then
        curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash \
            || die "nvm installation failed."
    fi
    export NVM_DIR="$nvm_dir"
    # shellcheck source=/dev/null
    source "${nvm_dir}/nvm.sh"
    have nvm || die "nvm not available after installation."
    nvm install 20 || die "nvm install 20 failed."
    nvm use 20
    nvm alias default 20 2>/dev/null || true
    ok "Node.js $(node --version) installed via nvm"
}

install_node_npm() {
    if have node && node -e "process.exit(parseInt(process.version.slice(1)) >= 20 ? 0 : 1)" 2>/dev/null; then
        ok "Node.js $(node --version) already installed"; return
    fi

    step "Installing Node.js v20 LTS"
    case "$DISTRO" in
        debian)
            curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
            apt_install nodejs
            ;;
        fedora)
            local rpm_url="https://rpm.nodesource.com/pub_20.x/nodistro/repo/nodesource-release-nodistro-1.noarch.rpm"
            sudo dnf install -y "$rpm_url" 2>/dev/null || true
            dnf_install nodejs
            ;;
        nixos)
            nix_install nodejs_20
            ;;
        arch)
            # Steam Deck has an immutable rootfs by default; pacman may fail — nvm is the reliable fallback
            pacman_install nodejs npm 2>/dev/null || install_node_via_nvm
            ;;
    esac

    # Universal fallback: if still no node, try nvm
    if ! have node; then
        install_node_via_nvm
    fi

    have npm || die "npm not found after Node.js install."
    ok "Node.js $(node --version) installed"
}

install_opencode() {
    if have opencode; then ok "OpenCode already installed"; return; fi

    step "Installing OpenCode"
    install_node_npm

    # If the npm global prefix is not writable (e.g. Steam Deck immutable rootfs),
    # redirect to a user-writable location before installing opencode.
    local npm_prefix
    npm_prefix=$(npm prefix -g 2>/dev/null)
    if [[ -n "$npm_prefix" && ! -w "$npm_prefix" ]]; then
        local fallback_prefix="${HOME}/.npm-global"
        info "npm global prefix ${npm_prefix} is not writable; using ${fallback_prefix}"
        mkdir -p "$fallback_prefix"
        npm config set prefix "$fallback_prefix"
    fi

    # npm global installs land in $(npm prefix -g)/bin — make sure it's on PATH
    local npm_global_bin
    npm_global_bin=$(npm prefix -g 2>/dev/null)/bin
    [[ ":$PATH:" != *":${npm_global_bin}:"* ]] && export PATH="${npm_global_bin}:${PATH}"

    npm install --global opencode-ai@latest \
        || die "npm install opencode-ai failed."

    have opencode || die "opencode not found after install. Add $(npm prefix -g)/bin to PATH."
    ok "OpenCode installed"
}

install_ollama() {
    if have ollama; then ok "Ollama already installed"; return; fi

    step "Installing Ollama"
    case "$DISTRO" in
        nixos)
            nix_install ollama
            ;;
        *)
            curl -fsSL https://ollama.com/install.sh | sh \
                || die "Ollama install script failed. See https://ollama.com/download"
            ;;
    esac
    have ollama || die "ollama not found after install."
    ok "Ollama installed"
}

# ─────────────────────────────────────────────────────────────────────────────
# LlmFit query and filtering
# ─────────────────────────────────────────────────────────────────────────────

get_candidates() {
    step "Querying LlmFit: top ${TOP_N} coding models for this hardware"

    local llmfit_err
    llmfit_err=$(mktemp /tmp/autolocalllm_llmfit_err_XXXXXX)
    TMP_FILES+=("$llmfit_err")

    local raw
    raw=$(llmfit recommend --json --use-case coding --capability tool_use --runtime llamacpp --min-fit good --limit "$TOP_N" 2>"$llmfit_err") \
        || die "LlmFit failed (exit $?). Stderr: $(cat "$llmfit_err")"

    CANDIDATES_JSON=$(echo "$raw" | py filter) \
        || die "Failed to parse LlmFit output. Raw JSON length: ${#raw}"
    local count
    count=$(echo "$CANDIDATES_JSON" | py len) \
        || die "Failed to count candidates."

    info "Found ${count} candidate(s)"
    [[ "$count" -eq 0 ]] && die "No candidates found. Try --top-n 30 or check that llmfit supports your hardware."
}

# ─────────────────────────────────────────────────────────────────────────────
# Model selection: display table, then auto or interactive
# ─────────────────────────────────────────────────────────────────────────────

SELECTED_JSON=""

select_model() {
    echo "$CANDIDATES_JSON" | py table \
        || die "Failed to display candidate table (Python error above)."

    if [[ "$MANUAL" == false ]]; then
        info "Auto-selecting #1  (use --manual to pick)"
        SELECTED_JSON=$(echo "$CANDIDATES_JSON" | py get 1) \
            || die "Failed to select candidate #1."
        return
    fi

    local count
    count=$(echo "$CANDIDATES_JSON" | py len)

    while true; do
        read -r -p "  Enter number [1-${count}] or press Enter for #1: " choice
        [[ -z "$choice" ]] && { SELECTED_JSON=$(echo "$CANDIDATES_JSON" | py get 1); return; }
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
            SELECTED_JSON=$(echo "$CANDIDATES_JSON" | py get "$choice")
            return
        fi
        warn "Please enter a number between 1 and ${count}."
    done
}

# Helper: extract a field from SELECTED_JSON
sel() { echo "$SELECTED_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('$1',''))"; }

# ─────────────────────────────────────────────────────────────────────────────
# llama-server runner
# ─────────────────────────────────────────────────────────────────────────────

start_llama_server() {
    local hf_repo gguf_basename quantization template
    hf_repo=$(sel gguf_repo)
    gguf_basename=$(sel gguf_basename)
    quantization=$(sel quantization)
    template=$(sel template)

    local hf_file="${gguf_basename}-${quantization}.gguf"
    local api_root="http://127.0.0.1:${PORT}"

    # Already running?
    if curl -fsS "${api_root}/health" 2>/dev/null | grep -q '"ok"'; then
        ok "llama-server already running on ${api_root}"
        RUNNER_API_ROOT="$api_root"
        return
    fi

    step "Starting llama-server  (${hf_repo} / ${hf_file})"
    local hf_cache="${HOME}/.cache/huggingface/hub"
    if find "$hf_cache" -name "$hf_file" 2>/dev/null | grep -q .; then
        info "Model found in HuggingFace cache — loading from disk (no download needed)."
    else
        warn "Model not yet cached — llama-server will download from HuggingFace (may take several minutes)."
    fi

    local -a server_args=(
        --hf-repo "$hf_repo"
        --hf-file "$hf_file"
        -c "$CONTEXT_SIZE"
        --host 127.0.0.1
        --port "$PORT"
        --jinja
    )
    [[ -n "$template" ]]  && server_args+=(--chat-template "$template")
    [[ -n "$HF_TOKEN" ]]  && export HF_TOKEN

    info "  llama-server ${server_args[*]}"

    mkdir -p "$SHARE_DIR"
    local log_file="${SHARE_DIR}/llama-server.log"

    llama-server "${server_args[@]}" > "$log_file" 2>&1 &
    local server_pid=$!
    info "PID ${server_pid}  log: ${log_file}"

    # Poll /health (up to 10 min — large model download + load)
    local timeout=600 interval=5 elapsed=0
    printf '     Waiting'
    while (( elapsed < timeout )); do
        sleep "$interval"; elapsed=$(( elapsed + interval ))
        printf '.'
        if curl -fsS "${api_root}/health" 2>/dev/null | grep -q '"ok"'; then
            echo ""
            ok "llama-server ready  (${api_root})"
            RUNNER_API_ROOT="$api_root"
            return
        fi
        # Check if server crashed
        if ! kill -0 "$server_pid" 2>/dev/null; then
            echo ""
            die "llama-server exited unexpectedly. Check log: ${log_file}"
        fi
    done
    echo ""
    die "llama-server did not become ready within ${timeout}s. Check log: ${log_file}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Ollama runner
# ─────────────────────────────────────────────────────────────────────────────

start_ollama_daemon() {
    local api_url="http://localhost:11434/api/tags"
    if curl -fsS "$api_url" &>/dev/null; then
        ok "Ollama daemon already running"; return
    fi
    info "Starting Ollama daemon..."
    ollama serve &>/dev/null &
    local i
    for (( i=0; i<20; i++ )); do
        sleep 1
        curl -fsS "$api_url" &>/dev/null && { ok "Ollama daemon started"; return; }
    done
    die "Ollama did not start within 20s. Run 'ollama serve' manually then retry."
}

run_ollama_model() {
    local tag
    tag=$(sel ollama_tag)
    local ctx_k=$(( CONTEXT_SIZE / 1024 ))
    local variant="${tag//:/-}-ctx${ctx_k}k"

    start_ollama_daemon

    # Pull base model
    if ! ollama list 2>/dev/null | grep -q "^${tag}"; then
        step "Pulling '${tag}' via Ollama"
        ollama pull "$tag" || die "ollama pull ${tag} failed."
        ok "Model '${tag}' pulled"
    else
        ok "Base model '${tag}' already present"
    fi

    # Create context-extended variant
    if ! ollama list 2>/dev/null | grep -q "^${variant}"; then
        step "Creating context-extended variant '${variant}'  (num_ctx=${CONTEXT_SIZE})"
        local tmp_mf
        tmp_mf=$(mktemp /tmp/autolocalllm_modelfile_XXXXXX)
        TMP_FILES+=("$tmp_mf")
        printf 'FROM %s\nPARAMETER num_ctx %d\n' "$tag" "$CONTEXT_SIZE" > "$tmp_mf"
        ollama create "$variant" --file "$tmp_mf" || die "ollama create ${variant} failed."
        ok "Variant '${variant}' created"
    else
        ok "Variant '${variant}' already exists"
    fi

    RUNNER_API_ROOT="http://localhost:11434"
    OLLAMA_MODEL_TAG="$variant"
}

# ─────────────────────────────────────────────────────────────────────────────
# OpenCode configuration
# ─────────────────────────────────────────────────────────────────────────────

write_opencode_config() {
    local model_id="$1" display_name="$2" api_base="$3" runner="$4"
    local config_path="${HOME}/.config/opencode/config.json"

    py config "$config_path" "$model_id" "$display_name" "$api_base" "$runner" \
        || die "Failed to write OpenCode config."
    ok "OpenCode config: ${config_path}"
    OPENCODE_CONFIG="$config_path"
}

# ─────────────────────────────────────────────────────────────────────────────
# Startup helper script
# ─────────────────────────────────────────────────────────────────────────────

write_startup_script() {
    local runner="$1" model_id="$2"
    local script_path="${SHARE_DIR}/start-llama-server.sh"
    mkdir -p "$SHARE_DIR"

    if [[ "$runner" == "llamacpp" ]]; then
        local hf_repo gguf_basename quantization template
        hf_repo=$(sel gguf_repo)
        gguf_basename=$(sel gguf_basename)
        quantization=$(sel quantization)
        template=$(sel template)
        local hf_file="${gguf_basename}-${quantization}.gguf"

        local tmpl_arg=""
        [[ -n "$template" ]] && tmpl_arg="--chat-template ${template}"

        local token_line=""
        [[ -n "$HF_TOKEN" ]] && token_line="export HF_TOKEN='${HF_TOKEN}'"

        cat > "$script_path" << SHEOF
#!/usr/bin/env bash
# Auto-generated by setup-opencode-llm.sh  (runner: llama.cpp)
# Run this before using OpenCode when llama-server is not already running.

set -euo pipefail

${token_line}

API_ROOT="http://127.0.0.1:${PORT}"
if curl -fsS "\${API_ROOT}/health" 2>/dev/null | grep -q '"ok"'; then
    echo "llama-server already running on \${API_ROOT}"
    exit 0
fi

echo "Starting llama-server on \${API_ROOT} ..."
exec llama-server \\
    --hf-repo "${hf_repo}" \\
    --hf-file "${hf_file}" \\
    -c "${CONTEXT_SIZE}" \\
    --host 127.0.0.1 \\
    --port "${PORT}" \\
    --jinja \\
    ${tmpl_arg}
SHEOF
    else
        local tag ollama_variant
        tag=$(sel ollama_tag)
        local ctx_k=$(( CONTEXT_SIZE / 1024 ))
        ollama_variant="${tag//:/-}-ctx${ctx_k}k"

        cat > "$script_path" << SHEOF
#!/usr/bin/env bash
# Auto-generated by setup-opencode-llm.sh  (runner: Ollama)
# Run this before using OpenCode when Ollama is not already running.

set -euo pipefail

if curl -fsS "http://localhost:11434/api/tags" &>/dev/null; then
    echo "Ollama already running."
    exit 0
fi

echo "Starting Ollama daemon..."
ollama serve &
sleep 3
echo "Loading model: ${ollama_variant}"
ollama run "${ollama_variant}" --keepalive -1
SHEOF
    fi

    chmod +x "$script_path"
    ok "Startup script: ${script_path}"
    STARTUP_SCRIPT="$script_path"
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

main() {
    printf "\n  ${MAGENTA}+------------------------------------------------------------+${RESET}\n"
    printf   "  ${MAGENTA}|   AutoLocalLLM  --  LlmFit -> llama.cpp -> OpenCode       |${RESET}\n"
    printf   "  ${MAGENTA}+------------------------------------------------------------+${RESET}\n"
    if [[ "$MANUAL" == true ]]; then
        printf "  ${CYAN}Mode: manual selection${RESET}\n"
    else
        printf "  ${GRAY}Mode: auto  (use --manual to pick from a list)${RESET}\n"
    fi
    printf "\n"

    mkdir -p "$BIN_DIR" "$SHARE_DIR"
    [[ ":$PATH:" != *":${BIN_DIR}:"* ]] && export PATH="${BIN_DIR}:${PATH}"

    # 1. Prerequisites
    step "Checking prerequisites"
    detect_distro
    install_base_tools
    install_llama_cpp
    install_llmfit
    install_opencode

    # 2. Query LlmFit
    get_candidates

    # 3. Select model
    select_model

    local runner hf_id
    runner=$(sel runner)
    hf_id=$(sel hf_id)

    printf "\n  Chosen model\n"
    info "HuggingFace : ${hf_id}"
    info "Runner      : ${runner}"
    if [[ "$runner" == "llamacpp" ]]; then
        info "GGUF repo   : $(sel gguf_repo)"
        info "File        : $(sel gguf_basename)-$(sel quantization).gguf"
    else
        info "Ollama tag  : $(sel ollama_tag)"
    fi
    info "Score: $(sel score)   Params: $(sel params)B   VRAM: $(sel mem_pct)%"

    # 4. Start model server
    local model_id display_name
    RUNNER_API_ROOT=""
    OLLAMA_MODEL_TAG=""

    if [[ "$runner" == "llamacpp" ]]; then
        start_llama_server
        model_id=$(echo "$(sel gguf_basename)-$(sel quantization)" | tr '[:upper:]' '[:lower:]')
        display_name="$(sel gguf_basename) ($(sel quantization), ctx=${CONTEXT_SIZE})"
    else
        install_ollama
        run_ollama_model
        model_id="$OLLAMA_MODEL_TAG"
        display_name="$(sel ollama_tag) (ctx=${CONTEXT_SIZE})"
    fi

    # 5. Write OpenCode config
    write_opencode_config "$model_id" "$display_name" "$RUNNER_API_ROOT" "$runner"

    # 6. Write startup script
    write_startup_script "$runner" "$model_id"

    # 7. Determine provider label
    local provider_label
    [[ "$runner" == "llamacpp" ]] && provider_label="llama-cpp" || provider_label="ollama"

    # 8. Done
    printf "\n  ${GREEN}+------------------------------------------------------------+${RESET}\n"
    printf   "  ${GREEN}|                   Setup Complete!                          |${RESET}\n"
    printf   "  ${GREEN}+------------------------------------------------------------+${RESET}\n\n"
    printf   "  ${YELLOW}Model    :${RESET} %s\n" "$model_id"
    printf   "  ${YELLOW}Server   :${RESET} %s\n" "$RUNNER_API_ROOT"
    printf   "  ${YELLOW}Config   :${RESET} %s\n" "$OPENCODE_CONFIG"
    printf   "  ${YELLOW}Relaunch :${RESET} %s\n\n" "$STARTUP_SCRIPT"
    printf   "  Start coding now:\n"
    printf   "    ${CYAN}opencode${RESET}\n\n"
    printf   "  Press Ctrl+K inside OpenCode to open the model picker, then select:\n"
    printf   "    ${CYAN}%s > %s${RESET}\n\n" "$provider_label" "$model_id"
    printf   "  ${GRAY}After a reboot, restart the model server with:${RESET}\n"
    printf   "  ${GRAY}  bash %s${RESET}\n\n" "$STARTUP_SCRIPT"
}

main "$@"
