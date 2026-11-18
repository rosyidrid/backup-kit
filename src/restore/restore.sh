#!/usr/bin/env bash
# BackupKit - src/restore/restore.sh
#
# Restore utilities. Every destructive step requires an explicit confirmation:
# either an interactive "yes" or --yes on the command line, plus a --target
# database whenever data would be overwritten.

bk_confirm() {
  # bk_confirm PROMPT -> 0 when confirmed
  local prompt="$1" answer=""
  if [ "$BK_YES" = "1" ]; then
    bk_info "confirmed via --yes: $prompt"
    return 0
  fi
  if [ ! -t 0 ]; then
    bk_die "$BK_EXIT_CANCELLED" "refusing to run without confirmation (no TTY). Re-run with --yes if you are sure: $prompt"
  fi
  printf '%s\n' "$prompt" >&2
  printf 'Type exactly "yes" to continue: ' >&2
  read -r answer
  case "$answer" in
    yes|YES|Yes) return 0 ;;
    *) bk_die "$BK_EXIT_CANCELLED" "aborted by user" ;;
  esac
}

bk_restore_manifest() {
  # bk_restore_manifest BACKUP_ID -> manifest JSON (local first, then remote)
  local id="$1" manifest
  manifest="$(bk_manifest_read "$id")"
  if [ -z "$manifest" ]; then
    manifest="$(bk_manifest_fetch_remote "$id")" || true
  fi
  [ -n "$manifest" ] || bk_die "$BK_EXIT_NOTFOUND" "no manifest found for backup id $id"
  if bk_manifest_is_failed "$manifest"; then
    bk_die "$BK_EXIT_RESTORE" "backup $id is marked as failed; refusing to restore it"
  fi
  printf '%s' "$manifest"
}

bk_restore_artifact_for_role() {
  # bk_restore_artifact_for_role MANIFEST ROLE -> "key sha256" (tab separated)
  local manifest="$1" role="$2"
  printf '%s' "$manifest" | jq -r --arg role "$role" '
    (.artifacts // [])[] | select(.role == $role) | [.key, .sha256] | @tsv' 2>/dev/null | head -1
}

# bk_restore_download_artifact MANIFEST ROLE WORKDIR -> echoes the local path
bk_restore_download_artifact() {
  local manifest="$1" role="$2" dir="$3" line key sha expected local_file rc
  line="$(bk_restore_artifact_for_role "$manifest" "$role")"
  [ -n "$line" ] || bk_die "$BK_EXIT_NOTFOUND" "backup has no artifact for role '$role'"

  key="$(printf '%s' "$line" | cut -f1)"
  sha="$(printf '%s' "$line" | cut -f2)"
  local_file="${dir}/$(basename "$key")"

  bk_info "downloading $key"
  bk_storage_download "$key" "$local_file" || bk_die "$BK_EXIT_VERIFY" "download failed: $key"

  if ! bk_stage_validate_artifact "$local_file" "$sha" "artifact $key"; then
    bk_die "$BK_EXIT_VERIFY" "checksum validation failed for $key"
  fi
  printf '%s' "$local_file"
}

# bk_restore_unwrap MANIFEST IN_FILE OUT_FILE
# Decrypt + decompress according to what the manifest recorded.
bk_restore_unwrap() {
  local in="$1" out="$2" comp="$3" enc="$4" staged detected
  staged="$in"
  if [ "$enc" = "age" ]; then
    bk_decrypt "$in" "${in}.plain" || bk_die "$BK_EXIT_ENCRYPT" "decryption failed"
    staged="${in}.plain"
  fi
  detected="$(bk_compress_magic "$staged")"
  if [ "$detected" = "unknown" ] && [ "$comp" = "none" ]; then
    mv -f "$staged" "$out"
    return 0
  fi
  if [ "$detected" = "unknown" ]; then
    bk_die "$BK_EXIT_COMPRESS" "cannot detect the compression format of the downloaded artifact (manifest says $comp)"
  fi
  bk_decompress_auto "$staged" "$out" || bk_die "$BK_EXIT_COMPRESS" "decompression failed"
  return 0
}

# bk_restore_run BACKUP_ID [--target DB] [--role primary|globals] [--dry-run]
bk_restore_run() {
  local id="$1" target="" role="primary" dir manifest db_id db_type db_name
  shift

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --target) target="${2-}"; shift 2 ;;
      --role)   role="${2-}"; shift 2 ;;
      --dry-run) BK_DRY_RUN=1; shift ;;
      --globals) role="globals"; shift ;;
      *) bk_die "$BK_EXIT_GENERAL" "unknown option for restore: $1" ;;
    esac
  done

  bk_id_valid "$id" || bk_die "$BK_EXIT_GENERAL" "invalid backup id: $id"

  manifest="$(bk_restore_manifest "$id")"
  db_id="$(bk_json_get "$manifest" '.database.id' '')"
  db_type="$(bk_json_get "$manifest" '.database.type' '')"
  db_name="$(bk_json_get "$manifest" '.database.name' '')"

  [ -n "$db_id" ] || bk_die "$BK_EXIT_RESTORE" "manifest is missing database.id"

  if [ "$role" = "primary" ] && [ -z "$target" ]; then
    bk_die "$BK_EXIT_RESTORE" "--target <database> is required for a primary restore"
  fi

  bk_info "restore plan: backup=$id database=$db_id type=$db_type role=$role target=${target:-<none>}"

  if [ "$BK_DRY_RUN" = "1" ]; then
    bk_info "[dry-run] would download, verify, decrypt, decompress and restore; nothing was changed"
    printf '%s' "$manifest" | jq .
    return 0
  fi

  # Explicit confirmation before anything destructive.
  if [ "$role" = "globals" ]; then
    bk_confirm "This will restore PostgreSQL global objects (roles) from $id on $BK_HOSTNAME."
  else
    bk_confirm "This will OVERWRITE database '$target' on $BK_HOSTNAME with backup $id (source database was '$db_name')."
  fi

  dir="$(bk_mkworkdir "restore")"
  local downloaded plain comp enc rc
  # bk_restore_download_artifact reports failures through its exit status, so
  # the status has to be checked here: a bk_die inside the command substitution
  # would only terminate the subshell.
  downloaded="$(bk_restore_download_artifact "$manifest" "$role" "$dir")" || {
    rc=$?
    return "$rc"
  }
  comp="$(printf '%s' "$manifest" | jq -r --arg role "$role" '(.artifacts // [])[] | select(.role == $role) | .compression // "none"' | head -1)"
  enc="$(printf '%s' "$manifest" | jq -r --arg role "$role" '(.artifacts // [])[] | select(.role == $role) | .encryption // "none"' | head -1)"
  plain="${dir}/payload"
  bk_restore_unwrap "$downloaded" "$plain" "$comp" "$enc"

  bk_info "restoring $role artifact into ${target:-globals}"
  if bk_driver_restore "$db_id" "$role" "$plain" "$target"; then
    bk_info "restore completed for $id"
    bk_notify "restore" "Restore completed: $db_id" "backup: \`$id\`\nrole: $role\ntarget: ${target:-globals}"
    return 0
  fi
  bk_warn "restore FAILED for $id"
  bk_notify "restore_failed" "Restore FAILED: $db_id" "backup: \`$id\`\nrole: $role"
  return "$BK_EXIT_RESTORE"
}
