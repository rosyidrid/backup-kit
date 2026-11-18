#!/usr/bin/env bash
# Verification and restore workflows.

. "$(dirname "$0")/lib/helpers.sh"

backup_once() {
  bk backup --database app-mysql --force >/dev/null 2>&1
  latest_backup_id
}

test_verify_reports_success_for_a_good_backup() {
  bk_test_init
  id="$(backup_once)"
  out="$(bk verify --id "$id" 2>&1)"
  rc=$?
  assert_status 0 "$rc" "verify exits 0"
  assert_contains "$out" "verified" "reports verification"
}

test_verify_deep_decrypts_and_decompresses() {
  bk_test_init
  id="$(backup_once)"
  out="$(bk verify --id "$id" --deep 2>&1)"
  rc=$?
  assert_status 0 "$rc" "deep verify exits 0"
  assert_contains "$out" "decrypt, decompress" "proves the pipeline is reversible"
}

test_verify_detects_a_tampered_object() {
  bk_test_init
  id="$(backup_once)"
  key="$(manifest_json "$id" | jq -r '.artifacts[0].key')"
  printf 'tampered\n' >>"${MOCK_STORE_DIR}/${key}"
  out="$(bk verify --id "$id" 2>&1)"
  rc=$?
  assert_status 9 "$rc" "checksum mismatch is reported as a verification failure"
  assert_contains "$out" "checksum mismatch" "says what went wrong"
}

test_verify_unknown_id_is_not_found() {
  bk_test_init
  out="$(bk verify --id bk_20260101T000000Z_deadbe 2>&1)"
  rc=$?
  assert_status 13 "$rc" "unknown id exits with the not-found code"
}

test_restore_requires_a_target() {
  bk_test_init
  id="$(backup_once)"
  out="$(bk restore --id "$id" --yes 2>&1)"
  rc=$?
  assert_status 11 "$rc" "a primary restore without --target is refused"
  assert_contains "$out" "--target" "explains the requirement"
}

test_restore_refuses_without_confirmation() {
  bk_test_init
  id="$(backup_once)"
  mock_reset
  out="$(bk restore --id "$id" --target restored_db 2>&1)"
  rc=$?
  assert_status 12 "$rc" "no confirmation means no restore"
  assert_contains "$out" "confirmation" "explains why"
  assert_eq "0" "$(mock_call_count '^mysql --defaults')" "the database client was never invoked"
}

test_restore_dry_run_changes_nothing() {
  bk_test_init
  id="$(backup_once)"
  mock_reset
  out="$(bk restore --id "$id" --target restored_db --dry-run 2>&1)"
  rc=$?
  assert_status 0 "$rc" "dry-run exits 0"
  assert_contains "$out" "nothing was changed" "states that nothing changed"
  assert_eq "0" "$(mock_call_count '^mysql --defaults')" "no client call"
  assert_eq "0" "$(mock_call_count 's3 cp')" "no download"
}

test_restore_with_confirmation_runs_the_client() {
  bk_test_init
  id="$(backup_once)"
  mock_reset
  out="$(bk restore --id "$id" --target restored_db --yes 2>&1)"
  rc=$?
  assert_status 0 "$rc" "restore exits 0"
  assert_contains "$(mock_calls)" "mysql-restore-bytes" "the client received credentials and a payload"
  assert_contains "$(mock_calls)" "-- restored_db" "the payload went to the requested target"
}

test_restore_refuses_a_failed_backup() {
  bk_test_init
  mk_manifest app-mysql daily bk_20260101T020000Z_ff0001 "2026-01-01T02:00:00Z" "daily" "failed"
  out="$(bk restore --id bk_20260101T020000Z_ff0001 --target x --yes 2>&1)"
  rc=$?
  assert_status 11 "$rc" "a failed backup cannot be restored"
  assert_contains "$out" "marked as failed" "explains why"
}

test_restore_detects_a_tampered_object() {
  bk_test_init
  id="$(backup_once)"
  key="$(manifest_json "$id" | jq -r '.artifacts[0].key')"
  printf 'tampered\n' >>"${MOCK_STORE_DIR}/${key}"
  out="$(bk restore --id "$id" --target restored_db --yes 2>&1)"
  rc=$?
  assert_status 9 "$rc" "a corrupted artifact stops the restore"
  assert_contains "$out" "checksum validation failed" "says why"
}

test_list_shows_the_backup_and_status_reports_it() {
  bk_test_init
  id="$(backup_once)"
  out="$(bk list 2>&1)"
  assert_contains "$out" "$id" "list shows the backup"
  out="$(bk status 2>&1)"
  assert_contains "$out" "app-mysql" "status shows the database"
  assert_contains "$out" "daily=1/7" "status shows retention usage"
}

test_list_json_is_machine_readable() {
  bk_test_init
  backup_once >/dev/null
  out="$(bk list --json 2>&1)"
  printf '%s' "$out" | jq -e '. | length >= 1' >/dev/null 2>&1
  assert_status 0 "$?" "list --json emits valid JSON"
}

run_tests
