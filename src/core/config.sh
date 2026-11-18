#!/usr/bin/env bash
# BackupKit - src/core/config.sh
#
# Configuration loading and validation.
#
# Two files, deliberately separated:
#   config.json   non-secret settings  (0600 recommended, 0640 accepted)
#   secrets.json  credentials          (must be 0600)
#
# Configuration is read as JSON with jq and never evaluated as shell code.

CONFIG_JSON=""
BK_TZ="Asia/Jakarta"

bk_config_exists() {
  [ -f "$BK_CONFIG_FILE" ]
}

bk_perm_bits() {
  # Octal permission bits, portable between BSD and GNU stat.
  local f="$1"
  if stat -f '%Lp' "$f" >/dev/null 2>&1; then
    stat -f '%Lp' "$f"
  else
    stat -c '%a' "$f"
  fi
}

bk_perms_too_open() {
  # $1 = file, $2 = human description -> warns/errors for group/other bits.
  local f="$1" what="$2" bits
  [ -f "$f" ] || return 0
  bits="$(bk_perm_bits "$f")"
  case "$bits" in
    600|400|0) return 1 ;;
  esac
  if [ "$BK_ALLOW_INSECURE_PERMS" = "1" ]; then
    bk_warn "$what has permissions $bits; allowed because BK_ALLOW_INSECURE_PERMS=1 (development only)"
    return 1
  fi
  bk_die "$BK_EXIT_CONFIG" "$what must be readable by the owner only, found permissions $bits. Run: chmod 600 $f"
}

bk_config_load() {
  [ -f "$BK_CONFIG_FILE" ] || bk_die "$BK_EXIT_CONFIG" "config file not found: $BK_CONFIG_FILE (run 'backupkit init')"

  bk_need_cmd jq

  CONFIG_JSON="$(jq -c '.' "$BK_CONFIG_FILE" 2>/dev/null)" || CONFIG_JSON=""
  if [ -z "$CONFIG_JSON" ]; then
    bk_die "$BK_EXIT_CONFIG" "config file is not valid JSON: $BK_CONFIG_FILE"
  fi

  BK_TZ="$(bk_cfg '.timezone' 'Asia/Jakarta')"

  if [ -f "$BK_SECRETS_FILE" ]; then
    bk_perms_too_open "$BK_SECRETS_FILE" "secrets file ($BK_SECRETS_FILE)"
    BK_SECRETS_JSON="$(jq -c '.' "$BK_SECRETS_FILE" 2>/dev/null)" || BK_SECRETS_JSON=""
    [ -n "$BK_SECRETS_JSON" ] || bk_die "$BK_EXIT_CONFIG" "secrets file is not valid JSON: $BK_SECRETS_FILE"
  else
    BK_SECRETS_JSON="{}"
  fi
}

# bk_cfg JQ_PATH [DEFAULT]
bk_cfg() {
  local path="$1" def="${2-}"
  bk_json_get "$CONFIG_JSON" "$path" "$def"
}

bk_secret() {
  # bk_secret JQ_PATH [DEFAULT]
  local path="$1" def="${2-}"
  bk_json_get "$BK_SECRETS_JSON" "$path" "$def"
}

# ---------------------------------------------------------------------------
# Database accessors
# ---------------------------------------------------------------------------

bk_db_ids() {
  printf '%s' "$CONFIG_JSON" | jq -r '.databases // [] | .[].id' 2>/dev/null
}

bk_db_json() {
  # bk_db_json DB_ID -> compact JSON object or empty
  local id="$1"
  printf '%s' "$CONFIG_JSON" | jq -c --arg id "$id" '.databases // [] | map(select(.id == $id)) | .[0] // empty' 2>/dev/null
}

bk_db_field() {
  # bk_db_field DB_ID JQ_PATH [DEFAULT]
  local id="$1" path="$2" def="${3-}"
  local obj
  obj="$(bk_db_json "$id")"
  [ -n "$obj" ] || { printf '%s' "$def"; return 0; }
  bk_json_get "$obj" "$path" "$def"
}

bk_db_type() {
  bk_db_field "$1" '.type' ''
}

bk_db_name() {
  bk_db_field "$1" '.database' "$1"
}

bk_db_enabled() {
  [ "$(bk_db_field "$1" '.enabled' 'true')" = "true" ]
}

bk_db_schedule() {
  # bk_db_schedule DB_ID TYPE -> true/false
  local id="$1" type="$2"
  [ "$(bk_db_field "$id" ".schedule.${type}" 'false')" = "true" ]
}

bk_db_retention() {
  # bk_db_retention DB_ID TYPE -> integer, falls back to global retention
  local id="$1" type="$2" value
  value="$(bk_db_field "$id" ".retention.${type}" '')"
  if [ -z "$value" ]; then
    value="$(bk_cfg ".retention.${type}" '')"
  fi
  if [ -z "$value" ]; then
    case "$type" in
      daily)   value=7 ;;
      weekly)  value=4 ;;
      monthly) value=12 ;;
      *)       value=0 ;;
    esac
  fi
  printf '%s' "$value"
}

bk_db_extra_dump_opts() {
  # Optional array of extra argv entries for the dump tool.
  local id="$1" obj
  obj="$(bk_db_json "$id")"
  [ -n "$obj" ] || return 0
  printf '%s' "$obj" | jq -r '(.dump_options // [])[]' 2>/dev/null
}

bk_db_config_ids() {
  # Backup ids of databases with at least one enabled schedule.
  local id
  for id in $(bk_db_ids); do
    bk_db_enabled "$id" || continue
    if bk_db_schedule "$id" daily || bk_db_schedule "$id" weekly || bk_db_schedule "$id" monthly; then
      printf '%s\n' "$id"
    fi
  done
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

BK_VALIDATION_ERRORS=""

bk_validate_error() {
  BK_VALIDATION_ERRORS="${BK_VALIDATION_ERRORS}${BK_VALIDATION_ERRORS:+
}$1"
}

bk_is_int() {
  printf '%s' "$1" | grep -Eq '^[0-9]+$'
}

bk_config_validate() {
  # Prints validation errors, one per line. Empty output means valid.
  BK_VALIDATION_ERRORS=""

  if [ -z "$CONFIG_JSON" ]; then
    bk_validate_error "config is empty or unreadable: $BK_CONFIG_FILE"
    printf '%s\n' "$BK_VALIDATION_ERRORS"
    return 1
  fi

  bk_need_cmd jq

  # --- timezone -------------------------------------------------------------
  local tz
  tz="$(bk_cfg '.timezone' '')"
  [ -n "$tz" ] || bk_validate_error ".timezone is required (example: Asia/Jakarta)"
  if [ -n "$tz" ] && ! TZ="$tz" date +%Y >/dev/null 2>&1; then
    bk_validate_error ".timezone '$tz' is not a valid TZ identifier"
  fi

  # --- storage --------------------------------------------------------------
  local provider endpoint bucket prefix
  provider="$(bk_cfg '.storage.provider' '')"
  endpoint="$(bk_cfg '.storage.endpoint' '')"
  bucket="$(bk_cfg '.storage.bucket' '')"
  prefix="$(bk_cfg '.storage.prefix' '')"

  case "$provider" in
    '')        bk_validate_error ".storage.provider is required (cloudflare-r2, s3, local)" ;;
    cloudflare-r2)
               [ -n "$endpoint" ] || bk_validate_error "cloudflare-r2 requires .storage.endpoint (https://<account_id>.r2.cloudflarestorage.com)"
               case "$endpoint" in
                 https://*.r2.cloudflarestorage.com*) ;;
                 *) bk_validate_error ".storage.endpoint for cloudflare-r2 must look like https://<account_id>.r2.cloudflarestorage.com" ;;
               esac
               [ -n "$bucket" ] || bk_validate_error "cloudflare-r2 requires .storage.bucket"
               ;;
    s3)        [ -n "$bucket" ] || bk_validate_error "s3 requires .storage.bucket"
               case "$endpoint" in
                 ''|https://*) ;;
                 http://127.0.0.1*|http://localhost*) ;;
                 *) bk_validate_error ".storage.endpoint must be an https URL (http only allowed for localhost)"
               esac
               ;;
    local)     [ -n "$(bk_cfg '.storage.local.path' '')" ] || bk_validate_error "local provider requires .storage.local.path" ;;
    *)         bk_validate_error ".storage.provider '$provider' is not supported" ;;
  esac

  if [ -n "$prefix" ]; then
    case "$prefix" in
      /*|*..*|*' '*) bk_validate_error ".storage.prefix must be a relative path without spaces or '..'" ;;
    esac
  fi

  # --- encryption -----------------------------------------------------------
  local enc_enabled allow_plain
  enc_enabled="$(bk_cfg '.encryption.enabled' 'true')"
  allow_plain="$(bk_cfg '.encryption.allow_plaintext' 'false')"

  if [ "$enc_enabled" != "true" ] && [ "$allow_plain" != "true" ]; then
    bk_validate_error "encryption.enabled=false requires encryption.allow_plaintext=true to acknowledge that plaintext leaves the host"
  fi
  if [ "$enc_enabled" = "true" ]; then
    if [ -z "$(bk_cfg '.encryption.recipient' '')" ] && [ -z "$(bk_cfg '.encryption.recipients_file' '')" ]; then
      bk_validate_error "encryption.recipient is required when encryption.enabled=true"
    fi
    case "$(bk_cfg '.encryption.recipient' '')" in
      ''|age1*) ;;
      *) bk_validate_error "encryption.recipient must be an age public key starting with 'age1'" ;;
    esac
  fi

  # --- compression ----------------------------------------------------------
  case "$(bk_cfg '.compression.algorithm' 'zstd')" in
    zstd|gzip) ;;
    *) bk_validate_error ".compression.algorithm must be zstd or gzip" ;;
  esac
  local level
  level="$(bk_cfg '.compression.level' '10')"
  bk_is_int "$level" || bk_validate_error ".compression.level must be an integer"

  # --- notifications --------------------------------------------------------
  if [ "$(bk_cfg '.notifications.telegram.enabled' 'false')" = "true" ]; then
    if [ -z "$(bk_secret '.notifications.telegram.bot_token' '')" ]; then
      bk_validate_error "notifications.telegram.enabled=true but secrets.notifications.telegram.bot_token is missing"
    fi
    if [ -z "$(bk_secret '.notifications.telegram.chat_id' '')" ]; then
      bk_validate_error "notifications.telegram.enabled=true but secrets.notifications.telegram.chat_id is missing"
    fi
  fi

  # --- databases ------------------------------------------------------------
  local count
  count="$(printf '%s' "$CONFIG_JSON" | jq -r '.databases | if type == "array" then length else -1 end' 2>/dev/null)"
  case "$count" in
    -1) bk_validate_error ".databases must be an array" ;;
    0)  bk_validate_error ".databases must contain at least one entry" ;;
  esac

  if [ "${count:-0}" -gt 0 ] 2>/dev/null; then
    local id type dbname ret
    for id in $(bk_db_ids); do
      bk_db_id_valid "$id" || bk_validate_error "database id '$id' must match ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"

      type="$(bk_db_type "$id")"
      case "$type" in
        mysql|mariadb|postgres|postgresql) ;;
        '') bk_validate_error "database '$id' is missing .type" ;;
        *)  bk_validate_error "database '$id' has unsupported .type '$type' (mysql, mariadb, postgres)" ;;
      esac

      dbname="$(bk_db_field "$id" '.database' '')"
      [ -n "$dbname" ] || bk_validate_error "database '$id' is missing .database"

      local s
      for s in daily weekly monthly; do
        local sval
        sval="$(bk_db_field "$id" ".schedule.${s}" '')"
        case "$sval" in
          ''|true|false) ;;
          *) bk_validate_error "database '$id' .schedule.${s} must be true or false" ;;
        esac
      done

      local t
      for t in daily weekly monthly; do
        ret="$(bk_db_field "$id" ".retention.${t}" '')"
        if [ -n "$ret" ]; then
          if ! bk_is_int "$ret"; then
            bk_validate_error "database '$id' .retention.${t} must be a non-negative integer"
          fi
        fi
      done

      if [ "$(bk_db_field "$id" '.globals' 'false')" = "true" ]; then
        case "$type" in
          postgres|postgresql) ;;
          *) bk_validate_error "database '$id' sets .globals=true which is only supported for postgres" ;;
        esac
      fi

      # Credentials must live in the secrets file, never in config.json.
      if [ -n "$(bk_db_field "$id" '.password' '')" ]; then
        bk_validate_error "database '$id' contains a .password in config.json; move credentials to $BK_SECRETS_FILE"
      fi
    done
  fi

  if [ -n "$BK_VALIDATION_ERRORS" ]; then
    printf '%s\n' "$BK_VALIDATION_ERRORS"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Credential lookups (secrets file only)
# ---------------------------------------------------------------------------

bk_db_cred() {
  # bk_db_cred DB_ID KEY [DEFAULT]
  local id="$1" key="$2" def="${3-}"
  # Per-database credentials first, then a shared default block.
  local v
  v="$(bk_secret ".databases.\"${id}\".${key}" '')"
  if [ -z "$v" ]; then
    v="$(bk_secret ".databases_default.${key}" '')"
  fi
  [ -n "$v" ] || v="$def"
  printf '%s' "$v"
}

bk_storage_cred() {
  bk_secret ".storage.$1" "${2-}"
}
