# Windows Support

Windows is supported through **WSL2** (Windows Subsystem for Linux). libvirt and QEMU
run inside the WSL2 Linux distribution, and `setup.sh` follows the normal Linux path
when it detects WSL. There is no native Windows CLI.

## Prerequisites

- Windows 10 (2004+) or Windows 11, with virtualization enabled in the BIOS/UEFI
- A WSL2 Linux distribution (Ubuntu recommended)
- 64-bit CPU with nested virtualization support for KVM acceleration

## Install WSL2

From PowerShell (Administrator):

```powershell
wsl --install -d Ubuntu
wsl --set-default-version 2
```

## Enable systemd (required)

The setup playbook uses systemd to enable and start `libvirtd`. Enable systemd inside
the distro by creating `/etc/wsl.conf`:

```ini
[boot]
systemd=true
```

Then restart WSL from PowerShell:

```powershell
wsl --shutdown
```

If systemd is not enabled, install still runs but `libvirtd` will not be started
automatically; `setup.sh` warns about this.

## Enable KVM acceleration (optional)

Without `/dev/kvm`, VMs fall back to TCG software emulation, which is much slower. To
expose KVM to WSL2, enable nested virtualization in `%UserProfile%\.wslconfig`:

```ini
[wsl2]
nestedVirtualization=true
```

Apply it from PowerShell:

```powershell
wsl --shutdown
```

Verify inside WSL with `ls -la /dev/kvm`. If the file is missing, finish the Windows
and WSL updates; older Windows builds do not support nested virtualization.

## Install and Run

Keep the project in the WSL Linux filesystem (for example `~/ai-vm-manager`), **not**
under `/mnt/c`, for correct file permissions and disk performance.

```bash
# Inside the WSL distro, from the project directory
sudo ./setup.sh

# Create your config
cp config.example.json config.json

# Create and start the VM
./vm.sh create
./vm.sh ssh
```

## Accessing VM Services from Windows

WSL2 enables `localhostForwarding` by default, so ports forwarded to the VM (for
example `localhost:2222` for SSH) are reachable from Windows as `localhost`:

```powershell
ssh -p 2222 ubuntu@localhost
```

SSH keys are generated inside the WSL filesystem under `keys/`; run `./vm.sh ssh` from
WSL, or copy the key out if you want to connect with a native Windows SSH client.

## Limitations

- **WSL2 only**: libvirt is not available on native Windows.
- **Nested virtualization**: KVM requires Windows/WSL support for nested
  virtualization; otherwise the VM runs under slow TCG emulation.
- **GPU passthrough**: PCI passthrough is not possible inside WSL2; leave
  `gpu_passthrough` set to `false`.
- **Filesystem**: build the VM disk and keep the project inside the WSL filesystem to
  avoid `/mnt/c` performance and permission issues.
- **Port forwarding**: the Linux `iptables` rules apply inside WSL; Windows reaches
  them via WSL2 localhost forwarding.