#!/bin/bash
# install-e2e-deps.sh — guest-side installer for running nested VM e2e checks.
#
# Installs inside the Ubuntu guest:
#   - QEMU, libvirt, cloud-image-utils, OVMF, jq, iptables, cpu-checker
#   - apt-cacher-ng, so nested VMs reuse a local apt package cache
#   - enables libvirtd, apt-cacher-ng, and the default NAT network
#   - adds 'ubuntu' to the libvirt and kvm groups
#
# Idempotent: safe to re-run. Progress lines use the '>>>' convention from
# cloud-init/user-data. Exits non-zero with a clear message on failure.
set -euo pipefail

GUEST_USER="ubuntu"

PACKAGES=(
    qemu-system-x86
    qemu-utils
    libvirt-daemon-system
    libvirt-clients
    # dnsmasq-base is only a Recommends of libvirt-daemon-system; without it
    # the default NAT network cannot start.
    dnsmasq-base
    cloud-image-utils
    genisoimage
    ovmf
    jq
    iptables
    cpu-checker
    apt-cacher-ng
)

log_progress() { echo ">>> $*"; }
fail() {
    echo ">>> ERROR: $*" >&2
    exit 1
}

if ! command -v apt-get >/dev/null 2>&1; then
    fail "This installer targets Debian/Ubuntu guests (apt-get not found)."
fi

log_progress "Installing QEMU/libvirt and e2e dependencies..."
sudo apt-get update
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${PACKAGES[@]}"

for bin in virsh qemu-img qemu-system-x86_64 cloud-localds; do
    command -v "$bin" >/dev/null 2>&1 \
        || fail "Required command not found after install: ${bin}"
done

log_progress "Enabling libvirtd..."
sudo systemctl enable --now libvirtd

log_progress "Enabling apt-cacher-ng (caches nested VM apt packages)..."
sudo systemctl enable --now apt-cacher-ng

log_progress "Ensuring the libvirt default network is defined and active..."
if ! sudo virsh net-info default >/dev/null 2>&1; then
    fail "libvirt default network is not defined; check 'libvirt-daemon-system'."
fi
sudo virsh net-autostart default >/dev/null 2>&1 || true
# Capture the output first: piping `virsh net-info` into `grep -q` under
# pipefail can SIGPIPE virsh and falsely report the network as inactive.
net_info=$(sudo virsh net-info default) \
    || fail "Could not read the libvirt default network state."
if ! grep -qE '^Active:[[:space:]]*yes' <<<"$net_info"; then
    sudo virsh net-start default \
        || fail "Could not start the libvirt default network."
fi

log_progress "Adding ${GUEST_USER} to the libvirt/kvm groups..."
GROUPS_TO_ADD="libvirt"
if getent group kvm >/dev/null 2>&1; then
    GROUPS_TO_ADD="${GROUPS_TO_ADD},kvm"
fi
sudo usermod -aG "$GROUPS_TO_ADD" "$GUEST_USER"

log_progress "Checking nested virtualization support..."
if [[ ! -e /dev/kvm ]]; then
    echo ">>> WARNING: /dev/kvm is missing; nested VMs will use TCG (slow)."
elif [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
    echo ">>> NOTE: /dev/kvm is not writable yet; reconnect so the new kvm group applies."
fi
if ! grep -qE '(^flags|^Features)[^:]*:.*(vmx|svm)' /proc/cpuinfo; then
    echo ">>> WARNING: CPU virtualization flags (vmx/svm) are not exposed to this guest."
    echo ">>> Nested VMs will fall back to TCG; enable nested virtualization on the host for KVM."
fi
if command -v kvm-ok >/dev/null 2>&1; then
    sudo kvm-ok || true
fi

qemu_img_version=$(qemu-img --version 2>/dev/null | sed -n '1p')
log_progress "e2e dependencies ready: $(virsh --version), ${qemu_img_version}"
echo ">>> Reconnect SSH (or run nested commands via 'sg kvm -c ...') to pick up the new group membership."
