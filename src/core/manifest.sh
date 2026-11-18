#!/usr/bin/env bash
# BackupKit - src/core/manifest.sh
#
# The manifest is the authoritative record for one backup: what was uploaded,
# where, its checksum, which retention categories it belongs to and whether it
# was verified. Retention and restore both trust the manifest, never a
# filename guess.

BK_MANIFEST_SCHEMA_VERSION=1

bk_manifest_artifact_json() {
  # bk_manifest_artifact_json ROLE KEY SHA256 SIZE_BYTES COMPRESSION ENCRYPTION
  local role="$1" key="$2" sha="$3" size="$4" comp="$5" enc="$6"
  jq -cn \
    --arg role "$role" \
    --arg key "$key" \
    --arg sha256 "$sha" \
    --argjson size_bytes "${size:-0}" \
    --arg compression "$comp" \
    --arg encryption "$enc" \
    --arg size_human "$(bk_human_size "${size:-0}")" \
    '{role:$role,key:$key,sha256:$sha256,size_bytes:$size_bytes,size_human:$size_human,compression:$compression,encryption:$encryption}'
}

bk_manifest_json() {
  # bk_manifest_json reads these variables from the caller:
  #   M_ID M_STATUS M_DB_ID M_DB_TYPE M_DB_NAME M_TYPES_JSON M_PRIMARY_TYPE
  #   M_CREATED_AT M_DURATION M_ARTIFACTS_JSON M_TOOL_VERSIONS M_ERROR
  local created_local
  created_local="$(bk_fmt_epoch '%Y-%m-%d %H:%M:%S %Z' "$(bk_epoch_of "$M_CREATED_AT")" 2>/dev/null || printf '%s' "$M_CREATED_AT")"

  jq -cn \
    --argjson schema_version "$BK_MANIFEST_SCHEMA_VERSION" \
    --arg id "$M_ID" \
    --arg status "$M_STATUS" \
    --arg db_id "$M_DB_ID" \
    --arg db_type "$M_DB_TYPE" \
    --arg db_name "$M_DB_NAME" \
    --argjson types "${M_TYPES_JSON:-[]}" \
    --arg primary_type "$M_PRIMARY_TYPE" \
    --arg created_at "$M_CREATED_AT" \
    --arg created_local "$created_local" \
    --arg timezone "$BK_TZ" \
    --arg host "$BK_HOSTNAME" \
    --arg version "${BACKUPKIT_VERSION:-unknown}" \
    --argjson duration_seconds "${M_DURATION:-0}" \
    --argjson artifacts "${M_ARTIFACTS_JSON:-[]}" \
    --argjson tool_versions "${M_TOOL_VERSIONS:-{\}}" \
    --argjson retention "$(bk_manifest_retention_json "$M_DB_ID")" \
    --arg error "${M_ERROR:-}" \
    '{
      schema_version: $schema_version,
      id: $id,
      status: $status,
      database: {id: $db_id, type: $db_type, name: $db_name},
      types: $types,
      primary_type: $primary_type,
      created_at: $created_at,
      created_local: $created_local,
      timezone: $timezone,
      host: $host,
      backupkit_version: $version,
      duration_seconds: $duration_seconds,
      artifacts: $artifacts,
      tool_versions: $tool_versions,
      retention: $retention,
      error: $error
    }'
}

bk_manifest_retention_json() {
  local id="$1"
  jq -cn \
    --argjson daily "$(bk_db_retention "$id" daily)" \
    --argjson weekly "$(bk_db_retention "$id" weekly)" \
    --argjson monthly "$(bk_db_retention "$id" monthly)" \
    '{daily:$daily,weekly:$weekly,monthly:$monthly}'
}

bk_manifest_field() {
  # bk_manifest_field JSON JQ_PATH [DEFAULT]
  bk_json_get "$1" "$2" "${3-}"
}

# bk_manifest_add_type MANIFEST_JSON TYPE -> manifest JSON with TYPE added
bk_manifest_add_type() {
  local json="$1" type="$2"
  printf '%s' "$json" | jq -c --arg t "$type" '.types = ((.types + [$t]) | unique)'
}

bk_manifest_types() {
  printf '%s' "$1" | jq -r '(.types // []) | join(",")' 2>/dev/null
}

bk_manifest_has_type() {
  local json="$1" type="$2"
  [ "$(printf '%s' "$json" | jq -r --arg t "$type" '(.types // []) | index($t) != null')" = "true" ]
}

bk_manifest_is_failed() {
  [ "$(bk_json_get "$1" '.status' '')" = "failed" ]
}

bk_manifest_artifact_keys() {
  # One object key per line, for every artifact in the manifest.
  printf '%s' "$1" | jq -r '(.artifacts // [])[].key' 2>/dev/null
}
