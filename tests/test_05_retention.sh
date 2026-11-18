#!/usr/bin/env bash
# Retention policy: what may be deleted, what must never be deleted.

. "$(dirname "$0")/lib/helpers.sh"

test_cleanup_keeps_the_policy_count() {
  bk_test_init
  mk_many_manifests app-mysql daily 10
  assert_eq "10" "$(count_manifests app-mysql daily)" "10 backups staged"

  out="$(bk cleanup 2>&1)"
  rc=$?
  assert_status 0 "$rc" "cleanup exits 0"
  # daily retention is 7 in the test config.
  assert_eq "7" "$(count_manifests app-mysql daily)" "exactly the policy count remains"
  assert_contains "$out" "3 backup(s) deleted" "reports the number removed"
}

test_dry_run_deletes_nothing() {
  bk_test_init
  mk_many_manifests app-mysql daily 10
  out="$(bk cleanup --dry-run 2>&1)"
  rc=$?
  assert_status 0 "$rc" "dry-run exits 0"
  assert_contains "$out" "would delete" "lists the candidates"
  assert_eq "10" "$(count_manifests app-mysql daily)" "nothing was removed"
}

test_snapshot_tagged_for_two_categories_survives_one_of_them_expiring() {
  bk_test_init
  # 6 snapshots, each serving daily and weekly. weekly=4, daily=7.
  mk_many_manifests app-mysql daily 6 "daily,weekly"
  bk cleanup >/dev/null 2>&1
  assert_eq "6" "$(count_manifests app-mysql daily)" "a snapshot still inside the daily window is kept"
}

test_newest_backup_is_never_deleted() {
  bk_test_init
  write_config '.databases[0].retention.daily = 1'
  mk_many_manifests app-mysql daily 4
  bk cleanup >/dev/null 2>&1
  assert_eq "1" "$(count_manifests app-mysql daily)" "only one remains"
  assert_file_exists "${MOCK_STORE_DIR}/backups/app-mysql/daily/2026/01/bk_20260104T020000Z_aa0004.manifest.json" \
    "the newest backup is the survivor"
}

test_retention_zero_disables_deletion() {
  bk_test_init
  write_config '.databases[0].retention.daily = 0'
  mk_many_manifests app-mysql daily 10
  bk cleanup >/dev/null 2>&1
  assert_eq "10" "$(count_manifests app-mysql daily)" "0 means keep forever"
}

test_unrecognised_manifest_is_not_deleted() {
  bk_test_init
  write_config '.databases[0].retention.daily = 1'
  mk_many_manifests app-mysql daily 3
  # A verified manifest with no retention tag: nothing tells us it is expired.
  mk_manifest app-mysql daily bk_20260109T020000Z_bb0009 "2026-01-09T02:00:00Z" ""
  bk cleanup >/dev/null 2>&1
  assert_file_exists "${MOCK_STORE_DIR}/backups/app-mysql/daily/2026/01/bk_20260109T020000Z_bb0009.manifest.json" \
    "an untagged manifest is left alone"
}

test_failed_manifests_are_never_deleted() {
  bk_test_init
  write_config '.databases[0].retention.daily = 1'
  mk_many_manifests app-mysql daily 3
  mk_manifest app-mysql daily bk_20260108T020000Z_cc0008 "2026-01-08T02:00:00Z" "daily" "failed"
  bk cleanup >/dev/null 2>&1
  assert_file_exists "${MOCK_STORE_DIR}/backups/app-mysql/daily/2026/01/bk_20260108T020000Z_cc0008.manifest.json" \
    "a failed manifest is not eligible for deletion"
}

test_per_database_retention_overrides_the_global_default() {
  bk_test_init
  # app-pg has daily: 2 in the test config.
  mk_many_manifests app-pg daily 5 "daily"
  bk cleanup --database app-pg >/dev/null 2>&1
  assert_eq "2" "$(count_manifests app-pg daily)" "the per-database value is used"
}

test_cleanup_removes_the_artifacts_too() {
  bk_test_init
  mk_many_manifests app-mysql daily 3
  bk cleanup >/dev/null 2>&1
  # daily=7 keeps all three, so force the point with a tighter policy.
  write_config '.databases[0].retention.daily = 1'
  bk cleanup >/dev/null 2>&1
  assert_eq "1" "$(count_manifests app-mysql daily)" "one manifest remains"
  assert_eq "1" "$(count_artifacts "${MOCK_STORE_DIR}/backups/app-mysql/daily")" \
    "its artifact remains, the others were removed"
}

test_cleanup_runs_after_a_successful_backup() {
  bk_test_init
  write_config '.databases[0].retention.daily = 1'
  mk_many_manifests app-mysql daily 3
  bk backup --database app-mysql --force >/dev/null 2>&1
  # 3 staged + 1 fresh = 4, retention 1 → 1 left.
  assert_eq "1" "$(count_manifests app-mysql daily)" "retention ran as part of the backup"
}

test_no_cleanup_flag_leaves_everything_alone() {
  bk_test_init
  write_config '.databases[0].retention.daily = 1'
  mk_many_manifests app-mysql daily 3
  bk backup --database app-mysql --force --no-cleanup >/dev/null 2>&1
  assert_eq "4" "$(count_manifests app-mysql daily)" "3 staged + 1 fresh are all present"
}

run_tests
