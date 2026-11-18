# 001 — Install LanceDB and opencode-indexing in VM

- **Status:** done
- **Phase:** P1
- **Priority:** medium
- **Depends on:** none

## Goal

Provide a repeatable way to install LanceDB (Python package `lancedb`) and the
`@javierkaiser/opencode-indexing` OpenCode plugin (which uses an embedded LanceDB
index) inside the guest VM, for both newly created VMs and existing running VMs.

## Acceptance criteria

- [x] Add `scripts/install-lancedb.sh` (guest-side installer) that:
  - [x] starts with `#!/bin/bash` and `set -euo pipefail`
  - [x] verifies `python3`/`pip3` are present (installing `python3-pip` if missing)
  - [x] installs `lancedb` (pulling `pyarrow` as needed) via
        `pip3 install --break-system-packages`
  - [x] is idempotent: re-running does not fail and does not duplicate work
  - [x] prints progress via the guest conventions used in `cloud-init/user-data`
  - [x] exits non-zero with a clear message on failure
- [x] Add a `./vm.sh install-lancedb` command implemented as a `cmd_*` function and
      dispatched in `main()`, which copies/runs the installer inside the guest via
      `./vm.sh ssh` without manual steps.
- [x] Add `lancedb` to the guest Python package install in `cloud-init/user-data`
      so freshly created VMs have it out of the box.
- [x] Install `@javierkaiser/opencode-indexing` in the guest:
  - [x] require Node.js >= 22.6 (already installed as Node 22 LTS)
  - [x] install OpenCode v2 (`@opencode/cli`) instead of v1 (`opencode-ai`); it
        provides `opencode plugin add` and satisfies the plugin's
        `@opencode/plugin >=2.2.7` peer dependency
  - [x] run `npx @javierkaiser/opencode-indexing --aio --no-restart` as the
        `ubuntu` user so it writes to `~/.config/opencode` and registers the
        plugin. The package's `isMain` check fails when npx runs it through the
        `.bin` symlink, so the script falls back to running `install.mjs`
        directly from a temporary npm install.
  - [x] verify it is idempotent and does not overwrite an existing `indexing.json`
  - [x] verify the plugin is registered (via `opencode plugin list` or the
        `opencode.json`/`tui.json` entry)
- [x] Run the plugin install from `./vm.sh install-lancedb` (or a sibling
      `./vm.sh install-indexing` command) for existing VMs.
- [x] Add the plugin install to `cloud-init/user-data` `runcmd` so freshly created
      VMs have it out of the box.
- [x] Document the command in `README.md`.
- [x] `bash -n vm.sh setup.sh scripts/install-lancedb.sh` passes.
- [x] No secrets, keys, or generated artifacts committed.

## Test cases

- [x] [unit] `bash -n vm.sh setup.sh scripts/install-lancedb.sh` reports no syntax errors.
- [x] [e2e] On a fresh `./vm.sh create` VM, `python3 -c "import lancedb; print(lancedb.__version__)"` succeeds.
- [x] [e2e] On an existing VM, `./vm.sh install-lancedb` succeeds and the import check passes.
- [x] [e2e] On a fresh VM the opencode-indexing install completes (via `npx --aio`
      or the direct `install.mjs` fallback) and the plugin is registered
      (`opencode plugin list` or the config entry).
- [x] [e2e] `~/.config/opencode/indexing.json` exists with `"vectorStore": "lancedb"`.
      The model prefetch (`settings.test`) is deferred to first use because the
      installer does not start the opencode service.
- [x] [e2e] Re-running `./vm.sh install-lancedb` and the plugin installer succeeds
      (idempotent) and preserves the existing `indexing.json` (sha256 unchanged).

## Notes

- Follow existing conventions in `AGENTS.md`: guest Python packages go through
  `pip3 install --break-system-packages` (with `--ignore-installed` for
  `lancedb` to avoid Debian-managed `typing_extensions`); commands are `cmd_*` functions dispatched
  in `main()`; quote all variables.
- `cloud-init/user-data` changes only affect newly created VMs; existing VMs are
  covered by the standalone installer / `vm.sh` command.
- The script lives on the host and is executed in the guest, so it must not depend
  on host-only tools.
- `@javierkaiser/opencode-indexing` requires Node.js >= 22.6 and must run as
  `ubuntu` (not root) to write user config. Embedded LanceDB means no separate
  vector DB service is needed.
- OpenCode v2 is the separate npm package `@opencode/cli` (v2.3.0), not
  `opencode-ai` (whose latest is v1.19.6). The installer uninstalls v1 if present
  and installs `@opencode/cli`; the plugin's AIO installer then runs its normal
  `opencode plugin add` path. `codegraph` is installed as the optional `--aio`
  companion; registration may warn if its CLI is not yet on PATH.
- The package's `install.mjs` guards execution with
  `resolve(process.argv[1]) === fileURLToPath(import.meta.url)`. npx runs the bin
  through a `.bin` symlink, so `isMain` is false and the installer exits silently
  with status 0. After the npx attempt, the script checks `opencode plugin list`
  and, if needed, runs `install.mjs` directly from a temporary `npm install`.
- `--no-restart` skips the `settings.test` model prefetch (~512 MB); it is
  deferred until first use.
- `pip3 install --ignore-installed` is required because Ubuntu's Debian-managed
  `typing_extensions` cannot be uninstalled by pip (`RECORD file not found`).
- E2E was run on a throwaway 4 GB `ai-vm-debug` VM with non-conflicting ports and
  destroyed afterwards. `package_upgrade` was disabled only in the debug copy to
  avoid unrelated dist-upgrade time; production cloud-init still enables it. The
  user's `ai-vm` had already been removed, so no main VM was started or left
  running.