# macOS Support

`setup.sh` detects macOS and installs host dependencies with Homebrew instead of the
Linux Ansible playbook. macOS has no KVM, so QEMU uses the Hypervisor framework (HVF)
for acceleration.

## Install Host Dependencies

```bash
# Homebrew is installed automatically if missing
./setup.sh
```

`setup.sh` installs `qemu`, `libvirt`, `cdrtools`, `jq`, `wget`, and `openssl@3`, then
starts the `libvirt` service.

The manual equivalent:

```bash
brew install qemu libvirt cdrtools jq wget openssl@3
brew services start libvirt
```

## Limitations

This covers dependency installation. The VM lifecycle commands in `vm.sh` are still
Linux-first and are not yet fully ported to macOS, so expect to adjust firmware paths,
ISO tooling, and networking manually. In particular:

- **Acceleration**: KVM is Linux-only; macOS falls back to HVF.
- **Shared directory**: `virtiofsd` only runs on Linux, so `shared_dir` is unsupported.
- **Port forwarding**: the `iptables` rules are Linux-only; automatic host→guest port
  forwards are not applied on macOS.
- **Provisioning**: `cloud-localds` is not packaged for Homebrew; the `mkisofs` binary
  from `cdrtools` can be used to build the cloud-init seed ISO manually.