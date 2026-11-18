#!/usr/bin/env bash
# MySQL backup pipeline: happy path, dump validation and snapshot reuse.

. "$(dirname "$0")/lib/helpers.sh"

test_backup_happy_path_records_verified_manifest() {
  bk_test_init
  out="$(bk backup --database app-mysql --force 2>&1)"
  rc=$?
  assert_status 0 "$rc" "backup exits 0"
  assert_contains "$out" "backup ok" "reports success"

  id="$(latest_backup_id)"
  assert_not_empty "$id" "a manifest was written"

  manifest="$(manifest_json "$id")"
  assert_eq "verified" "$(printf '%s' "$manifest" | jq -r '.status')" "manifest is verified"
  assert_eq "daily" "$(printf '%s' "$manifest" | jq -r '.primary_type')" "primary type recorded"
  assert_eq "1" "$(printf '%s' "$manifest" | jq -r '.artifacts | length')" "one artifact"

  key="$(printf '%s' "$manifest" | jq -r '.artifacts[0].key')"
  expected="$(printf '%s' "$manifest" | jq -r '.artifacts[0].sha256')"
  actual="$(shasum -a 256 "${MOCK_STORE_DIR}/${key}" | awk '{print $1}')"
  assert_eq "$expected" "$actual" "sha256 in the manifest matches the stored object"

  assert_contains "$(history_dump)" '"status":"success"' "history records success"
}

test_failed_dump_uploads_nothing_and_keeps_status_failed() {
  bk_test_init
  MOCK_MYSQLDUMP_FAIL=1
  export MOCK_MYSQLDUMP_FAIL
  out="$(bk backup --database app-mysql --force 2>&1)"
  rc=$?
  assert_status 5 "$rc" "dump failure exits with the dump code"
  assert_eq "0" "$(count_files "$MOCK_STORE_DIR")" "nothing was uploaded"

  id="$(latest_backup_id)"
  assert_not_empty "$id" "a local manifest records the failure"
  assert_eq "failed" "$(manifest_json "$id" | jq -r '.status')" "manifest marked failed"
  assert_contains "$(history_dump)" '"status":"failed"' "history records failure"
}

test_dump_without_footer_is_treated_as_failure() {
  bk_test_init
  MOCK_MYSQLDUMP_NOFOOTER=1
  export MOCK_MYSQLDUMP_NOFOOTER
  out="$(bk backup --database app-mysql --force 2>&1)"
  rc=$?
  assert_status 5 "$rc" "truncated dump is rejected even though mysqldump exited 0"
  assert_contains "$out" "Dump completed" "explains what was missing"
  assert_eq "0" "$(count_files "$MOCK_STORE_DIR")" "nothing was uploaded"
}

test_empty_dump_is_rejected() {
  bk_test_init
  MOCK_MYSQLDUMP_EMPTY=1
  export MOCK_MYSQLDUMP_EMPTY
  out="$(bk backup --database app-mysql --force 2>&1)"
  rc=$?
  assert_status 5 "$rc" "empty dump is rejected"
  assert_eq "0" "$(count_files "$MOCK_STORE_DIR")" "nothing was uploaded"
}

test_password_never_appears_in_argv() {
  bk_test_init
  bk backup --database app-mysql --force >/dev/null 2>&1
  calls="$(grep '^mysqldump' "$MOCK_LOG")"
  assert_contains "$calls" "--defaults-extra-file" "credentials come from an option file"
  case "$calls" in
    *s3cr3t-mysql*) bk_test_fail "password leaked into command line arguments" ;;
    *) bk_test_pass "password is not on the command line" ;;
  esac
}

test_one_snapshot_satisfies_daily_and_weekly() {
  bk_test_init "$(due_schedule_jq)"
  bk backup --database app-mysql --type daily >/dev/null 2>&1
  first="$(latest_backup_id)"
  dumps_before="$(mock_call_count '^mysqldump --defaults')"

  out="$(bk backup --database app-mysql --type weekly 2>&1)"
  rc=$?
  assert_status 0 "$rc" "weekly run succeeds"
  assert_contains "$out" "reusing snapshot" "the existing snapshot is reused"
  assert_eq "$first" "$(latest_backup_id)" "no second snapshot was created"
  assert_eq "$dumps_before" "$(mock_call_count '^mysqldump --defaults')" "no second dump was taken"
  assert_eq "daily,weekly" "$(manifest_json "$first" | jq -r '.types | join(",")')" "both categories are tagged"
}

test_repeat_run_of_same_type_is_a_no_op() {
  bk_test_init "$(due_schedule_jq)"
  bk backup --database app-mysql --type daily >/dev/null 2>&1
  first="$(latest_backup_id)"
  out="$(bk backup --database app-mysql --type daily 2>&1)"
  rc=$?
  assert_status 0 "$rc" "second daily run succeeds"
  assert_contains "$out" "already satisfies" "recognises the existing snapshot"
  assert_eq "$first" "$(latest_backup_id)" "no new snapshot"
  assert_eq "1" "$(count_artifacts "$MOCK_STORE_DIR")" "storage still holds exactly one artifact"
}

test_force_creates_a_new_snapshot() {
  bk_test_init "$(due_schedule_jq)"
  bk backup --database app-mysql --type daily >/dev/null 2>&1
  first="$(latest_backup_id)"
  bk backup --database app-mysql --type daily --force >/dev/null 2>&1
  second="$(latest_backup_id)"
  assert_ne "$first" "$second" "force bypasses reuse"
}

test_type_not_due_is_skipped_without_force() {
  bk_test_init
  # weekly_dow defaults to 0 (Sunday); pick a day that is not today.
  dow="$(today_dow)"
  other=$(( (10#$dow + 1) % 7 ))
  write_config ".schedule.weekly_dow = ${other}"
  out="$(bk backup --database app-mysql --type weekly 2>&1)"
  rc=$?
  assert_status 0 "$rc" "skipping is not an error"
  assert_contains "$out" "no backup type is due" "explains the skip"
  assert_empty "$(latest_backup_id)" "nothing was backed up"
}

test_dry_run_changes_nothing() {
  bk_test_init
  out="$(bk backup --database app-mysql --force --dry-run 2>&1)"
  rc=$?
  assert_status 0 "$rc" "dry-run exits 0"
  assert_contains "$out" "dry-run" "announces dry-run"
  assert_empty "$(latest_backup_id)" "no manifest was written"
  assert_eq "0" "$(count_files "$MOCK_STORE_DIR")" "nothing was uploaded"
}

run_tests
