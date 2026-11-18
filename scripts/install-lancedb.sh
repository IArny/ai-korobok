#!/bin/bash
# install-lancedb.sh — guest-side installer for LanceDB + opencode-indexing.
#
# Installs inside the Ubuntu guest VM:
#   - Python lancedb + pyarrow (pip3, system-wide)
#   - Node.js >= 22.6 (NodeSource 22.x) when missing or too old
#   - OpenCode v2 CLI (npm: @opencode/cli) when missing or v1
#   - @javierkaiser/opencode-indexing plugin (embedded LanceDB semantic index),
#     run as the 'ubuntu' user so it writes to ~/.config/opencode
#
# Idempotent: safe to re-run. Progress lines use the '>>>' convention from
# cloud-init/user-data. Exits non-zero with a clear message on failure.
set -euo pipefail

GUEST_USER="ubuntu"

log_progress() { echo ">>> $*"; }
fail() {
    echo ">>> ERROR: $*" >&2
    exit 1
}

# Run a command as the guest user with a login environment (PATH, HOME).
run_as_guest_user() {
    if [[ "$(id -un)" == "${GUEST_USER}" ]]; then
        bash -lc "$1"
    else
        su - "${GUEST_USER}" -c "$1"
    fi
}

ensure_python() {
    if command -v python3 &>/dev/null && command -v pip3 &>/dev/null; then
        log_progress "python3 and pip3 already present."
        return
    fi
    log_progress "Installing python3-pip..."
    sudo apt-get update
    sudo apt-get install -y python3-pip
    command -v python3 &>/dev/null || fail "python3 not found after install."
    command -v pip3 &>/dev/null || fail "pip3 not found after install."
}

install_lancedb() {
    log_progress "Installing Python packages: lancedb, pyarrow..."
    sudo pip3 install --break-system-packages --ignore-installed lancedb pyarrow \
        || fail "pip3 install lancedb pyarrow failed."
    local version
    version=$(python3 -c 'import lancedb; print(lancedb.__version__)') \
        || fail "lancedb import check failed."
    log_progress "lancedb ${version} installed."
}

ensure_node() {
    local node_ver node_major node_minor
    node_ver="$(node --version 2>/dev/null | sed 's/^v//')" || true
    if [[ -n "${node_ver}" ]]; then
        node_major="${node_ver%%.*}"
        node_minor="${node_ver#*.}"
        node_minor="${node_minor%%.*}"
        if [[ "${node_major}" -gt 22 || ( "${node_major}" -eq 22 && "${node_minor}" -ge 6 ) ]]; then
            log_progress "Node.js v${node_ver} already satisfies >= 22.6."
            return
        fi
        log_progress "Node.js v${node_ver} is older than 22.6 — installing Node 22 LTS..."
    else
        log_progress "Node.js not found — installing Node 22 LTS..."
    fi
    curl -fsSL https://deb.nodesource.com/setup_22.x | sudo bash -
    sudo apt-get install -y nodejs
    command -v node &>/dev/null || fail "node not found after install."
    log_progress "Node.js $(node --version) installed."
}

opencode_major() {
    opencode --version 2>/dev/null | sed -E 's/[^0-9]*([0-9]+).*/\1/' | head -1 || true
}

ensure_opencode_cli() {
    local major=""
    if command -v opencode &>/dev/null; then
        major=$(opencode_major)
    fi
    if [[ "${major}" =~ ^[0-9]+$ ]] && [[ "${major}" -ge 2 ]]; then
        log_progress "OpenCode v2 CLI already installed: $(opencode --version)"
        return
    fi
    log_progress "Installing OpenCode v2 CLI (npm: @opencode/cli)..."
    if command -v opencode &>/dev/null; then
        sudo npm uninstall -g opencode-ai &>/dev/null || true
    fi
    sudo npm install -g @opencode/cli
    command -v opencode &>/dev/null || fail "opencode CLI not found after 'npm install -g @opencode/cli'."
    major=$(opencode_major)
    [[ "${major}" =~ ^[0-9]+$ ]] && [[ "${major}" -ge 2 ]] \
        || fail "OpenCode v2 CLI not active after install (got: $(opencode --version 2>/dev/null || echo missing))."
    log_progress "OpenCode $(opencode --version) installed."
}

OPENCODE_DIR="/home/${GUEST_USER}/.config/opencode"

plugin_registered() {
    grep -qs 'javierkaiser' \
        "${OPENCODE_DIR}/tui.json" \
        "${OPENCODE_DIR}/opencode.json" \
        "${OPENCODE_DIR}/opencode.jsonc" \
        "${OPENCODE_DIR}/package.json"
}

ensure_opencode_config() {
    log_progress "Preparing ${OPENCODE_DIR} for '${GUEST_USER}'..."
    sudo install -d -o "${GUEST_USER}" -g "${GUEST_USER}" "${OPENCODE_DIR}"
    sudo chown -R "${GUEST_USER}:${GUEST_USER}" "${OPENCODE_DIR}"
}

write_aio_profile() {
    local indexing_json="${OPENCODE_DIR}/indexing.json"
    if [[ -f "${indexing_json}" ]]; then
        log_progress "Keeping existing ${indexing_json}."
        return
    fi
    log_progress "Writing all-in-one indexing.json profile..."
    sudo tee "${indexing_json}" >/dev/null <<'EOF'
{
  "vectorStore": "lancedb",
  "provider": "local",
  "model": "potion-multilingual-128M",
  "dimension": 256,
  "autoRefresh": false,
  "searchKilo": false,
  "importFromKilo": false
}
EOF
    sudo chown "${GUEST_USER}:${GUEST_USER}" "${indexing_json}"
}

install_indexing_plugin() {
    log_progress "Installing @javierkaiser/opencode-indexing plugin as '${GUEST_USER}'..."
    if ! run_as_guest_user 'npx --yes @javierkaiser/opencode-indexing@latest --aio --no-restart'; then
        log_progress "npx --aio failed; trying the installer entrypoint directly."
    fi
    if ! plugin_registered; then
        log_progress "Running install.mjs directly (npx bin symlink bypass)..."
        run_as_guest_user 'tmp=$(mktemp -d) && npm install --prefix "$tmp" --no-audit --no-fund --loglevel=error @javierkaiser/opencode-indexing@latest && node "$tmp/node_modules/@javierkaiser/opencode-indexing/install.mjs" --aio --no-restart; rc=$?; rm -rf "$tmp"; exit $rc' \
            || fail "opencode-indexing direct installer failed."
    fi
    write_aio_profile
}

verify_install() {
    log_progress "Verifying installation..."

    local lancedb_version
    lancedb_version=$(run_as_guest_user "python3 -c 'import lancedb; print(lancedb.__version__)'") \
        || fail "lancedb is not importable for user '${GUEST_USER}'."
    log_progress "lancedb ${lancedb_version} importable as '${GUEST_USER}'."

    if run_as_guest_user 'opencode plugin list' 2>/dev/null | grep -qi 'javierkaiser'; then
        log_progress "Plugin 'javierkaiser.indexing' is listed by 'opencode plugin list'."
    elif plugin_registered; then
        log_progress "Plugin 'javierkaiser.indexing' is registered."
    else
        fail "Plugin 'javierkaiser.indexing' not registered under ${OPENCODE_DIR}."
    fi

    local indexing_json="${OPENCODE_DIR}/indexing.json"
    [[ -f "${indexing_json}" ]] || fail "Expected ${indexing_json} but it does not exist."
    grep -q '"vectorStore"[[:space:]]*:[[:space:]]*"lancedb"' "${indexing_json}" \
        || fail "${indexing_json} does not contain \"vectorStore\": \"lancedb\"."
    log_progress "indexing.json present with vectorStore=lancedb."
}

main() {
    log_progress "Starting LanceDB + opencode-indexing installation..."
    ensure_python
    install_lancedb
    ensure_node
    ensure_opencode_cli
    ensure_opencode_config
    install_indexing_plugin
    verify_install
    log_progress "Done: LanceDB + @javierkaiser/opencode-indexing installed."
}

main
