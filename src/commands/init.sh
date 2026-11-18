#!/usr/bin/env bash
# BackupKit - src/commands/init.sh
#
# 'backupkit init' scaffolds the configuration directory. It never overwrites
# an existing config, secrets file or encryption key unless --force is given
# for the non-secret files (keys and secrets are never overwritten).

bk_cmd_init() {
  local force=0 no_key=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force)  force=1; shift ;;
      --no-key) no_key=1; shift ;;
      -h|--help)
        cat <<'EOF'
Usage: backupkit init [--force] [--no-key]

Creates the configuration directory, example config/secrets files and an age
key pair. Existing files are preserved unless --force is used; secrets and
keys are never overwritten.
EOF
        return 0 ;;
      *) bk_die "$BK_EXIT_GENERAL" "unknown option for init: $1" ;;
    esac
  done

  bk_need_cmd jq
  local example_dir="${BACKUPKIT_ROOT}/config"

  mkdir -p "$BK_ETC" || bk_die "$BK_EXIT_GENERAL" "cannot create $BK_ETC (try with sudo)"
  chmod 700 "$BK_ETC"

  bk_state_init
  bk_log_dir_init

  local created=0
  if [ -f "$BK_CONFIG_FILE" ] && [ "$force" != "1" ]; then
    bk_info "kept existing config: $BK_CONFIG_FILE"
  else
    [ -f "${example_dir}/config.example.json" ] || bk_die "$BK_EXIT_GENERAL" "example config not found at ${example_dir}/config.example.json"
    ( umask 077; cp -- "${example_dir}/config.example.json" "$BK_CONFIG_FILE" )
    chmod 600 "$BK_CONFIG_FILE"
    bk_info "wrote $BK_CONFIG_FILE"
    created=1
  fi

  if [ -f "$BK_SECRETS_FILE" ]; then
    bk_info "kept existing secrets: $BK_SECRETS_FILE"
  else
    [ -f "${example_dir}/secrets.example.json" ] || bk_die "$BK_EXIT_GENERAL" "example secrets not found at ${example_dir}/secrets.example.json"
    ( umask 077; cp -- "${example_dir}/secrets.example.json" "$BK_SECRETS_FILE" )
    chmod 600 "$BK_SECRETS_FILE"
    bk_info "wrote $BK_SECRETS_FILE (fill in your credentials)"
    created=1
  fi

  if [ "$no_key" = "1" ]; then
    bk_info "skipping age key generation (--no-key)"
  elif [ -f "$BK_IDENTITY_FILE" ]; then
    bk_info "kept existing encryption key: $BK_IDENTITY_FILE"
  elif bk_have age-keygen; then
    ( umask 077; age-keygen -o "$BK_IDENTITY_FILE" ) 2>/dev/null || bk_warn "age-keygen failed; generate a key manually"
    if [ -f "$BK_IDENTITY_FILE" ]; then
      chmod 600 "$BK_IDENTITY_FILE"
      bk_info "wrote encryption key $BK_IDENTITY_FILE"
      local pub
      pub="$(bk_encryption_public_key_for_identity "$BK_IDENTITY_FILE" 2>/dev/null || printf '')"
      if [ -n "$pub" ]; then
        bk_info "age public key: $pub"
        printf 'Add this to %s as .encryption.recipient:\n  %s\n' "$BK_CONFIG_FILE" "$pub"
      fi
      bk_warn "BACK UP THIS KEY OFFLINE. Without it the backups cannot be decrypted."
    fi
  else
    bk_warn "age-keygen not found; install age and run 'age-keygen -o $BK_IDENTITY_FILE'"
  fi

  printf '\nNext steps:\n'
  printf '  1. edit %s\n' "$BK_CONFIG_FILE"
  printf '  2. fill credentials in %s\n' "$BK_SECRETS_FILE"
  printf '  3. backupkit config validate\n'
  printf '  4. backupkit doctor\n'
  printf '  5. backupkit backup --all --dry-run\n'
  printf '  6. backupkit install-scheduler\n'
  [ "$created" = "1" ] || printf '\n(nothing was overwritten; use --force to rewrite config.json)\n'
  return 0
}
