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
    LOCAL_NETWORK=""
    WIFI_NET_PREFIX="192.168.100"
    WIFI_GATEWAY="${WIFI_NET_PREFIX}.1"

    KEYS_DIR="${SCRIPT_DIR}/keys"
    SSH_KEY="${KEYS_DIR}/${VM_NAME}"
    SEED_ISO="${STATE_DIR}/${VM_NAME}-seed.iso"
    OVERLAY_PATH="${DISK_PATH}"
    BASE_IMAGE="${STATE_DIR}/ubuntu-24.04-server-cloudimg-amd64.img"
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

    cp "$meta_data_template" "$meta_data_out"

    rm -f "$SEED_ISO"
    cloud-localds "$SEED_ISO" "$user_data_out" "$meta_data_out"
    log_info "Cloud-init seed ISO created: ${SEED_ISO}"
}

download_cloud_image() {
    if [[ -f "$BASE_IMAGE" ]]; then
        log_info "Using cached cloud image: ${BASE_IMAGE}"
        return
    fi
    local url="https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
    log_info "Downloading Ubuntu 24.04 cloud image..."
    log_info "URL: ${url}"
    wget -q --show-progress -O "$BASE_IMAGE" "$url"
    log_info "Cloud image downloaded: ${BASE_IMAGE}"
}

create_disk_overlay() {
    if [[ -f "$DISK_PATH" ]]; then
        log_info "Disk image already exists: ${DISK_PATH}"
        return
    fi
    local disk_dir
    disk_dir=$(dirname "$DISK_PATH")
    if [[ ! -d "$disk_dir" ]]; then
        sudo mkdir -p "$disk_dir"
    fi
    log_info "Creating qcow2 overlay (${DISK_GB}GB)..."
    qemu-img create -f qcow2 -b "$BASE_IMAGE" -F qcow2 "$DISK_PATH" "${DISK_GB}G"
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
    local ip=""
    for i in $(seq 1 30); do
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

check_port_available() {
    local port="$1"
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        return 1
    fi
    return 0
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
    ensure_state_dir
    load_config
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
        log_info "SSH into ${VM_NAME} (${vm_ip})..."
        exec ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "ubuntu@${vm_ip}" "$@"
    else
        log_info "IP not found via DHCP leases, trying localhost:2222..."
        exec ssh -i "$SSH_KEY" -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@localhost "$@"
    fi
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
    echo "  create      Download cloud image, create VM, and start it"
    echo "  start       Start an existing stopped VM"
    echo "  stop        Graceful ACPI shutdown"
    echo "  destroy     Force stop, undefine, and delete disk images"
    echo "  ssh         SSH into the VM"
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
        create)     cmd_create ;;
        start)      cmd_start ;;
        stop)       cmd_stop ;;
        destroy)    cmd_destroy ;;
        ssh)        cmd_ssh "$@" ;;
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
