#!/usr/bin/env bash
# BackupKit - src/retention/retention.sh
#
# Retention management. Rules, in order of precedence:
#
#   1. Only objects that BackupKit created are considered. A key must live
#      under the configured storage prefix and have a matching manifest.
#   2. Only manifests with status "verified" can be deleted.
#   3. A backup tagged with several types (a snapshot that served daily and
#      weekly at once) is deleted only when it is out of policy for *every*
#      tag it carries.
#   4. The newest verified backup of a database is never deleted.
#   5. A retention value of 0 disables deletion for that type (keep forever).
#   6. Cleanup runs only after a new backup has been uploaded and verified, or
#      when an operator runs 'backupkit cleanup' explicitly.

bk_retention_min_age_hours() {
  bk_cfg '.retention.min_age_hours' '0'
}

# bk_retention_inventory DB_ID
# TSV, newest first:
#   created_epoch <TAB> backup_id <TAB> types <TAB> status <TAB> manifest_key <TAB> artifact_keys(comma)
bk_retention_inventory() {
  local db_id="$1" prefix key tmp manifest created types status mkey akeys
  prefix="$(bk_storage_db_prefix "$db_id")"

  local keys_file
  keys_file="$(mktemp "${TMPDIR:-/tmp}/bkinv.XXXXXX")"
  bk_tmp_register "$keys_file"
  bk_storage_list "$prefix" 2>/dev/null | grep -F "$(bk_storage_manifest_suffix)" >"$keys_file" || true

  local lines_file
  lines_file="$(mktemp "${TMPDIR:-/tmp}/bkinv.XXXXXX")"
  bk_tmp_register "$lines_file"

  while IFS= read -r key; do
    [ -n "$key" ] || continue
    manifest=""
    # Prefer the local copy: it is free to read and identical after upload.
    local id_from_key
    id_from_key="$(basename "$key" .manifest.json)"
    if bk_id_valid "$id_from_key"; then
      manifest="$(bk_manifest_read "$id_from_key")"
    fi
    if [ -z "$manifest" ]; then
      tmp="$(mktemp "${TMPDIR:-/tmp}/bkman.XXXXXX")"
      if bk_storage_download "$key" "$tmp" 2>/dev/null; then
        manifest="$(jq -c '.' "$tmp" 2>/dev/null || printf '')"
      fi
      rm -f -- "$tmp"
    fi
    [ -n "$manifest" ] || continue

    created="$(bk_json_get "$manifest" '.created_at' '')"
    [ -n "$created" ] || continue
    types="$(bk_manifest_types "$manifest")"
    status="$(bk_json_get "$manifest" '.status' '')"
    akeys="$(bk_manifest_artifact_keys "$manifest" | paste -sd, -)"

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(bk_epoch_of "$created")" \
      "$(bk_json_get "$manifest" '.id' "$id_from_key")" \
      "$types" "$status" "$key" "$akeys" >>"$lines_file"
  done <"$keys_file"

  sort -t "$(printf '\t')" -k1,1nr "$lines_file" 2>/dev/null || cat "$lines_file"
}

# bk_retention_plan DB_ID
# TSV of backups to delete: backup_id <TAB> manifest_key <TAB> artifact_keys(comma)
bk_retention_plan() {
  local db_id="$1" min_age inv min_epoch
  min_age="$(bk_retention_min_age_hours)"
  # A backup is eligible only when it is older than min_age_hours.
  min_epoch=$(( $(date +%s) - (min_age * 3600) ))

  inv="$(bk_retention_inventory "$db_id")"
  [ -n "$inv" ] || return 0

  printf '%s\n' "$inv" | awk -F'\t' \
    -v ld="$(bk_db_retention "$db_id" daily)" \
    -v lw="$(bk_db_retention "$db_id" weekly)" \
    -v lm="$(bk_db_retention "$db_id" monthly)" \
    -v min_epoch="$min_epoch" '
    BEGIN {
      lim["daily"] = ld + 0
      lim["weekly"] = lw + 0
      lim["monthly"] = lm + 0
      split("daily weekly monthly", T, " ")
      newest_id = ""
    }
    {
      epoch = $1 + 0
      id = $2
      tagstr = $3
      status = $4
      mkey = $5
      akeys = $6

      if (status != "verified") next
      if (id == "") next
      if (newest_id == "") newest_id = id
      # Newer than the minimum age: protected from deletion.
      if (epoch > min_epoch) next

      tagof[id] = tagstr
      mkeyof[id] = mkey
      akeyof[id] = akeys
      seen[id] = 1

      n = split(tagstr, tags, ",")
      for (k = 1; k <= n; k++) {
        t = tags[k]
        if (!(t in lim)) continue
        if (lim[t] <= 0) continue
        count[t]++
        rank[id SUBSEP t] = count[t]
      }
    }
    END {
      for (id in seen) {
        if (id == newest_id) continue
        if (tagof[id] == "") continue   # no retention tag: never delete
        n = split(tagof[id], tags, ",")
        deletable = 1
        for (k = 1; k <= n; k++) {
          t = tags[k]
          if (!(t in lim)) { deletable = 0; break }
          if (lim[t] <= 0) { deletable = 0; break }
          r = rank[id SUBSEP t]
          if (r == "") { deletable = 0; break }
          if (r <= lim[t]) { deletable = 0; break }
        }
        if (deletable) printf "%s\t%s\t%s\n", id, mkeyof[id], akeyof[id]
      }
    }'
}

# bk_retention_apply DB_ID [--dry-run]
bk_retention_apply() {
  local db_id="$1" dry="${2:-}" plan id mkey akeys key rc=0 deleted=0 failed=0
  plan="$(bk_retention_plan "$db_id")"
  if [ -z "$plan" ]; then
    bk_debug "retention: nothing to delete for $db_id"
    printf '0'
    return 0
  fi

  while IFS="$(printf '\t')" read -r id mkey akeys; do
    [ -n "$id" ] || continue
    if [ "$dry" = "--dry-run" ] || [ "$BK_DRY_RUN" = "1" ]; then
      bk_info "[dry-run] would delete $id ($mkey)"
      deleted=$((deleted + 1))
      continue
    fi

    # Delete artifacts first, manifest last: a crash mid-way leaves a manifest
    # without artifacts, which verify/restore will report as a failure rather
    # than silently restoring a partial backup.
    local ok=1
    local IFS_OLD="$IFS"
    IFS=','
    for key in $akeys; do
      IFS="$IFS_OLD"
      [ -n "$key" ] || continue
      if bk_storage_delete "$key"; then
        bk_debug "retention: deleted $key"
      else
        bk_warn "retention: failed to delete $key"
        ok=0
      fi
      IFS=','
    done
    IFS="$IFS_OLD"

    if [ "$ok" -eq 1 ]; then
      bk_storage_delete "$mkey" || { bk_warn "retention: failed to delete manifest $mkey"; ok=0; }
    fi

    if [ "$ok" -eq 1 ]; then
      bk_manifest_local_path "$id" >/dev/null 2>&1
      rm -f -- "$(bk_manifest_local_path "$id")" 2>/dev/null || true
      bk_info "retention: removed expired backup $id"
      deleted=$((deleted + 1))
      bk_event "retention_delete" "$(jq -cn --arg id "$id" --arg db "$db_id" --arg key "$mkey" '{backup_id:$id,database:$db,manifest_key:$key}')"
    else
      failed=$((failed + 1))
      rc="$BK_EXIT_RETENTION"
    fi
  done <<EOF
$plan
EOF

  printf '%s' "$deleted"
  return "$rc"
}

bk_retention_summary() {
  # bk_retention_summary DB_ID -> "daily=3/7 weekly=1/4 monthly=0/12"
  local db_id="$1" inv t count limit out=""
  inv="$(bk_retention_inventory "$db_id")"
  for t in daily weekly monthly; do
    limit="$(bk_db_retention "$db_id" "$t")"
    count=0
    if [ -n "$inv" ]; then
      count="$(printf '%s\n' "$inv" | awk -F'\t' -v t="$t" '
        $4 == "verified" {
          n = split($3, tags, ",")
          for (k = 1; k <= n; k++) if (tags[k] == t) { c++; break }
        }
        END { print c + 0 }')"
    fi
    out="${out}${out:+ }${t}=${count}/${limit}"
  done
  printf '%s' "$out"
}
