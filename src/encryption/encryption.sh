#!/usr/bin/env bash
# BackupKit - src/encryption/encryption.sh
#
# Public-key encryption with age. The private key never leaves the host and is
# never uploaded: losing the key means losing the backups, by design.

bk_encryption_enabled() {
  [ "$(bk_cfg '.encryption.enabled' 'true')" = "true" ]
}

bk_identity_file() {
  # Precedence: an explicit BACKUPKIT_IDENTITY wins (tests, CI, non-root
  # installs), then the configured path, then the default location.
  local cfg
  cfg="$(bk_cfg '.encryption.identity_file' '')"
  if [ -n "${BACKUPKIT_IDENTITY:-}" ]; then
    printf '%s' "$BACKUPKIT_IDENTITY"
    return 0
  fi
  if [ -n "$cfg" ]; then
    printf '%s' "$cfg"
    return 0
  fi
  printf '%s' "$BK_IDENTITY_FILE"
}

bk_encryption_required_cmds() {
  bk_encryption_enabled && printf 'age\n'
}

bk_encryption_recipient_args() {
  # Prints one argument per line: -r KEY or -R FILE
  local recipient file r
  recipient="$(bk_cfg '.encryption.recipient' '')"
  file="$(bk_cfg '.encryption.recipients_file' '')"
  if [ -n "$file" ]; then
    [ -f "$file" ] || bk_die "$BK_EXIT_CONFIG" "encryption.recipients_file not found: $file"
    printf '%s\n' -R "$file"
  fi
  [ -n "$recipient" ] && printf '%s\n' -r "$recipient"
  local extra
  extra="$(printf '%s' "$CONFIG_JSON" | jq -r '(.encryption.recipients // [])[]' 2>/dev/null)"
  for r in $extra; do
    [ -n "$r" ] && printf '%s\n' -r "$r"
  done
  return 0
}

# bk_encrypt IN OUT
bk_encrypt() {
  local in="$1" out="$2" status
  if ! bk_encryption_enabled; then
    bk_warn "encryption is disabled; copying artifact without encryption (allow_plaintext=true)"
    ( umask 077; cp -- "$in" "$out" ) || return "$BK_EXIT_ENCRYPT"
    return 0
  fi
  bk_need_cmd age
  local args
  args=($(bk_encryption_recipient_args))
  [ "${#args[@]}" -gt 0 ] || bk_die "$BK_EXIT_CONFIG" "no age recipient configured"

  ( umask 077; age "${args[@]}" -o "$out" "$in" )
  status=$?
  if [ "$status" -ne 0 ] || [ ! -s "$out" ]; then
    return "$BK_EXIT_ENCRYPT"
  fi
  return 0
}

# bk_decrypt IN OUT
bk_decrypt() {
  local in="$1" out="$2" identity status
  if ! bk_encryption_enabled; then
    ( umask 077; cp -- "$in" "$out" ) || return "$BK_EXIT_ENCRYPT"
    return 0
  fi
  bk_need_cmd age
  identity="$(bk_identity_file)"
  [ -f "$identity" ] || bk_die "$BK_EXIT_CONFIG" "age identity file not found: $identity"
  bk_perms_too_open "$identity" "age identity file ($identity)"
  ( umask 077; age -d -i "$identity" -o "$out" "$in" )
  status=$?
  if [ "$status" -ne 0 ] || [ ! -s "$out" ]; then
    return "$BK_EXIT_ENCRYPT"
  fi
  return 0
}

# bk_encryption_ext -> ".age" or ""
bk_encryption_ext() {
  bk_encryption_enabled && printf '.age'
  return 0
}

# bk_encryption_public_key_for_identity FILE -> derived age1... key
bk_encryption_public_key_for_identity() {
  local f="$1"
  bk_have age-keygen || return 1
  age-keygen -y "$f" 2>/dev/null
}
