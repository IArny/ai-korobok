# 005 — Verify persistence and provisioning e2e against a real VM

- **Status:** todo
- **Phase:** P1
- **Priority:** medium
- **Depends on:** 002, 003, 004

## Goal

Run the VM-backed e2e cases for agent persistence (002) and the provisioning
wait (003) that were deferred when no libvirt host was available. Nested e2e
support (004) now makes this possible on the `ai-vm` guest itself.

## Acceptance criteria

- [ ] All test cases below pass against a throwaway VM, and the results are
      recorded in Notes (date, VM config, observed output).
- [ ] `bash -n vm.sh setup.sh scripts/*.sh` passes.
- [ ] No secrets, keys, archives, or generated artifacts committed.

## Test cases

Moved from 002:

- [ ] [e2e] Create a VM, write a marker OpenCode config and a session/DB marker,
      run `vm.sh destroy`, recreate, and verify both markers are restored.
- [ ] [e2e] First `vm.sh create` with an empty host persistence directory succeeds
      without errors.
- [ ] [e2e] `vm.sh destroy` when the VM is already stopped/undefined leaves the host
      backup intact.
- [ ] [e2e] Restored OpenCode files are owned by `ubuntu:ubuntu` and are readable by
      the `ubuntu` user after recreation.
- [ ] [e2e] With `include_cache: false`, `~/.cache/opencode` is not copied; with
      `true`, it is restored.
- [ ] [e2e] `vm.sh backup-agent` with no profile configured uses `agent` and
      includes credentials while excluding caches.
- [ ] [e2e] Run `vm.sh backup-agent` on a running VM, destroy the VM, restore the
      archive under a different host persistence path (simulating a new host),
      recreate the VM, and verify the config/session markers are present.
- [ ] [e2e] `vm.sh restore-agent` while the VM is running applies the restored data
      immediately.
- [ ] [e2e] The backup archive is mode `0600` and excludes `~/.cache/opencode` by
      default.

Moved from 003:

- [ ] [e2e] On a fresh `vm.sh create`, the "created and started" message appears
      only after provisioning; an immediate `./vm.sh ssh` finds `docker`, `node`,
      `python3 -c "import lancedb"`, and `opencode` working, with no reboot in
      progress.
- [ ] [e2e] `vm.sh create --no-wait` returns after the IP step; `vm.sh status`
      then shows `in progress (<step>)` and later `complete`.
- [ ] [e2e] `vm.sh status` during provisioning shows the same `>>> step` that
      `cloud-init-output.log` is currently printing.
- [ ] [e2e] After provisioning finishes (including the cloud-init reboot), the
      configured port forwards still target the VM's current IP.
- [ ] [e2e] `vm.sh ssh` during provisioning prints the warning but still opens a
      working shell.
- [ ] [e2e] Re-running `vm.sh create` against an already provisioned VM does not
      wait for the full timeout.

## Notes

- Use the nested e2e recipe from 004 / `README.md`: a project copy outside the
  virtiofs mount, a distinct `vm_name`/`disk_path`, non-conflicting ports, and a
  size that fits the guest's free memory. A full provision takes ~12–22 minutes
  including the cloud-init reboot, so run creates in the background.
- For persistence cases, enable `opencode_persistence` and use a temporary
  `host_path` under `/tmp` so the real agent state is never touched. Keep
  `include_docker_volumes: false`.
- The ad-hoc unit harnesses used for 002/003
  (`/tmp/opencode/persist-test.sh`, `/tmp/opencode/provision-test.sh`) were not
  committed; recreate them or promote them to `scripts/` before relying on them.
- 004 left the nested image cache in `cache_dir` and the guest's
  `apt-cacher-ng` populated, so repeat creates should not re-download the image
  or Ubuntu archive packages.