#!/usr/bin/env bash
# BackupKit - scripts/uninstall.sh
#
# Removes the program files and the cron entries.
#
#   sudo ./scripts/uninstall.sh            remove the program and the cron file
#   sudo ./scripts/uninstall.sh --purge    ALSO delete config, state and logs
#
# --purge destroys the local manifest store and, with it, the local record of
# what exists in object storage, and the age key. The prompt requires the exact
# word "yes". Backups in object storage are never deleted by this script.

set -o pipefail

LIB_DIR="/usr/local/lib/backupkit"
BIN_LINK="/usr/local/bin/backupkit"
ETC_DIR="/etc/backupkit"
STATE_DIR="/var/lib/backupkit"
LOG_DIR="/var/log/backupkit"
CRON_FILE="/etc/cron.d/backupkit"
PURGE=0
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: sudo ./scripts/uninstall.sh [--purge] [--dry-run] [--lib DIR] [--bin PATH]

  --purge     also remove /etc/backupkit, /var/lib/backupkit and /var/log/backupkit
  --dry-run   print what would be removed
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --purge)   PURGE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --lib)     LIB_DIR="${2-}"; shift 2 ;;
    --bin)     BIN_LINK="${2-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'uninstall.sh: unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}
as_root() {
  if [ "$(id -u)" = "0" ]; then run "$@"; else run sudo "$@"; fi
}

# ---------------------------------------------------------------------------
# Cron entries: only if the file is ours.
# ---------------------------------------------------------------------------
if [ -f "$CRON_FILE" ]; then
  if grep -q 'Managed by BackupKit' "$CRON_FILE" 2>/dev/null; then
    as_root rm -f "$CRON_FILE"
    printf 'removed cron entries: %s\n' "$CRON_FILE"
  else
    printf 'kept %s: it was not created by BackupKit\n' "$CRON_FILE"
  fi
else
  printf 'no cron file at %s\n' "$CRON_FILE"
fi

# ---------------------------------------------------------------------------
# Program files
# ---------------------------------------------------------------------------
if [ -L "$BIN_LINK" ] || [ -f "$BIN_LINK" ]; then
  as_root rm -f "$BIN_LINK"
  printf 'removed launcher: %s\n' "$BIN_LINK"
fi

if [ -d "$LIB_DIR" ]; then
  as_root rm -rf "$LIB_DIR"
  printf 'removed program files: %s\n' "$LIB_DIR"
fi

# ---------------------------------------------------------------------------
# Optional purge
# ---------------------------------------------------------------------------
if [ "$PURGE" = "1" ]; then
  printf '\nThis will DELETE the configuration, the local manifest store and the logs:\n'
  printf '  %s\n  %s\n  %s\n' "$ETC_DIR" "$STATE_DIR" "$LOG_DIR"
  printf 'WARNING: the age private key lives in %s/age.key. Without it the\n' "$ETC_DIR"
  printf 'backups already in object storage CANNOT be decrypted or restored.\n'
  printf 'Backups in object storage are not touched by this script; use\n'
  printf "'backupkit cleanup' before uninstalling if you want them removed.\n\n"

  if [ "$DRY_RUN" = "1" ]; then
    printf '[dry-run] would remove the directories above\n'
  else
    printf 'Type exactly "yes" to continue: '
    read -r answer
    if [ "$answer" = "yes" ]; then
      for d in "$ETC_DIR" "$STATE_DIR" "$LOG_DIR"; do
        [ -d "$d" ] && as_root rm -rf "$d" && printf 'removed %s\n' "$d"
      done
    else
      printf 'purge cancelled; configuration and state were kept\n'
    fi
  fi
else
  printf '\nconfiguration, state and logs were kept:\n  %s\n  %s\n  %s\n' "$ETC_DIR" "$STATE_DIR" "$LOG_DIR"
  printf 're-installing later restores the previous behaviour without reconfiguration\n'
fi
