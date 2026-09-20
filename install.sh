#!/usr/bin/env bash
# Control-node installer. Run this on the machine that will run the dashboard.
# It installs everything needed there; managed Linux hosts need nothing but SSH.
#
# Works on Debian/Ubuntu, Fedora/RHEL, Arch, openSUSE, Alpine and NixOS.
#   ./install.sh            install
#   ./install.sh --dry-run  show what it would do
set -Eeuo pipefail
cd "$(dirname "$0")"

KEY="${GLOSSY_SSH_KEY:-$HOME/.ssh/id_ed25519_glossy}"
DRY=0
[[ ${1:-} == --dry-run ]] && DRY=1

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
run() { if ((DRY)); then printf '    would run: %s\n' "$*"; else "$@"; fi; }

# --- distro -----------------------------------------------------------------
distro_id () {
    [[ -r /etc/os-release ]] && . /etc/os-release && echo "${ID:-unknown} ${ID_LIKE:-}"
}

pkg_install () {
    # Installs packages with whatever package manager this distro has.
    local pkgs=("$@") sudo=""
    (( EUID != 0 )) && command -v sudo > /dev/null && sudo=sudo
    if command -v apt-get > /dev/null; then
        run $sudo apt-get update -qq && run $sudo apt-get install -y "${pkgs[@]}"
    elif command -v dnf > /dev/null; then
        run $sudo dnf install -y "${pkgs[@]}"
    elif command -v yum > /dev/null; then
        run $sudo yum install -y "${pkgs[@]}"
    elif command -v zypper > /dev/null; then
        run $sudo zypper --non-interactive install "${pkgs[@]}"
    elif command -v pacman > /dev/null; then
        run $sudo pacman -Sy --noconfirm "${pkgs[@]}"
    elif command -v apk > /dev/null; then
        run $sudo apk add "${pkgs[@]}"
    else
        echo "warning: unknown package manager; install these yourself: ${pkgs[*]}" >&2
        return 1
    fi
}

# Package names differ per distro; only the ones we actually miss get installed.
ensure_base () {
    local missing=()
    command -v curl > /dev/null || missing+=(curl)
    command -v ssh > /dev/null || missing+=(openssh-client)
    command -v ssh-copy-id > /dev/null || missing+=(openssh-client)
    ((${#missing[@]})) || return 0

    if command -v nix-env > /dev/null; then
        echo "NixOS: add these to your configuration.nix: ${missing[*]}" >&2
        return 1
    fi
    # openssh-client is called openssh on non-Debian distros
    if ! command -v apt-get > /dev/null; then
        missing=("${missing[@]/openssh-client/openssh}")
    fi
    log "Installing: ${missing[*]}"
    pkg_install "${missing[@]}"
}

# --- the MCP server ---------------------------------------------------------
# uv brings its own Python, so the distro's Python version does not matter.
ensure_uv () {
    command -v uv > /dev/null && return 0
    log "Installing uv"
    run sh -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
    export PATH="$HOME/.local/bin:$PATH"
}

ensure_mcp () {
    log "Installing linux-mcp-server"
    run uv tool install --upgrade linux-mcp-server
    ((DRY)) && return 0
    export PATH="$HOME/.local/bin:$PATH"
    command -v linux-mcp-server > /dev/null \
        || { echo "linux-mcp-server is not on PATH; add ~/.local/bin to it" >&2; exit 1; }
    linux-mcp-server --version
}

ensure_key () {
    [[ -f $KEY ]] && return 0
    log "Creating SSH key $KEY"
    run ssh-keygen -t ed25519 -N "" -f "$KEY" -C "glossy-control@$(hostname)"
}

ensure_configs () {
    [[ -f hosts.toml ]] || run cp hosts.example.toml hosts.toml
    [[ -f server/servers.toml ]] || run cp server/servers.example.toml server/servers.toml
}

main () {
    log "Control node: $(distro_id)"
    ensure_base || true
    ensure_uv
    ensure_mcp
    ensure_key
    ensure_configs
    cat <<MSG

Done. Managed hosts need nothing installed: only SSH access.

  Add a host:      ./add-host.sh web1 admin@10.0.0.64
  Other network:   ./add-host.sh db1 root@10.1.0.5 --jump admin@bastion.example.com
  Start the UI:    cd server && python3 server.py     # http://127.0.0.1:8000

The dashboard starts linux-mcp-server itself, over stdio. Nothing listens on a port.
MSG
}

main "$@"
