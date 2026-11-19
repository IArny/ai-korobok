#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.json"
STATE_DIR="${SCRIPT_DIR}/.state"
IPTABLES_STATE="${STATE_DIR}/iptables-rules"
VIRTIOFS_PID_FILE="${STATE_DIR}/virtiofsd.pid"
CLOUD_IMAGE_CACHE="${STATE_DIR}/.cloud-image-cache"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_cmd()   { echo -e "${CYAN}[CMD]${NC} $*"; }

ensure_state_dir() {
    mkdir -p "$STATE_DIR"
}

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        local example_config="${SCRIPT_DIR}/config.example.json"
        if [[ -f "$example_config" ]]; then
            log_error "Config file not found: $CONFIG_FILE"
            log_info "Copy the example config to get started:"
            log_info "  cp config.example.json config.json"
        else
            log_error "Config file not found: $CONFIG_FILE"
        fi
        exit 1
    fi
    if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
        log_error "Invalid JSON in config file: $CONFIG_FILE"
        exit 1
    fi
    VM_NAME=$(jq -r '.vm_name' "$CONFIG_FILE")
    VCPUS=$(jq -r '.vcpus' "$CONFIG_FILE")
    MEMORY_MB=$(jq -r '.memory_mb' "$CONFIG_FILE")
    DISK_GB=$(jq -r '.disk_gb' "$CONFIG_FILE")
    DISK_PATH=$(jq -r '.disk_path' "$CONFIG_FILE")
    GPU_PASSTHROUGH=$(jq -r '.gpu_passthrough // false' "$CONFIG_FILE")
    OS_VARIANT=$(jq -r '.os_variant // "ubuntu24.04"' "$CONFIG_FILE")
    VM_PASSWORD=$(jq -r '.vm_password // "ubuntu"' "$CONFIG_FILE")
    SHARED_HOST_PATH=$(jq -r '.shared_dir.host_path // empty' "$CONFIG_FILE")
    SHARED_MOUNT_TAG=$(jq -r '.shared_dir.mount_tag // empty' "$CONFIG_FILE")
    SHARED_MOUNT_POINT=$(jq -r '.shared_dir.mount_point // empty' "$CONFIG_FILE")
    NETWORK_TYPE=$(jq -r '.network.type // "nat"' "$CONFIG_FILE")
    WIFI_INTERFACE=$(jq -r '.network.wifi_interface // empty' "$CONFIG_FILE")
    PROVISIONING_WAIT=$(jq -r 'if (.provisioning | type) == "object" and .provisioning.wait == false then "false" else "true" end' "$CONFIG_FILE")
    PROVISIONING_TIMEOUT=$(jq -r 'if (.provisioning | type) == "object" then (.provisioning.timeout_seconds // 1800) else 1800 end' "$CONFIG_FILE")
    PERSIST_ENABLED=$(jq -r 'if (.opencode_persistence | type) == "object" and .opencode_persistence.enabled == false then "false" else "true" end' "$CONFIG_FILE")
    PERSIST_HOST_PATH=$(jq -r 'if (.opencode_persistence | type) == "object" then (.opencode_persistence.host_path // "") else "" end' "$CONFIG_FILE")
    PERSIST_PROFILE=$(jq -r 'if (.opencode_persistence | type) == "object" then (.opencode_persistence.backup_profile // "agent") else "agent" end' "$CONFIG_FILE")
    PERSIST_INCLUDE_CACHE_RAW=$(jq -r 'if (.opencode_persistence | type) == "object" then (if .opencode_persistence.include_cache == true then "true" elif .opencode_persistence.include_cache == false then "false" else "null" end) else "null" end' "$CONFIG_FILE")
    PERSIST_INCLUDE_DOCKER_VOLUMES=$(jq -r 'if (.opencode_persistence | type) == "object" and .opencode_persistence.include_docker_volumes == true then "true" else "false" end' "$CONFIG_FILE")

    case "$PERSIST_HOST_PATH" in
        "~/"*) PERSIST_HOST_PATH="${HOME}/${PERSIST_HOST_PATH#\~/}" ;;
        "")    PERSIST_HOST_PATH="${HOME}/.local/share/ai-korobok/opencode" ;;
        /*)    ;;
        *)     PERSIST_HOST_PATH="${SCRIPT_DIR}/${PERSIST_HOST_PATH}" ;;
    esac
    case "$PERSIST_HOST_PATH" in
        "$SCRIPT_DIR"|"$SCRIPT_DIR"/*)
            log_warn "opencode_persistence.host_path is inside the project; keep it gitignored and never commit its contents."
            ;;
    esac
    case "$PERSIST_PROFILE" in
        minimal|agent|full) ;;
        *)
            log_warn "Invalid opencode_persistence.backup_profile '${PERSIST_PROFILE}' — using 'agent'."
            PERSIST_PROFILE="agent"
            ;;
    esac
    if [[ "$PERSIST_INCLUDE_CACHE_RAW" == "null" ]]; then
        if [[ "$PERSIST_PROFILE" == "full" ]]; then
            PERSIST_INCLUDE_CACHE="true"
        else
            PERSIST_INCLUDE_CACHE="false"
        fi
    else
        PERSIST_INCLUDE_CACHE="$PERSIST_INCLUDE_CACHE_RAW"
    fi
    if [[ "$PERSIST_PROFILE" != "full" && "$PERSIST_INCLUDE_DOCKER_VOLUMES" == "true" ]]; then
        log_warn "opencode_persistence.include_docker_volumes only applies to the 'full' profile; ignoring."
        PERSIST_INCLUDE_DOCKER_VOLUMES="false"
    fi
    LOCAL_NETWORK=""
    WIFI_NET_PREFIX="192.168.100"
    WIFI_GATEWAY="${WIFI_NET_PREFIX}.1"

    KEYS_DIR="${SCRIPT_DIR}/keys"
    SSH_KEY="${KEYS_DIR}/${VM_NAME}"
    DISK_DIR="$(dirname "$DISK_PATH")"
    SEED_ISO="${DISK_DIR}/${VM_NAME}-seed.iso"
    OVERLAY_PATH="${DISK_PATH}"
    BASE_IMAGE="${DISK_DIR}/ubuntu-24.04-server-cloudimg-amd64.img"
    DOMAIN_XML="${STATE_DIR}/${VM_NAME}.xml"
}

detect_kvm() {
    if [[ -e /dev/kvm ]] && [[ -r /dev/kvm ]] && [[ -w /dev/kvm ]]; then
        KVM_AVAILABLE=true
        DOMAIN_TYPE="kvm"
        CPU_MODE="host-passthrough"
        log_info "KVM acceleration available."
    else
        KVM_AVAILABLE=false
        DOMAIN_TYPE="qemu"
        CPU_MODE="max"
        log_warn "/dev/kvm not available — using TCG (software emulation). VM will be slower."
    fi
}

detect_qemu_machine() {
    local qemu_version
    qemu_version=$(qemu-system-x86_64 --version 2>/dev/null | grep -oP 'version \K[0-9]+\.[0-9]+' | head -1)
    if [[ -z "$qemu_version" ]]; then
        MACHINE_TYPE="q35"
        log_warn "Could not detect QEMU version, using generic 'q35' machine type."
        return
    fi
    local major minor
    major=$(echo "$qemu_version" | cut -d. -f1)
    minor=$(echo "$qemu_version" | cut -d. -f2)
    MACHINE_TYPE="pc-q35-${major}.${minor}"
    log_info "Detected QEMU ${qemu_version}, using machine type: ${MACHINE_TYPE}"
}

detect_ovmf() {
    local code_paths=(
        "/usr/share/OVMF/OVMF_CODE_4M.ms.fd"
        "/usr/share/OVMF/OVMF_CODE_4M.fd"
        "/usr/share/OVMF/OVMF_CODE.fd"
        "/usr/share/edk2/ovmf/OVMF_CODE.fd"
    )
    local vars_paths=(
        "/usr/share/OVMF/OVMF_VARS_4M.ms.fd"
        "/usr/share/OVMF/OVMF_VARS_4M.fd"
        "/usr/share/OVMF/OVMF_VARS.fd"
        "/usr/share/edk2/ovmf/OVMF_VARS.fd"
    )
    OVMF_CODE=""
    OVMF_VARS=""
    for p in "${code_paths[@]}"; do
        if [[ -f "$p" ]]; then OVMF_CODE="$p"; break; fi
    done
    for p in "${vars_paths[@]}"; do
        if [[ -f "$p" ]]; then OVMF_VARS="$p"; break; fi
    done
    if [[ -z "$OVMF_CODE" ]] || [[ -z "$OVMF_VARS" ]]; then
        log_error "OVMF firmware files not found. Install 'ovmf' (Debian/Ubuntu) or 'edk2-ovmf' (Fedora)."
        exit 1
    fi
    log_info "OVMF: code=${OVMF_CODE} vars=${OVMF_VARS}"
}

detect_local_network() {
    if [[ "$NETWORK_TYPE" != "wifi-bridge" ]] || [[ -z "$WIFI_INTERFACE" ]]; then
        LOCAL_NETWORK=""
        return
    fi

    local cidr host prefix o1 o2 o3 o4 mask net
    cidr=$(ip -4 -o addr show dev "$WIFI_INTERFACE" 2>/dev/null | awk '{print $4}' | head -1 || true)
    if [[ -z "$cidr" ]]; then
        log_warn "No IPv4 subnet detected on ${WIFI_INTERFACE}; skipping guest local route."
        LOCAL_NETWORK=""
        return
    fi

    host="${cidr%%/*}"
    prefix="${cidr##*/}"
    IFS=. read -r o1 o2 o3 o4 <<< "$host"
    mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    net=$(( ((o1 << 24) | (o2 << 16) | (o3 << 8) | o4) & mask ))
    LOCAL_NETWORK="$(( (net >> 24) & 255 )).$(( (net >> 16) & 255 )).$(( (net >> 8) & 255 )).$(( net & 255 ))/${prefix}"
    log_info "Local network ${LOCAL_NETWORK} detected on ${WIFI_INTERFACE}; routing it via ${WIFI_GATEWAY}."
}

generate_ssh_key() {
    mkdir -p "$KEYS_DIR"
    if [[ -f "$SSH_KEY" ]]; then
        log_info "SSH key already exists: ${SSH_KEY}"
        return
    fi
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "${VM_NAME}@ai-vm"
    log_info "Generated SSH keypair: ${SSH_KEY}"
}

get_public_key() {
    cat "${SSH_KEY}.pub"
}

generate_cloud_init() {
    log_info "Generating cloud-init seed ISO..."
    local user_data_template="${SCRIPT_DIR}/cloud-init/user-data"
    local meta_data_template="${SCRIPT_DIR}/cloud-init/meta-data"
    local user_data_out="${STATE_DIR}/user-data"
    local meta_data_out="${STATE_DIR}/meta-data"

    if [[ ! -f "$user_data_template" ]] || [[ ! -f "$meta_data_template" ]]; then
        log_error "Cloud-init templates not found in ${SCRIPT_DIR}/cloud-init/"
        exit 1
    fi

    local pub_key
    pub_key=$(get_public_key)

    local password_hash
    password_hash=$(openssl passwd -6 "$VM_PASSWORD")

    sed -e "s|__SSH_PUBLIC_KEY__|${pub_key}|g" \
        -e "s|__PASSWORD_HASH__|${password_hash}|g" \
        -e "s|__MOUNT_POINT__|${SHARED_MOUNT_POINT}|g" \
        -e "s|__MOUNT_TAG__|${SHARED_MOUNT_TAG}|g" \
        -e "s|__LOCAL_NETWORK__|${LOCAL_NETWORK}|g" \
        -e "s|__WIFI_GATEWAY__|${WIFI_GATEWAY}|g" \
        "$user_data_template" > "$user_data_out"

    local skill_src="${SCRIPT_DIR}/skills/backlog/SKILL.md"
    if [[ ! -f "$skill_src" ]]; then
        log_error "Global skill not found: ${skill_src}"
        exit 1
    fi
    local skill_indented="${STATE_DIR}/backlog-skill.indented"
    local user_data_tmp="${STATE_DIR}/user-data.tmp"
    sed 's/^/      /' "$skill_src" > "$skill_indented"
    awk -v skill="$skill_indented" '
        /__BACKLOG_SKILL_CONTENT__/ {
            while ((getline line < skill) > 0) print line
            close(skill)
            next
        }
        { print }
    ' "$user_data_out" > "$user_data_tmp"
    mv "$user_data_tmp" "$user_data_out"
    rm -f "$skill_indented"

    cp "$meta_data_template" "$meta_data_out"

    if [[ ! -d "$DISK_DIR" ]]; then
        if ! mkdir -p "$DISK_DIR" 2>/dev/null; then
            sudo mkdir -p "$DISK_DIR"
        fi
    fi

    if [[ -w "$DISK_DIR" ]]; then
        rm -f "$SEED_ISO"
        cloud-localds "$SEED_ISO" "$user_data_out" "$meta_data_out"
    else
        local tmp_seed="${STATE_DIR}/${VM_NAME}-seed.iso"
        rm -f "$tmp_seed"
        cloud-localds "$tmp_seed" "$user_data_out" "$meta_data_out"
        sudo rm -f "$SEED_ISO"
        sudo mv "$tmp_seed" "$SEED_ISO"
    fi

    if ! chmod 0644 "$SEED_ISO" 2>/dev/null; then
        sudo chmod 0644 "$SEED_ISO"
    fi
    log_info "Cloud-init seed ISO created: ${SEED_ISO}"
}

download_cloud_image() {
    if [[ ! -d "$DISK_DIR" ]]; then
        if ! mkdir -p "$DISK_DIR" 2>/dev/null; then
            sudo mkdir -p "$DISK_DIR"
        fi
    fi

    LEGACY_IMAGE_MOVED=false
    local legacy_image="${STATE_DIR}/ubuntu-24.04-server-cloudimg-amd64.img"
    if [[ ! -f "$BASE_IMAGE" ]] && [[ -f "$legacy_image" ]]; then
        log_info "Moving cached cloud image to libvirt storage: ${BASE_IMAGE}"
        if [[ -w "$DISK_DIR" ]]; then
            mv "$legacy_image" "$BASE_IMAGE"
        else
            sudo mv "$legacy_image" "$BASE_IMAGE"
        fi
        LEGACY_IMAGE_MOVED=true
    fi

    if [[ -f "$BASE_IMAGE" ]]; then
        log_info "Using cached cloud image: ${BASE_IMAGE}"
    else
        local url="https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
        log_info "Downloading Ubuntu 24.04 cloud image..."
        log_info "URL: ${url}"
        if [[ -w "$DISK_DIR" ]]; then
            wget -q --show-progress -O "$BASE_IMAGE" "$url"
        else
            local tmp="${STATE_DIR}/ubuntu-24.04-server-cloudimg-amd64.img.download"
            wget -q --show-progress -O "$tmp" "$url"
            sudo mv "$tmp" "$BASE_IMAGE"
        fi
    fi

    if ! chmod 0644 "$BASE_IMAGE" 2>/dev/null; then
        sudo chmod 0644 "$BASE_IMAGE"
    fi
    log_info "Cloud image ready: ${BASE_IMAGE}"
}

create_disk_overlay() {
    if [[ -f "$DISK_PATH" ]]; then
        if [[ "${LEGACY_IMAGE_MOVED:-false}" == "true" ]]; then
            log_info "Rebasing existing overlay onto moved cloud image..."
            if [[ -w "$DISK_PATH" ]]; then
                qemu-img rebase -u -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$DISK_PATH"
            else
                sudo qemu-img rebase -u -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$DISK_PATH"
            fi
        fi
        log_info "Disk image already exists: ${DISK_PATH}"
        return
    fi
    if [[ ! -d "$DISK_DIR" ]]; then
        if ! mkdir -p "$DISK_DIR" 2>/dev/null; then
            sudo mkdir -p "$DISK_DIR"
        fi
    fi
    log_info "Creating qcow2 overlay (${DISK_GB}GB)..."
    if [[ -w "$DISK_DIR" ]]; then
        qemu-img create -f qcow2 -b "$BASE_IMAGE" -F qcow2 "$DISK_PATH" "${DISK_GB}G"
    else
        sudo qemu-img create -f qcow2 -b "$BASE_IMAGE" -F qcow2 "$DISK_PATH" "${DISK_GB}G"
    fi
    log_info "Disk overlay created: ${DISK_PATH}"
}

generate_domain_xml() {
    log_info "Generating domain XML..."

    local virtiofs_block=""
    local mem_backing_block=""
    local gpu_block=""
    local network_block=""

    local virsh_net_name="${VM_NAME}-wifi"
    if [[ "$NETWORK_TYPE" == "wifi-bridge" ]]; then
        network_block="    <interface type='network'>
      <source network='${virsh_net_name}'/>
      <model type='virtio'/>
    </interface>"
    else
        network_block="    <interface type='network'>
      <source network='default'/>
      <model type='virtio'/>
    </interface>"
    fi

    if [[ -n "$SHARED_HOST_PATH" ]] && [[ -n "$SHARED_MOUNT_TAG" ]]; then
        mkdir -p "$SHARED_HOST_PATH"
        virtiofs_block="    <filesystem type='mount' accessmode='passthrough'>
      <driver type='virtiofs'/>
      <source dir='${SHARED_HOST_PATH}'/>
      <target dir='${SHARED_MOUNT_TAG}'/>
      <binary path='/usr/libexec/virtiofsd'/>
    </filesystem>"
        mem_backing_block="  <memoryBacking>
    <source type='memfd'/>
    <access mode='shared'/>
  </memoryBacking>"
    fi

    if [[ "$GPU_PASSTHROUGH" == "true" ]]; then
        local gpu_pci
        gpu_pci=$(lspci -nn 2>/dev/null | grep -i 'vga\|3d\|display' | grep -iv 'intel' | head -1 | grep -oP '^\K[0-9a-f:.]+' || true)
        if [[ -n "$gpu_pci" ]]; then
            local bus slot
            bus="${gpu_pci%%:*}"
            slot="${gpu_pci#*:}"
            gpu_block="    <hostdev mode='subsystem' type='pci' managed='yes'>
      <source>
        <address domain='0x0000' bus='0x${bus}' slot='0x${slot}' function='0x0'/>
      </source>
    </hostdev>"
            log_info "GPU passthrough enabled for PCI device: ${gpu_pci}"
        else
            log_warn "GPU passthrough requested but no discrete GPU found. Skipping."
        fi
    fi

    cat > "$DOMAIN_XML" <<EOF
<domain type='${DOMAIN_TYPE}'>
  <name>${VM_NAME}</name>
  <memory unit='MiB'>${MEMORY_MB}</memory>
  <vcpu placement='static'>${VCPUS}</vcpu>
${mem_backing_block:+${mem_backing_block}
}
  <os firmware='efi'>
    <type arch='x86_64' machine='${MACHINE_TYPE}'>hvm</type>
    <firmware>
      <feature enabled='yes' name='enrolled-keys'/>
      <feature enabled='yes' name='secure-boot'/>
    </firmware>
  </os>
  <features>
    <acpi/>
    <apic/>
    <vmport state='off'/>
  </features>
  <cpu mode='${CPU_MODE}' check='none'>
    <topology sockets='1' dies='1' cores='${VCPUS}' threads='1'/>
  </cpu>
  <clock offset='utc'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
  </clock>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' discard='unmap' detect-zeroes='unmap'/>
      <source file='${DISK_PATH}'/>
      <target dev='vda' bus='virtio'/>
      <boot order='1'/>
    </disk>
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='${SEED_ISO}'/>
      <target dev='sda' bus='sata'/>
      <readonly/>
    </disk>
${network_block}
    <serial type='pty'>
      <target type='isa-serial' port='0'>
        <model name='isa-serial'/>
      </target>
    </serial>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
    <channel type='unix'>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
    </channel>
    <input type='tablet' bus='usb'/>
    <input type='keyboard' bus='usb'/>
    <graphics type='vnc' port='-1' autoport='yes' listen='127.0.0.1'>
      <listen type='address' address='127.0.0.1'/>
    </graphics>
    <video>
      <model type='virtio' heads='1' primary='yes'/>
    </video>
    <memballoon model='virtio'/>
${virtiofs_block:+${virtiofs_block}
}${gpu_block:+${gpu_block}
}  </devices>
</domain>
EOF

    log_info "Domain XML written: ${DOMAIN_XML}"
}

get_vm_ip() {
    local attempts="${1:-30}"
    local ip=""
    for i in $(seq 1 "$attempts"); do
        ip=$(virsh domifaddr "$VM_NAME" 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+' | head -1 || true)
        if [[ -n "$ip" ]]; then
            echo "$ip"
            return 0
        fi
        ip=$(virsh net-dhcp-leases default 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+' | head -1 || true)
        if [[ -n "$ip" ]]; then
            echo "$ip"
            return 0
        fi
        if [[ -f /var/lib/libvirt/dnsmasq/virbr0.status ]]; then
            ip=$(jq -r '.[] | select(.["ip-address"] != null) | .["ip-address"]' /var/lib/libvirt/dnsmasq/virbr0.status 2>/dev/null | head -1 || true)
            if [[ -n "$ip" ]]; then
                echo "$ip"
                return 0
            fi
        fi
        sleep 2
    done
    return 1
}

# Non-interactive SSH to the guest; never blocks on prompts.
vm_ssh() {
    local ip="$1"
    shift
    local connect_timeout="${VM_SSH_CONNECT_TIMEOUT:-5}"
    ssh -i "$SSH_KEY" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o BatchMode=yes \
        -o ConnectTimeout="$connect_timeout" \
        -o ServerAliveInterval=5 \
        -o ServerAliveCountMax=2 \
        -o LogLevel=ERROR \
        "ubuntu@${ip}" "$@"
}

# Probe guest provisioning over SSH. Prints the last ">>>" step (or a READY
# marker) and exits with:
#   0   provisioning complete
#  10   still provisioning
#  11   cloud-init missing or disabled
#  12   cloud-init reported an error
# 255   SSH connection failure
provisioning_state() {
    local ip="$1"
    local output rc=0
    output=$(vm_ssh "$ip" 'bash -s' 2>/dev/null <<'REMOTE'
sentinel=/var/lib/ai-korobok/provisioned
if ! command -v cloud-init >/dev/null 2>&1; then
    echo "cloud-init is not installed"
    exit 11
fi
last_step=$(grep '^>>> ' /var/log/cloud-init-output.log 2>/dev/null | tail -n 1)
cstatus=$(cloud-init status 2>/dev/null | sed -n 's/^status: //p')
case "$cstatus" in
    disabled)
        echo "cloud-init is disabled"
        exit 11
        ;;
    error)
        echo "$last_step"
        exit 12
        ;;
esac
if [ -f "$sentinel" ]; then
    marker_boot=$(cut -d' ' -f1 "$sentinel" 2>/dev/null)
    current_boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
    # Require the sentinel to come from an earlier boot so the final
    # cloud-init reboot has already happened before we report success.
    if [ -n "$marker_boot" ] && [ "$marker_boot" != "$current_boot" ] && [ "$cstatus" = "done" ]; then
        echo "READY"
        exit 0
    fi
    echo "$last_step"
    exit 10
fi
# No sentinel: accept an already provisioned VM created before the marker existed.
if [ "$cstatus" = "done" ]; then
    log_age=$(( $(date -u +%s) - $(stat -c %Y /var/log/cloud-init-output.log 2>/dev/null || echo 0) ))
    if [ "$log_age" -gt 300 ]; then
        echo "READY-LEGACY"
        exit 0
    fi
fi
echo "$last_step"
exit 10
REMOTE
    ) || rc=$?
    printf '%s' "$output"
    return "$rc"
}

format_elapsed() {
    local seconds="$1"
    if (( seconds >= 60 )); then
        printf '%dm%02ds' $((seconds / 60)) $((seconds % 60))
    else
        printf '%ds' "$seconds"
    fi
}

# Wait until the guest finishes cloud-init provisioning. Sets PROVISIONED_IP
# to the address that answered when it succeeds.
wait_for_provisioning() {
    local vm_ip="${1:-}"
    local timeout="${2:-$PROVISIONING_TIMEOUT}"
    local start_ts now_ts elapsed last_step="" last_heartbeat rc output failures=0
    start_ts=$(date +%s)
    last_heartbeat=$start_ts
    PROVISIONED_IP=""

    while true; do
        now_ts=$(date +%s)
        elapsed=$((now_ts - start_ts))
        if (( elapsed >= timeout )); then
            log_warn "Provisioning did not finish within $(format_elapsed "$timeout")."
            return 1
        fi

        if [[ -z "$vm_ip" ]]; then
            vm_ip=$(get_vm_ip 2>/dev/null || true)
            if [[ -z "$vm_ip" ]]; then
                sleep 5
                continue
            fi
            log_info "VM IP: ${vm_ip}"
        fi

        rc=0
        output=$(provisioning_state "$vm_ip") || rc=$?

        case "$rc" in
            0)
                PROVISIONED_IP="$vm_ip"
                log_info "Guest provisioning complete ($(format_elapsed "$elapsed"))."
                return 0
                ;;
            11)
                log_warn "cloud-init is not available in the guest; skipping the provisioning wait."
                return 2
                ;;
            12)
                log_error "cloud-init reported an error during provisioning."
                log_warn "Inspect /var/log/cloud-init-output.log in the guest for details."
                return 3
                ;;
            10)
                failures=0
                if [[ -n "$output" && "$output" != "$last_step" ]]; then
                    log_info "Provisioning: ${output#>>> }"
                    last_step="$output"
                    last_heartbeat=$now_ts
                elif (( now_ts - last_heartbeat >= 30 )); then
                    log_info "Still provisioning ($(format_elapsed "$elapsed") elapsed)${last_step:+: ${last_step#>>> }}"
                    last_heartbeat=$now_ts
                fi
                ;;
            *)
                failures=$((failures + 1))
                if (( failures == 3 )); then
                    log_warn "SSH is not available yet (the guest may be booting or rebooting); still waiting..."
                fi
                if (( failures % 6 == 0 )); then
                    vm_ip=""
                    last_step=""
                fi
                ;;
        esac

        sleep 5
    done
}

wait_for_guest_ssh() {
    local ip="$1"
    local timeout="${2:-120}"
    local deadline=$(( $(date +%s) + timeout ))
    while (( $(date +%s) < deadline )); do
        if vm_ssh "$ip" true 2>/dev/null; then
            return 0
        fi
        sleep 2
    done
    return 1
}

# Paths persisted by profile. OpenCode paths are resolved in the guest first;
# the rest are conventional locations that are filtered by existence there.
persist_profile_paths() {
    local profile="$1"
    local home="$2"
    local config="$3"
    local data="$4"
    local state="$5"
    local cache="$6"
    local include_cache="$7"

    local paths=("$config" "$data" "$state")
    if [[ "$include_cache" == "true" ]]; then
        paths+=("$cache")
    fi

    if [[ "$profile" == "agent" || "$profile" == "full" ]]; then
        paths+=(
            "$home/.ssh"
            "$home/.gitconfig"
            "$home/.config/gh"
            "$home/.npmrc"
            "$home/.netrc"
            "$home/.config/pip"
            "$home/.pip/pip.conf"
            "$home/.aws"
            "$home/.config/gcloud"
            "$home/.kube"
            "$home/.docker/config.json"
            "$home/.bashrc"
            "$home/.profile"
            "$home/.bash_history"
            "$home/.config/fish"
            "$home/.config/systemd/user"
            "$home/.local/bin"
            "$home/.local/state/opencode-indexing"
            "$home/.config/mcp"
            "$home/.local/share/mcp"
            "/var/spool/cron/crontabs/ubuntu"
        )
    fi

    if [[ "$profile" == "full" ]]; then
        paths+=(
            "$home/.cache/huggingface"
            "$home/.ollama"
            "$home/.npm/_cacache"
            "$home/.cache/pip"
            "$home/.cache/uv"
            "$home/go/pkg/mod"
            "$home/.cache/ms-playwright"
        )
    fi

    printf '%s\n' "${paths[@]}" | awk '!seen[$0]++'
}

# Prints guest home, config, data, state, and cache paths (one per line),
# asking OpenCode when it is installed and falling back to Linux defaults.
persist_resolve_guest_paths() {
    local ip="$1"
    vm_ssh "$ip" 'bash -s' 2>/dev/null <<'REMOTE'
home="${HOME:-/home/ubuntu}"
echo "$home"
if command -v opencode >/dev/null 2>&1; then
    p=$(opencode debug paths config 2>/dev/null); echo "${p:-$home/.config/opencode}"
    p=$(opencode debug paths data 2>/dev/null); echo "${p:-$home/.local/share/opencode}"
    p=$(opencode debug paths state 2>/dev/null); echo "${p:-$home/.local/state/opencode}"
    p=$(opencode debug paths cache 2>/dev/null); echo "${p:-$home/.cache/opencode}"
else
    echo "$home/.config/opencode"
    echo "$home/.local/share/opencode"
    echo "$home/.local/state/opencode"
    echo "$home/.cache/opencode"
fi
REMOTE
}

persist_guest_filter_existing() {
    local ip="$1"
    shift
    {
        echo 'paths=('
        printf '%q\n' "$@"
        echo ')'
        cat <<'REMOTE'
for p in "${paths[@]}"; do
    if [ -e "$p" ] || [ -L "$p" ]; then
        printf '%s\n' "$p"
    fi
done
REMOTE
    } | vm_ssh "$ip" 'bash -s' 2>/dev/null
}

persist_guest_tar() {
    local ip="$1"
    shift
    {
        echo 'paths=('
        printf '%q\n' "$@"
        echo ')'
        cat <<'REMOTE'
existing=()
for p in "${paths[@]}"; do
    [ -e "$p" ] || [ -L "$p" ] || continue
    existing+=("${p#/}")
done
if [ ${#existing[@]} -eq 0 ]; then
    exit 7
fi
sudo tar czf - -C / --exclude=authorized_keys "${existing[@]}"
REMOTE
    } | vm_ssh "$ip" 'bash -s'
}

persist_guest_opencode_version() {
    local ip="$1"
    vm_ssh "$ip" 'opencode --version 2>/dev/null | head -n 1' 2>/dev/null || true
}

persist_write_manifest() {
    local host_path="$1"
    local ip="$2"
    shift 2

    local created version paths_json docker_json
    created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    version=$(persist_guest_opencode_version "$ip")
    [[ -z "$version" ]] && version="unknown"

    paths_json=$(printf '%s\n' "$@" | jq -R -s 'split("\n") | map(select(length > 0))')

    local volumes=()
    local archive
    for archive in "$host_path"/docker-volumes/*.tar.gz; do
        [[ -f "$archive" ]] || continue
        volumes+=("$(basename "$archive" .tar.gz)")
    done
    if [[ ${#volumes[@]} -gt 0 ]]; then
        docker_json=$(printf '%s\n' "${volumes[@]}" | jq -R -s 'split("\n") | map(select(length > 0))')
    else
        docker_json='[]'
    fi

    if ! jq -n \
        --arg created "$created" \
        --arg vm "$VM_NAME" \
        --arg version "$version" \
        --arg profile "$PERSIST_PROFILE" \
        --arg cache "$PERSIST_INCLUDE_CACHE" \
        --argjson paths "$paths_json" \
        --argjson volumes "$docker_json" \
        '{
            format_version: 1,
            created_at: $created,
            source_vm: $vm,
            opencode_version: $version,
            profile: $profile,
            include_cache: ($cache == "true"),
            included_paths: $paths,
            docker_volumes: $volumes
        }' > "${host_path}/manifest.json.tmp"; then
        rm -f "${host_path}/manifest.json.tmp"
        return 1
    fi
    mv "${host_path}/manifest.json.tmp" "${host_path}/manifest.json"
    chmod 0600 "${host_path}/manifest.json"
}

persist_sync_docker_volumes() {
    local ip="$1"
    local dir="${PERSIST_HOST_PATH}/docker-volumes"
    local volumes vol

    volumes=$(vm_ssh "$ip" 'docker volume ls -q 2>/dev/null || true' 2>/dev/null || true)
    rm -rf "$dir"
    if [[ -z "$volumes" ]]; then
        return 0
    fi

    install -d -m 0700 "$dir"
    while IFS= read -r vol; do
        [[ "$vol" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || continue
        if vm_ssh "$ip" "sudo tar czf - -C /var/lib/docker/volumes/${vol}/_data ." > "${dir}/${vol}.tar.gz" 2>/dev/null; then
            log_info "  Docker volume: ${vol}"
        else
            rm -f "${dir}/${vol}.tar.gz"
            log_warn "  Could not export Docker volume '${vol}'; skipping."
        fi
    done <<< "$volumes"

    if [[ -z "$(ls -A "$dir" 2>/dev/null)" ]]; then
        rmdir "$dir" 2>/dev/null || true
    fi
}

persist_sync_from_guest() {
    local ip="$1"
    local resolved=()

    if ! [[ "$PERSIST_HOST_PATH" == /* ]]; then
        log_error "opencode_persistence.host_path must be absolute: ${PERSIST_HOST_PATH}"
        return 1
    fi

    mapfile -t resolved < <(persist_resolve_guest_paths "$ip")
    if [[ ${#resolved[@]} -lt 5 ]]; then
        log_warn "Could not resolve guest OpenCode paths; skipping agent state sync."
        return 1
    fi

    local home="${resolved[0]}"
    local config="${resolved[1]}"
    local data="${resolved[2]}"
    local state="${resolved[3]}"
    local cache="${resolved[4]}"

    local paths=()
    mapfile -t paths < <(persist_profile_paths "$PERSIST_PROFILE" "$home" "$config" "$data" "$state" "$cache" "$PERSIST_INCLUDE_CACHE")

    local existing=()
    mapfile -t existing < <(persist_guest_filter_existing "$ip" "${paths[@]}")
    if [[ ${#existing[@]} -eq 0 ]]; then
        log_warn "No agent state found in the guest; leaving the existing backup untouched."
        return 0
    fi

    install -d -m 0700 "$PERSIST_HOST_PATH"
    chmod 0700 "$PERSIST_HOST_PATH"
    local tmp
    tmp=$(mktemp -d "${PERSIST_HOST_PATH}/.sync.XXXXXX")

    if ! persist_guest_tar "$ip" "${existing[@]}" | tar xzf - -C "$tmp" --no-same-owner; then
        rm -rf "$tmp"
        log_error "Failed to copy agent state from ${VM_NAME}."
        return 1
    fi

    rm -rf "${PERSIST_HOST_PATH}/guest.old"
    if [[ -d "${PERSIST_HOST_PATH}/guest" ]]; then
        mv "${PERSIST_HOST_PATH}/guest" "${PERSIST_HOST_PATH}/guest.old"
    fi
    mv "$tmp" "${PERSIST_HOST_PATH}/guest"
    rm -rf "${PERSIST_HOST_PATH}/guest.old"

    if [[ "$PERSIST_INCLUDE_DOCKER_VOLUMES" == "true" ]]; then
        persist_sync_docker_volumes "$ip"
    else
        rm -rf "${PERSIST_HOST_PATH}/docker-volumes"
    fi

    if ! persist_write_manifest "$PERSIST_HOST_PATH" "$ip" "${existing[@]}"; then
        log_warn "Agent state synced, but writing ${PERSIST_HOST_PATH}/manifest.json failed."
        return 1
    fi

    log_info "Synced agent state (${PERSIST_PROFILE}) to ${PERSIST_HOST_PATH}."
}

persist_push_to_guest() {
    local ip="$1"
    local mirror="${PERSIST_HOST_PATH}/guest"
    local manifest="${PERSIST_HOST_PATH}/manifest.json"

    if [[ ! -f "$manifest" || ! -d "$mirror" ]]; then
        return 0
    fi

    if ! tar czf - -C "$mirror" . | vm_ssh "$ip" 'sudo tar xzf - -C / --owner=ubuntu --group=ubuntu --exclude=authorized_keys'; then
        log_error "Failed to restore agent state into ${VM_NAME}."
        return 1
    fi

    local home_paths=()
    mapfile -t home_paths < <(jq -r '.included_paths[]?' "$manifest" | grep '^/home/' || true)
    if [[ ${#home_paths[@]} -gt 0 ]]; then
        {
            echo 'paths=('
            printf '%q\n' "${home_paths[@]}"
            echo ')'
            cat <<'REMOTE'
for p in "${paths[@]}"; do
    [ -e "$p" ] || continue
    sudo chown -R ubuntu:ubuntu "$p"
done
REMOTE
        } | vm_ssh "$ip" 'bash -s' >/dev/null || log_warn "Could not fix ownership for all restored paths."
    fi

    local volume
    for volume in $(jq -r '.docker_volumes[]?' "$manifest"); do
        [[ "$volume" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || continue
        local archive="${PERSIST_HOST_PATH}/docker-volumes/${volume}.tar.gz"
        [[ -f "$archive" ]] || continue
        if vm_ssh "$ip" "docker volume create ${volume} >/dev/null 2>&1 || true; sudo mkdir -p /var/lib/docker/volumes/${volume}/_data && sudo tar xzf - -C /var/lib/docker/volumes/${volume}/_data" < "$archive"; then
            log_info "  Restored Docker volume: ${volume}"
        else
            log_warn "  Could not restore Docker volume '${volume}'."
        fi
    done

    log_info "Restored agent state into ${VM_NAME}."
}

persist_create_archive() {
    local archive="$1"
    local manifest="${PERSIST_HOST_PATH}/manifest.json"
    local mirror="${PERSIST_HOST_PATH}/guest"

    if [[ ! -f "$manifest" || ! -d "$mirror" ]]; then
        log_error "No agent state to archive at ${PERSIST_HOST_PATH}."
        return 1
    fi

    local staging
    staging=$(mktemp -d)
    cp "$manifest" "${staging}/manifest.json"
    cp -R "$mirror" "${staging}/guest"
    local members=(manifest.json guest)
    if [[ -d "${PERSIST_HOST_PATH}/docker-volumes" ]]; then
        cp -R "${PERSIST_HOST_PATH}/docker-volumes" "${staging}/docker-volumes"
        members+=(docker-volumes)
    fi

    if ! ( umask 077; tar czf "$archive" -C "$staging" "${members[@]}" ); then
        rm -rf "$staging"
        log_error "Failed to write archive: ${archive}"
        return 1
    fi
    chmod 0600 "$archive"
    rm -rf "$staging"
}

persist_install_archive() {
    local archive="$1"
    local force="$2"
    local tmp

    if [[ ! -f "$archive" ]]; then
        log_error "Archive not found: ${archive}"
        return 1
    fi

    local unsafe=0 member members
    if ! members=$(tar tzf "$archive" 2>/dev/null); then
        log_error "Could not read archive: ${archive}"
        return 1
    fi
    while IFS= read -r member; do
        case "$member" in
            /*|../*|*/../*|*/..) unsafe=1 ;;
        esac
    done <<< "$members"
    if (( unsafe )); then
        log_error "Archive contains unsafe paths; refusing to restore."
        return 1
    fi

    tmp=$(mktemp -d)
    if ! tar xzf "$archive" -C "$tmp" --no-same-owner 2>/dev/null; then
        rm -rf "$tmp"
        log_error "Could not read archive: ${archive}"
        return 1
    fi

    local manifest="${tmp}/manifest.json"
    if [[ ! -f "$manifest" ]] || ! jq empty "$manifest" 2>/dev/null; then
        rm -rf "$tmp"
        log_error "Archive is missing a valid manifest.json: ${archive}"
        return 1
    fi

    local version
    version=$(jq -r '.format_version // empty' "$manifest")
    if [[ "$version" != "1" ]]; then
        rm -rf "$tmp"
        log_error "Unsupported archive format version '${version:-unknown}' (expected 1)."
        return 1
    fi

    if [[ ! -d "${tmp}/guest" ]]; then
        rm -rf "$tmp"
        log_error "Archive has no guest/ payload: ${archive}"
        return 1
    fi

    local path
    unsafe=0
    while IFS= read -r path; do
        case "$path" in
            /*) ;;
            *) unsafe=1 ;;
        esac
        [[ "$path" == *".."* ]] && unsafe=1
    done < <(jq -r '.included_paths[]?' "$manifest")
    if (( unsafe )); then
        rm -rf "$tmp"
        log_error "Archive manifest contains unsafe paths; refusing to restore."
        return 1
    fi

    install -d -m 0700 "$PERSIST_HOST_PATH"
    if [[ "$force" != "true" && -n "$(find "$PERSIST_HOST_PATH" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
        rm -rf "$tmp"
        log_error "Host persistence is not empty: ${PERSIST_HOST_PATH}"
        log_error "Re-run with --force to overwrite it."
        return 1
    fi

    rm -rf "${PERSIST_HOST_PATH}/guest" "${PERSIST_HOST_PATH}/manifest.json" "${PERSIST_HOST_PATH}/docker-volumes"
    mv "${tmp}/guest" "${PERSIST_HOST_PATH}/guest"
    cp "$manifest" "${PERSIST_HOST_PATH}/manifest.json"
    if [[ -d "${tmp}/docker-volumes" ]]; then
        mv "${tmp}/docker-volumes" "${PERSIST_HOST_PATH}/docker-volumes"
    fi
    chmod 0700 "$PERSIST_HOST_PATH"
    chmod 0600 "${PERSIST_HOST_PATH}/manifest.json"
    rm -rf "$tmp"

    log_info "Restored agent state from ${archive} to ${PERSIST_HOST_PATH}."
}

check_port_available() {
    local port="$1"
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        return 1
    fi
    return 0
}

ensure_forwarding() {
    local policy
    policy=$(iptables -S FORWARD 2>/dev/null | awk '/^-P FORWARD/ {print $3}' || true)
    if [[ "$policy" != "ACCEPT" ]]; then
        log_warn "Host FORWARD policy is '${policy:-unknown}' — setting to ACCEPT so VM traffic can be routed."
        iptables -P FORWARD ACCEPT
    fi
    persist_forwarding
}

persist_forwarding() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        log_warn "Not running as root — FORWARD policy will not persist across reboots."
        log_warn "Re-run with sudo, e.g. sudo ./vm.sh create"
        return
    fi

    if command -v netfilter-persistent &>/dev/null; then
        if netfilter-persistent save &>/dev/null; then
            log_info "Saved iptables rules via netfilter-persistent."
        else
            log_warn "Could not save iptables rules via netfilter-persistent."
        fi
    elif [[ -d /etc/sysconfig ]] && command -v iptables-save &>/dev/null; then
        if iptables-save > /etc/sysconfig/iptables; then
            log_info "Saved iptables rules to /etc/sysconfig/iptables."
        else
            log_warn "Could not save iptables rules to /etc/sysconfig/iptables."
        fi
    else
        log_warn "No iptables persistence mechanism found — FORWARD policy will not persist."
    fi
}

apply_port_forwards() {
    local vm_ip="$1"
    if [[ -z "$vm_ip" ]]; then
        log_warn "No VM IP available — skipping port forwarding."
        return
    fi

    log_info "Applying port forwarding rules (VM IP: ${vm_ip})..."
    : > "$IPTABLES_STATE"

    local num_forwards
    num_forwards=$(jq '.port_forwards | length' "$CONFIG_FILE")
    for ((i = 0; i < num_forwards; i++)); do
        local host_port guest_port proto
        host_port=$(jq -r ".port_forwards[$i].host" "$CONFIG_FILE")
        guest_port=$(jq -r ".port_forwards[$i].guest" "$CONFIG_FILE")
        proto=$(jq -r ".port_forwards[$i].protocol // \"tcp\"" "$CONFIG_FILE")

        if ! check_port_available "$host_port"; then
            log_warn "Host port ${host_port} already in use — skipping forward ${host_port}->${guest_port}."
            continue
        fi

        local rule="-p ${proto} --dport ${host_port} -j DNAT --to-destination ${vm_ip}:${guest_port}"
        if ! iptables -t nat -C PREROUTING $rule 2>/dev/null; then
            iptables -t nat -A PREROUTING $rule
        fi
        echo "nat:PREROUTING:${rule}" >> "$IPTABLES_STATE"

        local rule2="-d ${vm_ip}/32 -p ${proto} --dport ${guest_port} -j ACCEPT"
        if ! iptables -C FORWARD $rule2 2>/dev/null; then
            iptables -A FORWARD $rule2
        fi
        echo "filter:FORWARD:${rule2}" >> "$IPTABLES_STATE"

        log_info "  Forwarding: host:${host_port} -> guest:${guest_port} (${proto})"
    done
}

remove_port_forwards() {
    if [[ ! -f "$IPTABLES_STATE" ]]; then
        return
    fi
    log_info "Removing port forwarding rules..."
    while IFS= read -r line; do
        local table chain rule
        table=$(echo "$line" | cut -d: -f1)
        chain=$(echo "$line" | cut -d: -f2)
        rule=$(echo "$line" | cut -d: -f3-)
        iptables -t "$table" -D "$chain" $rule 2>/dev/null || true
    done < "$IPTABLES_STATE"
    rm -f "$IPTABLES_STATE"
}

start_virtiofsd() {
    if [[ -z "$SHARED_HOST_PATH" ]] || [[ -z "$SHARED_MOUNT_TAG" ]]; then
        return
    fi
    if [[ -f "$VIRTIOFS_PID_FILE" ]] && kill -0 "$(cat "$VIRTIOFS_PID_FILE")" 2>/dev/null; then
        log_info "virtiofsd already running (PID: $(cat "$VIRTIOFS_PID_FILE"))."
        return
    fi

    local virtiofsd_path="/usr/libexec/virtiofsd"
    if [[ ! -x "$virtiofsd_path" ]]; then
        virtiofsd_path=$(which virtiofsd 2>/dev/null || true)
        if [[ -z "$virtiofsd_path" ]]; then
            log_warn "virtiofsd not found. Shared directory may not work."
            return
        fi
    fi

    local socket_path="${STATE_DIR}/virtiofsd.sock"
    rm -f "$socket_path"

    log_info "Starting virtiofsd for ${SHARED_HOST_PATH}..."
    "$virtiofsd_path" \
        --socket-path="$socket_path" \
        --shared-dir="$SHARED_HOST_PATH" \
        --cache=auto \
        --log-level=info &
    local pid=$!
    echo "$pid" > "$VIRTIOFS_PID_FILE"
    sleep 1

    if ! kill -0 "$pid" 2>/dev/null; then
        log_warn "virtiofsd failed to start. Shared directory may not work."
        rm -f "$VIRTIOFS_PID_FILE"
    else
        log_info "virtiofsd started (PID: ${pid})."
    fi
}

stop_virtiofsd() {
    if [[ -f "$VIRTIOFS_PID_FILE" ]]; then
        local pid
        pid=$(cat "$VIRTIOFS_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            log_info "Stopped virtiofsd (PID: ${pid})."
        fi
        rm -f "$VIRTIOFS_PID_FILE"
    fi
}

define_wifi_network() {
    if [[ "$NETWORK_TYPE" != "wifi-bridge" ]]; then
        return
    fi
    if [[ -z "$WIFI_INTERFACE" ]]; then
        log_error "network.wifi_interface not set in config for wifi-bridge mode."
        exit 1
    fi
    if [[ ! -d "/sys/class/net/${WIFI_INTERFACE}" ]]; then
        log_error "WiFi interface '${WIFI_INTERFACE}' not found on host."
        exit 1
    fi

    local virsh_net_name="${VM_NAME}-wifi"

    if virsh net-info "$virsh_net_name" &>/dev/null; then
        local net_state
        net_state=$(virsh net-info "$virsh_net_name" 2>/dev/null | awk '/Active:/ {print $2}')
        if [[ "$net_state" != "yes" ]]; then
            virsh net-start "$virsh_net_name" 2>/dev/null || true
        fi
        log_info "Virsh network '${virsh_net_name}' already defined."
        return
    fi

    local bridge_name="virbr-${VM_NAME}"
    local subnet="${WIFI_NET_PREFIX}"
    local mac_addr
    mac_addr=$(printf '52:54:00:%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))

    local net_xml="${STATE_DIR}/${virsh_net_name}.xml"
    cat > "$net_xml" <<EOF
<network>
  <name>${virsh_net_name}</name>
  <forward dev='${WIFI_INTERFACE}' mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
    <interface dev='${WIFI_INTERFACE}'/>
  </forward>
  <bridge name='${bridge_name}' stp='on' delay='0'/>
  <mac address='${mac_addr}'/>
  <domain name='${virsh_net_name}'/>
  <ip address='${subnet}.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='${subnet}.128' end='${subnet}.254'/>
    </dhcp>
  </ip>
</network>
EOF

    virsh net-define "$net_xml"
    virsh net-start "$virsh_net_name"
    virsh net-autostart "$virsh_net_name"
    log_info "Virsh network '${virsh_net_name}' defined: NAT via ${WIFI_INTERFACE}, subnet ${subnet}.0/24"
}

undefine_wifi_network() {
    if [[ "$NETWORK_TYPE" != "wifi-bridge" ]]; then
        return
    fi

    local virsh_net_name="${VM_NAME}-wifi"

    if virsh net-info "$virsh_net_name" &>/dev/null; then
        virsh net-destroy "$virsh_net_name" 2>/dev/null || true
        virsh net-undefine "$virsh_net_name" 2>/dev/null || true
        log_info "Virsh network '${virsh_net_name}' removed."
    fi
}

cmd_create() {
    local wait_override=""
    local timeout_override=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-wait) wait_override="false"; shift ;;
            --wait)    wait_override="true"; shift ;;
            --timeout)
                if [[ $# -lt 2 ]]; then
                    log_error "--timeout requires a value in seconds."
                    exit 1
                fi
                timeout_override="$2"
                shift 2
                ;;
            --timeout=*) timeout_override="${1#*=}"; shift ;;
            -h|--help) usage; exit 0 ;;
            *)
                log_error "Unknown create option: $1"
                exit 1
                ;;
        esac
    done

    ensure_state_dir
    load_config

    if [[ -n "$wait_override" ]]; then
        PROVISIONING_WAIT="$wait_override"
    fi
    if [[ -n "$timeout_override" ]]; then
        PROVISIONING_TIMEOUT="$timeout_override"
    fi
    if ! [[ "$PROVISIONING_TIMEOUT" =~ ^[0-9]+$ ]] || (( PROVISIONING_TIMEOUT <= 0 )); then
        log_warn "Invalid provisioning timeout '${PROVISIONING_TIMEOUT}' — using 1800 seconds."
        PROVISIONING_TIMEOUT=1800
    fi

    detect_kvm
    detect_qemu_machine
    detect_ovmf
    detect_local_network
    generate_ssh_key
    download_cloud_image
    create_disk_overlay
    generate_cloud_init
    generate_domain_xml

    if virsh dominfo "$VM_NAME" &>/dev/null; then
        log_warn "Domain '${VM_NAME}' already defined. Destroying and redefining..."
        virsh destroy "$VM_NAME" 2>/dev/null || true
        virsh undefine "$VM_NAME" --nvram 2>/dev/null || true
    fi

    log_info "Defining domain '${VM_NAME}'..."
    virsh define "$DOMAIN_XML"

    define_wifi_network
    ensure_forwarding
    start_virtiofsd

    log_info "Starting VM '${VM_NAME}'..."
    virsh start "$VM_NAME"

    log_info "Waiting for VM to get an IP address..."
    local vm_ip
    if vm_ip=$(get_vm_ip); then
        log_info "VM IP: ${vm_ip}"
        apply_port_forwards "$vm_ip"
    else
        log_warn "Could not determine VM IP. Port forwarding skipped."
        log_warn "Try 'vm.sh status' later to get the IP, then restart to apply forwards."
    fi

    if [[ "$PROVISIONING_WAIT" != "true" ]]; then
        log_warn "Provisioning wait disabled; guest dependencies may still be installing."
        log_info "Monitor with: ./vm.sh status"
        log_info "Guest log:    /var/log/cloud-init-output.log (via ./vm.sh ssh)"
    elif [[ -z "$vm_ip" ]]; then
        log_warn "No VM IP available — cannot wait for provisioning."
    else
        log_info "Waiting for guest provisioning to finish (timeout: $(format_elapsed "$PROVISIONING_TIMEOUT"))..."
        local prov_rc=0
        local provisioning_ok=false
        wait_for_provisioning "$vm_ip" || prov_rc=$?
        case "$prov_rc" in
            0)
                provisioning_ok=true
                if [[ -n "${PROVISIONED_IP:-}" && "${PROVISIONED_IP}" != "$vm_ip" ]]; then
                    log_info "VM IP changed after the provisioning reboot (${vm_ip} -> ${PROVISIONED_IP}); re-applying port forwards..."
                    remove_port_forwards
                    apply_port_forwards "$PROVISIONED_IP"
                    vm_ip="$PROVISIONED_IP"
                fi
                ;;
            2)
                provisioning_ok=true
                ;;
            3)
                log_warn "The VM is running, but provisioning did not finish cleanly."
                log_warn "Check ./vm.sh status and the guest's /var/log/cloud-init-output.log."
                ;;
            *)
                log_warn "The VM is running, but provisioning is still in progress."
                log_warn "Check progress with: ./vm.sh status"
                log_warn "Guest log: /var/log/cloud-init-output.log"
                ;;
        esac

        if [[ "$PERSIST_ENABLED" == "true" && -f "${PERSIST_HOST_PATH}/manifest.json" ]]; then
            if [[ "$provisioning_ok" == "true" ]]; then
                persist_push_to_guest "$vm_ip" || log_warn "Agent state restore failed; retry with './vm.sh restore-agent <archive>'."
            else
                log_info "Agent state restore deferred until provisioning completes; it will apply on the next 'vm.sh start'."
            fi
        fi
    fi

    echo ""
    log_info "VM '${VM_NAME}' created and started."
    log_info "SSH: ssh -i ${SSH_KEY} ubuntu@localhost -p 2222"
    log_info "     (or use: ./vm.sh ssh)"
}

cmd_start() {
    ensure_state_dir
    load_config

    if ! virsh dominfo "$VM_NAME" &>/dev/null; then
        log_error "Domain '${VM_NAME}' not defined. Run 'vm.sh create' first."
        exit 1
    fi

    local state
    state=$(virsh domstate "$VM_NAME" 2>/dev/null)
    if [[ "$state" == "running" ]]; then
        log_info "VM '${VM_NAME}' is already running."
        return
    fi

    start_virtiofsd
    define_wifi_network
    ensure_forwarding
    virsh start "$VM_NAME"
    log_info "VM '${VM_NAME}' started."

    log_info "Waiting for IP..."
    local vm_ip
    if vm_ip=$(get_vm_ip); then
        log_info "VM IP: ${vm_ip}"
        apply_port_forwards "$vm_ip"
    else
        log_warn "Could not determine VM IP."
    fi

    if [[ "$PERSIST_ENABLED" == "true" && -n "$vm_ip" && -f "${PERSIST_HOST_PATH}/manifest.json" ]]; then
        if wait_for_guest_ssh "$vm_ip" 120; then
            persist_push_to_guest "$vm_ip" || log_warn "Could not restore agent state."
        else
            log_warn "SSH is not ready; agent state restore skipped (it will apply on the next start)."
        fi
    fi
}

cmd_stop() {
    load_config

    local state
    state=$(virsh domstate "$VM_NAME" 2>/dev/null || echo "undefined")
    if [[ "$state" != "running" ]]; then
        log_info "VM '${VM_NAME}' is not running."
        return
    fi

    log_info "Shutting down VM '${VM_NAME}'..."

    if [[ "$PERSIST_ENABLED" == "true" ]]; then
        local vm_ip=""
        vm_ip=$(get_vm_ip 1 2>/dev/null || true)
        if [[ -n "$vm_ip" ]] && wait_for_guest_ssh "$vm_ip" 30; then
            persist_sync_from_guest "$vm_ip" || log_warn "Could not sync agent state before shutdown."
        else
            log_warn "Guest is not reachable; skipping agent state sync."
        fi
    fi

    virsh shutdown "$VM_NAME"

    local timeout=60
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        state=$(virsh domstate "$VM_NAME" 2>/dev/null || echo "undefined")
        if [[ "$state" != "running" ]]; then
            break
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    if [[ "$state" == "running" ]]; then
        log_warn "Graceful shutdown timed out. Forcing destroy..."
        virsh destroy "$VM_NAME"
    fi

    remove_port_forwards
    stop_virtiofsd
    undefine_wifi_network
    log_info "VM '${VM_NAME}' stopped."
}

cmd_destroy() {
    load_config

    if [[ "$PERSIST_ENABLED" == "true" ]]; then
        local vm_state
        vm_state=$(virsh domstate "$VM_NAME" 2>/dev/null || echo "undefined")
        if [[ "$vm_state" == "running" ]]; then
            local vm_ip=""
            vm_ip=$(get_vm_ip 1 2>/dev/null || true)
            if [[ -n "$vm_ip" ]] && wait_for_guest_ssh "$vm_ip" 30; then
                persist_sync_from_guest "$vm_ip" || log_warn "Could not sync agent state before destroy; the existing host backup is unchanged."
            else
                log_warn "Guest is not reachable; skipping agent state sync."
            fi
        fi
    fi

    log_info "Destroying VM '${VM_NAME}'..."
    virsh destroy "$VM_NAME" 2>/dev/null || true
    virsh undefine "$VM_NAME" --nvram --remove-all-storage 2>/dev/null || true

    remove_port_forwards
    stop_virtiofsd
    undefine_wifi_network

    if [[ -f "$DISK_PATH" ]]; then
        rm -f "$DISK_PATH"
        log_info "Removed disk: ${DISK_PATH}"
    fi

    if [[ -f "$SEED_ISO" ]]; then
        rm -f "$SEED_ISO" 2>/dev/null || sudo rm -f "$SEED_ISO"
        log_info "Removed seed ISO: ${SEED_ISO}"
    fi

    rm -rf "$STATE_DIR"
    log_info "VM '${VM_NAME}' destroyed and cleaned up."
}

cmd_ssh() {
    load_config

    if [[ ! -f "$SSH_KEY" ]]; then
        log_error "SSH key not found: ${SSH_KEY}"
        log_error "Run 'vm.sh create' first."
        exit 1
    fi

    local state
    state=$(virsh domstate "$VM_NAME" 2>/dev/null || echo "undefined")
    if [[ "$state" != "running" ]]; then
        log_error "VM '${VM_NAME}' is not running (state: ${state})."
        log_error "Run 'vm.sh start' first."
        exit 1
    fi

    local vm_ip
    vm_ip=$(get_vm_ip 2>/dev/null) || true

    if [[ -n "$vm_ip" ]]; then
        local prov_rc=0 prov_step=""
        local VM_SSH_CONNECT_TIMEOUT=3
        prov_step=$(provisioning_state "$vm_ip" 2>/dev/null) || prov_rc=$?
        if [[ "$prov_rc" -eq 10 ]]; then
            log_warn "Guest provisioning is still running${prov_step:+ (${prov_step#>>> })}; packages may be missing."
            log_warn "Check progress with: ./vm.sh status"
            log_warn "Guest log: /var/log/cloud-init-output.log"
        fi

        log_info "SSH into ${VM_NAME} (${vm_ip})..."
        exec ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "ubuntu@${vm_ip}" "$@"
    else
        log_info "IP not found via DHCP leases, trying localhost:2222..."
        exec ssh -i "$SSH_KEY" -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@localhost "$@"
    fi
}

cmd_backup_agent() {
    load_config

    local archive="${1:-}"
    if [[ -z "$archive" ]]; then
        archive="opencode-agent-${VM_NAME}-$(date +%Y%m%d%H%M%S).tar.gz"
    fi

    local state
    state=$(virsh domstate "$VM_NAME" 2>/dev/null || echo "undefined")
    if [[ "$state" == "running" ]]; then
        local vm_ip
        vm_ip=$(get_vm_ip 2>/dev/null) || true
        if [[ -z "$vm_ip" ]]; then
            log_error "VM '${VM_NAME}' is running but has no IP; cannot sync agent state."
            exit 1
        fi
        if ! wait_for_guest_ssh "$vm_ip" 30; then
            log_error "VM '${VM_NAME}' is running but SSH is not reachable; cannot sync agent state."
            exit 1
        fi
        log_info "Syncing agent state from ${VM_NAME}..."
        if ! persist_sync_from_guest "$vm_ip"; then
            log_error "Backup cancelled: could not sync agent state from the VM."
            exit 1
        fi
    elif [[ -f "${PERSIST_HOST_PATH}/manifest.json" ]]; then
        log_info "VM '${VM_NAME}' is not running; using ${PERSIST_HOST_PATH}."
    else
        log_error "VM '${VM_NAME}' is not running and no host persistence exists at ${PERSIST_HOST_PATH}."
        exit 1
    fi

    persist_create_archive "$archive" || exit 1
    log_info "Agent backup: ${archive} ($(du -h "$archive" | cut -f1))"
    log_warn "This archive contains credentials and session data. Keep it mode 0600 and do not commit or upload it."
}

cmd_restore_agent() {
    local archive=""
    local force="false"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force="true"; shift ;;
            -h|--help) usage; exit 0 ;;
            *) archive="$1"; shift ;;
        esac
    done

    if [[ -z "$archive" ]]; then
        log_error "Usage: vm.sh restore-agent <archive.tar.gz> [--force]"
        exit 1
    fi

    load_config
    persist_install_archive "$archive" "$force" || exit 1

    local state
    state=$(virsh domstate "$VM_NAME" 2>/dev/null || echo "undefined")
    if [[ "$state" == "running" ]]; then
        local vm_ip=""
        vm_ip=$(get_vm_ip 2>/dev/null || true)
        if [[ -n "$vm_ip" ]] && wait_for_guest_ssh "$vm_ip" 60; then
            persist_push_to_guest "$vm_ip" || exit 1
        else
            log_warn "VM is running but SSH is not ready; state will be pushed on the next start."
        fi
    else
        log_info "VM is not running; the restored state will be applied on the next 'vm.sh create' or 'vm.sh start'."
    fi

    log_info "Restore complete."
}

cmd_install_lancedb() {
    load_config

    if [[ ! -f "$SSH_KEY" ]]; then
        log_error "SSH key not found: ${SSH_KEY}"
        log_error "Run 'vm.sh create' first."
        exit 1
    fi

    local state
    state=$(virsh domstate "$VM_NAME" 2>/dev/null || echo "undefined")
    if [[ "$state" != "running" ]]; then
        log_error "VM '${VM_NAME}' is not running (state: ${state})."
        log_error "Run 'vm.sh start' first."
        exit 1
    fi

    local installer="${SCRIPT_DIR}/scripts/install-lancedb.sh"
    if [[ ! -f "$installer" ]]; then
        log_error "Installer script not found: ${installer}"
        exit 1
    fi

    local vm_ip
    vm_ip=$(get_vm_ip 2>/dev/null) || true

    log_info "Installing LanceDB + opencode-indexing in ${VM_NAME}..."
    if [[ -n "$vm_ip" ]]; then
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "ubuntu@${vm_ip}" 'bash -s' < "$installer"
    else
        log_warn "IP not found via DHCP leases, trying localhost:2222..."
        ssh -i "$SSH_KEY" -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@localhost 'bash -s' < "$installer"
    fi

    log_info "LanceDB + opencode-indexing installed in ${VM_NAME}."
}

cmd_status() {
    load_config
    detect_kvm
    detect_qemu_machine

    echo "=== VM Status: ${VM_NAME} ==="
    echo ""

    if ! virsh dominfo "$VM_NAME" &>/dev/null; then
        echo "  State:      not defined"
        echo ""
        echo "Run 'vm.sh create' to create the VM."
        return
    fi

    local state
    state=$(virsh domstate "$VM_NAME" 2>/dev/null)
    echo "  State:      ${state}"
    echo "  vCPUs:      ${VCPUS}"
    echo "  Memory:     ${MEMORY_MB} MB"
    echo "  Disk:       ${DISK_PATH}"

    if [[ -f "$DISK_PATH" ]]; then
        local disk_size
        disk_size=$(qemu-img info "$DISK_PATH" 2>/dev/null | grep 'virtual size' | grep -oP '[0-9.]+[A-Za-z]+' || echo "unknown")
        local disk_actual
        disk_actual=$(du -h "$DISK_PATH" 2>/dev/null | cut -f1 || echo "unknown")
        echo "  Disk Size:  ${disk_size} (actual: ${disk_actual})"
    fi

    echo ""
    if [[ "$state" == "running" ]]; then
        local vm_ip
        vm_ip=$(get_vm_ip 2>/dev/null) || true
        if [[ -n "$vm_ip" ]]; then
            echo "  IP Address: ${vm_ip}"
        else
            echo "  IP Address: (waiting for DHCP...)"
        fi

        if [[ -n "$vm_ip" ]]; then
            local prov_rc=0 prov_state=""
            local VM_SSH_CONNECT_TIMEOUT=3
            prov_state=$(provisioning_state "$vm_ip" 2>/dev/null) || prov_rc=$?
            case "$prov_rc" in
                0)
                    if [[ "$prov_state" == "READY-LEGACY" ]]; then
                        echo "  Provisioning: complete (legacy VM, no marker file)"
                    else
                        echo "  Provisioning: complete"
                    fi
                    ;;
                10)
                    echo "  Provisioning: in progress${prov_state:+ (${prov_state#>>> })}"
                    ;;
                11)
                    echo "  Provisioning: unknown (cloud-init not available)"
                    ;;
                12)
                    echo "  Provisioning: error (see /var/log/cloud-init-output.log)"
                    ;;
                *)
                    echo "  Provisioning: starting (SSH not ready)"
                    ;;
            esac
        else
            echo "  Provisioning: starting (no IP yet)"
        fi

        echo ""
        echo "  Port Forwards:"
        local num_forwards
        num_forwards=$(jq '.port_forwards | length' "$CONFIG_FILE")
        for ((i = 0; i < num_forwards; i++)); do
            local hp gp pr
            hp=$(jq -r ".port_forwards[$i].host" "$CONFIG_FILE")
            gp=$(jq -r ".port_forwards[$i].guest" "$CONFIG_FILE")
            pr=$(jq -r ".port_forwards[$i].protocol // \"tcp\"" "$CONFIG_FILE")
            echo "    ${hp} -> ${gp} (${pr})"
        done

        echo ""
        echo "  KVM:        ${KVM_AVAILABLE:-unknown}"
        echo "  Machine:    ${MACHINE_TYPE:-unknown}"
    fi
    echo ""
}

cmd_export() {
    load_config

    local export_name="${VM_NAME}-export-$(date +%Y%m%d%H%M%S).tar.gz"
    local export_dir
    export_dir=$(mktemp -d)

    log_info "Exporting VM '${VM_NAME}' to ${export_name}..."

    local state
    state=$(virsh domstate "$VM_NAME" 2>/dev/null || echo "undefined")
    if [[ "$state" == "running" ]]; then
        log_warn "VM is running. It's recommended to stop it before exporting."
        read -rp "Continue anyway? [y/N] " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            log_info "Export cancelled."
            return
        fi
    fi

    virsh dumpxml "$VM_NAME" > "${export_dir}/domain.xml" 2>/dev/null || true
    cp "$CONFIG_FILE" "${export_dir}/config.json"

    if [[ -f "$DISK_PATH" ]]; then
        log_info "Copying disk image (this may take a while)..."
        cp "$DISK_PATH" "${export_dir}/$(basename "$DISK_PATH")"
    fi

    if [[ -d "$KEYS_DIR" ]]; then
        cp -r "$KEYS_DIR" "${export_dir}/keys"
    fi

    tar czf "$export_name" -C "$export_dir" .
    rm -rf "$export_dir"

    log_info "Export complete: ${export_name}"
}

cmd_import() {
    local tarball="$1"
    if [[ -z "$tarball" ]] || [[ ! -f "$tarball" ]]; then
        log_error "Usage: vm.sh import <tarball.tar.gz>"
        exit 1
    fi

    ensure_state_dir
    local import_dir
    import_dir=$(mktemp -d)

    log_info "Importing VM from ${tarball}..."
    tar xzf "$tarball" -C "$import_dir"

    if [[ -f "${import_dir}/config.json" ]]; then
        cp "${import_dir}/config.json" "$CONFIG_FILE"
        log_info "Restored config.json."
    fi

    load_config

    if [[ -f "${import_dir}/domain.xml" ]]; then
        cp "${import_dir}/domain.xml" "$DOMAIN_XML"
    fi

    local disk_name
    disk_name=$(basename "$DISK_PATH")
    if [[ -f "${import_dir}/${disk_name}" ]]; then
        local disk_dir
        disk_dir=$(dirname "$DISK_PATH")
        mkdir -p "$disk_dir"
        cp "${import_dir}/${disk_name}" "$DISK_PATH"
        log_info "Restored disk image: ${DISK_PATH}"
    fi

    if [[ -d "${import_dir}/keys" ]]; then
        mkdir -p "$KEYS_DIR"
        cp -r "${import_dir}/keys/"* "$KEYS_DIR/"
        log_info "Restored SSH keys."
    fi

    rm -rf "$import_dir"

    if [[ -f "$DOMAIN_XML" ]]; then
        if virsh dominfo "$VM_NAME" &>/dev/null; then
            virsh destroy "$VM_NAME" 2>/dev/null || true
            virsh undefine "$VM_NAME" --nvram 2>/dev/null || true
        fi
        virsh define "$DOMAIN_XML"
        log_info "Domain '${VM_NAME}' defined."
    fi

    log_info "Import complete. Run 'vm.sh start' to start the VM."
}

cmd_list_ports() {
    load_config

    echo "=== Port Forwards for ${VM_NAME} ==="
    echo ""
    local num_forwards
    num_forwards=$(jq '.port_forwards | length' "$CONFIG_FILE")
    if [[ "$num_forwards" -eq 0 ]]; then
        echo "  (none configured)"
    else
        printf "  %-8s %-8s %-10s\n" "HOST" "GUEST" "PROTOCOL"
        printf "  %-8s %-8s %-10s\n" "------" "------" "--------"
        for ((i = 0; i < num_forwards; i++)); do
            local hp gp pr
            hp=$(jq -r ".port_forwards[$i].host" "$CONFIG_FILE")
            gp=$(jq -r ".port_forwards[$i].guest" "$CONFIG_FILE")
            pr=$(jq -r ".port_forwards[$i].protocol // \"tcp\"" "$CONFIG_FILE")
            printf "  %-8s %-8s %-10s\n" "$hp" "$gp" "$pr"
        done
    fi
    echo ""
}

usage() {
    echo "Usage: $(basename "$0") <command>"
    echo ""
    echo "Commands:"
    echo "  create [--no-wait] [--timeout <sec>]"
    echo "              Download cloud image, create VM, start it, and wait for provisioning"
    echo "              (--no-wait returns after boot; --timeout overrides the config value)"
    echo "  start       Start an existing stopped VM"
    echo "  stop        Graceful ACPI shutdown"
    echo "  destroy     Force stop, undefine, and delete disk images"
    echo "  ssh         SSH into the VM"
    echo "  backup-agent [archive]   Sync guest agent state and write a portable archive"
    echo "  restore-agent <archive> [--force]"
    echo "              Restore agent state into the host persistence directory and the VM"
    echo "  install-lancedb  Install LanceDB + opencode-indexing plugin in the VM"
    echo "  status      Show VM state, IP, resource usage"
    echo "  export      Package VM into a portable tarball"
    echo "  import <f>  Import a VM from a tarball"
    echo "  list-ports  Show configured port forwarding rules"
    echo ""
}

main() {
    local command="${1:-}"
    shift || true

    case "$command" in
        create)     cmd_create "$@" ;;
        start)      cmd_start ;;
        stop)       cmd_stop ;;
        destroy)    cmd_destroy ;;
        ssh)        cmd_ssh "$@" ;;
        backup-agent) cmd_backup_agent "$@" ;;
        restore-agent) cmd_restore_agent "$@" ;;
        install-lancedb) cmd_install_lancedb ;;
        status)     cmd_status ;;
        export)     cmd_export ;;
        import)     cmd_import "${1:-}" ;;
        list-ports) cmd_list_ports ;;
        help|-h|--help) usage ;;
        *)
            if [[ -n "$command" ]]; then
                log_error "Unknown command: ${command}"
            fi
            usage
            exit 1
            ;;
    esac
}

main "$@"
