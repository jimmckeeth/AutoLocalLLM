#!/usr/bin/env bash
# setup-opencode-llm.sh
#
# Installs prerequisites (llama.cpp, llmfit, OpenCode) then delegates to
# llm-setup-helper.py for model selection, download, and server launch.
#
# Supported distros: Debian, Ubuntu, Fedora (and RHEL-likes), NixOS,
#                    Arch, SteamOS, and any Linux with the Nix package manager.
#
# Usage:
#   ./setup-opencode-llm.sh [OPTIONS]
#
# Options:
#   --manual    | -manual | -m          Show ranked candidate list; pick interactively
#   --update    | -update | -u          Refresh LlmFit model database before querying
#   --top-n N   | -top-n N | -n N       Cap candidates returned from LlmFit  (default: all)
#   --context N | -context N | -c N     Context window size in tokens        (default: 16384)
#   --port N    | -port N  | -p N       llama-server port                    (default: 8080)
#   --force     | -force  | -f          Re-download model even if cached
#   --hf-token TOKEN | -hf-token TOKEN  HuggingFace token for gated models
#   --help      | -h                    Show this message

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Defaults
# ─────────────────────────────────────────────────────────────────────────────

TOP_N=""
CONTEXT_SIZE=16384
PORT=8080
HF_TOKEN=""
MANUAL=false
FORCE=false
UPDATE=false

BIN_DIR="${HOME}/.local/bin"
LIB_DIR="${HOME}/.local/lib"
SHARE_DIR="${HOME}/.local/share/autolocalllm"

# ─────────────────────────────────────────────────────────────────────────────
# Argument parsing
# ─────────────────────────────────────────────────────────────────────────────

usage() { grep '^#' "$0" | head -30 | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --manual|-manual|-m)        MANUAL=true;          shift   ;;
        --update|-update|-u)        UPDATE=true;           shift   ;;
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
# Python helper (llm-setup-helper.py — lives alongside this script)
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_HELPER="${SCRIPT_DIR}/llm-setup-helper.py"
[[ -f "$PYTHON_HELPER" ]] || die "Helper not found: ${PYTHON_HELPER}  (run from the cloned repo directory)"

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
                DISTRO="fedora" ;;
            nixos)
                DISTRO="nixos" ;;
            arch|manjaro|endeavouros|garuda|cachyos)
                DISTRO="arch" ;;
            steamos)
                DISTRO="arch" ;;
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

apt_install()    { sudo apt-get install -y "$@"; }
dnf_install()    { sudo dnf install -y "$@"; }
nix_install()    {
    for pkg in "$@"; do
        nix profile install "nixpkgs#${pkg}" 2>/dev/null \
            || nix-env -iA "nixpkgs.${pkg}" \
            || warn "nix: could not install ${pkg} — install manually"
    done
}
pacman_install() { sudo pacman -S --noconfirm "$@"; }

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
    step "Installing base tools (curl, python3)"
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

    mkdir -p "$BIN_DIR" "$LIB_DIR"
    tar -xzf "${tmp_dir}/${archive}" -C "${tmp_dir}"

    find "${tmp_dir}" -name 'llama-server' -type f | while read -r bin; do
        cp "$bin" "$BIN_DIR/llama-server"
        chmod +x "$BIN_DIR/llama-server"
    done

    find "${tmp_dir}" -name '*.so*' -type f | while read -r lib; do
        cp "$lib" "$LIB_DIR/" 2>/dev/null || true
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
arch = '${ARCH}'
for a in data.get('assets', []):
    n = a['name'].lower()
    if arch in n and 'linux' in n and (n.endswith('.tar.gz') or n.endswith('.zip')):
        print(a['browser_download_url'])
        sys.exit(0)
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
            # Steam Deck has an immutable rootfs; pacman may fail — nvm is the reliable fallback
            pacman_install nodejs npm 2>/dev/null || install_node_via_nvm
            ;;
    esac

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

    local npm_prefix
    npm_prefix=$(npm prefix -g 2>/dev/null)
    if [[ -n "$npm_prefix" && ! -w "$npm_prefix" ]]; then
        local fallback_prefix="${HOME}/.npm-global"
        info "npm global prefix ${npm_prefix} is not writable; using ${fallback_prefix}"
        mkdir -p "$fallback_prefix"
        npm config set prefix "$fallback_prefix"
    fi

    local npm_global_bin
    npm_global_bin=$(npm prefix -g 2>/dev/null)/bin
    [[ ":$PATH:" != *":${npm_global_bin}:"* ]] && export PATH="${npm_global_bin}:${PATH}"

    npm install --global opencode-ai@latest \
        || die "npm install opencode-ai failed."

    have opencode || die "opencode not found after install. Add $(npm prefix -g)/bin to PATH."
    ok "OpenCode installed"
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

main() {
    mkdir -p "$BIN_DIR" "$LIB_DIR" "$SHARE_DIR"
    [[ ":$PATH:" != *":${BIN_DIR}:"* ]] && export PATH="${BIN_DIR}:${PATH}"

    step "Checking prerequisites"
    detect_distro
    install_base_tools
    install_llama_cpp
    install_llmfit
    install_opencode

    # Hand off to Python for model selection, download, server start, and config
    local -a py_args=(setup)
    [[ "$MANUAL" == true ]] && py_args+=(--manual)
    [[ "$FORCE"  == true ]] && py_args+=(--force)
    [[ "$UPDATE" == true ]] && py_args+=(--update)
    [[ -n "$TOP_N"    ]]   && py_args+=(--top-n    "$TOP_N")
    [[ -n "$HF_TOKEN" ]]   && py_args+=(--hf-token "$HF_TOKEN")
    py_args+=(--port "$PORT" --context "$CONTEXT_SIZE")
    py_args+=(--bin-dir "$BIN_DIR" --lib-dir "$LIB_DIR" --share-dir "$SHARE_DIR")

    python3 "$PYTHON_HELPER" "${py_args[@]}"
}

main "$@"
