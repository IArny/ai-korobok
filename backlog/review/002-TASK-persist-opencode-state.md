# 002 — Persist and back up OpenCode agent state

- **Status:** review
- **Phase:** P1
- **Priority:** high
- **Depends on:** 001

## Goal

Keep OpenCode configuration, credentials, plugins/skills, and session history when
the VM is removed and recreated (`vm.sh destroy` followed by `vm.sh create`), and
provide portable backup/restore commands so the same agent state can be moved to
another host.

## Acceptance criteria

- [x] Add persistence settings to `config.example.json` and `config.json` handling:
  - [x] `opencode_persistence.enabled` (default `true`)
  - [x] `opencode_persistence.host_path` (default outside the repo, e.g.
        `${HOME}/.local/share/ai-korobok/opencode`)
  - [x] `opencode_persistence.include_cache` (default `false`; `full` profile
        implies `true` unless explicitly overridden)
  - [x] `opencode_persistence.backup_profile` (`minimal`, `agent`, `full`;
        default `agent`)
  - [x] `opencode_persistence.include_docker_volumes` (default `false`, only
        meaningful for `full`)
  - [x] Validate the fields in `load_config` and document them in `README.md`.
- [x] Create the host persistence directory with mode `0700`, owned by the invoking
      user; keep it gitignored and never commit its contents.
- [x] Persist and restore the OpenCode paths, resolved in the guest with
      `opencode debug paths` rather than hardcoded where possible:
  - [x] config (`~/.config/opencode`: `opencode.json(c)`, `tui.json`,
        `indexing.json`, skills, plugins)
  - [x] data (`~/.local/share/opencode`: sessions/DB, auth/credentials)
  - [x] state (`~/.local/state/opencode`)
  - [x] cache (`~/.cache/opencode`) only when `include_cache` is enabled; excluded
        by default because it is large and re-creatable.
- [x] Restore the persisted paths into a newly created VM before OpenCode is used
      (during `vm.sh create`, after SSH is available); first run with no backup is
      a no-op.
- [x] Sync guest → host before the guest data is lost:
  - [x] `vm.sh destroy` syncs before undefining/deleting the disk.
  - [x] `vm.sh stop` also syncs, so a later destroy does not lose sessions created
        during the run.
  - [x] If the VM is already gone, leave the host backup untouched.
- [x] Define and document backup profiles, with `agent` as the default:
  - [x] `minimal`: OpenCode config, data, and state only.
  - [x] `agent`: `minimal` plus agent identity/runtime state (SSH/Git/gh/npm/cloud
        credentials, dotfiles and shell history, MCP/browser state, user services,
        custom tools, LanceDB/index data).
  - [x] `full`: `agent` plus OpenCode/package/model caches and local model weights;
        Docker volumes only when `include_docker_volumes` is enabled.
  - [x] The backup manifest records the profile and every included path.
- [x] Add portable agent backup/restore commands:
  - [x] `vm.sh backup-agent [archive.tar.gz]`: syncs from a running VM first (or
        uses the host persistence directory if the VM is gone) and writes a
        mode-`0600` tarball containing the paths selected by the active
        `backup_profile` (default `agent`).
  - [x] The archive has a manifest with format version, creation time, source VM
        name, OpenCode version, and the included paths; it uses relative paths so
        it is host-independent.
  - [x] Default name is identifiable, e.g.
        `opencode-agent-<vm>-<timestamp>.tar.gz`; add the pattern to `.gitignore`.
  - [x] `vm.sh restore-agent <archive.tar.gz>`: validates the manifest/archive,
        restores into the configured host persistence path, refuses to overwrite
        non-empty state unless `--force` is passed, and fixes ownership/permissions.
  - [x] If the VM is running, `restore-agent` pushes the restored data into the
        guest immediately; otherwise the next `vm.sh create`/`start` applies it.
  - [x] Warn that the archive contains credentials/session data and must be stored
        securely; never print secret file contents.
- [x] Preserve ownership/permissions in the guest (`ubuntu:ubuntu`) so OpenCode can
      read and write the restored files.
- [x] Keep secrets safe: `auth.json`/API keys live only in the host persistence
      directory (mode `0700`, gitignored); never print them or copy them into the
      repo.
- [x] Document how persistence interacts with `vm.sh export`/`import` (either
      include the persistence archive or state clearly that it is not included).
- [x] `bash -n vm.sh setup.sh scripts/*.sh` passes.
- [x] No secrets, keys, or generated artifacts committed.

## Test cases

- [x] [unit] `bash -n vm.sh setup.sh scripts/*.sh` reports no syntax errors.
- [x] [unit] A helper test with temporary source/destination directories preserves
      file contents, relative paths, and configured ownership mapping without a VM.
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
- [x] [unit] Profile selection with temporary home directories: `minimal`
      includes only OpenCode paths, `agent` adds credentials/runtime state, and
      `full` adds caches/models; the default profile resolves to `agent`.
- [ ] [e2e] `vm.sh backup-agent` with no profile configured uses `agent` and
      includes credentials while excluding caches.
- [x] [unit] Backup/restore helpers with temporary directories: the archive
      contains the manifest and expected paths, restore round-trips the data,
      `--force` governs overwriting, and a corrupt/missing manifest is rejected
      without touching existing persistence.
- [ ] [e2e] Run `vm.sh backup-agent` on a running VM, destroy the VM, restore the
      archive under a different host persistence path (simulating a new host),
      recreate the VM, and verify the config/session markers are present.
- [ ] [e2e] `vm.sh restore-agent` while the VM is running applies the restored data
      immediately.
- [ ] [e2e] The backup archive is mode `0600` and excludes `~/.cache/opencode` by
      default.

## Notes

### Backup profiles

| Profile | Contents |
| --- | --- |
| `minimal` | OpenCode config/data/state. |
| `agent` (default) | `minimal` + identity/credentials (`~/.ssh`, `~/.gitconfig`, `~/.config/gh`, `~/.npmrc`, `~/.netrc`, pip config, `~/.aws`, `~/.config/gcloud`, `~/.kube`, `~/.docker/config.json`), dotfiles/shell history, MCP/browser state, user systemd units/crontab, `~/.local/bin`, LanceDB/index data. |
| `full` | `agent` + `~/.cache/opencode`, package-manager caches, `~/.cache/huggingface`, `~/.ollama` model weights. Docker volumes only with `include_docker_volumes`. |

- `agent` deliberately includes secrets (SSH keys, tokens, `auth.json`) because
  those are what make the agent usable on another host. Treat every archive as
  sensitive; encrypt it or keep it `0600` and never commit/upload it implicitly.
- `agent` excludes regenerable caches by default to keep archives small. Use
  `full` or `include_cache: true` when moving to an offline host or avoiding a
  large model re-download is more important than archive size.
- Docker volumes are not plain files: enable `include_docker_volumes` to add a
  best-effort per-volume export, or back them up separately with the Docker
  tooling of the services involved.
- OpenCode paths come from `opencode debug paths` (selectors include `db`, `home`,
  `data`, `config`, `cache`, `state`, `tmp`, `bin`, `log`, `repos`). Expected Linux
  defaults: config `~/.config/opencode`, data `~/.local/share/opencode`, state
  `~/.local/state/opencode`, cache `~/.cache/opencode`.
- Session history and auth live under the data directory; config/plugins/skills
  live under the config directory. Verify with `opencode debug paths` on the
  installed v2 CLI (`@opencode/cli`) before hardcoding defaults.
- Prefer explicit sync on create/stop/destroy over a live virtiofs mount: a mount
  is simpler but makes persistence depend on the VM being bootable, and destroy
  should still work if the guest is unhealthy. A live-mount option can be a
  follow-up task.
- Use `tar` or `rsync` over the existing SSH path; do not require new guest
  packages beyond what cloud-init already installs.
- The backup archive is a portability boundary, not a git artifact: it contains
  `auth.json` and session history. Keep it `0600`, never commit it, and do not
  upload it implicitly. A different host may not have the same UID/GID, so restore
  must map ownership to `ubuntu`/the invoking user rather than preserving numeric
  IDs.
- The manifest should let `restore-agent` warn (not necessarily fail) when the
  archive format is unsupported or the OpenCode major version differs.
- This task depends on 001 so OpenCode v2 and `opencode debug paths` exist in the
  guest.

## Implementation notes

- `vm.sh` loads `opencode_persistence.*` in `load_config` with defaults and profile
  validation; relative `host_path` values resolve against the project directory and
  trigger a warning to keep them gitignored.
- Guest paths are resolved with `opencode debug paths`; profile path lists are
  filtered by existence in the guest before syncing.
- Sync runs automatically on `create` (after provisioning), `start` (after SSH),
  `stop`, and `destroy` (only while the domain is running). `destroy` leaves the
  host copy untouched when the VM is already gone.
- `backup-agent` syncs a running VM first, otherwise archives the host copy; the
  archive is `0600` and contains `manifest.json` plus a relative `guest/` tree.
- `restore-agent` validates the manifest and tar members, refuses a non-empty host
  path without `--force`, restores `0700`/`0600` permissions, and pushes into a
  running VM with `ubuntu:ubuntu` ownership; otherwise the next `create`/`start`
  applies it.
- Docker volumes are exported per volume as `docker-volumes/<name>.tar.gz` only for
  the `full` profile with `include_docker_volumes: true`.
- `export`/`import` do not include the host persistence directory; the README says
  to copy it separately.
- Unit checks were run with an ad-hoc harness at `/tmp/opencode/persist-test.sh`
  (not committed): 47 assertions covering profile selection, config defaults
  and overrides, archive round-trips, `--force`, corrupt/unsafe manifests,
  tar-member traversal, guest sync, and push.
- E2E cases remain unchecked: this environment has no `virsh`/libvirt, so no VM
  could be created.

- The real CLI path was exercised in a throwaway project copy: `backup-agent` wrote a
  mode-`0600` archive from the host copy with no VM, `restore-agent` refused a
  non-empty host path, and `restore-agent --force` restored it with `0700`/`0600`
  permissions.
