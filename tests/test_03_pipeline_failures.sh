#!/usr/bin/env bash
# Failure handling for the compression and encryption stages, and the
# guarantee that a failure never deletes or overwrites an earlier good backup.

. "$(dirname "$0")/lib/helpers.sh"

test_compression_failure_aborts_before_upload() {
  bk_test_init
  make_stub zstd 'echo "zstd: simulated failure" >&2; exit 1'
  out="$(bk backup --database app-mysql --force 2>&1)"
  rc=$?
  assert_status 6 "$rc" "compression failure exits with the compression code"
  assert_eq "0" "$(count_files "$MOCK_STORE_DIR")" "nothing was uploaded"
  assert_contains "$(history_dump)" '"stage":"compress"' "history names the failing stage"
}

test_encryption_failure_aborts_before_upload() {
  bk_test_init
  MOCK_AGE_FAIL=1
  export MOCK_AGE_FAIL
  out="$(bk backup --database app-mysql --force 2>&1)"
  rc=$?
  assert_status 7 "$rc" "encryption failure exits with the encryption code"
  assert_eq "0" "$(count_files "$MOCK_STORE_DIR")" "nothing was uploaded"
  assert_contains "$(history_dump)" '"stage":"encrypt"' "history names the failing stage"
}

test_failure_keeps_previous_backups() {
  bk_test_init
  bk backup --database app-mysql --force >/dev/null 2>&1
  good="$(latest_backup_id)"
  good_key="$(manifest_json "$good" | jq -r '.artifacts[0].key')"
  assert_file_exists "${MOCK_STORE_DIR}/${good_key}" "first backup is stored"

  MOCK_MYSQLDUMP_FAIL=1
  export MOCK_MYSQLDUMP_FAIL
  rc=0
  bk backup --database app-mysql --force >/dev/null 2>&1 || rc=$?
  assert_status 5 "$rc" "the later run failed"

  assert_file_exists "${MOCK_STORE_DIR}/${good_key}" "the earlier object survives the failure"
  assert_eq "verified" "$(manifest_json "$good" | jq -r '.status')" "the earlier manifest is untouched"
}

test_plaintext_is_never_uploaded_when_encryption_fails() {
  bk_test_init
  MOCK_AGE_FAIL=1
  export MOCK_AGE_FAIL
  bk backup --database app-mysql --force >/dev/null 2>&1
  # Nothing may reach storage, and no artifact may exist anywhere unencrypted.
  assert_eq "0" "$(count_files "$MOCK_STORE_DIR")" "storage is clean"
  leftovers="$(find "$BACKUPKIT_STATE_DIR" -name '*.zst' -o -name '*.sql' 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "0" "$leftovers" "no uncompressed dump is left behind"
}

run_tests
