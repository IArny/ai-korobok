#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAYBOOK="${SCRIPT_DIR}/playbooks/setup.yml"
VENV_DIR="${SCRIPT_DIR}/.venv"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

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
