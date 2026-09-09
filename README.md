# sftpctl

Manage chrooted, shell-less SFTP/SCP accounts with per-user disk quotas.

Each account can upload files over `scp` or `sftp` and nothing else — no shell,
no port forwarding, no visibility outside its own directory — with a hard cap on
how much disk it can consume. Authentication is by password, public key, or both.

Ships with a man page (`man sftpctl`) and tab completion.

---

## Contents

| file | purpose |
|---|---|
| `sftpctl.sh` | the tool |
| `sftpctl.8` | man page (troff, section 8) |
| `sftpctl.bash-completion` | tab completion for bash |
| `install.sh` | installs all three |

## Requirements

| | |
|---|---|
| OS | Any systemd Linux (Debian/Ubuntu, RHEL/Rocky/Alma, SUSE) |
| Filesystem | ext4 (preferred) or XFS |
| Packages | `quota`, `openssh-server`; `lvm2` for `provision --lv` |
| Privileges | root |

```bash
sudo apt install quota openssh-server lvm2        # Debian / Ubuntu
sudo dnf install quota openssh-server lvm2        # RHEL / Rocky / Alma
```

## Install

```bash
sudo ./install.sh
```

Places the tool at `/usr/local/sbin/sftpctl`, the man page at
`/usr/share/man/man8/`, and completion in whichever bash-completion directory
your distro uses. It refuses to install if the script fails a syntax check, and
reports any missing packages at the end.

```bash
man sftpctl                    # full manual with worked examples
sftpctl --help                 # command summary
source /usr/share/bash-completion/completions/sftpctl   # completion, this shell
```

Uninstall with `sudo ./install.sh --uninstall`. That removes the three installed
files and leaves your config, accounts, volumes, and sshd drop-in alone.

---

## Start here: does /home have its own filesystem?

This one question decides your whole setup path. Quotas are a per-filesystem
mechanism, so it is not something you can work around.

```bash
sudo findmnt -no SOURCE,TARGET --target /home
```

If `TARGET` is `/home`, you have a separate filesystem — **Path A**. If it is
`/`, which is the default on a stock Ubuntu LVM install, take **Path B**.

### Path A — /home is its own filesystem

The ext4 quota feature can only be enabled on an unmounted filesystem, so this
is a brief offline step:

```bash
sudo systemctl stop sshd
sudo umount /home
sudo tune2fs -O quota -Q usrquota,grpquota /dev/<your-home-device>
sudo mount /home
sudo systemctl start sshd

sudo sftpctl setup --auth=both
sudo sftpctl add alice 10 --pass
```

No fstab change is needed — the quota feature activates automatically at mount.

### Path B — /home is on the root filesystem

Give the accounts their own filesystem:

```bash
sudo sftpctl volumes                          # inspect volume groups first
sudo sftpctl provision /srv/sftp 10G
sudo sftpctl setup /srv/sftp --auth=both
sudo sftpctl config init                      # records DEFAULT_BASE, DEFAULT_VG
sudo sftpctl config show                      # confirm DEFAULT_BASE=/srv/sftp
sudo sftpctl add alice 5 --pass
```

Two reasons the root filesystem won't work. First, `tune2fs -O quota` needs the
filesystem unmounted, and you cannot unmount a running root — the only offline
path is rescue media. Second, a user quota on `/` limits that UID *everywhere*
on `/`, including `/tmp` and `/var/tmp`, not just their upload directory.

The deprecated alternative — external `aquota.user` / `aquota.group` files via a
`usrquota` mount option — is refused by current kernels. If you've hit
`quotaon: Device or resource busy`, clean up with:

```bash
sudo quotaoff -a 2>/dev/null; sudo rm -f /aquota.user /aquota.group
```

---

## Verifying quotas are live

Do this before creating accounts. Use `repquota`, **not** `quotaon -p`:

```bash
sudo repquota -u /srv/sftp
```

A table with grace times and a `root` row means quotas are working, even if
otherwise empty. That is the authoritative test.

`quotaon -p` reports unreliably on a filesystem using the ext4 quota feature,
because the kernel manages quotas through hidden inodes rather than the
interface `quotaon` was built around. For the same reason `/proc/mounts` will
**not** show a `usrquota` option — its absence is expected, not a fault.

---

## Configuration

On a server with several volume groups or a non-default account directory, put
the settings in a config file rather than repeating flags:

```bash
sudo sftpctl config init          # writes /etc/sftpctl.conf, pre-fills DEFAULT_VG
sudo sftpctl config show          # effective values and where they came from
```

```bash
# /etc/sftpctl.conf
DEFAULT_VG="data-vg"              # provision targets this VG
DEFAULT_BASE="/srv/sftp"          # add/list/show default here; drop --base
DEFAULT_QUOTA_GB="10"
SOFT_PCT="90"
INODES_PER_GB="20000"
PASS_LENGTH="20"
SFTP_GROUP="sftpusers"
UPLOAD_SUBDIR="upload"
```

Precedence is **environment → config file → built-in default**. Because `sudo`
strips the environment, an exported variable won't reach the tool unless you use
`sudo -E` or set it inline:

```bash
sudo DEFAULT_VG=other-vg sftpctl provision /srv/bulk 500G
```

`SFTPCTL_CONFIG` points at an alternate config path, which is useful for testing
without touching `/etc`.

**Set `DEFAULT_BASE` right after provisioning.** It ships as `/home`, which on a
Path B server resolves to `/` — the one filesystem without quotas. Every `add`
will fail until you either pass `--base` or change this:

```bash
sudo sftpctl config init
sudo sed -i 's|^DEFAULT_BASE=.*|DEFAULT_BASE="/srv/sftp"|' /etc/sftpctl.conf
sudo sftpctl config show
```

Changing `SFTP_GROUP` after accounts exist orphans them — they stay in the old
group and lose the chroot. Set it before creating anything, or not at all.

---

## Commands

### volumes

```bash
sudo sftpctl volumes
```

Every volume group with size, free space, and LV count; which one auto-selection
would pick; any `DEFAULT_VG` from the config; and existing sftpctl volumes. Run
this before `provision` on a server with more than one VG. Aliased as
`sftpctl vgs`.

### config

```bash
sudo sftpctl config show
sudo sftpctl config init
```

`show` prints every tunable with its effective value. `init` writes a commented
`/etc/sftpctl.conf` from the current values, pre-filling `DEFAULT_VG` with the
volume group that has the most free space.

### provision

```bash
sudo sftpctl provision <mountpoint> <size> [--lv|--loop|--vg=NAME]
```

Creates a dedicated filesystem, formatted with the ext4 quota feature already
on, adds an fstab entry (backing up the original), and mounts it.

| mode | backing store |
|---|---|
| `--lv` | new LVM logical volume from free volume-group space |
| `--vg=NAME` | LV in a specific volume group |
| `--loop` | sparse image at `/var/lib/sftpctl/sftpdata.img` |
| *(omitted)* | `DEFAULT_VG` if set, else the VG with the most free space, else loop |

```bash
sudo sftpctl provision /srv/sftp 100G
sudo sftpctl provision /srv/sftp 100G --vg=data-vg
sudo sftpctl provision /srv/sftp 100G --loop
```

Free space is checked before `lvcreate` runs, so an oversized request aborts
with the available groups listed rather than failing partway.

Prefer `--lv`: a real block device, no stacked filesystems, growable later with
`lvextend` plus `resize2fs`. `--loop` is the fallback when the VG is full — it
works, but the image is sparse, so the host filesystem can fill underneath it
and accounts hit `ENOSPC` while still under quota.

**Leave headroom in the volume group.** `lvextend` needs free extents. Allocate
every last one now and you cannot grow anything later without rescue media.

### setup

```bash
sudo sftpctl setup [mountpoint] [--auth=key|password|both]
```

Run once per server. Verifies quota is active, creates the `sftpusers` group,
and writes `/etc/ssh/sshd_config.d/60-sftp-only.conf`.

The auth directives sit inside a `Match Group sftpusers` block, so they apply
**only** to SFTP accounts — a hardened global `PasswordAuthentication no` stays
in force for your admin logins.

| mode | effect |
|---|---|
| `key` | public keys only |
| `password` | passwords only |
| `both` | either works (default) |

Re-running backs up the existing drop-in first. If `sshd -t` fails, the change is
reverted and nothing is applied.

**XFS:** quota is a mount-time feature there and cannot be enabled live. `setup`
prints the fstab change; you then need a full umount/mount — a remount will not
do it. If the target is `/`, add `rootflags=uquota` to the kernel cmdline and
reboot.

### add

```bash
sudo sftpctl add <user> [size] [options]
```

| option | meaning |
|---|---|
| `--pass` | set a password, generated and printed once |
| `--pass=SECRET` | set a specific password (hits shell history — prefer `--ask`) |
| `--ask` | prompt for the password, twice, without echoing |
| `--key=STR\|FILE` | authorize a public key at creation |
| `--base=DIR` | parent directory (default `DEFAULT_BASE`) |
| `--expire=DAYS` | account expiry date |

```bash
sudo sftpctl add alice 5 --pass
sudo sftpctl add bob 25 --pass=Correct-Horse-Battery
sudo sftpctl add carol 50 --key=/root/carol.pub
sudo sftpctl add dave 10 --pass --key=/root/dave.pub
sudo sftpctl add vendor 100 --base=/srv/incoming --key=/root/vendor.pub --expire=90
```

Sizes accept `10`, `500M`, `10G`, `2T`. A bare number means GB.

The generated password prints **once**. It's stored as a hash and cannot be
recovered — use `sftpctl passwd <user> --gen` to issue a new one.

Creating an account with neither `--pass` nor `--key` is allowed but warns: it
has no way to log in until you add credentials.

**Quotas cap, they do not reserve.** A 10 GB quota on a 10 GB volume lets one
user fill the whole thing. With several accounts, size each at a fraction of the
volume so one sender can't starve the others.

### quota

```bash
sudo sftpctl quota <user> <size>
```

Takes effect on the next write: no logout, no service reload.

```bash
sudo sftpctl show autobus          # check usage before shrinking
sudo sftpctl quota autobus 500M
sudo repquota -u /srv/sftp         # verify independently
```

Shrinking below current usage is permitted and warns rather than blocking.
Existing files stay; the user can't write again until they delete something.
Over SFTP that surfaces as a generic transfer failure, not a quota message.

### passwd

```bash
sudo sftpctl passwd alice              # generate and print a new one
sudo sftpctl passwd alice --gen        # same
sudo sftpctl passwd alice --ask        # prompt twice, no echo
sudo sftpctl passwd alice --stdin      # read one line from stdin, for scripts
sudo sftpctl passwd alice --lock       # disable password, keep key auth
sudo sftpctl passwd alice --unlock     # re-enable
```

**Don't put passwords on the command line.** They land in `~/.bash_history` and
are visible in `ps` while the command runs. Worse, bash expands some characters
before `sftpctl` ever sees them — an unquoted `!` gives you
`bash: !23456: event not found`, because history expansion runs first.

```bash
sudo sftpctl passwd alice 'Aa@!23456'  # single quotes required for ! $ ` "
sudo sftpctl passwd alice --ask        # better: nothing to quote
```

From a secrets store:

```bash
pass-cli show sftp/alice | sudo sftpctl passwd alice --stdin
```

Any character is accepted except a newline, which `chpasswd` cannot carry.

### addkey / delkey

```bash
sudo sftpctl addkey alice "ssh-ed25519 AAAAC3Nza..."
sudo sftpctl addkey alice /root/alice.pub
ssh-keygen -y -f alice_rsa | sudo sftpctl addkey alice -
sudo sftpctl delkey alice                    # interactive picker
sudo sftpctl delkey alice "alice@laptop"     # match by comment or fingerprint
```

Duplicates are detected and skipped.

### list / show

```bash
sudo sftpctl list
sudo sftpctl show alice
```

Usage, quota, percentage, and auth method per account, flagging anything past
90% or missing credentials.

### disable / enable

```bash
sudo sftpctl disable alice
sudo sftpctl enable alice
```

Locks the password and moves `authorized_keys` aside. Data and quota untouched,
so a disabled account still occupies disk. Use `remove` to reclaim space.

### remove

```bash
sudo sftpctl remove alice              # delete account, keep data
sudo sftpctl remove alice --purge      # delete account and all data
```

Requires typing the username to confirm. The quota is zeroed before `userdel` —
otherwise the limit stays bound to the freed UID and whichever account next
reuses that UID silently inherits it.

### check

```bash
sudo sftpctl check
```

Audits sshd config, chroot ownership and permissions, shell assignment,
credentials, and quota state across all accounts.

---

## Tab completion

Completes subcommands, options per subcommand, and — dynamically — usernames
from the `sftpusers` group and volume group names from `vgs`:

```
sudo sftpctl <TAB>                    volumes config provision setup add ...
sudo sftpctl passwd <TAB>             alice bob carol
sudo sftpctl passwd alice --<TAB>     --gen --lock --unlock
sudo sftpctl provision /srv/sftp 100G --vg=<TAB>    ubuntu-vg data-vg
```

Completion after `sudo` needs bash-completion's sudo support, which is standard
on Debian/Ubuntu and RHEL. If it doesn't fire, check that
`/usr/share/bash-completion/bash_completion` is sourced from your `.bashrc`.

---

## How it works

```
/srv/sftp/alice            root:root   755   <- chroot root, NOT user-writable
├── .ssh/
│   └── authorized_keys      alice:alice 600  <- read by sshd as root, pre-chroot
└── upload/                alice:alice 700   <- where files land
```

`ChrootDirectory` requires the directory **and every parent** to be owned by
root with no group or world write. The user therefore cannot write to their own
home directory, which is why `upload/` exists inside it. Senders target
`upload/`, relative to the chroot — there's no absolute server path they can
reach.

This is the most common misconfiguration, and sshd's response when it's wrong
(`Connection closed`) identifies nothing. `sftpctl check` catches it.

The sshd drop-in:

```
Subsystem sftp internal-sftp

Match Group sftpusers
    ChrootDirectory %h
    ForceCommand internal-sftp -u 0022
    PasswordAuthentication yes
    KbdInteractiveAuthentication yes
    PubkeyAuthentication yes
    AuthenticationMethods any
    AllowTcpForwarding no
    AllowAgentForwarding no
    X11Forwarding no
    PermitTTY no
```

`Match` blocks consume every directive that follows them, so this lives in a
drop-in that sorts last rather than in the main config.

---

## Things that will bite you

**`scp -O` fails.** OpenSSH 9.0+ made `scp` use the SFTP protocol underneath, so
modern clients work against `internal-sftp`. A client forcing the legacy
protocol with `-O` needs a real shell and is rejected. Test your senders before
rolling this out, especially anything with a hardcoded flag in a cron job.

**Password expiry locks the account permanently.** These accounts have no shell,
so the user can never run `passwd`. A distro default like `PASS_MAX_DAYS 90` in
`/etc/login.defs` silently expires the account months later with no recovery
path. `sftpctl` runs `chage -M -1` on every password it sets, and `check` flags
any account where expiry got set another way.

**`UsePAM no` blocks passwords.** On most distros password authentication goes
through PAM regardless of `PasswordAuthentication yes`. `check` catches this.

**Quota errors surface badly over SFTP.** The client gets a generic transfer
failure, not "disk quota exceeded", and the partial file stays on disk still
consuming quota. For automated senders, verify size after upload, or alert on
`sftpctl list` rather than waiting for the hard stop.

**Inode limits.** Each account gets an inode cap alongside the space cap
(20,000 per GB by default). Without one, a user can exhaust the filesystem's
inodes with millions of empty files while well under their space quota. Tune
with `INODES_PER_GB`.

**Don't trust `quotaon -p`.** See [Verifying quotas are live](#verifying-quotas-are-live).

---

## Troubleshooting

| symptom | cause |
|---|---|
| `Connection closed` right after auth | chroot directory not `root:root`, or group/world writable. Run `sudo sftpctl check`. |
| Password rejected, key works | global `PasswordAuthentication no`, or `UsePAM no`. Re-run `setup --auth=both`. |
| `subsystem request failed` | no `Subsystem sftp internal-sftp`, or it points at `sftp-server` outside the chroot. |
| Permission denied writing files | sender targeting `/` inside the chroot instead of `upload/`. |
| Transfer stops partway, no clear error | quota hit. Check `sudo sftpctl show <user>`. |
| Worked yesterday, fails today | password expired. `sudo sftpctl check` flags it. |
| `quotaon: Device or resource busy` | kernel rejecting legacy `aquota.*` files. Use `provision`. |
| `tune2fs failed` during setup | target is mounted. The feature bit is offline-only. |
| `list` shows `0K / 0K` for everyone | pre-1.0 version parsing `quota` instead of `repquota`. Upgrade. |
| `insufficient free space` naming an unexpected VG | multiple volume groups. Use `--vg=NAME` or set `DEFAULT_VG`. |
| Completion does nothing | new shell needed, or bash-completion not sourced from `.bashrc`. |
| `add` says quota not active on `/` | `DEFAULT_BASE` still points at `/home`. Pass `--base=/srv/sftp` or set it in the config. |
| `bash: !23456: event not found` | bash history expansion, before sftpctl runs. Single-quote the password or use `--ask`. |

Watch a live login attempt:

```bash
sudo journalctl -u sshd -f
sudo /usr/sbin/sshd -d -p 2222        # debug mode on an alternate port
```

`man sftpctl` has the same troubleshooting material with worked examples for
each scenario, plus sections on offboarding and growing a full volume.

---

## License

MIT. See [LICENSE](LICENSE).

Replace the copyright line with your full name before publishing — `Copyright
(c) 2026 Mehran` is a placeholder.

If MIT is not the fit you want:

| license | when it suits |
|---|---|
| MIT | anyone may use it, including in closed products. Simplest, most common for tooling. |
| Apache-2.0 | same freedoms plus an explicit patent grant and a trademark clause. Preferred by companies. |
| GPL-3.0 | derivatives must also be open source. |

Drop the replacement text into `LICENSE` and update this section. GitHub detects
the license from that file automatically.

### On authorship

This tool was written with Claude (Anthropic). That raises two separate
questions, and it's worth keeping them apart.

**Do you have the right to publish it?** Yes. Anthropic's terms state that you
retain all rights to your inputs and own the outputs, that Anthropic disclaims
any rights it receives, and that it assigns you its right, title and interest —
if any — in the outputs. There is no Anthropic license to comply with, no
attribution requirement, and no restriction on commercial use. Nothing needs to
be credited back.

**Is it copyrightable?** Less certain, and this comes from copyright law rather
than from Anthropic. US copyright requires human authorship, and the Copyright
Office's position is that purely machine-generated material is not protectable
on its own. Work that a person meaningfully directed, selected, corrected and
shaped has a stronger claim — which describes this project, given the design
decisions, testing against a real server, and the round of bug fixes that came
out of it. But the boundary is unsettled and varies by jurisdiction.

The practical consequence is narrow: if someone copied this repo without
honouring the MIT terms, your ability to enforce that might be weaker than for
hand-written code. It does not affect your right to publish, license, or sell
it. For most tools of this kind that trade-off is irrelevant; if this were
going to underpin a commercial product, it would be worth asking a lawyer.

Documenting your own involvement helps, and the git history does that for free
— so commit as you iterate rather than pushing one finished dump. Some
maintainers also add a line to the README noting AI assistance. That is a
transparency choice, not an obligation.

None of the above is legal advice, and terms change. The current text is at
<https://www.anthropic.com/legal/consumer-terms> and
<https://www.anthropic.com/legal/commercial-terms>.
