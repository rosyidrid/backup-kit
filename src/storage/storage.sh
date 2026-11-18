#!/usr/bin/env bash
# BackupKit - src/storage/storage.sh
#
# Storage abstraction. The rest of BackupKit only talks to the functions
# declared here, so adding a provider means adding one file and one case arm.
#
# Providers: cloudflare-r2, s3 (any S3-compatible endpoint), local (directory;
# intended for testing, offline mirrors and air-gapped hosts).

bk_storage_provider() {
  bk_cfg '.storage.provider' ''
}

bk_storage_bucket() {
  bk_cfg '.storage.bucket' ''
}

bk_storage_prefix() {
  bk_cfg '.storage.prefix' ''
}

bk_storage_retry_attempts() {
  bk_cfg '.storage.retry.max_attempts' '3'
}

bk_storage_retry_delay() {
  bk_cfg '.storage.retry.delay_seconds' '5'
}

bk_storage_timeout() {
  bk_cfg '.storage.timeout_seconds' '300'
}

bk_storage_required_cmds() {
  case "$(bk_storage_provider)" in
    cloudflare-r2|s3) printf 'aws\n' ;;
    local)            printf '' ;;
  esac
}

# ---------------------------------------------------------------------------
# Key handling: the only place object keys are constructed and validated.
# ---------------------------------------------------------------------------

bk_storage_key_valid() {
  # Reject anything that could escape the bucket prefix or the local root.
  local key="$1"
  [ -n "$key" ] || return 1
  case "$key" in
    /*) return 1 ;;
    *..*) return 1 ;;
    *' '*) return 1 ;;
    *'\\'*) return 1 ;;
  esac
  printf '%s' "$key" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._/-]*$'
}

bk_storage_key_allowed() {
  # A key may only be touched if it lives under our configured prefix.
  local key="$1" prefix
  prefix="$(bk_storage_prefix)"
  bk_storage_key_valid "$key" || return 1
  if [ -z "$prefix" ]; then
    return 0
  fi
  case "$key" in
    "${prefix}"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# bk_storage_key DB_ID TYPE BACKUP_ID ROLE COMP_EXT ENC_EXT
bk_storage_key() {
  local db_id="$1" type="$2" backup_id="$3" role="$4" comp_ext="$5" enc_ext="$6"
  local prefix stamp year month
  prefix="$(bk_storage_prefix)"
  # bkyyyymmddThhmmssZ_xxxx -> yyyy/mm
  stamp="${backup_id#bk_}"
  year="$(printf '%s' "$stamp" | cut -c1-4)"
  month="$(printf '%s' "$stamp" | cut -c5-6)"

  local name="${backup_id}"
  [ "$role" = "primary" ] || name="${backup_id}.${role}"
  [ -n "$comp_ext" ] && name="${name}.${comp_ext}"
  [ -n "$enc_ext" ] && name="${name}${enc_ext}"

  if [ -n "$prefix" ]; then
    printf '%s/%s/%s/%s/%s/%s\n' "$prefix" "$db_id" "$type" "$year" "$month" "$name"
  else
    printf '%s/%s/%s/%s/%s\n' "$db_id" "$type" "$year" "$month" "$name"
  fi
}

# bk_storage_manifest_key DB_ID TYPE BACKUP_ID
bk_storage_manifest_key() {
  local db_id="$1" type="$2" backup_id="$3"
  local prefix stamp year month
  prefix="$(bk_storage_prefix)"
  stamp="${backup_id#bk_}"
  year="$(printf '%s' "$stamp" | cut -c1-4)"
  month="$(printf '%s' "$stamp" | cut -c5-6)"
  if [ -n "$prefix" ]; then
    printf '%s/%s/%s/%s/%s/%s.manifest.json\n' "$prefix" "$db_id" "$type" "$year" "$month" "$backup_id"
  else
    printf '%s/%s/%s/%s/%s.manifest.json\n' "$db_id" "$type" "$year" "$month" "$backup_id"
  fi
}

bk_storage_db_prefix() {
  local db_id="$1" prefix
  prefix="$(bk_storage_prefix)"
  if [ -n "$prefix" ]; then
    printf '%s/%s/\n' "$prefix" "$db_id"
  else
    printf '%s/\n' "$db_id"
  fi
}

bk_storage_manifest_suffix() {
  printf '.manifest.json'
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

# bk_storage_init_provider -> prepares credentials/env for the provider
bk_storage_init_provider() {
  case "$(bk_storage_provider)" in
    cloudflare-r2|s3) bk_s3_init ;;
    local)            bk_local_init ;;
    *)                bk_die "$BK_EXIT_CONFIG" "unsupported storage provider: $(bk_storage_provider)" ;;
  esac
}

bk_storage_upload() {
  local file="$1" key="$2"
  bk_storage_key_valid "$key" || bk_die "$BK_EXIT_UPLOAD" "refusing to upload to unsafe key: $key"
  case "$(bk_storage_provider)" in
    cloudflare-r2|s3) bk_s3_upload "$file" "$key" ;;
    local)            bk_local_upload "$file" "$key" ;;
  esac
}

bk_storage_put_string() {
  local str="$1" key="$2"
  bk_storage_key_valid "$key" || bk_die "$BK_EXIT_UPLOAD" "refusing to write to unsafe key: $key"
  case "$(bk_storage_provider)" in
    cloudflare-r2|s3) bk_s3_put_string "$str" "$key" ;;
    local)            bk_local_put_string "$str" "$key" ;;
  esac
}

bk_storage_download() {
  local key="$1" file="$2"
  bk_storage_key_allowed "$key" || bk_die "$BK_EXIT_VERIFY" "refusing to download unrecognised key: $key"
  case "$(bk_storage_provider)" in
    cloudflare-r2|s3) bk_s3_download "$key" "$file" ;;
    local)            bk_local_download "$key" "$file" ;;
  esac
}

bk_storage_get_string() {
  local key="$1"
  bk_storage_key_allowed "$key" || bk_die "$BK_EXIT_VERIFY" "refusing to read unrecognised key: $key"
  case "$(bk_storage_provider)" in
    cloudflare-r2|s3) bk_s3_get_string "$key" ;;
    local)            bk_local_get_string "$key" ;;
  esac
}

bk_storage_delete() {
  local key="$1"
  # Deleting anything not created by BackupKit is impossible by construction.
  bk_storage_key_allowed "$key" || bk_die "$BK_EXIT_RETENTION" "refusing to delete unrecognised key: $key"
  case "$(bk_storage_provider)" in
    cloudflare-r2|s3) bk_s3_delete "$key" ;;
    local)            bk_local_delete "$key" ;;
  esac
}

bk_storage_list() {
  local prefix="$1"
  case "$(bk_storage_provider)" in
    cloudflare-r2|s3) bk_s3_list "$prefix" ;;
    local)            bk_local_list "$prefix" ;;
  esac
}

bk_storage_size() {
  # Prints the object size in bytes, or -1 when missing/unreadable.
  local key="$1"
  bk_storage_key_allowed "$key" || { printf -- '-1'; return 0; }
  case "$(bk_storage_provider)" in
    cloudflare-r2|s3) bk_s3_size "$key" ;;
    local)            bk_local_size "$key" ;;
  esac
}

bk_storage_check() {
  case "$(bk_storage_provider)" in
    cloudflare-r2|s3) bk_s3_check ;;
    local)            bk_local_check ;;
  esac
}

# ---------------------------------------------------------------------------
# Retry helper: only used for network providers, local calls are cheap.
# ---------------------------------------------------------------------------

# bk_with_retry LABEL MAX_ATTEMPTS DELAY CMD ARGS...
bk_with_retry() {
  local label="$1" max="$2" delay="$3"
  shift 3
  local attempt=1 status=0
  while :; do
    "$@" && return 0
    status=$?
    if [ "$attempt" -ge "$max" ]; then
      bk_warn "$label failed after $attempt attempt(s)"
      return "$status"
    fi
    bk_warn "$label failed (attempt $attempt/$max, exit $status); retrying in ${delay}s"
    sleep "$delay"
    attempt=$((attempt + 1))
  done
}
