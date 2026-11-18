#!/usr/bin/env bash
# Configuration validation and redaction.

. "$(dirname "$0")/lib/helpers.sh"

test_valid_config_passes() {
  bk_test_init
  out="$(bk config validate 2>&1)"
  rc=$?
  assert_status 0 "$rc" "valid config exits 0"
  assert_contains "$out" "config OK" "reports OK"
}

test_plaintext_requires_acknowledgement() {
  bk_test_init
  write_config '.encryption.enabled = false'
  out="$(bk config validate 2>&1)"
  rc=$?
  assert_status 2 "$rc" "plaintext without acknowledgement is rejected"
  assert_contains "$out" "allow_plaintext" "explains the escape hatch"
}

test_plaintext_allowed_when_acknowledged() {
  bk_test_init
  write_config '.encryption.enabled = false | .encryption.allow_plaintext = true'
  out="$(bk config validate 2>&1)"
  rc=$?
  assert_status 0 "$rc" "acknowledged plaintext passes"
}

test_password_in_config_is_rejected() {
  bk_test_init
  write_config '.databases[0].password = "oops"'
  out="$(bk config validate 2>&1)"
  rc=$?
  assert_status 2 "$rc" "password in config.json is rejected"
  assert_contains "$out" "secrets.json" "points at the secrets file"
}

test_unknown_provider_is_rejected() {
  bk_test_init
  write_config '.storage.provider = "dropbox"'
  out="$(bk config validate 2>&1)"
  rc=$?
  assert_status 2 "$rc" "unknown provider rejected"
  assert_contains "$out" "not supported" "explains why"
}

test_r2_requires_cloudflare_endpoint() {
  bk_test_init
  write_config '.storage.provider = "cloudflare-r2" | .storage.endpoint = "https://s3.amazonaws.com"'
  out="$(bk config validate 2>&1)"
  rc=$?
  assert_status 2 "$rc" "R2 with a foreign endpoint is rejected"
  assert_contains "$out" "r2.cloudflarestorage.com" "shows the expected shape"
}

test_bad_retention_value_is_rejected() {
  bk_test_init
  write_config '.databases[0].retention.daily = "seven"'
  out="$(bk config validate 2>&1)"
  rc=$?
  assert_status 2 "$rc" "non-numeric retention rejected"
  assert_contains "$out" "retention.daily" "names the offending field"
}

test_globals_only_for_postgres() {
  bk_test_init
  write_config '.databases[0].globals = true'
  out="$(bk config validate 2>&1)"
  rc=$?
  assert_status 2 "$rc" "globals on mysql rejected"
  assert_contains "$out" "only supported for postgres" "explains the rule"
}

test_secrets_permissions_are_enforced() {
  bk_test_init
  unset BK_ALLOW_INSECURE_PERMS
  chmod 644 "$BACKUPKIT_ETC/secrets.json"
  out="$(bk config validate 2>&1)"
  rc=$?
  assert_status 2 "$rc" "world readable secrets are refused"
  assert_contains "$out" "chmod 600" "tells the operator what to do"
}

test_config_show_redacts_secrets() {
  bk_test_init
  out="$(bk config show 2>&1)"
  assert_contains "$out" "[REDACTED]" "secrets are masked"
  case "$out" in
    *s3cr3t-mysql*) bk_test_fail "secret leaked in config show" ;;
    *) bk_test_pass "no secret value in config show" ;;
  esac
}

test_invalid_json_is_reported() {
  bk_test_init
  printf '{ this is not json' >"$BACKUPKIT_ETC/config.json"
  chmod 600 "$BACKUPKIT_ETC/config.json"
  out="$(bk config validate 2>&1)"
  rc=$?
  assert_status 2 "$rc" "invalid JSON exits 2"
  assert_contains "$out" "not valid JSON" "says what is wrong"
}

run_tests
