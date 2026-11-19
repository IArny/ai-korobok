# 003 — Wait for dependency provisioning during `vm.sh create`

- **Status:** review
- **Phase:** P1
- **Priority:** high
- **Depends on:** 001

## Goal

Stop `vm.sh create` from reporting success while cloud-init is still installing
guest dependencies. Today `create` returns as soon as the VM has an IP and the
port forwards are applied; cloud-init then keeps running (Node.js, Docker, pip
packages, LanceDB, OpenCode plugin) for several more minutes and ends with a
`power_state: reboot`. A user who SSHs in immediately lands in a half-provisioned
guest (missing `docker`, `node`, `lancedb`, `opencode`, or the VM rebooting under
them) with no indication that anything is still in progress.

Make `create` wait for provisioning to finish by default, show what step is
running, and make `status` / `ssh` surface the provisioning state.

## Acceptance criteria

- [x] Add a guest-side sentinel written as the final `runcmd` step in
      `cloud-init/user-data` (e.g. `/var/lib/ai-korobok/provisioned`) containing
      an ISO-8601 timestamp; keep the existing `>>> Setup complete.` line and do
      not introduce new guest packages.
- [x] Add a `wait_for_provisioning()` helper in `vm.sh` that polls over SSH and
      returns only when the sentinel exists **and** `cloud-init status` reports
      `done` on the current boot.
  - [x] Tolerate the final cloud-init reboot (connection refused/reset, host key
        untouched): retry with backoff and a bounded total timeout.
  - [x] Use non-interactive SSH options (`BatchMode=yes`, `ConnectTimeout=5`,
        `StrictHostKeyChecking=no`, `UserKnownHostsFile=/dev/null`) so the wait
        can never block on a prompt.
  - [x] Return immediately when the VM is already provisioned (sentinel present),
        so re-running against an existing VM is cheap.
  - [x] After provisioning completes, re-resolve the VM IP and re-apply port
        forwards if the post-reboot address differs from the pre-reboot one.
- [x] `cmd_create` calls the helper after the VM gets an IP and prints progress
      while waiting:
  - [x] Show the current step by following the `>>> ...` lines from the guest's
        `/var/log/cloud-init-output.log` (only new lines, no log spam).
  - [x] Show elapsed time and a clear "provisioning still running" line so a long
        wait is explained rather than looking hung.
  - [x] Print the usual "created and started" message only after provisioning is
        complete (or after an explicit `--no-wait`).
- [x] Add flags and configuration:
  - [x] `vm.sh create --no-wait` returns right after the IP/port-forward step
        (current behavior) and prints how to monitor progress.
  - [x] `vm.sh create --timeout <seconds>` overrides the default.
  - [x] `config.example.json` and `.state` config handling gain
        `provisioning.wait` (default `true`) and
        `provisioning.timeout_seconds` (default `1800`); document them in
        `README.md`.
  - [x] On timeout, leave the VM running, print a warning with the log path and
        the command to keep monitoring, and exit 0 (the VM itself is healthy).
- [x] `cmd_status` reports provisioning state when the VM is running:
      `starting` (no SSH yet), `in progress (<last >>> step>)`, or `complete`.
      The check must be bounded (short SSH timeout) and must not make `status`
      hang when the guest is unreachable.
- [x] `cmd_ssh` performs a best-effort, low-latency check and prints a warning to
      stderr when provisioning is still in progress, then still opens SSH.
- [x] Handle "cloud-init not available / not enabled" by warning once and
      returning instead of waiting until the timeout.
- [x] Document the new behavior, flags, config keys, and how to troubleshoot a
      stuck provisioning run in `README.md`.
- [x] `bash -n vm.sh setup.sh scripts/*.sh` passes.
- [x] No secrets, keys, or generated artifacts committed.

## Test cases

- [x] [unit] `bash -n vm.sh setup.sh scripts/*.sh` reports no syntax errors.
- [x] [unit] `wait_for_provisioning` with stub `ssh`/`virsh`/`date` commands on
      `PATH` (temporary directories): returns once the sentinel appears, survives
      several failed SSH attempts (reboot window), honours `--timeout`, and can
      be skipped entirely with `--no-wait`.
- [x] [unit] Timeout path exits 0, keeps the domain defined, and prints the
      monitoring guidance.
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

- Cloud-init exposes `/var/lib/cloud/instance/boot-finished` and
  `cloud-init status [--long] [--wait]`. `status --wait` only covers the current
  boot, and `user-data` ends with `power_state: reboot`, so SSH may drop mid-wait
  and the second boot must be treated as success once the sentinel exists.
- The `>>> ...` progress lines already exist in `cloud-init/user-data`; reuse
  them instead of adding a second logging format. `/var/log/cloud-init-output.log`
  holds the full transcript.
- Prefer a sentinel over checking individual binaries: it also covers future
  dependencies and avoids false negatives when a package is optional or still
  installing. Optionally verify a couple of key commands (`docker`, `node`,
  `opencode`) after the sentinel as a sanity check, but do not make the wait
  depend on them.
- Keep the wait host-side (SSH polling) rather than relying on the virtiofs
  shared mount: `shared_dir` is optional and not mounted during early boot.
- The IP can change across the cloud-init reboot, so re-running
  `apply_port_forwards` (which already replaces `.state/iptables-rules`) after
  the wait is needed; verify the old rules are removed first.
- Follow the repo rules for testing: copy the project to a throwaway directory,
  use a distinct `vm_name`/`disk_path`/ports, never disturb the user's `ai-vm`,
  and check `free -h` before starting another VM.
- Run the long `create` as a background task and poll the log, per `AGENTS.md`.

### Implementation notes

- Implemented in `vm.sh` (`provisioning_state`, `wait_for_provisioning`,
  `cmd_create` flags, `status`/`ssh` reporting), `cloud-init/user-data` (sentinel),
  `config.example.json`, and `README.md`.
- Verified with `bash -n`, JSON validation, and an ad-hoc stub test covering SSH
  failures/reconnect, the post-provisioning reboot, timeout, cloud-init
  missing/error, legacy VMs, `--no-wait`, an IP change after reboot, and invalid
  timeouts. E2E creation was not run in the implementation environment because
  `virsh`/libvirt is unavailable there; the e2e cases still need a libvirt host.
