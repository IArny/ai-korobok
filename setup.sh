#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAYBOOK="${SCRIPT_DIR}/playbooks/setup.yml"
VENV_DIR="${SCRIPT_DIR}/.venv"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

HOMEBREW_BIN=""
MACOS_PACKAGES=(qemu libvirt cdrtools jq wget openssl@3)

find_brew() {
    if command -v brew &>/dev/null; then
        HOMEBREW_BIN="$(command -v brew)"
    elif [[ -x /opt/homebrew/bin/brew ]]; then
        HOMEBREW_BIN=/opt/homebrew/bin/brew
    elif [[ -x /usr/local/bin/brew ]]; then
        HOMEBREW_BIN=/usr/local/bin/brew
    else
        return 1
    fi
    eval "$("$HOMEBREW_BIN" shellenv)"
    return 0
}

install_homebrew() {
    log_info "Homebrew not found. Installing..."
    NONINTERACTIVE=1 /bin/bash -c \
        "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
}

install_macos_deps() {
    if ! find_brew; then
        install_homebrew
    fi
    if ! find_brew; then
        log_error "Homebrew is required but was not found."
        log_error "Install it manually: https://brew.sh"
        exit 1
    fi

    log_info "Installing host dependencies via Homebrew: ${MACOS_PACKAGES[*]}"
    "$HOMEBREW_BIN" install "${MACOS_PACKAGES[@]}"

    if ! "$HOMEBREW_BIN" services list 2>/dev/null | grep -q '^libvirt.*started'; then
        log_info "Starting libvirtd via brew services..."
        "$HOMEBREW_BIN" services start libvirt || \
            log_warn "Could not start libvirtd automatically. Start it with: brew services start libvirt"
    fi

    command -v qemu-system-x86_64 &>/dev/null || log_warn "qemu-system-x86_64 not found in PATH."
    command -v virsh &>/dev/null || log_warn "virsh not found in PATH. Ensure Homebrew is on your PATH."

    echo ""
    log_info "macOS host dependencies installed."
    log_info "  qemu:  $(qemu-system-x86_64 --version 2>/dev/null | head -1 || echo 'not found')"
    log_info "  virsh: $(virsh --version 2>/dev/null || echo 'not found')"
    log_warn "macOS uses QEMU with HVF acceleration — /dev/kvm and virtiofsd are unavailable."
    log_warn "The Linux Ansible playbook is skipped; see docs/macos.md for details."
}

is_wsl() {
    if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
        return 0
    fi
    if grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null; then
        return 0
    fi
    return 1
}

wsl_guidance() {
    log_info "Windows Subsystem for Linux (WSL) detected — using the Linux setup path."
    if [[ ! -d /run/systemd/system ]]; then
        log_warn "systemd is not running in this WSL distro, so libvirtd cannot be started automatically."
        log_warn "Enable it by adding the following to /etc/wsl.conf, then run 'wsl --shutdown':"
        log_warn "  [boot]"
        log_warn "  systemd=true"
    fi
    if [[ ! -e /dev/kvm ]]; then
        log_warn "/dev/kvm not available — VMs will use TCG (software emulation)."
        log_warn "For KVM acceleration, enable nested virtualization in %UserProfile%\\.wslconfig:"
        log_warn "  [wsl2]"
        log_warn "  nestedVirtualization=true"
        log_warn "Then run 'wsl --shutdown' and reopen WSL. See docs/windows.md."
    fi
}

if [[ "$(uname -s)" == "Darwin" ]]; then
    install_macos_deps
    exit 0
fi

if is_wsl; then
    wsl_guidance
fi

if [[ ! -f "$PLAYBOOK" ]]; then
    log_error "Playbook not found: ${PLAYBOOK}"
    exit 1
fi

install_ansible() {
    if command -v pip3 &>/dev/null; then
        pip3 install --user ansible
        export PATH="${HOME}/.local/bin:${PATH}"
    elif command -v pip &>/dev/null; then
        pip install --user ansible
        export PATH="${HOME}/.local/bin:${PATH}"
    elif command -v python3 &>/dev/null; then
        log_info "Creating virtual environment and installing Ansible..."
        python3 -m venv --without-pip "$VENV_DIR"
        curl -sS https://bootstrap.pypa.io/get-pip.py | "${VENV_DIR}/bin/python3" 2>&1 | tail -1
        "${VENV_DIR}/bin/pip" install ansible 2>&1 | tail -1
        export PATH="${VENV_DIR}/bin:${PATH}"
    elif command -v dnf &>/dev/null; then
        dnf install -y ansible
    elif command -v apt-get &>/dev/null; then
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y ansible
    else
        log_error "Cannot install Ansible automatically. Install it manually:"
        log_error "  pip install ansible   or   dnf install ansible   or   apt install ansible"
        exit 1
    fi
}

if ! command -v ansible-playbook &>/dev/null; then
    log_info "Ansible not found. Installing..."
    install_ansible
fi

if ! command -v ansible-playbook &>/dev/null; then
    log_error "ansible-playbook still not found after installation."
    exit 1
fi

log_info "Running Ansible playbook: ${PLAYBOOK}"
exec ansible-playbook --become -K "$PLAYBOOK"
