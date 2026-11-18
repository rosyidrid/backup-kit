#!/usr/bin/env bash
# Logging hygiene: structured lines, and no secret ever written to disk.

. "$(dirname "$0")/lib/helpers.sh"

test_secrets_never_appear_in_the_log_file() {
  bk_test_init
  bk backup --database app-mysql --force >/dev/null 2>&1
  assert_file_exists "$BK_LOG_FILE" "a log file was written"

  log="$(cat "$BK_LOG_FILE")"
  case "$log" in
    *s3cr3t-mysql*) bk_test_fail "the database password appears in the log" ;;
    *) bk_test_pass "database password absent from the log" ;;
  esac
  case "$log" in
    *test-secret-key*) bk_test_fail "the storage secret appears in the log" ;;
    *) bk_test_pass "storage secret absent from the log" ;;
  esac
}

test_log_lines_are_json() {
  bk_test_init
  bk backup --database app-mysql --force >/dev/null 2>&1
  bad=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s' "$line" | jq -e '.ts and .event' >/dev/null 2>&1 || bad=$((bad + 1))
    # Log lines carry a level; structured events carry their own payload.
    if [ "$(printf '%s' "$line" | jq -r '.event')" = "log" ]; then
      printf '%s' "$line" | jq -e '.level and .message' >/dev/null 2>&1 || bad=$((bad + 1))
    fi
  done <"$BK_LOG_FILE"
  assert_eq "0" "$bad" "every log line is valid JSON with ts/event (and level for log lines)"
}

test_structured_events_cover_the_pipeline() {
  BK_TEST_PROVIDER=s3
  export BK_TEST_PROVIDER
  bk_test_init
  bk backup --database app-mysql --force >/dev/null 2>&1
  log="$(cat "$BK_LOG_FILE")"
  assert_contains "$log" '"event":"artifact_uploaded"' "uploads are recorded as events"
}

test_history_records_size_checksum_and_key() {
  bk_test_init
  bk backup --database app-mysql --force >/dev/null 2>&1
  line="$(history_dump | tail -1)"
  assert_contains "$line" '"status":"success"' "status"
  assert_contains "$line" '"sha256":"' "checksum"
  assert_contains "$line" '"key":"' "storage key"
  assert_contains "$line" '"duration_seconds":' "duration"
  assert_contains "$line" '"size_bytes":' "size"
}

test_console_output_carries_no_secrets() {
  bk_test_init
  MOCK_AGE_FAIL=1
  export MOCK_AGE_FAIL
  out="$(bk backup --database app-mysql --force 2>&1)"
  case "$out" in
    *s3cr3t-mysql*) bk_test_fail "the password reached the console" ;;
    *) bk_test_pass "console output is clean" ;;
  esac
}

test_config_show_hides_credentials_even_in_json() {  bk_test_init
  out="$(bk config show 2>&1)"
  case "$out" in
    *test-access-key*) bk_test_fail "storage access key exposed" ;;
    *) bk_test_pass "storage access key hidden" ;;
  esac
  case "$out" in
    *s3cr3t-pg*) bk_test_fail "database password exposed" ;;
    *) bk_test_pass "database password hidden" ;;
  esac
}

run_tests
