#!/usr/bin/env bash
# BackupKit - src/core/log.sh
#
# Structured logging. Human readable on the terminal, JSON lines in the log
# file. Secrets are redacted before anything is written or printed.

BK_LOG_LEVEL="${BK_LOG_LEVEL:-info}"
BK_LOG_FILE="${BK_LOG_FILE:-}"
BK_LOG_JSON="${BK_LOG_JSON:-1}"

# Secret values are loaded from the (600) secrets file and redacted everywhere.
BK_SECRETS_JSON="${BK_SECRETS_JSON:-}"

bk_log_level_num() {
  case "$1" in
    debug) printf '10' ;;
    info)  printf '20' ;;
    warn)  printf '30' ;;
    error) printf '40' ;;
    *)     printf '20' ;;
  esac
}

bk_secret_values() {
  # One secret string per line, taken from keys that look like credentials
  # (password, secret, token, key, credential). Over-redaction is acceptable,
  # leaking is not; redacting every string would mangle unrelated messages.
  # Values shorter than 4 characters are skipped for the same reason.
  [ -n "${BK_SECRETS_JSON}" ] || return 0
  printf '%s' "$BK_SECRETS_JSON" \
    | jq -r 'paths(scalars) as $p
             | select(($p[-1] | type) == "string")
             | select($p[-1] | test("(?i)pass|secret|token|key|credential"))
             | getpath($p) | strings' 2>/dev/null \
    | awk 'length($0) >= 4'
}

bk_redact_stream() {
  # Read stdin, write stdout with every known secret replaced.
  local script_file value escaped
  script_file="$(mktemp "${TMPDIR:-/tmp}/bkredact.XXXXXX" 2>/dev/null)" || { cat; return 0; }
  : >"$script_file"
  while IFS= read -r value; do
    [ -n "$value" ] || continue
    escaped="$(printf '%s' "$value" | sed -e 's/[\\/&|]/\\&/g')"
    printf 's|%s|[REDACTED]|g\n' "$escaped" >>"$script_file"
  done <<EOF
$(bk_secret_values)
EOF
  if [ -s "$script_file" ]; then
    sed -f "$script_file"
  else
    cat
  fi
  rm -f -- "$script_file"
}

bk_log() {
  # bk_log LEVEL MESSAGE...
  local level="$1"
  shift
  local msg="$*"

  [ "$(bk_log_level_num "$level")" -lt "$(bk_log_level_num "$BK_LOG_LEVEL")" ] && return 0

  msg="$(printf '%s' "$msg" | bk_redact_stream)"

  local ts
  ts="$(bk_now_utc)"

  # Diagnostics always go to stderr: callers capture the stdout of functions
  # such as bk_mkworkdir and bk_retention_apply, and a log line on stdout would
  # corrupt that value.
  if [ "$BK_QUIET" != "1" ]; then
    printf '%s [%s] %s\n' "$ts" "$level" "$msg" >&2
  fi

  [ -n "$BK_LOG_FILE" ] || return 0
  [ "$BK_LOG_JSON" = "1" ] || return 0

  mkdir -p "$(dirname "$BK_LOG_FILE")" 2>/dev/null || true
  jq -cn \
    --arg ts "$ts" \
    --arg level "$level" \
    --arg msg "$msg" \
    --arg run "${BK_RUN_ID:-}" \
    --arg host "$BK_HOSTNAME" \
    '{ts:$ts,level:$level,event:"log",message:$msg,run_id:$run,host:$host}' \
    >>"$BK_LOG_FILE" 2>/dev/null || true
}

bk_debug() { bk_log debug "$@"; }
bk_info()  { bk_log info  "$@"; }
bk_warn()  { bk_log warn  "$@"; }

# bk_event EVENT JSON_OBJECT
# Appends a structured event to the log file (never to stdout).
bk_event() {
  local event="$1" payload="${2:-{\}}"
  [ -n "$BK_LOG_FILE" ] || return 0
  mkdir -p "$(dirname "$BK_LOG_FILE")" 2>/dev/null || true
  printf '%s' "$payload" | jq -c \
    --arg ts "$(bk_now_utc)" \
    --arg event "$event" \
    --arg run "${BK_RUN_ID:-}" \
    --arg host "$BK_HOSTNAME" \
    '. + {ts:$ts,event:$event,run_id:$run,host:$host}' >>"$BK_LOG_FILE" 2>/dev/null || true
}

bk_json_get() {
  # bk_json_get JSON JQ_PATH [DEFAULT]
  #
  # NOTE: jq's "//" treats false as an absent value, which would silently turn
  # every explicit "false" in the config into the caller's default. Use an
  # explicit null test instead.
  local json="$1" path="$2" def="${3-}"
  local out
  out="$(printf '%s' "$json" | jq -r "(${path}) as \$v | if \$v == null then empty else \$v end" 2>/dev/null)" || out=""
  if [ -z "$out" ]; then
    printf '%s' "$def"
  else
    printf '%s' "$out"
  fi
}
