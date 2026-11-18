#!/usr/bin/env bash
# BackupKit - src/core/common.sh
#
# Shared constants, exit codes and portable helpers.
# Written for bash 3.2+ so the same code runs on macOS (dev) and Ubuntu/Debian.

# ---------------------------------------------------------------------------
# Exit codes: stable public contract, documented in docs/architecture.md
# ---------------------------------------------------------------------------
readonly BK_EXIT_OK=0
readonly BK_EXIT_GENERAL=1
readonly BK_EXIT_CONFIG=2
readonly BK_EXIT_DEPENDENCY=3
readonly BK_EXIT_LOCKED=4
readonly BK_EXIT_DUMP=5
readonly BK_EXIT_COMPRESS=6
readonly BK_EXIT_ENCRYPT=7
readonly BK_EXIT_UPLOAD=8
readonly BK_EXIT_VERIFY=9
readonly BK_EXIT_RETENTION=10
readonly BK_EXIT_RESTORE=11
readonly BK_EXIT_CANCELLED=12
readonly BK_EXIT_NOTFOUND=13

# ---------------------------------------------------------------------------
# Runtime switches
# ---------------------------------------------------------------------------
BK_RUN_ID="${BK_RUN_ID:-}"
BK_QUIET="${BK_QUIET:-0}"
BK_DRY_RUN="${BK_DRY_RUN:-0}"
BK_YES="${BK_YES:-0}"
BK_HOSTNAME="${BK_HOSTNAME:-$(hostname 2>/dev/null || printf 'unknown')}"

# Directories. Every path can be overridden by environment variables, which is
# what the test suite and non-root installs rely on.
BK_ETC="${BACKUPKIT_ETC:-/etc/backupkit}"
BK_STATE_DIR="${BACKUPKIT_STATE_DIR:-/var/lib/backupkit}"
BK_LOG_DIR="${BACKUPKIT_LOG_DIR:-/var/log/backupkit}"

BK_CONFIG_FILE="${BACKUPKIT_CONFIG:-${BK_ETC}/config.json}"
BK_SECRETS_FILE="${BACKUPKIT_SECRETS:-${BK_ETC}/secrets.json}"
BK_IDENTITY_FILE="${BACKUPKIT_IDENTITY:-${BK_ETC}/age.key}"

BK_MANIFEST_DIR="${BK_STATE_DIR}/manifests"
BK_LOCK_DIR="${BK_STATE_DIR}/locks"
BK_WORK_ROOT="${BK_STATE_DIR}/tmp"
BK_HISTORY_FILE="${BK_STATE_DIR}/history.jsonl"
BK_STATE_VERSION_FILE="${BK_STATE_DIR}/.state-version"
BK_LOG_FILE="${BACKUPKIT_LOG_FILE:-${BK_LOG_DIR}/backupkit.log}"

# Escape hatch for local development only. Never set this in production.
BK_ALLOW_INSECURE_PERMS="${BK_ALLOW_INSECURE_PERMS:-0}"

# ---------------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------------

bk_have() {
  command -v "$1" >/dev/null 2>&1
}

# bk_die CODE MESSAGE...  -> logs, prints to stderr, exits with CODE.
bk_die() {
  local code="$1"
  shift
  local msg="$*"
  if bk_have bk_log; then
    bk_log error "$msg"
  fi
  printf 'backupkit: error: %s\n' "$msg" >&2
  exit "$code"
}

bk_need_cmd() {
  local c
  for c in "$@"; do
    if ! bk_have "$c"; then
      bk_die "$BK_EXIT_DEPENDENCY" "missing required command: ${c} (run 'backupkit doctor' for install hints)"
    fi
  done
}

# bk_missing_cmds CMD... -> space separated list of commands that are absent.
# Non-fatal counterpart of bk_need_cmd, used so a run can be recorded as failed
# instead of dying mid-flight.
bk_missing_cmds() {
  local c out=""
  for c in "$@"; do
    [ -n "$c" ] || continue
    bk_have "$c" || out="${out}${out:+ }${c}"
  done
  printf '%s' "$out"
}

bk_file_size() {
  # Portable byte size for a file. Prints -1 when the file does not exist.
  local f="$1"
  [ -f "$f" ] || { printf -- '-1'; return 0; }
  wc -c <"$f" | tr -d '[:space:]'
}

bk_epoch_of() {
  # Convert an ISO-8601 UTC timestamp (YYYY-MM-DDTHH:MM:SSZ) to epoch seconds.
  local iso="$1"
  case "$iso" in
    ''|null) printf '0'; return 0 ;;
  esac
  # BSD date (macOS)
  if date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s >/dev/null 2>&1; then
    date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s
    return 0
  fi
  # GNU date (Linux)
  if date -u -d "$iso" +%s >/dev/null 2>&1; then
    date -u -d "$iso" +%s
    return 0
  fi
  printf '0'
}

bk_fmt_epoch() {
  # bk_fmt_epoch FORMAT EPOCH -> format in the configured timezone.
  local fmt="$1" epoch="$2"
  if TZ="$BK_TZ" date -r "$epoch" +"$fmt" >/dev/null 2>&1; then
    TZ="$BK_TZ" date -r "$epoch" +"$fmt"
  else
    TZ="$BK_TZ" date -d "@$epoch" +"$fmt"
  fi
}

bk_now_utc() {
  date -u +'%Y-%m-%dT%H:%M:%SZ'
}

# bk_last_line FILE -> last line, or empty. No pipes, so it is pipefail-safe.
bk_last_line() {
  [ -f "$1" ] || return 0
  awk 'END { if (NR > 0) print }' "$1"
}

bk_utc_compact() {
  date -u +'%Y%m%dT%H%M%SZ'
}

bk_random_token() {
  # Short URL/JSON safe token. Prefers openssl, falls back to /dev/urandom.
  local n="${1:-6}"
  if bk_have openssl; then
    LC_ALL=C openssl rand -hex 8 | cut -c1-"$n"
  else
    LC_ALL=C tr -dc 'a-f0-9' </dev/urandom 2>/dev/null | head -c "$n"
  fi
}

bk_new_backup_id() {
  printf 'bk_%s_%s' "$(bk_utc_compact)" "$(bk_random_token 6)"
}

bk_id_valid() {
  # Backup ids are strictly controlled so they are safe in paths and URLs.
  printf '%s' "$1" | grep -Eq '^bk_[0-9]{8}T[0-9]{6}Z_[a-f0-9]{4,32}$'
}

bk_db_id_valid() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
}

bk_human_size() {
  local bytes="$1"
  awk -v b="$bytes" 'BEGIN {
    split("B KiB MiB GiB TiB", u, " ");
    i = 1;
    while (b >= 1024 && i < 5) { b = b / 1024; i++ }
    if (i == 1) printf "%d %s", b, u[i];
    else printf "%.2f %s", b, u[i];
  }'
}

# ---------------------------------------------------------------------------
# Temporary files
#
# Registrations go to a file, not a shell variable: bk_mkworkdir is called as
# "$(bk_mkworkdir ...)" and a command substitution runs in a subshell, so an
# in-memory list would be lost every time.
# ---------------------------------------------------------------------------
BK_TMP_REGISTRY="${BK_STATE_DIR}/tmp/.registry.$$"

bk_tmp_register() {
  local p="$1"
  [ -n "$p" ] || return 0
  mkdir -p "$BK_WORK_ROOT" 2>/dev/null || true
  printf '%s\n' "$p" >>"$BK_TMP_REGISTRY" 2>/dev/null || true
}

bk_mkworkdir() {
  # Create a private directory for one backup run, tracked for cleanup.
  local prefix="${1:-run}"
  mkdir -p "$BK_WORK_ROOT" 2>/dev/null || true
  local d
  d="$(mktemp -d "${BK_WORK_ROOT}/${prefix}.XXXXXX" 2>/dev/null)" || d=""
  if [ -z "$d" ]; then
    d="$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX")" || bk_die "$BK_EXIT_GENERAL" "cannot create temporary directory"
  fi
  chmod 700 "$d"
  bk_tmp_register "$d"
  printf '%s\n' "$d"
}

bk_cleanup_all() {
  # Idempotent. Only removes paths inside the work root or the system temp dir.
  local p
  [ -f "$BK_TMP_REGISTRY" ] || return 0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in
      "${BK_WORK_ROOT}"/*|"${TMPDIR:-/tmp}"/*)
        [ -e "$p" ] && rm -rf -- "$p"
        ;;
    esac
  done <"$BK_TMP_REGISTRY"
  rm -f -- "$BK_TMP_REGISTRY" 2>/dev/null || true
  return 0
}
