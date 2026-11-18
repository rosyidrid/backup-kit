#!/usr/bin/env bash
# BackupKit - src/commands/doctor.sh
#
# 'backupkit doctor' checks every dependency the configured setup needs and
# reports what is missing before a scheduled backup discovers it at 02:00.

BK_DOCTOR_FAILS=0
BK_DOCTOR_WARNS=0

bk_doctor_ok()   { printf '  [ ok ]   %s\n' "$1"; [ -n "${2-}" ] && printf '           %s\n' "$2"; return 0; }
bk_doctor_warn() {
  BK_DOCTOR_WARNS=$((BK_DOCTOR_WARNS + 1))
  printf '  [ warn ] %s\n' "$1"
  [ -n "${2-}" ] && printf '           %s\n' "$2"
  return 0
}
bk_doctor_fail() {
  BK_DOCTOR_FAILS=$((BK_DOCTOR_FAILS + 1))
  printf '  [ FAIL ] %s\n' "$1"
  [ -n "${2-}" ] && printf '           %s\n' "$2"
  return 0
}

bk_doctor_version_num() {
  # First major version number in a version string.
  printf '%s' "$1" | grep -Eo '[0-9]+(\.[0-9]+)+' | head -1
}

bk_doctor_major() {
  printf '%s' "$1" | cut -d. -f1
}

bk_cmd_doctor() {
  local connect=1
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --no-connect) connect=0; shift ;;
      -h|--help)
        cat <<'EOF'
Usage: backupkit doctor [--no-connect]

  --no-connect   skip the live database/cache connectivity probes
EOF
        return 0 ;;
      *) bk_die "$BK_EXIT_GENERAL" "unknown option for doctor: $1" ;;
    esac
  done

  printf 'BackupKit %s doctor on %s\n\n' "${BACKUPKIT_VERSION:-unknown}" "$BK_HOSTNAME"

  printf 'core\n'
  local missing
  missing="$(bk_missing_cmds bash jq awk sed grep date mktemp find cut)"
  if [ -n "$missing" ]; then
    bk_doctor_fail "missing core commands: $missing"
  else
    bk_doctor_ok "core commands present"
  fi
  if bk_have sha256sum || bk_have shasum; then
    bk_doctor_ok "SHA-256 tool present ($(bk_have sha256sum && printf sha256sum || printf shasum))"
  else
    bk_doctor_fail "no SHA-256 tool (install coreutils)"
  fi
  printf '  bash version: %s\n' "$BASH_VERSION"

  printf '\nconfiguration\n'
  if ! bk_config_exists; then
    bk_doctor_fail "no config file at $BK_CONFIG_FILE" "run 'backupkit init'"
    bk_doctor_summary
    return "$BK_EXIT_CONFIG"
  fi

  local perms
  perms="$(bk_perm_bits "$BK_CONFIG_FILE" 2>/dev/null || printf '?')"
  if [ "$perms" = "600" ] || [ "$perms" = "400" ]; then
    bk_doctor_ok "config permissions $perms"
  else
    bk_doctor_warn "config permissions are $perms" "chmod 600 $BK_CONFIG_FILE"
  fi

  if [ -f "$BK_SECRETS_FILE" ]; then
    perms="$(bk_perm_bits "$BK_SECRETS_FILE" 2>/dev/null || printf '?')"
    if [ "$perms" = "600" ] || [ "$perms" = "400" ]; then
      bk_doctor_ok "secrets permissions $perms"
    else
      bk_doctor_fail "secrets permissions are $perms" "chmod 600 $BK_SECRETS_FILE"
    fi
  else
    bk_doctor_warn "no secrets file at $BK_SECRETS_FILE" "credentials may be missing"
  fi

  bk_config_load 2>/dev/null || { bk_doctor_fail "cannot load config"; bk_doctor_summary; return "$BK_EXIT_CONFIG"; }

  local errors
  if errors="$(bk_config_validate)"; then
    bk_doctor_ok "config is valid (timezone $BK_TZ)"
  else
    bk_doctor_fail "config validation failed"
    printf '%s\n' "$errors" | sed 's/^/           /'
  fi

  printf '\nstate and logs\n'
  for d in "$BK_STATE_DIR" "$BK_LOG_DIR"; do
    if [ -d "$d" ] && [ -w "$d" ]; then
      bk_doctor_ok "$d is writable"
    elif [ -d "$d" ]; then
      bk_doctor_fail "$d is not writable" "check ownership"
    else
      bk_doctor_warn "$d does not exist yet" "it will be created on the first run"
    fi
  done

  local free_kb
  free_kb="$(df -Pk "$(dirname "$BK_STATE_DIR")" 2>/dev/null | awk 'NR==2 {print $4}')"
  if [ -n "$free_kb" ] && [ "$free_kb" -gt 0 ] 2>/dev/null; then
    if [ "$free_kb" -lt 1048576 ]; then
      bk_doctor_warn "only $(bk_human_size $((free_kb * 1024))) free on $(dirname "$BK_STATE_DIR")" "dumps need temporary space"
    else
      bk_doctor_ok "free space: $(bk_human_size $((free_kb * 1024)))"
    fi
  fi

  printf '\nencryption\n'
  if bk_encryption_enabled; then
    if bk_have age; then
      bk_doctor_ok "age present"
    else
      bk_doctor_fail "age not found" "apt-get install -y age  (encryption is enabled)"
    fi
    local identity pub recipient
    identity="$(bk_identity_file)"
    if [ -f "$identity" ]; then
      perms="$(bk_perm_bits "$identity" 2>/dev/null || printf '?')"
      if [ "$perms" = "600" ] || [ "$perms" = "400" ]; then
        bk_doctor_ok "identity file permissions $perms"
      else
        bk_doctor_fail "identity file permissions are $perms" "chmod 600 $identity"
      fi
      recipient="$(bk_cfg '.encryption.recipient' '')"
      pub="$(bk_encryption_public_key_for_identity "$identity" 2>/dev/null || printf '')"
      if [ -z "$pub" ]; then
        bk_doctor_warn "cannot derive the public key from $identity" "age-keygen is required to check"
      elif [ "$pub" = "$recipient" ]; then
        bk_doctor_ok "identity matches the configured recipient"
      else
        bk_doctor_fail "identity does not match .encryption.recipient" "expected $recipient, key is $pub"
      fi
    else
      bk_doctor_fail "identity file not found: $identity" "restores are impossible without it"
    fi
  else
    bk_doctor_warn "encryption is disabled" "plaintext backups leave the host; keep this only for lab use"
  fi

  printf '\ncompression\n'
  local algo
  algo="$(bk_compression_algo)"
  if bk_have "$algo"; then
    bk_doctor_ok "$algo present (level $(bk_compression_level))"
  else
    bk_doctor_fail "$algo not found"
  fi

  printf '\nstorage\n'
  local provider
  provider="$(bk_storage_provider)"
  printf '  provider: %s\n' "$provider"
  missing="$(bk_missing_cmds $(bk_storage_required_cmds))"
  if [ -n "$missing" ]; then
    bk_doctor_fail "missing storage command(s): $missing"
  else
    if bk_storage_init_provider 2>/dev/null; then
      if bk_storage_check; then
        bk_doctor_ok "storage reachable"
      else
        bk_doctor_fail "storage check failed" "verify bucket, endpoint and credentials"
      fi
    else
      bk_doctor_fail "cannot initialise storage provider"
    fi
  fi

  printf '\ndatabases\n'
  local id
  for id in $(bk_db_ids); do
    local dbt missing_cmds client_v server_v
    dbt="$(bk_db_type "$id")"
    printf '  %s (%s)\n' "$id" "$dbt"
    if ! bk_db_enabled "$id"; then
      printf '    disabled in config\n'
      continue
    fi
    missing_cmds="$(bk_missing_cmds $(bk_driver_required_cmds "$id"))"
    if [ -n "$missing_cmds" ]; then
      bk_doctor_fail "missing client command(s) for $id: $missing_cmds"
      continue
    fi

    case "$(bk_driver_kind "$id")" in
      mysql)
        client_v="$(bk_mysql_client_version)"
        server_v="$(bk_mysql_server_version "$id" 2>/dev/null || printf '')"
        ;;
      postgres)
        client_v="$(bk_pg_client_version)"
        server_v="$(bk_pg_server_version "$id" 2>/dev/null || printf '')"
        ;;
    esac

    if [ -z "$server_v" ]; then
      if [ "$connect" = "1" ]; then
        bk_doctor_fail "cannot query server version for $id" "check host, port and credentials"
      else
        bk_doctor_warn "server version unknown for $id (--no-connect)"
      fi
    else
      local cm sm
      cm="$(bk_doctor_major "$(bk_doctor_version_num "$client_v")")"
      sm="$(bk_doctor_major "$(bk_doctor_version_num "$server_v")")"
      if [ "$(bk_driver_kind "$id")" = "postgres" ] && [ -n "$cm" ] && [ -n "$sm" ] && [ "$cm" -lt "$sm" ] 2>/dev/null; then
        bk_doctor_fail "pg_dump $cm is older than server $sm for $id" "pg_dump must be >= the server version"
      elif [ -n "$cm" ] && [ -n "$sm" ] && [ "$cm" != "$sm" ]; then
        bk_doctor_warn "client $cm / server $sm version mismatch for $id" "backups usually still work; restore is the risky direction"
      else
        bk_doctor_ok "client/server versions compatible (client $(bk_doctor_version_num "$client_v"), server $(bk_doctor_version_num "$server_v"))"
      fi
    fi

    if [ "$connect" = "1" ]; then
      case "$(bk_driver_kind "$id")" in
        mysql)
          local cnf
          cnf="$(bk_mysql_cnf "$id")"
          if "$(bk_mysql_client_bin)" --defaults-extra-file="$cnf" -N -B -e 'SELECT 1' >/dev/null 2>&1; then
            bk_doctor_ok "connection test ok"
          else
            bk_doctor_fail "connection test failed for $id"
          fi ;;
        postgres)
          local passfile
          passfile="$(bk_pg_passfile "$id")"
          if PGPASSFILE="$passfile" "$(bk_pg_psql_bin)" $(bk_pg_common_args "$id") --dbname "$(bk_db_name "$id")" -tAc 'SELECT 1' >/dev/null 2>&1; then
            bk_doctor_ok "connection test ok"
          else
            bk_doctor_fail "connection test failed for $id"
          fi ;;
      esac
    fi
  done

  printf '\nlocks and scheduling\n'
  local stale=0
  for id in $(bk_db_ids); do
    if bk_lock_held "db-${id}"; then
      bk_doctor_warn "a backup appears to be running for $id" "if it is not, remove $BK_LOCK_DIR/db-${id}.lock"
      stale=$((stale + 1))
    fi
  done
  [ "$stale" -eq 0 ] && bk_doctor_ok "no active locks"

  if bk_cron_installed; then
    bk_doctor_ok "cron entries installed ($(bk_cron_file))"
  else
    bk_doctor_warn "no cron entries installed" "run 'backupkit install-scheduler'"
  fi

  bk_doctor_summary
}

bk_doctor_summary() {
  printf '\nsummary: %s failure(s), %s warning(s)\n' "$BK_DOCTOR_FAILS" "$BK_DOCTOR_WARNS"
  [ "$BK_DOCTOR_FAILS" -eq 0 ] && printf 'result: healthy\n' || printf 'result: attention required\n'
  [ "$BK_DOCTOR_FAILS" -eq 0 ] || return "$BK_EXIT_GENERAL"
  return 0
}
