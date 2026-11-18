#!/usr/bin/env bash
# Missing dependencies must be reported clearly, never ignored, and never
# turned into a silent partial backup.

. "$(dirname "$0")/lib/helpers.sh"

test_missing_mysqldump_stops_the_backup() {
  bk_test_init
  path_without mysqldump mariadb-dump
  out="$(bk backup --database app-mysql --force 2>&1)"
  rc=$?
  assert_status 3 "$rc" "a missing dump tool is a dependency error"
  assert_contains "$out" "mysqldump" "names the missing command"
  assert_eq "0" "$(count_files "$MOCK_STORE_DIR")" "nothing was uploaded"
}

test_missing_zstd_stops_the_backup() {
  bk_test_init
  path_without zstd
  out="$(bk backup --database app-mysql --force 2>&1)"
  rc=$?
  assert_status 3 "$rc" "a missing compressor is a dependency error"
  assert_contains "$out" "zstd" "names the missing command"
}

test_missing_age_stops_the_backup() {
  bk_test_init
  path_without age age-keygen
  out="$(bk backup --database app-mysql --force 2>&1)"
  rc=$?
  assert_status 3 "$rc" "a missing encryption tool is a dependency error"
  assert_contains "$out" "age" "names the missing command"
}

test_missing_aws_stops_the_backup_for_s3() {
  BK_TEST_PROVIDER=s3
  export BK_TEST_PROVIDER
  bk_test_init
  path_without aws
  out="$(bk backup --database app-mysql --force 2>&1)"
  rc=$?
  assert_status 3 "$rc" "a missing AWS CLI is a dependency error"
  assert_contains "$out" "aws" "names the missing command"
}

test_missing_dependency_is_recorded_in_history() {
  bk_test_init
  path_without mysqldump mariadb-dump
  bk backup --database app-mysql --force >/dev/null 2>&1
  assert_contains "$(history_dump)" '"stage":"dependency"' "history records the stage"
}

test_doctor_reports_a_healthy_install() {
  bk_test_init
  out="$(bk doctor --no-connect 2>&1)"
  rc=$?
  assert_status 0 "$rc" "doctor exits 0 on a healthy setup"
  assert_contains "$out" "result: healthy" "prints the verdict"
  assert_contains "$out" "storage" "checks storage"
  assert_contains "$out" "encryption" "checks encryption"
  assert_contains "$out" "no active locks" "checks locks"
}

test_doctor_flags_a_missing_client() {
  bk_test_init
  path_without mysqldump mariadb-dump
  out="$(bk doctor --no-connect 2>&1)"
  rc=$?
  assert_ne "0" "$rc" "doctor fails when a client is missing"
  assert_contains "$out" "missing client" "names the problem"
}

test_doctor_requires_a_config_file() {
  bk_test_init
  rm -f "$BACKUPKIT_ETC/config.json"
  out="$(bk doctor 2>&1)"
  rc=$?
  assert_status 2 "$rc" "no config file is a configuration error"
  assert_contains "$out" "no config file" "points at the missing file"
}

test_doctor_flags_a_recipient_key_mismatch() {
  bk_test_init
  # age-keygen is mocked and always reports the same public key; make the
  # config expect a different one.
  write_config '.encryption.recipient = "age1different00000000000000000000000000000000000000000000000000000000"'
  out="$(bk doctor --no-connect 2>&1)"
  rc=$?
  assert_ne "0" "$rc" "doctor fails on a key mismatch"
  assert_contains "$out" "does not match" "reports the mismatch"
}

test_doctor_flags_insecure_secret_permissions() {
  bk_test_init
  unset BK_ALLOW_INSECURE_PERMS
  chmod 644 "$BACKUPKIT_ETC/secrets.json"
  out="$(bk doctor --no-connect 2>&1)"
  rc=$?
  assert_ne "0" "$rc" "doctor fails on world readable secrets"
  assert_contains "$out" "secrets permissions" "names the file class"
}

test_unknown_command_shows_usage() {
  bk_test_init
  out="$(bk frobnicate 2>&1)"
  rc=$?
  assert_status 1 "$rc" "unknown command exits 1"
  assert_contains "$out" "unknown command" "says so"
  assert_contains "$out" "Usage: backupkit" "prints usage"
}

test_version_command() {
  out="$(bk version 2>&1)"
  assert_contains "$out" "backupkit" "prints the version"
}

run_tests
