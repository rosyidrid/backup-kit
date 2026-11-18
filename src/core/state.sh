#!/usr/bin/env bash
# BackupKit - src/core/state.sh
#
# Local state: manifests (authoritative copy of what was uploaded), the
# append-only execution history, and the temp/lock directories.

bk_state_init() {
  mkdir -p "$BK_STATE_DIR" "$BK_MANIFEST_DIR" "$BK_LOCK_DIR" "$BK_WORK_ROOT" || \
    bk_die "$BK_EXIT_GENERAL" "cannot create state directories under $BK_STATE_DIR"
  chmod 700 "$BK_STATE_DIR" "$BK_MANIFEST_DIR" "$BK_LOCK_DIR" "$BK_WORK_ROOT" 2>/dev/null || true
  [ -f "$BK_STATE_VERSION_FILE" ] || printf '1\n' >"$BK_STATE_VERSION_FILE"
}

bk_log_dir_init() {
  mkdir -p "$BK_LOG_DIR" 2>/dev/null || true
  chmod 700 "$BK_LOG_DIR" 2>/dev/null || true
}

bk_manifest_local_path() {
  printf '%s/%s.json' "$BK_MANIFEST_DIR" "$1"
}

bk_manifest_local_exists() {
  [ -f "$(bk_manifest_local_path "$1")" ]
}

bk_manifest_read() {
  # bk_manifest_read BACKUP_ID -> compact JSON or empty
  local f
  f="$(bk_manifest_local_path "$1")"
  [ -f "$f" ] || return 0
  jq -c '.' "$f" 2>/dev/null
}

bk_manifest_write() {
  # bk_manifest_write BACKUP_ID JSON  (atomic, 600)
  local id="$1" json="$2" f tmp
  bk_id_valid "$id" || bk_die "$BK_EXIT_GENERAL" "refusing to write manifest with invalid id: $id"
  f="$(bk_manifest_local_path "$id")"
  tmp="${f}.tmp.$$"
  printf '%s\n' "$json" | jq -c '.' >"$tmp" 2>/dev/null || { rm -f -- "$tmp"; bk_die "$BK_EXIT_GENERAL" "invalid manifest JSON for $id"; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$f"
}

bk_manifest_list_local() {
  # Newest first. Filenames encode the creation timestamp.
  local f
  [ -d "$BK_MANIFEST_DIR" ] || return 0
  for f in "$BK_MANIFEST_DIR"/*.json; do
    [ -f "$f" ] || continue
    basename "$f" .json
  done | grep -E '^bk_[0-9]{8}T[0-9]{6}Z_[a-f0-9]{4,32}$' | sort -r
}

bk_history_append() {
  # bk_history_append JSON_LINE
  local json="$1"
  bk_state_init
  printf '%s\n' "$json" | jq -c '.' >>"$BK_HISTORY_FILE" 2>/dev/null || true
  chmod 600 "$BK_HISTORY_FILE" 2>/dev/null || true
}
