#!/usr/bin/env bash
# Locking: overlapping cron slots, stale locks and lock release.

. "$(dirname "$0")/lib/helpers.sh"

fake_lock() {
  # fake_lock PID [STARTED_EPOCH]
  local pid="$1" started="${2:-$(date +%s)}" dir="${BACKUPKIT_STATE_DIR}/locks/db-app-mysql.lock"
  mkdir -p "$dir"
  printf '%s\n' "$pid" >"${dir}/pid"
  printf '%s\n' "$started" >"${dir}/started_epoch"
  printf 'testhost\n' >"${dir}/host"
}

test_concurrent_run_is_refused() {
  bk_test_init
  fake_lock "$$"
  out="$(bk backup --database app-mysql --force 2>&1)"
  rc=$?
  assert_status 4 "$rc" "a held lock blocks a second run"
  assert_contains "$out" "already running" "explains the skip"
  assert_eq "0" "$(count_files "$MOCK_STORE_DIR")" "the blocked run uploaded nothing"
}

test_blocked_run_is_recorded_in_history() {
  bk_test_init
  fake_lock "$$"
  bk backup --database app-mysql --force >/dev/null 2>&1
  assert_contains "$(history_dump)" '"stage":"lock"' "history records the lock conflict"
}

test_stale_lock_from_a_dead_process_is_reclaimed() {
  bk_test_init
  # A pid that cannot exist.
  fake_lock 4999999
  out="$(bk backup --database app-mysql --force 2>&1)"
  rc=$?
  assert_status 0 "$rc" "the run proceeds after reclaiming a dead lock"
  assert_contains "$out" "reclaiming stale lock" "the reclaim is reported"
  assert_eq "1" "$(count_artifacts "$MOCK_STORE_DIR")" "the backup was taken"
}

test_lock_older_than_the_timeout_is_reclaimed() {
  bk_test_init
  # Our own (alive) pid, but claimed long ago.
  fake_lock "$$" "$(( $(date +%s) - 100000 ))"
  rc=0
  bk backup --database app-mysql --force >/dev/null 2>&1 || rc=$?
  assert_status 0 "$rc" "an over-age lock is reclaimed even if the pid is alive"
}

test_lock_is_released_after_a_successful_run() {
  bk_test_init
  bk backup --database app-mysql --force >/dev/null 2>&1
  assert_file_missing "${BACKUPKIT_STATE_DIR}/locks/db-app-mysql.lock" "lock directory removed"
}

test_lock_is_released_after_a_failed_run() {
  bk_test_init
  MOCK_MYSQLDUMP_FAIL=1
  export MOCK_MYSQLDUMP_FAIL
  bk backup --database app-mysql --force >/dev/null 2>&1
  assert_file_missing "${BACKUPKIT_STATE_DIR}/locks/db-app-mysql.lock" "lock released on failure too"
}

test_lock_is_per_database() {
  bk_test_init
  fake_lock "$$"
  out="$(bk backup --database app-pg --force 2>&1)"
  rc=$?
  assert_status 0 "$rc" "a lock on one database does not block another"
}

run_tests
