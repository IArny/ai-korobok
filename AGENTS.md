# AGENTS.md

## Project

`ai-korobok` — a CLI tool that provisions and manages a QEMU/libvirt VM preloaded
with Python, Node.js, and Docker for AI agents and MCP servers. All project code lives
in this directory; the repo root above it is empty scaffolding. Run every command from
this directory (`ai-vm-manager/`); the scripts resolve paths via `SCRIPT_DIR`, so they
also work when invoked by absolute path from elsewhere.

There is no compiled artifact. It is a collection of Bash scripts, an Ansible playbook,
and cloud-init templates.

## Layout

```
/
├── vm.sh                  # Main CLI: create/start/stop/destroy/ssh/status/export/import/list-ports
├── setup.sh               # Host dependency installer; thin wrapper around the Ansible playbook
├── playbooks/setup.yml    # Installs QEMU/libvirt + host tools (Debian/Ubuntu and Fedora)
├── docs/macos.md          # macOS setup notes (Homebrew path) and limitations
├── docs/windows.md        # Windows setup notes (WSL2 path) and limitations
├── scripts/install-lancedb.sh  # Guest-side installer for LanceDB + opencode-indexing (run via `vm.sh install-lancedb`)
├── cloud-init/user-data   # Guest packages and provisioning (runs once, first boot)
├── cloud-init/meta-data   # Cloud-init meta-data
├── templates/domain.xml   # Reference libvirt domain XML (vm.sh generates its own)
├── config.example.json    # Copy to config.json before use
├── config.json            # Local config; gitignored
├── keys/                  # Auto-generated SSH keypairs; gitignored
├── .state/                # Runtime state: seed ISO, domain XML, pid/socket, image cache; gitignored
├── .venv/                 # Ansible virtualenv created by setup.sh when needed; gitignored
├── .gitignore
├── AGENTS.md
└── README.md
```

## Commands

There is no build, test, or lint pipeline configured. `shellcheck` is not installed.
Do not invent one; if you add tooling, document it here.

Run/verify manually from this directory:

- `sudo ./setup.sh` — install host deps (Ansible wrapper)
- `./vm.sh create|start|stop|destroy|status|list-ports`
- `./vm.sh ssh`

Before committing shell changes, at minimum run `bash -n vm.sh setup.sh` to check syntax.

## Debugging the VM

Do not test lifecycle/destructive changes (`create`, `start`, `stop`, `destroy`,
`install-lancedb`, cloud-init edits) against the user's existing VM.

1. Copy the whole project into a throwaway directory (e.g.
   `/tmp/ai-korobok-debug`). `SCRIPT_DIR`-relative state (`.state/`, `keys/`, seed
   ISO, domain XML) stays inside that copy.
2. In the copied `config.json`, change at least:
   - `vm_name` → a debug name (e.g. `ai-vm-debug`)
   - `disk_path` → a separate image (e.g.
     `/var/lib/libvirt/images/ai-vm-debug.qcow2`)
   - `port_forwards` → non-conflicting host ports (the main VM owns
     2222/8080/3000/3001), so nothing collides with or overwrites the user's VM.
3. Run and debug the VM from that copied directory only, then destroy the debug VM
   and delete its disk/state when done.

### Long-running and heavy processes

- Run potentially slow or hanging operations (VM `create`, cloud-init, package
  installs, plugin installers) as background tasks (`nohup`/`setsid`) and poll the
  log instead of blocking the session.
- Before starting VMs or other memory-heavy processes, check available memory
  (`free -h`, `/proc/meminfo` `MemAvailable`) and size the debug VM to fit. Do not
  run an 8 GB debug VM alongside the 8 GB `ai-vm` on a 7.7 GB host.
- Use a unique `vm_name` and never destroy/start the user's `ai-vm` during debug
  runs; restore it to its prior state when done.

## Conventions

### Bash
- Every script starts with `#!/bin/bash` and `set -euo pipefail`.
- `vm.sh` parses config with `jq`; never parse JSON with `grep`/`sed`.
- Commands live in `cmd_*` functions and are dispatched in `main()` via `case`.
- Use the existing `log_info`/`log_warn`/`log_error`/`log_cmd` helpers; match their colors.
- Quote all variables. Dependencies are probed with `command -v`, `virsh dominfo`, etc.

### Host vs guest dependencies
- Host packages go in `playbooks/setup.yml` (`debian_packages` and `fedora_packages`
  vars) — remember both distros.
- Guest packages go in the `packages:` list in `cloud-init/user-data`.
- Guest Python packages go in the `pip3 install --break-system-packages` runcmd.
- Adding to `cloud-init/user-data` only affects newly created VMs; existing VMs must be
  recreated (`vm.sh destroy` + `vm.sh create`) or updated manually.

### Templates and secrets
- `cloud-init/user-data` uses `__PLACEHOLDER__` tokens substituted by `sed` in
  `generate_cloud_init()` in `vm.sh`. Keep `__SSH_PUBLIC_KEY__`, `__PASSWORD_HASH__`,
  `__MOUNT_POINT__`, and `__MOUNT_TAG__` intact.
- Never hardcode keys or passwords. `config.json`, `keys/`, `.state/`, disk images,
  ISOs, and export tarballs are gitignored — do not add them back or commit secrets.

## Git

- Do not commit unless explicitly asked.
- Keep messages in the existing terse, lowercase style (e.g. `add wifi bridge to access local network`).
- The working tree may contain local modifications (e.g. a rendered `cloud-init/user-data`);
  verify with `git status` before staging.