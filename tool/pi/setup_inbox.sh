#!/usr/bin/env bash
# Samba share "inbox" for the PC (story 4-5). Run on the Pi:
#   sudo bash ~/tvsaver/pi/setup_inbox.sh [--dry-run]
#
# Idempotent: a second run reports "no changes". Never prints a password.
# Files dropped in the share land in ~/tvsaver/inbox, where the tvsaver
# service imports them once they stop changing (rejects go to inbox/rejected
# with a .txt that says why).
#
# After the first run, set the share password once (it is not stored here):
#   sudo smbpasswd -a allramest

set -eu
set -o pipefail

DRY=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY=1 ;;
  *) echo "usage: sudo bash setup_inbox.sh [--dry-run]" >&2; exit 2 ;;
esac

if [ "$(id -u)" != 0 ] && [ -z "${TVSAVER_TEST:-}" ]; then
  echo "run with sudo: sudo bash $0" >&2
  exit 1
fi

OWNER="${TVSAVER_OWNER:-allramest}"
INBOX="${TVSAVER_INBOX_DIR:-/home/$OWNER/tvsaver/inbox}"
SMB_CONF="${TVSAVER_SMB_CONF:-/etc/samba/smb.conf}"
BEGIN="# BEGIN tvsaver inbox"
END="# END tvsaver inbox"
CHANGES=0

say() { echo "$*"; }
planned() { CHANGES=$((CHANGES + 1)); if [ "$DRY" = 1 ]; then say "[dry-run] would: $*"; else say "$*"; fi; }

block() {
  cat <<EOF
$BEGIN
[inbox]
   comment = TV Saver inbox: drop photos and videos here
   path = $INBOX
   browseable = yes
   read only = no
   guest ok = no
   valid users = $OWNER
   force user = $OWNER
   create mask = 0644
   directory mask = 0755
$END
EOF
}

# 1. Samba itself.
if ! command -v smbd >/dev/null 2>&1 && [ -z "${TVSAVER_TEST:-}" ]; then
  planned "install samba (apt)"
  if [ "$DRY" = 0 ]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y samba
  fi
fi

# 2. The folder.
if [ ! -d "$INBOX" ]; then
  planned "create $INBOX owned by $OWNER"
  if [ "$DRY" = 0 ]; then
    mkdir -p "$INBOX"
    chown "$OWNER:$OWNER" "$INBOX" 2>/dev/null || true
  fi
fi

# 3. The share block in smb.conf (replaced as a whole when it differs).
want="$(block)"
have=""
if [ -r "$SMB_CONF" ]; then
  have="$(sed -n "/^$BEGIN\$/,/^$END\$/p" "$SMB_CONF")"
fi
if [ "$have" != "$want" ]; then
  planned "write the [inbox] share into $SMB_CONF"
  if [ "$DRY" = 0 ]; then
    tmp="$(mktemp)"
    if [ -r "$SMB_CONF" ]; then
      sed "/^$BEGIN\$/,/^$END\$/d" "$SMB_CONF" >"$tmp"
    fi
    printf '\n%s\n' "$want" >>"$tmp"
    install -m 0644 "$tmp" "$SMB_CONF"
    rm -f "$tmp"
  fi
fi

# 4. Reload.
if [ "$CHANGES" -gt 0 ] && [ "$DRY" = 0 ] && [ -z "${TVSAVER_TEST:-}" ]; then
  systemctl enable --now smbd >/dev/null 2>&1 || true
  systemctl restart smbd
  say "smbd restarted"
fi

if [ "$CHANGES" = 0 ]; then
  say "no changes"
else
  say "done: $CHANGES change(s)."
  say "Set the share password once:  sudo smbpasswd -a $OWNER"
  say "Windows: open \\\\gemini-pi.local\\inbox and sign in as $OWNER."
fi
