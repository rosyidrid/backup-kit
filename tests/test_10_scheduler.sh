#!/usr/bin/env bash
# Scheduler installation, and the safety rules around removing it.

. "$(dirname "$0")/lib/helpers.sh"

test_print_shows_the_default_schedule() {
  bk_test_init
  out="$(bk install-scheduler --print 2>&1)"
  rc=$?
  assert_status 0 "$rc" "printing exits 0"
  assert_contains "$out" "0 2 * * *" "daily at 02:00"
  assert_contains "$out" "0 3 * * 0" "weekly on Sunday at 03:00"
  assert_contains "$out" "0 4 1 * *" "monthly on the 1st at 04:00"
  assert_contains "$out" "CRON_TZ=Asia/Jakarta" "timezone comes from the config"
  assert_contains "$out" "backup --all --type daily" "invokes the CLI"
  assert_contains "$out" "Managed by BackupKit" "marks the file as ours"
}

test_print_honours_schedule_overrides() {
  bk_test_init '.schedule.weekly_dow = 3 | .schedule.monthly_dom = 15'
  out="$(bk install-scheduler --print 2>&1)"
  assert_contains "$out" "0 3 * * 3" "weekly day respects the config"
  assert_contains "$out" "0 4 15 * *" "monthly day respects the config"
}

test_install_writes_a_cron_file() {
  bk_test_init
  out="$(bk install-scheduler 2>&1)"
  rc=$?
  assert_status 0 "$rc" "install exits 0"
  assert_file_exists "$(bk_cron_file)" "cron file created"
  assert_contains "$(cat "$(bk_cron_file)")" "Managed by BackupKit" "content is ours"
}

test_install_is_idempotent() {
  bk_test_init
  bk install-scheduler >/dev/null 2>&1
  bk install-scheduler >/dev/null 2>&1
  assert_eq "1" "$(grep -c 'Managed by BackupKit' "$(bk_cron_file)")" "no duplicated block"
}

test_uninstall_removes_our_file() {
  bk_test_init
  bk install-scheduler >/dev/null 2>&1
  out="$(bk uninstall-scheduler 2>&1)"
  rc=$?
  assert_status 0 "$rc" "uninstall exits 0"
  assert_file_missing "$(bk_cron_file)" "cron file removed"
}

test_uninstall_refuses_a_foreign_file() {
  bk_test_init
  printf '# someone else cron\n0 1 * * * root /usr/bin/true\n' >"$(bk_cron_file)"
  out="$(bk uninstall-scheduler 2>&1)"
  rc=$?
  assert_status 1 "$rc" "a foreign cron file is not removed"
  assert_contains "$out" "not created by BackupKit" "explains the refusal"
  assert_file_exists "$(bk_cron_file)" "the file is still there"
}

test_uninstall_without_a_file_is_not_an_error() {
  bk_test_init
  out="$(bk uninstall-scheduler 2>&1)"
  rc=$?
  assert_status 0 "$rc" "nothing to remove is fine"
  assert_contains "$out" "nothing to do" "says so"
}

test_install_scheduler_honours_bin_and_user() {
  bk_test_init
  out="$(bk install-scheduler --print --bin /opt/backupkit/bin/backupkit --user deploy 2>&1)"
  assert_contains "$out" "/opt/backupkit/bin/backupkit backup --all" "custom binary path"
  assert_contains "$out" "deploy /opt/backupkit/bin/backupkit" "custom user field"
}

run_tests
