#!/usr/bin/env bash
# BackupKit - src/notifications/notify.sh
#
# Optional notifications. Notifications must never be able to fail a backup:
# every path here swallows errors and returns 0.

bk_notify_enabled() {
  [ "$(bk_cfg '.notifications.telegram.enabled' 'false')" = "true" ]
}

bk_notify() {
  # bk_notify EVENT TITLE BODY
  local event="$1" title="$2" body="$3"
  bk_notify_enabled || return 0

  local text
  text="$(printf '*%s*%s%s%s' \
    "$title" \
    "$(printf '\n')" \
    "$body" \
    "$(printf '\n\nhost: `%s`\nbackupkit: `%s`' "$BK_HOSTNAME" "${BACKUPKIT_VERSION:-unknown}")")"

  if [ "$BK_DRY_RUN" = "1" ]; then
    bk_info "[dry-run] notification ($event) not sent"
    return 0
  fi

  bk_notify_telegram "$text" || true
  return 0
}

bk_notify_telegram() {
  local text="$1" token chat
  token="$(bk_secret '.notifications.telegram.bot_token' '')"
  chat="$(bk_secret '.notifications.telegram.chat_id' '')"
  [ -n "$token" ] && [ -n "$chat" ] || { bk_warn "telegram notification requested but token/chat_id missing"; return 0; }
  bk_have curl || { bk_warn "curl not available; telegram notification skipped"; return 0; }

  local api
  api="$(bk_cfg '.notifications.telegram.api_base' 'https://api.telegram.org')"

  # Hard timeout, output discarded, failures logged as warnings only.
  curl -sS --max-time "$(bk_cfg '.notifications.telegram.timeout_seconds' '10')" \
    -X POST "${api}/bot${token}/sendMessage" \
    -d "chat_id=${chat}" \
    --data-urlencode "text=${text}" \
    -d "parse_mode=Markdown" \
    -o /dev/null 2>&1 || bk_warn "telegram notification failed (ignored)"
  return 0
}

bk_notify_backup_result() {
  # bk_notify_backup_result STATUS DB_ID MESSAGE
  local status="$1" db_id="$2" msg="$3"
  case "$status" in
    success) bk_notify "backup_success" "Backup OK: ${db_id}" "$msg" ;;
    reused)  bk_notify "backup_reused" "Backup reused: ${db_id}" "$msg" ;;
    failed)  bk_notify "backup_failed" "Backup FAILED: ${db_id}" "$msg" ;;
  esac
}
