# 004 — Run VM lifecycle e2e inside the guest

- **Status:** done
- **Phase:** P1
- **Priority:** high
- **Depends on:** 001, 002, 003

## Goal

Make the `ai-vm` guest able to act as a libvirt host so `vm.sh create`/`destroy`
and provisioning e2e checks can run inside the VM (nested virtualization)
instead of on the host. Put the dependencies in the project configs, provide an
idempotent installer for existing VMs, and enable nested KVM on the host
best-effort.

## Acceptance criteria

- [x] Add guest packages to `cloud-init/user-data`: `qemu-system-x86`,
      `qemu-utils`, `libvirt-daemon-system`, `libvirt-clients`, `dnsmasq-base`,
      `cloud-image-utils`, `genisoimage`, `ovmf`, `jq`, `iptables`,
      `cpu-checker`, `apt-cacher-ng`.
- [x] cloud-init enables `libvirtd` and the default network, adds `ubuntu` to
      the `libvirt`/`kvm` groups, and warns when `vmx`/`svm` is not exposed.
- [x] Add `scripts/install-e2e-deps.sh`: idempotent guest-side installer with
      progress output and clear errors.
- [x] Add `vm.sh install-e2e-deps` for existing VMs, mirroring
      `install-lancedb` (running check, SSH key check, help text, dispatch).
- [x] Enable nested KVM in `playbooks/setup.yml` best-effort for Intel/AMD
      without disrupting running guests (module reload is skipped when busy).
- [x] Document the nested e2e workflow in `README.md`, including memory/disk
      guidance and the `kvm` group reconnect requirement.
- [x] `bash -n vm.sh setup.sh scripts/*.sh` passes.
- [x] Cache the cloud image in a `cache_dir` that survives `destroy`, and let
      nested VMs use the guest's `apt-cacher-ng` (`apt_proxy: auto`).
- [x] No secrets, keys, or generated artifacts committed.

## Test cases

- [x] [unit] `bash -n vm.sh setup.sh scripts/*.sh` reports no syntax errors.
- [x] [unit] `./vm.sh help` lists `install-e2e-deps`; a stopped/undefined VM
      fails with a clear message.
- [x] [unit] `ansible-playbook --syntax-check playbooks/setup.yml` passes.
- [x] [unit] Rendered cloud-init parses with the apt proxy enabled and disabled.
- [x] [e2e] A second nested `create` after `destroy` reuses the cached cloud image
      and serves apt packages from `apt-cacher-ng` (no re-download). Verified:
      recreate logged `Using cached cloud image`, and `apt-get update` in the new
      VM finished in 12 s with **0 KiB** of cache growth.
- [x] [e2e] Inside the guest, `./vm.sh install-e2e-deps` installs the packages,
      and `virsh --version`, `qemu-img --version`, and `cloud-localds --help`
      work. Verified with a second (idempotent) run: exit 0, apt-cacher-ng
      enabled and active, `virsh 10.0.0`, `qemu-img 8.2.2`.
- [x] [e2e] Inside the guest, create a small nested VM, SSH into it, and destroy
      it, leaving no domain or disk behind. Verified over several
      create/ssh/destroy cycles; the final `destroy` left no domain, disk, or
      seed ISO, and both caches stayed.

## Notes

- The Ubuntu `libvirt-daemon-system` postinst already avoids the nested subnet
  clash (`maybe_set_autostart`): if `192.168.122.0/24` is in use, it rewrites
  the default network to a free `192.168.123-128.0/24`. No custom network XML
  is needed.
- `/dev/kvm` inside the guest requires nested virtualization on the host
  (`kvm_intel.nested=1` or `kvm_amd.nested=1`) and a CPU mode that exposes
  `vmx`/`svm`; `vm.sh` already uses `host-passthrough` when `/dev/kvm` is
  writable.
- Group changes do not affect the current SSH session. Reconnect, or run the
  nested command through `sg kvm -c '...'`, after installing the deps.
- Use a guest-local directory (e.g. `/tmp/ai-korobok-e2e`) for the project copy
  and nested disk rather than the virtiofs mount, and size the nested VM for
  the guest's free memory (e.g. 2 vCPU / 2 GB).
- Adding packages to cloud-init only affects newly created VMs; existing VMs use
  `./vm.sh install-e2e-deps`.
- The cloud image is cached in `cache_dir` (default `<disk dir>/cache`) and is not
  removed by `destroy`, so a recreate downloads it at most once. New VMs also
  inherit the guest's `apt-cacher-ng` automatically (`apt_proxy: auto`), so apt
  packages are served from the guest cache instead of being fetched again.
  `apt_mirror` can point VMs at a different archive when the default CDN is
  unreachable.

## Implementation notes

- Guest packages are in `cloud-init/user-data` and mirrored in
  `scripts/install-e2e-deps.sh`; the installer enables `libvirtd`, ensures the
  default network is active, and adds `ubuntu` to `libvirt`/`kvm`.
- Ubuntu's `libvirt-daemon-system` postinst already handles the nested subnet
  clash: `maybe_set_autostart` picks a free `192.168.123-128.0/24` when
  `192.168.122.0/24` is taken, so no custom network XML is required.
- The cloud-init shared-directory block is now conditional; configs without
  `shared_dir` no longer write an empty `virtiofs` fstab line or run `mkdir -p`
  with no operand.
- The playbook writes `/etc/modprobe.d/kvm-nested.conf` and reloads the module
  only when it is not busy; otherwise the setting applies on the next boot.
- This agent environment is itself an `ai-vm`: it has `/dev/kvm`, `vmx` is
  exposed (`kvm_intel.nested=Y`), and the guest address is `192.168.124.3/24`
  (no clash with the nested default `192.168.122.0/24`).
- Package names were validated with `apt-get -s install ...`; `bash -n` and the
  playbook syntax check pass. The CLI success path was stub-tested (SSH receives
  the installer and targets the guest IP) and a stopped/undefined VM fails with
  a clear message.
- The `[e2e]` items were exercised against a throwaway `ai-vm-e2e` in this
  environment: the guest installer ran (twice, idempotent), nested `create`
  reached full provisioning (cloud-init `done`), SSH worked, and repeated
  create/destroy cycles reused the image and apt cache while leaving no domain
  or disk behind. The nested copy under `/home/ubuntu/ai-korobok-e2e` has no
  `.state/` left.
- This sandbox intermittently drops HTTP requests to Canonical's archive; the
  installer tolerates that (`apt-get update` prints warnings and uses existing
  lists). When the archive was unreachable, a nested VM was temporarily pointed
  at `azure.archive.ubuntu.com` via `apt_mirror` to finish provisioning. This is
  environmental, not a project requirement.
- The existing-VM installer uses `--no-install-recommends` (37 packages); the
  cloud-init `packages:` module uses apt recommends (191 packages, including the
  QEMU GUI/SPICE extras). Both install the same required commands.
- Running the e2e for real surfaced several nested-only bugs, now fixed:
  `dnsmasq-base` was only a Recommends, so the default NAT network would not
  start until it was added to both package lists; libvirt 10 rejects
  `<cpu mode='max'>`, so the TCG fallback uses `maximum`; non-root `iptables`
  calls aborted `create` (FORWARD policy DROP), so forwarding now goes through a
  `priv()` helper that uses `sudo -n` when not root; the IP wait window was too
  short for a nested boot (30 → 90 attempts); the SSH hint now reads the first
  `guest == 22` forward instead of hardcoding `-p 2222`; `destroy` removes the
  libvirt-chowned disk/state with the same sudo fallback.
- The first real nested provision also showed apt's HTTPS repos failing through
  `apt-cacher-ng` (`403 CONNECT denied`), so cloud-init now sets
  `Acquire::https::Proxy "DIRECT"` and only HTTP archive traffic is cached.
- Typical nested timings on this host (2 vCPU / 2 GB, TCG-free): first
  `create` including image download and full provisioning ~19 min; a recreate
  with the cached image ~12.5 min. The long tail is cloud-init's
  `package_upgrade`, reboot, and the Node/Docker/LanceDB installs, not image
  fetching.
- Audit fix: the installer now captures `virsh net-info default` into a variable
  before grepping for `Active: yes` instead of piping it into `grep -q`; under
  `set -o pipefail` the pipe can SIGPIPE `virsh` (exit 141) and falsely report
  the network as inactive, making `virsh net-start` fail with "already active"
  on re-runs. The final summary line also drops the `qemu-img --version | head`
  pipe for the same reason. The installer file is now executable (100755),
  matching `install-lancedb.sh`.
