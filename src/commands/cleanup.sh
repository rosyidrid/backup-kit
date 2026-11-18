#!/usr/bin/env bash
# BackupKit - src/commands/cleanup.sh
# 'backupkit cleanup [--dry-run] [--database ID] [--remote]'

bk_cmd_cleanup() {
  local db_filter="" dry=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run)  dry="--dry-run"; shift ;;
      --database) db_filter="${2-}"; shift 2 ;;
      -h|--help)
        cat <<'EOF'
Usage: backupkit cleanup [--dry-run] [--database ID]

Applies the retention policy. Only backups recorded in a verified manifest and
living under the configured storage prefix are eligible. The newest verified
backup of a database is never deleted, and a snapshot that covers several
retention categories is deleted only when it is out of policy for all of them.

Run with --dry-run first.
EOF
        return 0 ;;
      *) bk_die "$BK_EXIT_GENERAL" "unknown option for cleanup: $1" ;;
    esac
  done

  bk_config_load
  local errors
  errors="$(bk_config_validate)" || {
    printf '%s\n' "$errors" >&2
    bk_die "$BK_EXIT_CONFIG" "configuration is invalid"
  }
  bk_state_init
  bk_storage_init_provider

  local id total=0 deleted rc=0
  for id in $(bk_db_ids); do
    [ -z "$db_filter" ] || [ "$db_filter" = "$id" ] || continue
    bk_info "retention check for $id ($(bk_retention_summary "$id"))"
    deleted="$(bk_retention_apply "$id" "$dry")" || rc="$BK_EXIT_RETENTION"
    case "$deleted" in ''|*[!0-9]*) deleted=0 ;; esac
    total=$((total + deleted))
  done

  if [ "$dry" = "--dry-run" ] || [ "$BK_DRY_RUN" = "1" ]; then
    bk_info "dry-run: $total backup(s) would be deleted"
  else
    bk_info "$total backup(s) deleted"
  fi
  return "$rc"
}
