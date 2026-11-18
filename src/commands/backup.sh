#!/usr/bin/env bash
# BackupKit - src/commands/backup.sh
#
# The backup pipeline. Order matters and mirrors the checklist in
# docs/architecture.md:
#
#   1  acquire lock
#   2  reuse check (one snapshot can satisfy daily + weekly + monthly)
#   3  dump
#   4  check dump exit status and footer/header sanity
#   5  compress
#   6  encrypt
#   7  verify artifact exists and is non-empty
#   8  SHA-256
#   9  upload
#  10  verify uploaded object
#  11  write manifest
#  12  record history
#  13  retention (after a verified upload only)
#  14  clean temporary files
#
# Any failure marks the run as failed, keeps the previous backups untouched,
# and exits with the corresponding stage code.

BK_OPT_DBS=""
BK_OPT_TYPE="auto"
BK_OPT_FORCE=0
BK_OPT_NO_CLEANUP=0

bk_backup_usage() {
  cat <<'EOF'
Usage: backupkit backup [options]

Options:
  --database <id>   Back up one database (repeatable, or comma separated)
  --all             Back up every enabled database (default)
  --type <type>     daily | weekly | monthly | auto (default: auto)
                    auto decides from each database's schedule and today's date
  --force           Run even when the type is not due today
  --no-cleanup      Skip retention cleanup after a successful backup
  --dry-run         Show what would happen, change nothing
EOF
}

bk_backup_due_types() {
  # bk_backup_due_types DB_ID -> space separated types that are due today
  local id="$1" out="" dow dom weekly_dow monthly_dom
  weekly_dow="$(bk_cfg '.schedule.weekly_dow' '0')"
  monthly_dom="$(bk_cfg '.schedule.monthly_dom' '1')"
  dow="$(TZ="$BK_TZ" date +%w)"
  dom="$(TZ="$BK_TZ" date +%d)"

  if bk_db_schedule "$id" daily; then
    out="daily"
  fi
  if bk_db_schedule "$id" weekly && [ "$dow" = "$weekly_dow" ]; then
    out="${out}${out:+ }weekly"
  fi
  if bk_db_schedule "$id" monthly && [ "$((10#$dom))" = "$((10#$monthly_dom))" ]; then
    out="${out}${out:+ }monthly"
  fi
  printf '%s' "$out"
}

bk_backup_types_for() {
  # bk_backup_types_for DB_ID -> types to run now (may be empty)
  local id="$1" t
  if [ "$BK_OPT_TYPE" = "auto" ]; then
    bk_backup_due_types "$id"
    return 0
  fi
  if [ "$BK_OPT_FORCE" = "1" ]; then
    printf '%s' "$BK_OPT_TYPE"
    return 0
  fi
  if bk_db_schedule "$id" "$BK_OPT_TYPE"; then
    # Explicit type still has to be due today, so a manual run or a missed cron
    # job cannot fabricate an extra weekly/monthly snapshot.
    for t in $(bk_backup_due_types "$id"); do
      if [ "$t" = "$BK_OPT_TYPE" ]; then
        printf '%s' "$BK_OPT_TYPE"
        return 0
      fi
    done
    printf ''
    return 0
  fi
  printf ''
}

bk_backup_primary_type() {
  # First type of the list decides the object path.
  local first
  first="$(printf '%s' "$1" | awk '{print $1}')"
  printf '%s' "$first"
}

bk_backup_types_json() {
  printf '%s' "$1" | tr ' ' '\n' | grep -v '^$' | jq -R . | jq -cs .
}

# bk_backup_find_reusable DB_ID
# Prints "backup_id<TAB>manifest_json" when the newest verified snapshot of the
# database was taken on the same local calendar day, so a coinciding weekly or
# monthly run can re-tag it instead of dumping again.
bk_backup_find_reusable() {
  local db_id="$1" inv row id manifest created today key
  inv="$(bk_retention_inventory "$db_id")"
  [ -n "$inv" ] || return 1

  # The inventory is newest first: only the newest verified snapshot qualifies.
  row="$(printf '%s\n' "$inv" | awk -F'\t' '$4 == "verified" { print; exit }')"
  [ -n "$row" ] || return 1
  id="$(printf '%s' "$row" | cut -f2)"
  [ -n "$id" ] || return 1

  manifest="$(bk_manifest_read "$id")"
  if [ -z "$manifest" ]; then
    manifest="$(bk_manifest_fetch_remote "$id")" || return 1
  fi
  [ -n "$manifest" ] || return 1

  # Same local day? Comparing formatted local dates keeps this portable: it
  # needs no epoch arithmetic and no platform specific date flags.
  created="$(bk_json_get "$manifest" '.created_at' '')"
  [ -n "$created" ] || return 1
  today="$(TZ="$BK_TZ" date +%Y-%m-%d)"
  [ "$(bk_fmt_epoch '%Y-%m-%d' "$(bk_epoch_of "$created")")" = "$today" ] || return 1

  # The artifacts must still be present, otherwise take a fresh backup.
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    [ "$(bk_storage_size "$key")" = "-1" ] && return 1
  done <<EOF
$(bk_manifest_artifact_keys "$manifest")
EOF

  printf '%s\t%s' "$id" "$manifest"
  return 0
}

bk_backup_record_failure() {
  local db_id="$1" id="$2" started_epoch="$3" stage="$4" message="$5" duration
  duration=$(( $(date +%s) - started_epoch ))
  bk_history_append "$(jq -cn \
    --arg ts "$(bk_now_utc)" \
    --arg run "$BK_RUN_ID" \
    --arg db "$db_id" \
    --arg id "$id" \
    --arg stage "$stage" \
    --arg msg "$message" \
    --argjson duration "$duration" \
    '{ts:$ts,run_id:$run,event:"backup",database:$db,backup_id:$id,status:"failed",stage:$stage,duration_seconds:$duration,error:$msg}')"
  bk_event "backup_failed" "$(jq -cn --arg db "$db_id" --arg id "$id" --arg stage "$stage" --arg msg "$message" \
    '{database:$db,backup_id:$id,stage:$stage,error:$msg}')"
}

# bk_backup_one DB_ID TYPES -> exit stage code
bk_backup_one() {
  local db_id="$1" types="$2"
  local started_epoch duration id primary types_json
  local dir manifest="" status="success" stage="" fail_msg=""
  local artifacts_json="[]" total_size=0
  local db_type db_name

  started_epoch="$(date +%s)"
  id="$(bk_new_backup_id)"
  primary="$(bk_backup_primary_type "$types")"
  types_json="$(bk_backup_types_json "$types")"
  db_type="$(bk_db_type "$db_id")"
  db_name="$(bk_db_name "$db_id")"

  bk_info "backup start: db=$db_id type=$db_type types=[$(printf '%s' "$types" | tr ' ' ',')] id=$id"

  # --- 1. lock ------------------------------------------------------------
  if ! bk_lock_acquire "db-${db_id}"; then
    bk_warn "another backup is already running for $db_id; skipping (cron overlap guard)"
    bk_backup_record_failure "$db_id" "$id" "$started_epoch" "lock" "concurrent run for the same database"
    bk_notify_backup_result failed "$db_id" "skipped: another backup is running"
    return "$BK_EXIT_LOCKED"
  fi

  # --- 2. reuse check ----------------------------------------------------
  if [ "$BK_OPT_FORCE" != "1" ]; then
    local reusable
    reusable="$(bk_backup_find_reusable "$db_id" 2>/dev/null || true)"
    if [ -n "$reusable" ]; then
      local re_id re_manifest missing
      re_id="$(printf '%s' "$reusable" | cut -f1)"
      re_manifest="$(printf '%s' "$reusable" | cut -f2-)"
      missing=""
      local t
      for t in $types; do
        bk_manifest_has_type "$re_manifest" "$t" || missing="${missing}${missing:+ }$t"
      done
      if [ -z "$missing" ]; then
        bk_info "snapshot $re_id already satisfies [$(printf '%s' "$types" | tr ' ' ',')]; nothing to do"
        bk_lock_release
        bk_history_append "$(jq -cn --arg ts "$(bk_now_utc)" --arg run "$BK_RUN_ID" --arg db "$db_id" \
          --arg id "$re_id" --argjson duration 0 \
          '{ts:$ts,run_id:$run,event:"backup",database:$db,backup_id:$id,status:"reused",duration_seconds:$duration}')"
        bk_notify_backup_result reused "$db_id" "reused existing snapshot \`$re_id\`"
        return 0
      fi
      bk_info "reusing snapshot $re_id and tagging [$missing]"
      local updated
      for t in $missing; do
        re_manifest="$(bk_manifest_add_type "$re_manifest" "$t")"
      done
      updated="$re_manifest"
      if bk_manifest_write "$re_id" "$updated"; then
        local mkey
        mkey="$(bk_storage_manifest_key "$db_id" "$(bk_json_get "$updated" '.primary_type' "$primary")" "$re_id")"
        bk_storage_put_string "$updated" "$mkey" \
          || bk_warn "failed to update manifest for reused snapshot $re_id (local copy is updated)"
        bk_history_append "$(jq -cn --arg ts "$(bk_now_utc)" --arg run "$BK_RUN_ID" --arg db "$db_id" \
          --arg id "$re_id" --arg tags "$missing" \
          '{ts:$ts,run_id:$run,event:"backup",database:$db,backup_id:$id,status:"reused",tagged:$tags,duration_seconds:0}')"
        bk_notify_backup_result reused "$db_id" "reused \`$re_id\`, added types: $missing"
        bk_lock_release
        return 0
      fi
      bk_warn "could not update the reused manifest; taking a fresh backup instead"
    fi
  fi

  if [ "$BK_DRY_RUN" = "1" ]; then
    bk_info "[dry-run] would dump, compress, encrypt and upload ${db_id}; nothing was changed"
    bk_lock_release
    return 0
  fi

  dir="$(bk_mkworkdir "backup-${db_id}")"

  # --- 2b. dependency check ---------------------------------------------
  local missing
  missing="$(bk_missing_cmds jq $(bk_driver_required_cmds "$db_id") $(bk_compression_required_cmds) $(bk_encryption_required_cmds) $(bk_storage_required_cmds))"
  if [ -n "$missing" ]; then
    stage="dependency"
    fail_msg="missing required command(s): $missing"
  fi

  local roles="primary"
  if [ "$db_type" = "postgres" ] || [ "$db_type" = "postgresql" ]; then
    [ "$(bk_db_field "$db_id" '.globals' 'false')" = "true" ] && roles="primary globals"
  fi

  local role rc
  for role in $roles; do
    [ -z "$stage" ] || break

    local raw comp_file enc_file comp_ext enc_ext name key sha size base_name
    comp_ext="$(bk_compression_ext)"
    enc_ext="$(bk_encryption_ext)"

    base_name="$id"
    [ "$role" = "primary" ] || base_name="${id}.${role}"

    case "$db_type" in
      postgres|postgresql)
        [ "$role" = "globals" ] && raw="${dir}/${base_name}.sql" || raw="${dir}/${base_name}.dump" ;;
      *) raw="${dir}/${base_name}.sql" ;;
    esac
    comp_file="${dir}/${base_name}.${comp_ext}"
    enc_file="${comp_file}${enc_ext}"
    name="$(basename "$enc_file")"
    key="$(bk_storage_key "$db_id" "$primary" "$id" "$role" "$comp_ext" "$enc_ext")"

    # --- 3/4. dump -----------------------------------------------------
    bk_info "dump $db_id (role=$role)"
    if ! bk_driver_dump "$db_id" "$role" "$raw" "${dir}/${base_name}.err"; then
      stage="dump"; fail_msg="dump failed for role $role: $(head -c 500 "${dir}/${base_name}.err" 2>/dev/null | tr '\n' ' ')"
      break
    fi

    # --- 5. compress ---------------------------------------------------
    if ! bk_compress "$raw" "$comp_file"; then
      stage="compress"; fail_msg="compression failed for role $role"
      break
    fi
    rm -f -- "$raw"

    # --- 6. encrypt ----------------------------------------------------
    if ! bk_encrypt "$comp_file" "$enc_file"; then
      stage="encrypt"; fail_msg="encryption failed for role $role"
      break
    fi
    rm -f -- "$comp_file"

    # --- 7. artifact sanity -------------------------------------------
    if [ ! -s "$enc_file" ]; then
      stage="validate"; fail_msg="encrypted artifact is missing or empty for role $role"
      break
    fi

    # --- 8. checksum ---------------------------------------------------
    sha="$(bk_sha256 "$enc_file")" || { stage="validate"; fail_msg="cannot compute checksum for role $role"; break; }
    size="$(bk_file_size "$enc_file")"

    # --- 9. upload -----------------------------------------------------
    bk_info "upload $key ($(bk_human_size "$size"))"
    if ! bk_storage_upload "$enc_file" "$key"; then
      stage="upload"; fail_msg="upload failed for $key"
      break
    fi

    # --- 10. verify upload --------------------------------------------
    if ! bk_stage_validate_upload "$key" "$size" "role $role"; then
      stage="upload"; fail_msg="upload verification failed for $key"
      break
    fi

    artifacts_json="$(printf '%s' "$artifacts_json" | jq -c \
      --argjson a "$(bk_manifest_artifact_json "$role" "$key" "$sha" "$size" \
        "$([ "$comp_ext" = "gz" ] && printf 'gzip' || { [ "$comp_ext" = "zst" ] && printf 'zstd' || printf 'none'; })" \
        "$([ -n "$enc_ext" ] && printf 'age' || printf 'none')")" \
      '. + [$a]')"
    total_size=$((total_size + size))
    bk_event "artifact_uploaded" "$(jq -cn --arg db "$db_id" --arg id "$id" --arg key "$key" --argjson size "$size" --arg sha "$sha" \
      '{database:$db,backup_id:$id,key:$key,size_bytes:$size,sha256:$sha}')"
  done

  # --- 11. manifest ----------------------------------------------------
  duration=$(( $(date +%s) - started_epoch ))
  M_ID="$id"
  M_STATUS="verified"
  M_DB_ID="$db_id"
  M_DB_TYPE="$db_type"
  M_DB_NAME="$db_name"
  M_TYPES_JSON="$types_json"
  M_PRIMARY_TYPE="$primary"
  M_CREATED_AT="$(bk_now_utc)"
  M_DURATION="$duration"
  M_ARTIFACTS_JSON="$artifacts_json"
  M_TOOL_VERSIONS="$(bk_driver_tool_versions "$db_id" 2>/dev/null || printf '{}')"
  M_ERROR=""

  if [ -z "$stage" ]; then
    manifest="$(bk_manifest_json)"
    bk_manifest_write "$id" "$manifest" || bk_warn "could not write local manifest for $id"
    local mkey
    mkey="$(bk_storage_manifest_key "$db_id" "$primary" "$id")"
    if ! bk_storage_put_string "$manifest" "$mkey"; then
      stage="upload"; fail_msg="failed to upload manifest for $id"
    fi
  fi

  if [ -n "$stage" ]; then
    status="failed"
    M_STATUS="failed"
    M_ERROR="$fail_msg"
    bk_log error "backup failed: db=$db_id id=$id stage=$stage: $fail_msg"
    # A failed run is recorded locally only; it is never uploaded and never
    # eligible for retention.
    bk_manifest_write "$id" "$(bk_manifest_json)" 2>/dev/null || true
    bk_backup_record_failure "$db_id" "$id" "$started_epoch" "$stage" "$fail_msg"
    bk_notify_backup_result failed "$db_id" "stage: $stage\n$(printf '%s' "$fail_msg" | head -c 300)"
    bk_lock_release
    rm -rf -- "$dir" 2>/dev/null || true
    case "$stage" in
      dump)       return "$BK_EXIT_DUMP" ;;
      compress)   return "$BK_EXIT_COMPRESS" ;;
      encrypt)    return "$BK_EXIT_ENCRYPT" ;;
      upload)     return "$BK_EXIT_UPLOAD" ;;
      validate)   return "$BK_EXIT_VERIFY" ;;
      dependency) return "$BK_EXIT_DEPENDENCY" ;;
      *)          return "$BK_EXIT_GENERAL" ;;
    esac
  fi

  # --- 12. history -----------------------------------------------------
  bk_history_append "$(jq -cn \
    --arg ts "$(bk_now_utc)" \
    --arg run "$BK_RUN_ID" \
    --arg db "$db_id" \
    --arg id "$id" \
    --argjson types "$types_json" \
    --argjson duration "$duration" \
    --argjson size "$total_size" \
    --arg key "$(printf '%s' "$artifacts_json" | jq -r '.[0].key // ""')" \
    --arg sha "$(printf '%s' "$artifacts_json" | jq -r '.[0].sha256 // ""')" \
    '{ts:$ts,run_id:$run,event:"backup",database:$db,backup_id:$id,status:"success",types:$types,duration_seconds:$duration,size_bytes:$size,key:$key,sha256:$sha,error:""}')"

  bk_info "backup ok: $id ($(bk_human_size "$total_size"), ${duration}s)"

  bk_notify_backup_result success "$db_id" \
    "backup: \`$id\`\ntypes: $(printf '%s' "$types" | tr ' ' ',')\nsize: $(bk_human_size "$total_size")\nduration: ${duration}s"

  # --- 13. retention (only after a verified upload) --------------------
  if [ "$BK_OPT_NO_CLEANUP" != "1" ]; then
    local deleted
    deleted="$(bk_retention_apply "$db_id" "" 2>/dev/null || printf '0')"
    case "$deleted" in
      ''|0) ;;
      *)
        bk_info "retention: removed $deleted expired backup(s) for $db_id"
        bk_notify "retention" "Retention cleanup: $db_id" "removed $deleted expired backup(s)"
        ;;
    esac
  fi

  # --- 14. temp files --------------------------------------------------
  bk_lock_release
  rm -rf -- "$dir" 2>/dev/null || true
  return 0
}

bk_cmd_backup() {
  if [ "$#" -eq 0 ]; then
    BK_OPT_TYPE="auto"
  fi
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --database)
        [ -n "${2-}" ] || bk_die "$BK_EXIT_GENERAL" "--database requires an id"
        BK_OPT_DBS="${BK_OPT_DBS}${BK_OPT_DBS:+,}${2}"
        shift 2 ;;
      --all)        shift ;;
      --type)
        [ -n "${2-}" ] || bk_die "$BK_EXIT_GENERAL" "--type requires a value"
        case "$2" in
          daily|weekly|monthly|auto) BK_OPT_TYPE="$2" ;;
          *) bk_die "$BK_EXIT_GENERAL" "invalid --type: $2" ;;
        esac
        shift 2 ;;
      --force)      BK_OPT_FORCE=1; shift ;;
      --no-cleanup) BK_OPT_NO_CLEANUP=1; shift ;;
      --dry-run)    BK_DRY_RUN=1; shift ;;
      -h|--help)    bk_backup_usage; return 0 ;;
      *)            bk_die "$BK_EXIT_GENERAL" "unknown option for backup: $1" ;;
    esac
  done

  bk_config_load
  local errors
  errors="$(bk_config_validate)" || {
    printf '%s\n' "$errors" >&2
    bk_die "$BK_EXIT_CONFIG" "configuration is invalid (run 'backupkit config validate')"
  }
  bk_state_init
  bk_log_dir_init
  bk_storage_init_provider

  local targets="" id
  if [ -n "$BK_OPT_DBS" ]; then
    for id in $(printf '%s' "$BK_OPT_DBS" | tr ',' ' '); do
      [ -n "$(bk_db_json "$id")" ] || bk_die "$BK_EXIT_CONFIG" "unknown database id: $id"
      bk_db_enabled "$id" || bk_warn "database $id is disabled; skipping"
      targets="${targets}${targets:+ }${id}"
    done
  else
    targets="$(bk_db_config_ids | tr '\n' ' ')"
  fi

  [ -n "$targets" ] || { bk_info "no databases selected"; return 0; }

  local overall=0 rc types id
  for id in $targets; do
    types="$(bk_backup_types_for "$id")"
    if [ -z "$types" ]; then
      bk_info "skip $id: no backup type is due now (use --force or --type)"
      continue
    fi
    bk_backup_one "$id" "$types"
    rc=$?
    if [ "$rc" -ne 0 ] && [ "$overall" -eq 0 ]; then
      overall="$rc"
    fi
  done

  return "$overall"
}
