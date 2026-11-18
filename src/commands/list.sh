#!/usr/bin/env bash
# BackupKit - src/commands/list.sh
#
# 'backupkit list' and 'backupkit status'.
#
# list works from the local manifest store so it keeps working when object
# storage or monitoring is unreachable. --remote reconciles against storage.

bk_cmd_list() {
  local db_filter="" type_filter="" json=0 remote=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --database) db_filter="${2-}"; shift 2 ;;
      --type)     type_filter="${2-}"; shift 2 ;;
      --json)     json=1; shift ;;
      --remote)   remote=1; shift ;;
      -h|--help)
        cat <<'EOF'
Usage: backupkit list [--database ID] [--type daily|weekly|monthly] [--json] [--remote]
EOF
        return 0 ;;
      *) bk_die "$BK_EXIT_GENERAL" "unknown option for list: $1" ;;
    esac
  done

  bk_config_load
  bk_state_init

  if [ "$remote" = "1" ]; then
    bk_storage_init_provider
  fi

  local listfile
  listfile="$(mktemp "${BK_WORK_ROOT}/list.XXXXXX" 2>/dev/null || mktemp "${TMPDIR:-/tmp}/bklist.XXXXXX")"
  bk_tmp_register "$listfile"

  local id line out="[]"
  for id in $(bk_db_ids); do
    [ -z "$db_filter" ] || [ "$db_filter" = "$id" ] || continue
    if [ "$remote" = "1" ]; then
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf '%s\n' "$line"
      done <<EOF
$(bk_retention_inventory "$id" | awk -F'\t' -v t="$type_filter" '
  {
    if (t != "") { n = split($3, tags, ","); found = 0; for (i = 1; i <= n; i++) if (tags[i] == t) found = 1; if (!found) next }
    printf "%s\t%s\t%s\t%s\n", $2, $3, $4, $5
  }')
EOF
    else
      local f mid manifest
      for mid in $(bk_manifest_list_local); do
        manifest="$(bk_manifest_read "$mid")"
        [ -n "$manifest" ] || continue
        [ "$(bk_json_get "$manifest" '.database.id' '')" = "$id" ] || continue
        if [ -n "$type_filter" ]; then
          bk_manifest_has_type "$manifest" "$type_filter" || continue
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$mid" \
          "$(bk_manifest_types "$manifest")" \
          "$(bk_json_get "$manifest" '.status' '')" \
          "$(bk_json_get "$manifest" '.created_at' '')" \
          "$(bk_json_get "$manifest" '.artifacts[0].size_human' '')" \
          "$(bk_json_get "$manifest" '.duration_seconds' '0')"
      done
    fi
  done >"$listfile" 2>/dev/null || true

  if [ ! -s "$listfile" ]; then
    bk_info "no backups found"
    [ "$json" = "1" ] && printf '[]\n'
    return 0
  fi

  if [ "$json" = "1" ]; then
    awk -F'\t' '{printf "%s\t%s\t%s\t%s\t%s\t%s\n", $1, $2, $3, $4, $5, ($6 == "" ? "0" : $6)}' \
      "$listfile" | jq -R -s '
        split("\n") | map(select(length > 0)) | map(split("\t") | {
          id: .[0], types: .[1], status: .[2], created_at: .[3], size: .[4], duration_seconds: (.[5] | tonumber? // 0)
        })'
  else
    printf '%-28s %-18s %-9s %-21s %-10s %s\n' "BACKUP ID" "TYPES" "STATUS" "CREATED (UTC)" "SIZE" "DURATION"
    awk -F'\t' '{printf "%-28s %-18s %-9s %-21s %-10s %ss\n", $1, $2, $3, $4, $5, $6}' "$listfile"
  fi
  return 0
}

bk_cmd_status() {
  local json=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      -h|--help) printf 'Usage: backupkit status [--json]\n'; return 0 ;;
      *) bk_die "$BK_EXIT_GENERAL" "unknown option for status: $1" ;;
    esac
  done

  bk_config_load
  bk_state_init

  local provider bucket last_run last_status last_db
  provider="$(bk_storage_provider)"
  bucket="$(bk_storage_bucket)"

  last_run=""
  last_status=""
  last_db=""
  if [ -f "$BK_HISTORY_FILE" ]; then
    last_run="$(bk_last_line "$BK_HISTORY_FILE")"
    last_status="$(bk_json_get "$last_run" '.status' '')"
    last_db="$(bk_json_get "$last_run" '.database' '')"
    [ -n "$last_run" ] && last_run="$(bk_json_get "$last_run" '.ts' '')"
  fi

  if [ "$json" = "1" ]; then
    local db_items="[]"
    local id
    for id in $(bk_db_ids); do
      db_items="$(printf '%s' "$db_items" | jq -c --arg id "$id" \
        --arg type "$(bk_db_type "$id")" \
        --arg retention "$(bk_retention_summary "$id")" \
        --arg last_ok "$(bk_status_last_success "$id")" \
        --argjson locked "$(bk_lock_held "db-${id}" && printf true || printf false)" \
        '. + [{id:$id,type:$type,retention:$retention,last_success:$last_ok,locked:$locked}]')"
    done
    jq -cn \
      --arg version "${BACKUPKIT_VERSION:-unknown}" \
      --arg host "$BK_HOSTNAME" \
      --arg tz "$BK_TZ" \
      --arg provider "$provider" \
      --arg bucket "$bucket" \
      --arg state_dir "$BK_STATE_DIR" \
      --arg config "$BK_CONFIG_FILE" \
      --arg last_run "$last_run" \
      --arg last_status "$last_status" \
      --arg last_db "$last_db" \
      --argjson databases "$db_items" \
      '{version:$version,host:$host,timezone:$tz,storage:{provider:$provider,bucket:$bucket},state_dir:$state_dir,config:$config,
        last_run:{ts:$last_run,status:$last_status,database:$last_db},databases:$databases}'
    return 0
  fi

  printf 'BackupKit %s on %s\n' "${BACKUPKIT_VERSION:-unknown}" "$BK_HOSTNAME"
  printf '  timezone        : %s\n' "$BK_TZ"
  printf '  config          : %s\n' "$BK_CONFIG_FILE"
  printf '  state dir       : %s\n' "$BK_STATE_DIR"
  printf '  storage         : %s %s\n' "$provider" "${bucket:+($bucket)}"
  printf '  last run        : %s %s %s\n' "${last_run:-never}" "${last_status:+[$last_status]}" "${last_db:+for $last_db}"
  printf '\n'
  printf '%-20s %-10s %-26s %-22s %s\n' "DATABASE" "TYPE" "RETENTION (kept/limit)" "LAST SUCCESS (UTC)" "LOCK"
  local id
  for id in $(bk_db_ids); do
    local lock="no"
    bk_lock_held "db-${id}" && lock="YES"
    printf '%-20s %-10s %-26s %-22s %s\n' \
      "$id" "$(bk_db_type "$id")" "$(bk_retention_summary "$id")" "$(bk_status_last_success "$id")" "$lock"
  done
  return 0
}

bk_status_last_success() {
  local id="$1" line
  [ -f "$BK_HISTORY_FILE" ] || { printf 'never'; return 0; }
  line="$(awk -v id="$id" '
    /"event":"backup"/ {
      if (index($0, "\"database\":\"" id "\"") > 0 && index($0, "\"status\":\"success\"") > 0) { last = $0 }
    }
    END { if (last != "") print last }' "$BK_HISTORY_FILE")"
  [ -n "$line" ] || { printf 'never'; return 0; }
  bk_json_get "$line" '.ts' 'never'
}
