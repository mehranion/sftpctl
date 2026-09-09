#!/usr/bin/env bash
#
# install.sh — install sftpctl, its man page, and shell completion
#
#   sudo ./install.sh              install or upgrade
#   sudo ./install.sh --uninstall  remove (leaves /etc/sftpctl.conf and accounts)
#
set -euo pipefail

BIN=/usr/local/sbin/sftpctl
MAN=/usr/share/man/man8/sftpctl.8
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }

# bash-completion looks in different places depending on the distro and version
comp_dir() {
  local d
  for d in /usr/share/bash-completion/completions /etc/bash_completion.d; do
    [[ -d "$d" ]] && { echo "$d"; return; }
  done
  echo /etc/bash_completion.d
}

if [[ "${1:-}" == "--uninstall" ]]; then
  rm -f "$BIN" "$MAN" "$MAN.gz" "$(comp_dir)/sftpctl"
  command -v mandb >/dev/null && mandb -q 2>/dev/null || true
  echo "removed sftpctl, man page, and completion"
  echo "left in place: /etc/sftpctl.conf, accounts, provisioned volumes, sshd drop-in"
  exit 0
fi

for f in sftpctl.sh sftpctl.8 sftpctl.bash-completion; do
  [[ -f "$SRC/$f" ]] || { echo "missing $f in $SRC" >&2; exit 1; }
done

bash -n "$SRC/sftpctl.sh" || { echo "sftpctl.sh has a syntax error — refusing to install" >&2; exit 1; }

install -Dm 750 "$SRC/sftpctl.sh" "$BIN"
echo "installed $BIN"

install -Dm 644 "$SRC/sftpctl.8" "$MAN"
# distros differ on whether pages are stored compressed; mandb copes with either
command -v gzip >/dev/null && { gzip -f "$MAN"; MAN="$MAN.gz"; }
echo "installed $MAN"
command -v mandb >/dev/null && mandb -q 2>/dev/null || true

CDIR="$(comp_dir)"
install -Dm 644 "$SRC/sftpctl.bash-completion" "$CDIR/sftpctl"
echo "installed $CDIR/sftpctl"

echo
echo "  man sftpctl                 full manual"
echo "  sftpctl --help              command summary"
echo "  sudo sftpctl config init    create /etc/sftpctl.conf"
echo
echo "completion applies to new shells; for this one:"
echo "  source $CDIR/sftpctl"

MISSING=()
command -v setquota >/dev/null || MISSING+=("quota")
command -v sshd     >/dev/null || MISSING+=("openssh-server")
command -v vgs      >/dev/null || MISSING+=("lvm2 (only needed for provision --lv)")
if (( ${#MISSING[@]} )); then
  echo
  echo "missing packages: ${MISSING[*]}"
fi
