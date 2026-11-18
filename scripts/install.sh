#!/usr/bin/env bash
# BackupKit - scripts/install.sh
#
# Installs BackupKit on a Debian/Ubuntu (or any Linux with bash) host.
#
#   sudo ./scripts/install.sh                 install files, check dependencies
#   sudo ./scripts/install.sh --deps          also install packages with apt
#   ./scripts/install.sh --prefix ~/.local --no-sudo   user-level install
#   ./scripts/install.sh --dry-run            show what would happen
#
# The installer never writes to /etc/backupkit or /var/lib/backupkit if they
# already exist: configuration and state are always preserved.

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PREFIX="/usr/local"
LIB_DIR="/usr/local/lib/backupkit"
ETC_DIR="/etc/backupkit"
STATE_DIR="/var/lib/backupkit"
LOG_DIR="/var/log/backupkit"
INSTALL_DEPS=0
DRY_RUN=0
NO_SUDO=0

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Options:
  --prefix DIR      install the launcher under DIR/bin (default /usr/local)
  --lib DIR         install the program files to DIR (default /usr/local/lib/backupkit)
  --deps            install missing packages with apt-get
  --no-sudo         do not use sudo (for user level installs)
  --dry-run         print the actions without performing them
  -h, --help        this help
EOF
}

log() { printf '%s\n' "$*"; }
run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}
as_root() {
  if [ "$NO_SUDO" = "1" ] || [ "$(id -u)" = "0" ]; then
    run "$@"
  else
    run sudo "$@"
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix)  PREFIX="${2-}"; shift 2 ;;
    --lib)     LIB_DIR="${2-}"; shift 2 ;;
    --deps)    INSTALL_DEPS=1; shift ;;
    --no-sudo) NO_SUDO=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'install.sh: unknown option: %s\n' "$1" >&2; usage; exit 2 ;;
  esac
done

# A user-level install (--prefix in $HOME) should not need root at all.
case "$PREFIX" in
  "$HOME"*) NO_SUDO=1 ;;
esac

log "BackupKit installer"
log "  repo    : $REPO_ROOT"
log "  lib     : $LIB_DIR"
log "  launcher: $PREFIX/bin/backupkit"
log "  config  : $ETC_DIR (left untouched if present)"
log ""

# ---------------------------------------------------------------------------
# 1. Dependencies
# ---------------------------------------------------------------------------
required_cmds="bash jq"
optional_cmds="age age-keygen zstd gzip aws curl sha256sum shasum mysqldump mysql pg_dump pg_restore pg_dumpall psql"

missing_required=""
for c in $required_cmds; do
  command -v "$c" >/dev/null 2>&1 || missing_required="${missing_required} ${c}"
done

missing_optional=""
for c in $optional_cmds; do
  command -v "$c" >/dev/null 2>&1 || missing_optional="${missing_optional} ${c}"
done

if [ -n "$missing_required" ]; then
  log "required commands missing:${missing_required}"
else
  log "required commands present"
fi

if [ -n "$missing_optional" ]; then
  log "optional commands missing (needed depending on your config):${missing_optional}"
fi

if [ "$INSTALL_DEPS" = "1" ]; then
  if ! command -v apt-get >/dev/null 2>&1; then
    log "apt-get not found; install the packages manually. See docs/installation.md"
  else
    log "installing packages with apt-get (jq age zstd gzip awscli curl ca-certificates)"
    as_root apt-get update
    as_root apt-get install -y jq age zstd gzip curl ca-certificates awscli
    log "database clients are NOT installed automatically; install the one you need:"
    log "  mysql:  apt-get install -y default-mysql-client"
    log "  postgres: apt-get install -y postgresql-client"
  fi
fi

if [ -n "$missing_required" ]; then
  printf '\ninstall.sh: required commands are missing:%s\n' "$missing_required" >&2
  printf 'Re-run with --deps, or install them manually, then run: backupkit doctor\n' >&2
  exit 3
fi

# ---------------------------------------------------------------------------
# 2. Program files
# ---------------------------------------------------------------------------
log ""
log "installing program files to $LIB_DIR"
as_root mkdir -p "$LIB_DIR"
for d in bin src config docs; do
  [ -d "${REPO_ROOT}/${d}" ] || continue
  as_root mkdir -p "${LIB_DIR}/${d}"
  if [ "$DRY_RUN" = "1" ]; then
    printf '[dry-run] copy %s/* -> %s/%s/\n' "${REPO_ROOT}/${d}" "$LIB_DIR" "$d"
  else
    cp -R "${REPO_ROOT}/${d}/." "${LIB_DIR}/${d}/"
  fi
done
for f in VERSION README.md LICENSE CHANGELOG.md; do
  [ -f "${REPO_ROOT}/${f}" ] && as_root cp -f "${REPO_ROOT}/${f}" "${LIB_DIR}/${f}"
done
as_root chmod 755 "${LIB_DIR}/bin/backupkit"

as_root mkdir -p "${PREFIX}/bin"
if [ "$DRY_RUN" = "1" ]; then
  printf '[dry-run] ln -sf %s/bin/backupkit %s/bin/backupkit\n' "$LIB_DIR" "$PREFIX"
else
  ln -sf "${LIB_DIR}/bin/backupkit" "${PREFIX}/bin/backupkit"
fi

# ---------------------------------------------------------------------------
# 3. Directories (never overwrite contents)
# ---------------------------------------------------------------------------
log "preparing directories"
as_root mkdir -p "$ETC_DIR" "$STATE_DIR" "$LOG_DIR"
as_root chmod 700 "$ETC_DIR" "$STATE_DIR" "$LOG_DIR"

if [ ! -f "${ETC_DIR}/config.json" ]; then
  log "no config yet; run 'backupkit init' next (it writes config.json and an age key)"
fi

log ""
log "installed. Next steps:"
log "  1. backupkit init                 # config, secrets template, age key"
log "  2. edit ${ETC_DIR}/config.json and ${ETC_DIR}/secrets.json"
log "  3. backupkit config validate"
log "  4. backupkit doctor"
log "  5. backupkit backup --all --dry-run"
log "  6. sudo backupkit install-scheduler"
log ""
log "Docs: ${LIB_DIR}/docs/  (installation.md, configuration.md, usage.md, restore.md)"
