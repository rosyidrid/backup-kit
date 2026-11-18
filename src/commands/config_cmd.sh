#!/usr/bin/env bash
# BackupKit - src/commands/config_cmd.sh
# 'backupkit config validate' / 'config show' / 'config path'

bk_cmd_config() {
  local sub="${1-help}"
  [ "$#" -gt 0 ] && shift

  case "$sub" in
    validate)
      bk_config_load
      local errors
      if errors="$(bk_config_validate)"; then
        printf 'config OK: %s\n' "$BK_CONFIG_FILE"
        printf 'secrets    : %s%s\n' "$BK_SECRETS_FILE" "$([ -f "$BK_SECRETS_FILE" ] || printf ' (missing)')"
        printf 'databases  : %s\n' "$(bk_db_ids | tr '\n' ' ')"
        return 0
      fi
      printf 'config INVALID: %s\n' "$BK_CONFIG_FILE" >&2
      printf '%s\n' "$errors" >&2
      return "$BK_EXIT_CONFIG"
      ;;
    show)
      bk_config_load
      # Secrets are replaced by placeholders: this output is safe to paste.
      printf '%s' "$CONFIG_JSON" | jq .
      local redacted
      redacted="$(printf '%s' "$BK_SECRETS_JSON" | jq 'walk(if type == "string" and length > 0 then "[REDACTED]" else . end)')"
      printf '\n// secrets.json (values redacted)\n%s\n' "$redacted"
      ;;
    path)
      bk_config_load 2>/dev/null || true
      printf 'config : %s\n' "$BK_CONFIG_FILE"
      printf 'secrets: %s\n' "$BK_SECRETS_FILE"
      printf 'key    : %s\n' "$(bk_identity_file)"
      ;;
    -h|--help|help|'')
      cat <<'EOF'
Usage: backupkit config <validate|show|path>

  validate  parse and check the configuration, report every problem
  show      print the effective config with secrets redacted
  path      print the config, secrets and key file locations
EOF
      return 0
      ;;
    *)
      printf 'backupkit: error: unknown config subcommand: %s\n\n' "$sub" >&2
      printf 'Usage: backupkit config <validate|show|path>\n' >&2
      return "$BK_EXIT_GENERAL"
      ;;
  esac
}
