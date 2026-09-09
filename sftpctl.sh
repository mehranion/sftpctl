#!/usr/bin/env bash
#
# sftpctl — manage chrooted, shell-less SFTP/SCP accounts with disk quotas
#
#   sftpctl volumes                                   list volume groups
#   sftpctl config [show|init]                        view or create /etc/sftpctl.conf
#   sftpctl provision <mount> <size> [--lv|--loop|--vg=NAME]  dedicated fs
#   sftpctl setup [mount] [--auth=key|password|both]   one-time server prep
#   sftpctl add <user> [size] [options]                create an account
#   sftpctl quota <user> <size>                        change a quota
#   sftpctl passwd <user> [--ask|--stdin|--gen|--lock|--unlock|PASSWORD]
#   sftpctl addkey <user> <pubkey|file|->              authorize a public key
#   sftpctl delkey <user> [match]                      remove key(s)
#   sftpctl list                                       all accounts + usage
#   sftpctl show <user>                                detail for one account
#   sftpctl disable <user> / enable <user>             block or restore login
#   sftpctl remove <user> [--purge]                    delete account
#   sftpctl check                                      audit config and perms
#
#   add options:
#     --pass[=SECRET]     set a password; omit the value to generate one
#     --ask               prompt for the password (never hits history)
#     --key=STR|FILE      authorize a public key at creation
#     --base=DIR          parent directory (default /home)
#     --expire=DAYS       account expiry date (not password expiry — see notes)
#
#   Sizes accept 10, 500M, 10G, 2T. A bare number means GB.
#
#   MIT licensed. See LICENSE.
#
set -euo pipefail

# set -e can abort mid-run with no output at all (a false-y arithmetic command,
# an unexpected non-zero return). Without this trap those look like success.
trap 'rc=$?; [[ $rc -ne 0 ]] && printf "\n\e[31maborted\e[0m at line %s (exit %s) — nothing further was applied\n" "$LINENO" "$rc" >&2; exit $rc' ERR

# --------------------------------------------------------------- settings
# Precedence: environment > config file > built-in default. Environment values
# are stashed before the config is sourced, then restored over the top of it.
TUNABLES=(SFTP_GROUP UPLOAD_SUBDIR DEFAULT_BASE DEFAULT_QUOTA_GB
          SOFT_PCT INODES_PER_GB PASS_LENGTH DEFAULT_VG)

declare -A _from_env=()
for _v in "${TUNABLES[@]}"; do
  [[ -n "${!_v:-}" ]] && _from_env["$_v"]="${!_v}"
done

CONFIG_FILE="${SFTPCTL_CONFIG:-/etc/sftpctl.conf}"
CONFIG_LOADED=0
if [[ -r "$CONFIG_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE" && CONFIG_LOADED=1
fi

for _v in "${!_from_env[@]}"; do printf -v "$_v" '%s' "${_from_env[$_v]}"; done
unset _v _from_env

SFTP_GROUP="${SFTP_GROUP:-sftpusers}"
UPLOAD_SUBDIR="${UPLOAD_SUBDIR:-upload}"
DEFAULT_BASE="${DEFAULT_BASE:-/home}"
DEFAULT_QUOTA_GB="${DEFAULT_QUOTA_GB:-10}"
SOFT_PCT="${SOFT_PCT:-90}"
INODES_PER_GB="${INODES_PER_GB:-20000}"
PASS_LENGTH="${PASS_LENGTH:-20}"
DEFAULT_VG="${DEFAULT_VG:-}"
SSHD_DROPIN="/etc/ssh/sshd_config.d/60-sftp-only.conf"

# ----------------------------------------------------------------- output
if [[ -t 1 ]]; then
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_BLD=$'\e[1m'; C_DIM=$'\e[2m'; C_OFF=$'\e[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLD=""; C_DIM=""; C_OFF=""
fi
info() { echo "${C_DIM}==>${C_OFF} $*"; }
ok()   { echo "${C_GRN}ok${C_OFF}  $*"; }
warn() { echo "${C_YEL}warn${C_OFF} $*" >&2; }
die()  { echo "${C_RED}error${C_OFF} $*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "must run as root"; }

# ------------------------------------------------------------- size parsing
to_blocks() {
  local v="${1^^}" num unit
  num="${v%[MGT]}"; unit="${v: -1}"
  [[ "$num" =~ ^[0-9]+$ ]] || die "bad size: $1 (use 10, 500M, 10G, 2T)"
  case "$unit" in
    M) echo $(( num * 1024 )) ;;
    T) echo $(( num * 1024 * 1024 * 1024 )) ;;
    *) echo $(( num * 1024 * 1024 )) ;;   # G or bare number
  esac
}

human() {
  local b="${1:-0}"
  if   (( b >= 1073741824 )); then awk -v b="$b" 'BEGIN{printf "%.1fT", b/1073741824}'
  elif (( b >= 1048576 ));    then awk -v b="$b" 'BEGIN{printf "%.0fG", b/1048576}'
  elif (( b >= 1024 ));       then awk -v b="$b" 'BEGIN{printf "%.0fM", b/1024}'
  else printf '%dK' "$b"; fi
}

# Reads a password twice without echoing it. Nothing reaches the command line,
# the process table, or shell history.
ask_password() {
  local p1 p2
  read -rs -p "password: " p1 </dev/tty; echo >&2
  [[ -n "$p1" ]] || { echo "empty password" >&2; return 1; }
  read -rs -p "confirm:  " p2 </dev/tty; echo >&2
  [[ "$p1" == "$p2" ]] || { echo "passwords do not match" >&2; return 1; }
  printf '%s' "$p1"
}

gen_password() {
  # unambiguous alphabet: no 0/O/1/l/I, so it survives being read over the phone
  tr -dc 'A-HJ-NP-Za-km-z2-9' </dev/urandom | head -c "$PASS_LENGTH"
}

# --------------------------------------------------------------- fs helpers
fs_type()  { findmnt -no FSTYPE --target "$1" || die "no filesystem for $1"; }
fs_mount() { findmnt -no TARGET --target "$1" || die "no mountpoint for $1"; }

user_base() {
  local h; h=$(getent passwd "$1" | cut -d: -f6) || true
  [[ -n "$h" ]] || die "user $1 not found"
  dirname "$h"
}

# With the ext4 quota feature the kernel enables quotas at mount time and
# quotaon is no longer the mechanism, so 'quotaon -p' misreports. The only
# reliable test is whether quota can actually be queried.
quota_works() {
  local mnt="$1" fst="$2"
  case "$fst" in
    ext2|ext3|ext4)
      repquota -u "$mnt" >/dev/null 2>&1 && return 0
      quotaon -p "$mnt" 2>/dev/null | grep -q 'is on' && return 0
      return 1 ;;
    xfs)
      xfs_quota -x -c 'state -u' "$mnt" 2>/dev/null | grep -qi 'enforcement: ON' ;;
  esac
}

# Lists mountpoints where quota actually works. Used to turn a dead-end error
# into a usable suggestion.
quota_mounts() {
  local m t
  while read -r m t; do
    case "$t" in ext2|ext3|ext4|xfs) ;; *) continue ;; esac
    quota_works "$m" "$t" && echo "$m"
  done < <(findmnt -rno TARGET,FSTYPE 2>/dev/null)
}

require_quota_active() {
  local mnt="$1" fst="$2"
  case "$fst" in
    ext2|ext3|ext4)
      command -v setquota >/dev/null || die "setquota missing (install package: quota)"
      if ! quota_works "$mnt" "$fst"; then
        warn "user quota is not active on $mnt"
        local candidates; candidates=$(quota_mounts | grep -v '^/$' || true)
        if [[ -n "$candidates" ]]; then
          echo >&2
          echo "  these filesystems DO have quota enabled:" >&2
          echo "$candidates" | sed 's/^/    /' >&2
          echo >&2
          echo "  point this account at one of them:" >&2
          echo "    $0 add <user> <size> --base=$(echo "$candidates" | head -1) ..." >&2
          echo >&2
          echo "  or make it the default so you can drop --base:" >&2
          echo "    $0 config init" >&2
          echo "    then set DEFAULT_BASE=\"$(echo "$candidates" | head -1)\" in $CONFIG_FILE" >&2
        elif [[ "$mnt" == "/" ]]; then
          echo >&2
          echo "  $mnt is the root filesystem — quotas cannot be enabled there." >&2
          echo "  create a dedicated filesystem:  $0 provision /srv/sftp <size>" >&2
        else
          echo "  enable it with: $0 setup $mnt" >&2
        fi
        die "aborted — no account was created"
      fi
      ;;
    xfs)
      command -v xfs_quota >/dev/null || die "xfs_quota missing (install: xfsprogs)"
      xfs_quota -x -c 'state -u' "$mnt" 2>/dev/null | grep -qi 'enforcement: ON' \
        || warn "xfs quota enforcement may be off on $mnt"
      ;;
    *) die "unsupported filesystem: $fst" ;;
  esac
}

apply_quota() {
  local u="$1" hard="$2" mnt="$3" fst="$4"
  local soft=$(( hard * SOFT_PCT / 100 ))
  local gb=$(( hard / 1048576 )); (( gb < 1 )) && gb=1
  local ihard=$(( gb * INODES_PER_GB )) isoft
  isoft=$(( ihard * SOFT_PCT / 100 ))
  case "$fst" in
    ext2|ext3|ext4) setquota -u "$u" "$soft" "$hard" "$isoft" "$ihard" "$mnt" ;;
    xfs) xfs_quota -x -c "limit -u bsoft=${soft}k bhard=${hard}k isoft=${isoft} ihard=${ihard} $u" "$mnt" ;;
  esac
  ok "quota: soft $(human "$soft") / hard $(human "$hard"), inodes ${isoft}/${ihard}"
}

# Echoes "used soft hard" in 1K blocks, or nothing if no entry exists.
# repquota is parsed rather than 'quota', because 'quota' prints the DEVICE in
# column 1, not the mount point, so matching on the mount point silently yields
# nothing and every figure reads as zero.
usage_line() {
  local u="$1" mnt="$2" fst="$3"
  case "$fst" in
    ext2|ext3|ext4)
      # repquota inserts a two-character status field ("--", "+-") between the
      # username and the numbers, but only in some versions. Detect it.
      repquota -u "$mnt" 2>/dev/null | awk -v u="$u" '
        $1==u { if ($2 ~ /^[-+][-+]$/) print $3, $4, $5; else print $2, $3, $4; exit }'
      ;;
    xfs)
      xfs_quota -x -c "report -u -N -b" "$mnt" 2>/dev/null \
        | awk -v u="$u" '$1==u {gsub(/[KMGT]$/,"",$2); print $2, $3, $4; exit}'
      ;;
  esac
}

nologin_shell() {
  local c
  for c in /usr/sbin/nologin /sbin/nologin /usr/bin/false /bin/false; do
    [[ -x "$c" ]] && { echo "$c"; return; }
  done
  die "no nologin shell available"
}

pw_status() {   # -> nopass | locked | set | unknown
  local s; s=$(passwd -S "$1" 2>/dev/null | awk '{print $2}')
  case "$s" in
    NP|NNP) echo nopass ;;
    L|LK)   echo locked ;;
    P|PS)   echo set ;;
    *)      echo unknown ;;
  esac
}

set_password() {
  local user="$1" pass="$2"
  # chpasswd reads one user:password line, so a newline in the password would
  # silently truncate it. Everything else -- : @ ! $ quotes -- is fine here.
  [[ "$pass" == *$'\n'* ]] && die "password cannot contain a newline"
  [[ -z "$pass" ]] && die "password cannot be empty"
  # printf, not echo: echo mangles leading dashes and backslash sequences
  printf '%s:%s\n' "$user" "$pass" | chpasswd
  # These accounts have no shell, so the user can never run passwd. Any aging
  # policy that expires the password would lock them out with no way back in.
  chage -M -1 -m 0 -I -1 "$user" 2>/dev/null || true
  ok "password set for $user (expiry disabled — no shell to change it with)"
}

sshd_reload() {
  if sshd -t 2>/dev/null; then
    systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || \
      service ssh reload 2>/dev/null || true
    return 0
  fi
  return 1
}

# =============================================================== volumes
# On a server with many volume groups, guessing is worse than showing.
cmd_volumes() {
  command -v vgs >/dev/null || die "lvm2 not installed — only --loop provisioning is available"
  local auto=""
  auto=$(vgs --noheadings --nosuffix --units b -o vg_name,vg_free 2>/dev/null \
    | awk '{ gsub(/ /,"",$1); if ($2+0 > best) { best=$2+0; name=$1 } } END { if (name) print name }') || true

  echo "volume groups:"
  vgs -o vg_name,vg_size,vg_free,lv_count 2>/dev/null | sed 's/^/  /'
  echo
  [[ -n "$DEFAULT_VG" ]] && echo "  DEFAULT_VG (${CONFIG_FILE}): $DEFAULT_VG"
  [[ -n "$auto"       ]] && echo "  auto-selected (most free space): $auto"
  echo
  echo "existing sftpctl volumes:"
  lvs -o lv_name,vg_name,lv_size --noheadings 2>/dev/null | grep -i sftpdata | sed 's/^/  /' \
    || echo "  none" 
  echo
  echo "pin one with:  $0 provision <mount> <size> --vg=<name>"
  echo "or set DEFAULT_VG in ${CONFIG_FILE} ($0 config init)"
  return 0
}

# ================================================================ config
cmd_config() {
  local action="${1:-show}"
  case "$action" in
    show)
      echo "config file: ${CONFIG_FILE}$( (( CONFIG_LOADED )) && echo " (loaded)" || echo " (not present)")"
      echo
      printf '  %-18s %s\n' "SETTING" "EFFECTIVE VALUE"
      local v
      for v in "${TUNABLES[@]}"; do
        printf '  %-18s %s\n' "$v" "${!v:-(unset)}"
      done
      echo
      echo "precedence: environment > ${CONFIG_FILE} > built-in default"
      return 0 ;;
    init)
      need_root
      [[ -e "$CONFIG_FILE" ]] && die "$CONFIG_FILE already exists — edit it directly"
      local suggested_vg=""
      if command -v vgs >/dev/null; then
        suggested_vg=$(vgs --noheadings --nosuffix --units b -o vg_name,vg_free 2>/dev/null \
          | awk '{ gsub(/ /,"",$1); if ($2+0 > best) { best=$2+0; name=$1 } } END { print name }') || true
      fi
      cat > "$CONFIG_FILE" <<EOF
# /etc/sftpctl.conf — shell syntax, sourced by sftpctl.
# Environment variables override anything set here.

# Volume group used by 'provision'. Without this, the group with the most free
# space is chosen, which on a multi-VG server is rarely the one you meant.
DEFAULT_VG="${suggested_vg:-}"

# Where accounts live. Set this and you can drop --base from every 'add'.
DEFAULT_BASE="${DEFAULT_BASE}"

# Quota applied when 'add' is given no size.
DEFAULT_QUOTA_GB="${DEFAULT_QUOTA_GB}"

# Soft limit as a percentage of the hard limit. The gap is the grace zone.
SOFT_PCT="${SOFT_PCT}"

# Inode cap per GB of quota. Raise for many-small-files workloads.
INODES_PER_GB="${INODES_PER_GB}"

# Generated password length.
PASS_LENGTH="${PASS_LENGTH}"

# Group the sshd Match block targets. Changing this after accounts exist
# orphans them — they stay in the old group and lose the chroot.
SFTP_GROUP="${SFTP_GROUP}"

# Writable directory inside each chroot.
UPLOAD_SUBDIR="${UPLOAD_SUBDIR}"
EOF
      chmod 644 "$CONFIG_FILE"
      ok "wrote $CONFIG_FILE"
      [[ -n "$suggested_vg" ]] && info "DEFAULT_VG pre-filled with '$suggested_vg' — check it with: $0 volumes"
      return 0 ;;
    *) die "usage: $0 config [show|init]" ;;
  esac
}

# =============================================================== volumes end

# ============================================================= provision
# Creates a dedicated filesystem for SFTP accounts, formatted with the ext4
# quota feature already on. Needed when /home is not its own mount — quotas on
# the root filesystem would cap users across /tmp and /var/tmp too, and the
# feature bit cannot be set on a mounted root anyway.
cmd_provision() {
  need_root
  local mountpoint="" size="" mode="auto" want_vg="" a
  for a in "$@"; do
    case "$a" in
      --loop)  mode="loop" ;;
      --lv)    mode="lv" ;;
      --vg=*)  want_vg="${a#*=}"; mode="lv" ;;
      -*)      die "unknown option: $a" ;;
      *) if [[ -z "$mountpoint" ]]; then mountpoint="$a"; else size="$a"; fi ;;
    esac
  done
  [[ -n "$mountpoint" && -n "$size" ]] \
    || die "usage: $0 provision <mountpoint> <size> [--lv|--loop]"
  [[ "$mountpoint" == /* ]] || die "mountpoint must be an absolute path"
  mountpoint -q "$mountpoint" 2>/dev/null && die "$mountpoint is already a mount point"
  [[ "${size^^}" =~ ^[0-9]+[MGT]$ ]] || die "size needs a unit: 200G, 500M, 2T"

  local vg dev

  # Pick the volume group with the MOST free space. Taking the first one listed
  # lands on whichever sorts first, which is rarely the one with room.
  best_vg() {
    command -v vgs >/dev/null || return 0
    vgs --noheadings --nosuffix --units b -o vg_name,vg_free 2>/dev/null \
      | awk '{ gsub(/ /,"",$1); if ($2+0 > best) { best=$2+0; name=$1 } } END { if (name) print name }' || true
  }

  # --vg beats DEFAULT_VG from the config file, which beats auto-selection.
  [[ -z "$want_vg" && -n "$DEFAULT_VG" ]] && { want_vg="$DEFAULT_VG"; mode="lv"
    info "using DEFAULT_VG from ${CONFIG_FILE}: $want_vg"; }

  if [[ -n "$want_vg" ]]; then
    vgs "$want_vg" >/dev/null 2>&1 || {
      warn "no such volume group: $want_vg"
      vgs -o vg_name,vg_size,vg_free 2>/dev/null | sed 's/^/  /' >&2
      die "check the name, or run: $0 volumes"; }
    vg="$want_vg"
  fi

  if [[ "$mode" == "auto" ]]; then
    vg=$(best_vg) || true
    if [[ -n "$vg" ]]; then mode="lv"; else mode="loop"; fi
    info "auto-selected mode: $mode"
  fi

  case "$mode" in
    lv)
      command -v lvcreate >/dev/null || die "lvcreate not found (install: lvm2)"
      vg="${vg:-$(best_vg)}"
      [[ -n "$vg" ]] || die "no volume group found — use --loop instead"

      # Compare in bytes so 'is there room' is answered before lvcreate runs.
      local free_b want_b
      free_b=$(vgs --noheadings --nosuffix --units b -o vg_free "$vg" | tr -d ' ')
      want_b=$(( $(to_blocks "$size") * 1024 ))
      info "volume group $vg has $(human $(( free_b / 1024 ))) free, requesting $(human $(( want_b / 1024 )))"

      if (( want_b > free_b )); then
        warn "not enough space in volume group '$vg'"
        echo >&2
        echo "  volume groups on this system:" >&2
        vgs -o vg_name,vg_size,vg_free 2>/dev/null | sed 's/^/  /' >&2
        echo >&2
        echo "  options:" >&2
        echo "    $0 provision $mountpoint $size --vg=<other-vg>" >&2
        echo "    $0 provision $mountpoint <smaller-size>" >&2
        echo "    $0 provision $mountpoint $size --loop" >&2
        die "aborted — nothing was created"
      fi

      lvcreate -L "$size" -n sftpdata "$vg" || die "lvcreate failed on $vg"
      dev="/dev/${vg}/sftpdata"
      ;;
    loop)
      local img="/var/lib/sftpctl/sftpdata.img"
      mkdir -p "$(dirname "$img")"
      [[ -f "$img" ]] && die "$img already exists"
      info "creating sparse image $img ($size)"
      # sparse: allocates on write, so it does not claim the space up front.
      # That means the host filesystem can still fill underneath it.
      truncate -s "$size" "$img"
      dev="$img"
      ;;
  esac

  info "formatting $dev with the ext4 quota feature"
  mkfs.ext4 -q -O quota -E quotatype=usrquota:grpquota "$dev" \
    || die "mkfs failed"

  mkdir -p "$mountpoint"

  local fstab_line uuid
  if [[ "$mode" == "lv" ]]; then
    uuid=$(blkid -s UUID -o value "$dev")
    fstab_line="UUID=${uuid}  ${mountpoint}  ext4  defaults  0 2"
  else
    fstab_line="${dev}  ${mountpoint}  ext4  defaults,loop  0 2"
  fi

  if grep -qF " ${mountpoint} " /etc/fstab; then
    warn "an fstab entry for $mountpoint already exists — leaving it alone"
  else
    cp -a /etc/fstab "/etc/fstab.bak.$(date +%s)"
    echo "$fstab_line" >> /etc/fstab
    ok "fstab entry added (backup saved)"
  fi

  mount "$mountpoint" || die "mount failed — check /etc/fstab"
  chmod 755 "$mountpoint"

  if quota_works "$mountpoint" ext4; then
    ok "quota active on $mountpoint"
  else
    quotaon -v "$mountpoint" 2>/dev/null || true
    quota_works "$mountpoint" ext4 \
      && ok "quota active on $mountpoint" \
      || warn "quota did not activate — check: repquota -u $mountpoint"
  fi

  df -h "$mountpoint" | tail -1
  echo
  echo "next:"
  echo "  $0 setup $mountpoint --auth=both"
  echo "  $0 add <user> 10 --pass --base=$mountpoint"
  echo
  echo "set DEFAULT_BASE=$mountpoint in your environment to skip --base each time."
}

# ================================================================= setup
cmd_setup() {
  need_root
  local mnt_arg="$DEFAULT_BASE" auth="both" a
  for a in "$@"; do
    case "$a" in
      --auth=*) auth="${a#*=}" ;;
      -*) die "unknown option: $a" ;;
      *) mnt_arg="$a" ;;
    esac
  done
  [[ "$auth" =~ ^(key|password|both)$ ]] || die "--auth must be key, password, or both"

  local mnt fst dev
  mnt=$(fs_mount "$mnt_arg"); fst=$(fs_type "$mnt_arg")
  info "filesystem: $fst at $mnt, auth mode: $auth"

  case "$fst" in
    ext2|ext3|ext4)
      command -v setquota >/dev/null || die "install the 'quota' package first"
      dev=$(findmnt -no SOURCE "$mnt")
      if quota_works "$mnt" "$fst"; then
        ok "quota already active on $mnt"
      elif tune2fs -l "$dev" 2>/dev/null | grep -qi '^Filesystem features.*\bquota\b'; then
        # Feature bit is set, so quotas activate at mount with no fstab option.
        # If they are not live yet the filesystem was almost certainly mounted
        # before the feature was set, or mounted with an explicit noquota.
        info "quota feature present on $dev but not active — remounting $mnt"
        mount -o remount "$mnt" 2>/dev/null || true
        quota_works "$mnt" "$fst" || { quotaon -v "$mnt" 2>/dev/null || true; }
        if quota_works "$mnt" "$fst"; then
          ok "quota enabled on $mnt"
        else
          warn "quota still not active after remount. Try a full cycle:"
          echo "    umount $mnt && mount $mnt" >&2
          echo "  then check:  repquota -u $mnt" >&2
          echo "  if /proc/mounts shows 'noquota' for $mnt, remove it from fstab." >&2
          die "quota not active on $mnt"
        fi
      else
        # The ext4 'quota' feature can only be toggled on an UNMOUNTED
        # filesystem. Legacy external aquota.* files are deprecated and the
        # kernel refuses them on a modern ext4, so there is no online path.
        warn "the ext4 quota feature is not enabled on $dev, and it cannot be"
        warn "turned on while the filesystem is mounted."
        echo
        if [[ "$mnt" == "/" ]]; then
          cat >&2 <<EOF
  $mnt_arg resolves to the root filesystem, so it cannot be unmounted on a
  running system. You also would not want quotas there: they would cap each
  user across /tmp and /var/tmp as well as their upload directory.

  Give the accounts their own filesystem instead:

      sftpctl provision /srv/sftp 200G      # new LV from free VG space
      sftpctl provision /srv/sftp 200G --loop   # image file, if the VG is full
      sftpctl setup /srv/sftp --auth=${auth}
      sftpctl add alice 10 --pass --base=/srv/sftp

  Check free space first with: vgs

  If you must use the root filesystem, boot from rescue media and run
  'tune2fs -O quota -Q usrquota,grpquota $dev' with it unmounted.
EOF
        else
          cat >&2 <<EOF
  $mnt is a separate filesystem, so you can enable the feature offline:

      systemctl stop sshd
      umount $mnt
      tune2fs -O quota -Q usrquota,grpquota $dev
      mount $mnt
      systemctl start sshd
      sftpctl setup $mnt --auth=${auth}

  No fstab change is needed afterwards — the ext4 quota feature activates
  automatically at mount.
EOF
        fi
        die "quota not enabled — nothing was changed"
      fi
      ;;
    xfs)
      if xfs_quota -x -c 'state -u' "$mnt" 2>/dev/null | grep -qi 'enforcement: ON'; then
        ok "xfs quota enforcing on $mnt"
      else
        warn "XFS enables quota only at mount time and cannot be switched on live."
        echo "  add 'uquota' to the $mnt fstab entry, then umount/mount (remount will NOT work)."
        echo "  if $mnt is /, add rootflags=uquota to the kernel cmdline and reboot."
      fi
      ;;
    *) die "unsupported filesystem: $fst" ;;
  esac

  groupadd -f "$SFTP_GROUP"; ok "group $SFTP_GROUP present"

  # Auth directives inside Match apply ONLY to this group, so a hardened global
  # 'PasswordAuthentication no' stays in force for every other account.
  local pw_lines=""
  case "$auth" in
    key)      pw_lines="    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PubkeyAuthentication yes" ;;
    password) pw_lines="    PasswordAuthentication yes
    KbdInteractiveAuthentication yes
    PubkeyAuthentication no" ;;
    both)     pw_lines="    PasswordAuthentication yes
    KbdInteractiveAuthentication yes
    PubkeyAuthentication yes" ;;
  esac

  if [[ -f "$SSHD_DROPIN" ]]; then
    warn "drop-in exists: $SSHD_DROPIN"
    cp -a "$SSHD_DROPIN" "${SSHD_DROPIN}.bak.$(date +%s)"
    info "backed up before rewriting"
  fi

  mkdir -p "$(dirname "$SSHD_DROPIN")"
  cat > "$SSHD_DROPIN" <<EOF
# managed by sftpctl — auth mode: ${auth}
Subsystem sftp internal-sftp

Match Group ${SFTP_GROUP}
    ChrootDirectory %h
    ForceCommand internal-sftp -u 0022
${pw_lines}
    AuthenticationMethods any
    AllowTcpForwarding no
    AllowAgentForwarding no
    X11Forwarding no
    PermitTTY no
EOF
  chmod 644 "$SSHD_DROPIN"

  grep -qs 'sshd_config.d' /etc/ssh/sshd_config \
    || warn "sshd_config may not Include sshd_config.d/*.conf — verify, or the drop-in is ignored"

  if sshd_reload; then
    ok "sshd configured and reloaded ($SSHD_DROPIN)"
  else
    local bak; bak=$(ls -t "${SSHD_DROPIN}".bak.* 2>/dev/null | head -1 || true)
    if [[ -n "$bak" ]]; then mv "$bak" "$SSHD_DROPIN"; else rm -f "$SSHD_DROPIN"; fi
    die "sshd config test failed — reverted, nothing changed"
  fi

  if [[ "$auth" != "key" ]]; then
    grep -qs '^[[:space:]]*PasswordAuthentication[[:space:]]\+no' \
      /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null \
      && info "global PasswordAuthentication is off; the Match block re-enables it for $SFTP_GROUP only"
  fi
  echo
  echo "ready. create accounts with: $0 add <user> [size] [--pass] [--key=...]"
}

# =================================================================== add
cmd_add() {
  need_root
  local user="" size="$DEFAULT_QUOTA_GB" base="$DEFAULT_BASE"
  local want_pass=0 ask_pass=0 pass="" pubkey="" expire="" positional=0 a

  for a in "$@"; do
    case "$a" in
      --pass)      want_pass=1 ;;
      --pass=*)    want_pass=1; pass="${a#*=}" ;;
      --ask)       want_pass=1; ask_pass=1 ;;
      --key=*)     pubkey="${a#*=}" ;;
      --base=*)    base="${a#*=}" ;;
      --expire=*)  expire="${a#*=}" ;;
      -*)          die "unknown option: $a" ;;
      *)  if   (( positional == 0 )); then user="$a"
          elif (( positional == 1 )); then size="$a"
          else die "unexpected argument: $a"; fi
          positional=$(( positional + 1 )) ;;
    esac
  done

  [[ -n "$user" ]] || die "usage: $0 add <user> [size] [--pass[=SECRET]] [--key=...]"
  [[ "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "invalid username: $user"
  id "$user" &>/dev/null && die "user $user exists (use 'quota' or 'passwd' to modify)"

  # An account nobody can log into is almost never what was intended.
  if (( want_pass == 0 )) && [[ -z "$pubkey" ]]; then
    warn "no --pass and no --key: the account will have no way to authenticate."
    warn "add credentials later with '$0 passwd $user' or '$0 addkey $user ...'"
  fi

  local home="${base}/${user}" upload="${base}/${user}/${UPLOAD_SUBDIR}"
  local mnt fst hard shell
  mnt=$(fs_mount "$base"); fst=$(fs_type "$base")
  require_quota_active "$mnt" "$fst"
  hard=$(to_blocks "$size"); shell=$(nologin_shell)

  grep -qs 'internal-sftp' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf \
    || warn "no internal-sftp directive found — run '$0 setup' or logins will fail"

  info "creating $user ($(human "$hard") on $mnt, $fst)"
  groupadd -f "$SFTP_GROUP"
  # -M: the chroot root must be root-owned, so the tree is built by hand
  useradd -M -d "$home" -s "$shell" -G "$SFTP_GROUP" "$user"
  if [[ -n "$expire" ]]; then
    chage -E "$(date -d "+${expire} days" +%Y-%m-%d)" "$user"
    ok "account expires in ${expire} days"
  fi

  mkdir -p "$upload"
  # ChrootDirectory requires root ownership and no group/world write on the
  # directory and every parent, or sshd refuses the session.
  chown root:root "$home"; chmod 755 "$home"
  chown "${user}:${user}" "$upload"; chmod 700 "$upload"

  local ssh_dir="${home}/.ssh"
  mkdir -p "$ssh_dir"; touch "${ssh_dir}/authorized_keys"
  chown -R "${user}:${user}" "$ssh_dir"
  chmod 700 "$ssh_dir"; chmod 600 "${ssh_dir}/authorized_keys"

  local shown_pass=""
  if (( want_pass )); then
    if (( ask_pass )); then
      pass=$(ask_password) || { userdel "$user" 2>/dev/null; die "aborted"; }
    elif [[ -z "$pass" ]]; then
      pass=$(gen_password); shown_pass="$pass"
    fi
    set_password "$user" "$pass"
  else
    passwd -l "$user" >/dev/null
    ok "password locked (key authentication only)"
  fi

  [[ -n "$pubkey" ]] && cmd_addkey "$user" "$pubkey"

  apply_quota "$user" "$hard" "$mnt" "$fst"

  local hn; hn=$(hostname -f 2>/dev/null || hostname)
  echo
  echo "${C_BLD}account ready${C_OFF}"
  printf '  %-10s %s\n' "host" "$hn"
  printf '  %-10s %s\n' "user" "$user"
  [[ -n "$shown_pass" ]] && printf '  %-10s %s%s%s\n' "password" "$C_BLD" "$shown_pass" "$C_OFF"
  printf '  %-10s %s/\n' "path" "$UPLOAD_SUBDIR"
  cat <<EOF

  scp file.tar ${user}@${hn}:${UPLOAD_SUBDIR}/
  sftp ${user}@${hn}

  the target is '${UPLOAD_SUBDIR}/' relative to the chroot, not a server path.
EOF
  [[ -n "$shown_pass" ]] && \
    warn "this password is shown once — it is hashed on disk and cannot be recovered"
  return 0
}

# ================================================================= passwd
cmd_passwd() {
  need_root
  local user="${1:?usage: $0 passwd <user> [--ask|--stdin|--gen|--lock|--unlock|PASSWORD]}"
  local arg="${2:-}"
  id "$user" &>/dev/null || die "no such user: $user"
  local home; home=$(getent passwd "$user" | cut -d: -f6)

  case "$arg" in
    --lock)
      passwd -l "$user" >/dev/null
      ok "$user password locked (key auth still works if a key is authorized)"
      [[ -s "${home}/.ssh/authorized_keys" ]] \
        || warn "$user has no authorized keys either — the account is now unreachable"
      return 0 ;;
    --unlock)
      [[ "$(pw_status "$user")" == "locked" ]] || { ok "$user is not locked"; return 0; }
      passwd -u "$user" >/dev/null 2>&1 \
        || die "no password hash to unlock — set one with: $0 passwd $user --gen"
      ok "$user password unlocked"; return 0 ;;
    --ask)
      local p; p=$(ask_password) || die "aborted"
      set_password "$user" "$p"
      ok "password updated for $user"
      return 0 ;;
    --stdin)
      local p; IFS= read -r p || true
      [[ -n "$p" ]] || die "no password on stdin"
      set_password "$user" "$p"
      ok "password updated for $user"
      return 0 ;;
    --gen|"")
      local p; p=$(gen_password)
      set_password "$user" "$p"
      echo
      printf '  %-10s %s\n'     "user"     "$user"
      printf '  %-10s %s%s%s\n' "password" "$C_BLD" "$p" "$C_OFF"
      echo
      warn "shown once — stored only as a hash"
      return 0 ;;
    -*) die "unknown option: $arg" ;;
    *)
      [[ ${#arg} -ge 8 ]] || warn "that password is under 8 characters"
      set_password "$user" "$arg"
      warn "a password on the command line lands in shell history and the process"
      warn "table. Use '--ask' to be prompted instead."
      return 0 ;;
  esac
}

# ================================================================ addkey
cmd_addkey() {
  need_root
  local user="${1:?usage: $0 addkey <user> <pubkey|file|->}"; shift
  id "$user" &>/dev/null || die "no such user: $user"
  local src="$*" key

  if   [[ "$src" == "-" ]]; then key=$(cat)
  elif [[ -f "$src" ]];      then key=$(<"$src")
  else key="$src"; fi

  key=$(echo "$key" | tr -d '\r' | sed '/^[[:space:]]*$/d')
  [[ "$key" =~ ^(ssh-(rsa|ed25519|dss)|ecdsa-sha2|sk-) ]] \
    || die "that does not look like an OpenSSH public key"

  local home ak
  home=$(getent passwd "$user" | cut -d: -f6)
  ak="${home}/.ssh/authorized_keys"
  mkdir -p "$(dirname "$ak")"; touch "$ak"

  if grep -qxF "$key" "$ak"; then ok "key already authorized for $user"
  else echo "$key" >> "$ak"; ok "key added for $user"; fi

  chown -R "${user}:${user}" "$(dirname "$ak")"
  chmod 700 "$(dirname "$ak")"; chmod 600 "$ak"
}

cmd_delkey() {
  need_root
  local user="${1:?usage: $0 delkey <user> [match]}" match="${2:-}"
  id "$user" &>/dev/null || die "no such user: $user"
  local ak; ak="$(getent passwd "$user" | cut -d: -f6)/.ssh/authorized_keys"
  [[ -f "$ak" ]] || { ok "no authorized_keys file for $user"; return 0; }

  if [[ -z "$match" ]]; then
    nl -ba "$ak"; echo
    read -r -p "line number to delete (blank to cancel): " n
    [[ -n "$n" ]] || { echo "cancelled"; return 0; }
    sed -i "${n}d" "$ak"; ok "line $n removed"
  else
    grep -qF "$match" "$ak" || die "no key matching '$match'"
    grep -vF "$match" "$ak" > "${ak}.tmp" && mv "${ak}.tmp" "$ak"
    chown "${user}:${user}" "$ak"; chmod 600 "$ak"
    ok "removed key(s) matching '$match'"
  fi
  [[ -s "$ak" ]] || [[ "$(pw_status "$user")" == "set" ]] \
    || warn "$user now has no keys and no password — the account is unreachable"
  return 0
}

# ================================================================== show
cmd_show() {
  local user="${1:?usage: $0 show <user>}"
  id "$user" &>/dev/null || die "no such user: $user"
  local base mnt fst home used soft hard pct=0 nkeys=0 pws expiry
  base=$(user_base "$user"); home=$(getent passwd "$user" | cut -d: -f6)
  mnt=$(fs_mount "$base"); fst=$(fs_type "$base")
  read -r used soft hard <<<"$(usage_line "$user" "$mnt" "$fst")"
  used="${used:-0}"; soft="${soft:-0}"; hard="${hard:-0}"
  (( hard > 0 )) && pct=$(( used * 100 / hard ))
  [[ -f "${home}/.ssh/authorized_keys" ]] && \
    nkeys=$(grep -cE '^(ssh-|ecdsa-|sk-)' "${home}/.ssh/authorized_keys" 2>/dev/null || true)
  nkeys="${nkeys:-0}"
  pws=$(pw_status "$user")
  expiry=$(chage -l "$user" 2>/dev/null | awk -F': ' '/Account expires/{print $2}')

  local auth=""
  [[ "$pws" == "set" ]] && auth="password"
  (( nkeys > 0 )) && auth="${auth:+$auth + }key (${nkeys})"
  [[ -z "$auth" ]] && auth="${C_RED}none — unreachable${C_OFF}"

  printf '%-12s %s\n' "user"     "$user"
  printf '%-12s %s\n' "home"     "$home"
  printf '%-12s %s\n' "shell"    "$(getent passwd "$user" | cut -d: -f7)"
  printf '%-12s %s\n' "auth"     "$auth"
  printf '%-12s %s\n' "password" "$pws"
  printf '%-12s %s\n' "expires"  "${expiry:-never}"
  printf '%-12s %s / %s  (%s%%, soft %s)\n' "usage" \
    "$(human "$used")" "$(human "$hard")" "$pct" "$(human "$soft")"
  (( pct >= 90 )) && warn "$user is at ${pct}% of quota"
  return 0
}

# ================================================================== list
cmd_list() {
  local members u base mnt fst used soft hard
  members=$(getent group "$SFTP_GROUP" | cut -d: -f4 | tr ',' ' ')
  [[ -n "${members// }" ]] || { echo "no members in group $SFTP_GROUP"; return 0; }

  printf '%-16s %8s %8s %6s %-10s %s\n' USER USED QUOTA PCT AUTH HOME
  for u in $members; do
    base=$(user_base "$u" 2>/dev/null) || continue
    mnt=$(fs_mount "$base"); fst=$(fs_type "$base")
    read -r used soft hard <<<"$(usage_line "$u" "$mnt" "$fst")"
    used="${used:-0}"; hard="${hard:-0}"
    local pct=0; (( hard > 0 )) && pct=$(( used * 100 / hard ))
    local home nkeys=0 pws auth
    home=$(getent passwd "$u" | cut -d: -f6)
    [[ -f "${home}/.ssh/authorized_keys" ]] && \
      nkeys=$(grep -cE '^(ssh-|ecdsa-|sk-)' "${home}/.ssh/authorized_keys" 2>/dev/null || true)
    nkeys="${nkeys:-0}"
    pws=$(pw_status "$u")
    if   [[ "$pws" == "set" ]] && (( nkeys > 0 )); then auth="pass+key"
    elif [[ "$pws" == "set" ]];                   then auth="password"
    elif (( nkeys > 0 ));                          then auth="key"
    else auth="NONE"; fi
    local flag=""
    (( pct >= 90 )) && flag="${C_RED} <-- near limit${C_OFF}"
    [[ "$auth" == "NONE" ]] && flag="${flag}${C_YEL} <-- no credentials${C_OFF}"
    printf '%-16s %8s %8s %5s%% %-10s %s%s\n' \
      "$u" "$(human "$used")" "$(human "$hard")" "$pct" "$auth" "$home" "$flag"
  done
}

# ================================================================= quota
cmd_quota() {
  need_root
  local user="${1:?usage: $0 quota <user> <size>}" size="${2:?usage: $0 quota <user> <size>}"
  id "$user" &>/dev/null || die "no such user: $user"
  local base mnt fst hard used
  base=$(user_base "$user"); mnt=$(fs_mount "$base"); fst=$(fs_type "$base")
  require_quota_active "$mnt" "$fst"
  hard=$(to_blocks "$size")

  read -r used _ _ <<<"$(usage_line "$user" "$mnt" "$fst")"; used="${used:-0}"
  if (( used > hard )); then
    warn "$user already holds $(human "$used"), above the new $(human "$hard") limit."
    warn "existing files are kept, but writes fail until they delete something."
  fi
  apply_quota "$user" "$hard" "$mnt" "$fst"
  echo; cmd_show "$user"
}

# ====================================================== disable / enable
cmd_disable() {
  need_root
  local user="${1:?usage: $0 disable <user>}"
  id "$user" &>/dev/null || die "no such user: $user"
  usermod -L "$user" 2>/dev/null || true
  local ak; ak="$(getent passwd "$user" | cut -d: -f6)/.ssh/authorized_keys"
  [[ -f "$ak" && -s "$ak" ]] && mv "$ak" "${ak}.disabled"
  ok "$user disabled — password locked, keys parked, data untouched"
}

cmd_enable() {
  need_root
  local user="${1:?usage: $0 enable <user>}"
  id "$user" &>/dev/null || die "no such user: $user"
  local ak; ak="$(getent passwd "$user" | cut -d: -f6)/.ssh/authorized_keys"
  if [[ -f "${ak}.disabled" ]]; then
    mv "${ak}.disabled" "$ak"; chown "${user}:${user}" "$ak"; chmod 600 "$ak"
  fi
  if passwd -u "$user" >/dev/null 2>&1; then
    ok "$user enabled (password and keys restored)"
  else
    ok "$user keys restored"
    [[ -s "$ak" ]] || warn "no password hash and no keys — set one with: $0 passwd $user"
  fi
  return 0
}

# ================================================================ remove
cmd_remove() {
  need_root
  local user="${1:?usage: $0 remove <user> [--purge]}" purge="${2:-}"
  id "$user" &>/dev/null || die "no such user: $user"
  local home base mnt fst used
  home=$(getent passwd "$user" | cut -d: -f6)
  base=$(user_base "$user"); mnt=$(fs_mount "$base"); fst=$(fs_type "$base")
  read -r used _ _ <<<"$(usage_line "$user" "$mnt" "$fst")"

  echo "removing $user (home $home, holding $(human "${used:-0}"))"
  if [[ "$purge" == "--purge" ]]; then
    echo "${C_RED}--purge: the home directory and all data will be deleted.${C_OFF}"
  else
    echo "data will be KEPT at $home (pass --purge to delete it)"
  fi
  read -r -p "type the username to confirm: " confirm
  [[ "$confirm" == "$user" ]] || die "aborted"

  # zero the quota first, or the limit lingers against a freed UID and the next
  # account to reuse that UID silently inherits it
  case "$fst" in
    ext2|ext3|ext4) setquota -u "$user" 0 0 0 0 "$mnt" 2>/dev/null || true ;;
    xfs) xfs_quota -x -c "limit -u bsoft=0 bhard=0 isoft=0 ihard=0 $user" "$mnt" 2>/dev/null || true ;;
  esac

  if [[ "$purge" == "--purge" ]]; then
    userdel -r "$user" 2>/dev/null || { userdel "$user"; rm -rf "$home"; }
    ok "$user removed, data deleted"
  else
    userdel "$user"; ok "$user removed, data left at $home"
  fi
}

# ================================================================= check
cmd_check() {
  local issues=0 u
  info "sshd configuration"
  if grep -qs 'internal-sftp' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; then
    ok "internal-sftp directive found"
  else warn "no internal-sftp directive — SFTP logins will fail"; issues=$(( issues + 1 )); fi

  sshd -t 2>/dev/null && ok "sshd config syntax valid" \
    || { warn "sshd config test FAILED"; issues=$(( issues + 1 )); }

  # passwords enabled for the group while PAM is off is a common silent failure
  if grep -qs 'PasswordAuthentication yes' "$SSHD_DROPIN" 2>/dev/null; then
    ok "passwords enabled for $SFTP_GROUP"
    grep -qs '^[[:space:]]*UsePAM[[:space:]]\+no' /etc/ssh/sshd_config \
      && { warn "UsePAM no may block password auth on some distros"; issues=$(( issues + 1 )); }
  fi

  info "accounts"
  local members; members=$(getent group "$SFTP_GROUP" | cut -d: -f4 | tr ',' ' ')
  for u in $members; do
    local home owner perms shell nkeys=0 pws
    home=$(getent passwd "$u" | cut -d: -f6)
    owner=$(stat -c '%U:%G' "$home" 2>/dev/null || echo MISSING)
    perms=$(stat -c '%a' "$home" 2>/dev/null || echo "")
    if [[ "$owner" != "root:root" ]]; then
      warn "$u: chroot $home owned by $owner — sshd requires root:root"; issues=$(( issues + 1 ))
    elif [[ "${perms: -1}" =~ [2367] || "${perms: -2:1}" =~ [2367] ]]; then
      warn "$u: chroot $home is mode $perms — group/world write breaks chroot"; issues=$(( issues + 1 ))
    else ok "$u: chroot permissions correct"; fi

    shell=$(getent passwd "$u" | cut -d: -f7)
    [[ "$shell" =~ (nologin|false)$ ]] || { warn "$u: shell is $shell, not nologin"; issues=$(( issues + 1 )); }

    [[ -f "${home}/.ssh/authorized_keys" ]] && \
      nkeys=$(grep -cE '^(ssh-|ecdsa-|sk-)' "${home}/.ssh/authorized_keys" 2>/dev/null || true)
    nkeys="${nkeys:-0}"
    pws=$(pw_status "$u")
    if [[ "$pws" != "set" ]] && (( nkeys == 0 )); then
      warn "$u: no password and no keys — cannot log in"; issues=$(( issues + 1 ))
    fi
    # a password that expires locks out an account with no shell to change it
    if [[ "$pws" == "set" ]]; then
      chage -l "$u" 2>/dev/null | grep -q 'Password expires.*never' \
        || { warn "$u: password expiry is set, but this account has no shell to change it"; issues=$(( issues + 1 )); }
    fi
  done

  info "quota"
  local mnt fst; mnt=$(fs_mount "$DEFAULT_BASE"); fst=$(fs_type "$DEFAULT_BASE")
  quota_works "$mnt" "$fst" && ok "quota active on $mnt ($fst)" \
    || { warn "quota not active on $mnt"; issues=$(( issues + 1 )); }

  echo
  (( issues == 0 )) && ok "no problems found" || warn "$issues issue(s) found"
  return 0
}

# ================================================================== main
usage() { sed -n '3,29p' "$0" | sed 's/^#\ \?//'; exit 1; }

cmd="${1:-}"; shift || true
case "$cmd" in
  provision) cmd_provision "$@" ;;
  volumes|vgs) cmd_volumes "$@" ;;
  config)  cmd_config  "$@" ;;
  setup)   cmd_setup   "$@" ;;
  add)     cmd_add     "$@" ;;
  quota)   cmd_quota   "$@" ;;
  passwd)  cmd_passwd  "$@" ;;
  addkey)  cmd_addkey  "$@" ;;
  delkey)  cmd_delkey  "$@" ;;
  list)    cmd_list    "$@" ;;
  show)    cmd_show    "$@" ;;
  disable) cmd_disable "$@" ;;
  enable)  cmd_enable  "$@" ;;
  remove)  cmd_remove  "$@" ;;
  check)   cmd_check   "$@" ;;
  ""|-h|--help|help) usage ;;
  *) die "unknown command: $cmd (try --help)" ;;
esac
