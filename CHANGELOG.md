# Changelog

## 1.0 — 2026-09-08

First complete release. Everything below was found and fixed while deploying
this against a real Ubuntu LVM server, so each entry is a bug that actually bit
rather than a theoretical one.

### Features

- `provision` — creates a dedicated filesystem (LVM logical volume or sparse
  loop image) formatted with the ext4 quota feature already enabled, adds an
  fstab entry with a backup, and mounts it.
- `volumes` — lists volume groups with free space, shows which one
  auto-selection would pick, and lists existing sftpctl volumes.
- `config` — `/etc/sftpctl.conf` support with `show` and `init`. Precedence is
  environment, then config file, then built-in default.
- `DEFAULT_VG` and `--vg=NAME` for servers with several volume groups.
- Flexible authentication: password, public key, or both, per server via
  `setup --auth=` and per account via `add --pass` / `--key=`.
- `passwd`, `addkey`, `delkey`, `disable`, `enable` for credential lifecycle.
- `check` — audits sshd config, chroot permissions, shells, credentials, and
  quota state.
- man page (section 8) with ten worked scenarios and eleven troubleshooting
  sections.
- bash completion, including live usernames from the group and volume group
  names from `vgs`.

### Fixes

**`add` exited silently, creating nothing.** `((positional++))` is a
post-increment: it evaluates to the value *before* incrementing, so the first
one from zero returned 0, which bash treats as a failed command. Under
`set -euo pipefail` that aborted the script on the very first argument, with no
output and no account created. Same bug in `((issues++))` in `check`. Both are
now `x=$(( x + 1 ))`. An `ERR` trap was added so no future abort can be silent.

**`list` and `show` reported `0K / 0K` for every account.** The parser used
`quota -uw`, which prints the *device* in its first column, not the mount point.
Matching on the mount point silently produced nothing and every figure read as
zero — including the over-quota warning in `quota`, so shrinking a limit below
current usage went unwarned. Now parses `repquota`, handling the optional
two-character status field. The XFS branch had a related unit bug: `xfs_quota
report` emits human-suffixed sizes while the ext4 path returns 1K blocks.

**`setup` misreported quota as inactive on a working filesystem.** The check
relied on `quotaon -p`, which is unreliable on a filesystem using the ext4 quota
feature — the kernel manages quotas through hidden inodes rather than the
interface `quotaon` was built around. Now tests functionally with `repquota`,
falling back to `quotaon -p`, and tries a remount before giving up.

**`setup` attempted `tune2fs -O quota` on a mounted root filesystem.** That
feature bit can only be set offline, so it always failed, then fell through to
`quotaon` with deprecated external `aquota.*` files, which modern kernels reject
with `Device or resource busy` — leaving stray files behind. `setup` now detects
the condition first and explains the options without changing anything.

**`provision` picked the wrong volume group.** It took the first from `vgs`
output, which is whichever sorts first, not whichever has room. Now selects by
most free space, honours `DEFAULT_VG` and `--vg=`, and checks free space in
bytes before calling `lvcreate` so an oversized request aborts with the
available groups listed.

**`config init` and `volumes` aborted silently on hosts without LVM.** A missing
`vgs` made the pipeline fail, and `pipefail` turned that into a silent exit.
Both now check for the command first.

**`add` gave a dead-end error when `DEFAULT_BASE` pointed at a filesystem
without quota.** It suggested `setup /`, which cannot work. It now scans mounted
filesystems, reports which ones do have quota, and gives the exact `--base=` and
config lines to fix it.

**Passwords on the command line were fragile and leaky.** An unquoted `!` is
consumed by bash history expansion before the script runs (`event not found`),
and any password given as an argument persists in shell history and is visible
in `ps`. Added `--ask` (prompts twice, no echo) and `--stdin` (one line from
standard input, for scripts) to `passwd`, and `--ask` to `add`. `set_password`
now uses `printf` rather than `echo`, which would mangle a password beginning
with `-e` or `-n`, and rejects newlines, which `chpasswd` cannot carry.

### Known limitations

- XFS support is written but untested — no XFS system was available.
- `scp -O` (legacy protocol) is incompatible by design; it requires a real
  shell. OpenSSH 9.0+ clients work without it.
- Quotas cap consumption but do not reserve it. Overcommitting across accounts
  is possible and unpoliced.
