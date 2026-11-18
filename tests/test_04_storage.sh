#!/usr/bin/env bash
# Storage abstraction: local and S3-compatible providers, retries, upload
# verification and provider specific endpoint handling.

. "$(dirname "$0")/lib/helpers.sh"

aws_store() { printf '%s/test-bucket' "$MOCK_AWS_ROOT"; }

test_local_provider_requires_a_path() {
  bk_test_init
  write_config '.storage.local.path = ""'
  out="$(bk config validate 2>&1)"
  rc=$?
  assert_status 2 "$rc" "local provider without a path is invalid"
  assert_contains "$out" "storage.local.path" "names the missing field"
}

test_s3_upload_verifies_and_manifests_the_object() {
  BK_TEST_PROVIDER=s3
  export BK_TEST_PROVIDER
  bk_test_init
  out="$(bk backup --database app-mysql --force 2>&1)"
  rc=$?
  assert_status 0 "$rc" "backup over the s3 provider succeeds"

  id="$(latest_backup_id)"
  key="$(manifest_json "$id" | jq -r '.artifacts[0].key')"
  assert_file_exists "$(aws_store)/${key}" "the artifact reached the bucket"
  assert_file_exists "$(aws_store)/backups/app-mysql/daily/$(printf '%s' "$key" | cut -d/ -f4)/$(printf '%s' "$key" | cut -d/ -f5)/${id}.manifest.json" \
    "the manifest reached the bucket"
}

test_upload_is_retried_until_it_succeeds() {
  BK_TEST_PROVIDER=s3
  export BK_TEST_PROVIDER
  bk_test_init
  MOCK_AWS_FAIL_UPLOADS=2
  export MOCK_AWS_FAIL_UPLOADS
  out="$(bk backup --database app-mysql --force 2>&1)"
  rc=$?
  assert_status 0 "$rc" "transient upload failures are retried"
  assert_contains "$out" "retrying" "the retry is reported"
  attempts="$(mock_call_count 's3 cp')"
  [ "$attempts" -ge 3 ] && bk_test_pass "3 upload attempts were made" || bk_test_fail "expected at least 3 attempts, saw $attempts"
}

test_upload_fails_after_exhausting_retries() {
  BK_TEST_PROVIDER=s3
  export BK_TEST_PROVIDER
  bk_test_init
  MOCK_AWS_FAIL_UPLOADS=10
  export MOCK_AWS_FAIL_UPLOADS
  out="$(bk backup --database app-mysql --force 2>&1)"
  rc=$?
  assert_status 8 "$rc" "persistent upload failure exits with the upload code"
  attempts="$(mock_call_count 's3 cp')"
  assert_eq "3" "$attempts" "exactly max_attempts upload attempts were made"
  assert_contains "$(history_dump)" '"stage":"upload"' "history names the failing stage"
}

test_size_mismatch_is_detected_after_upload() {
  BK_TEST_PROVIDER=s3
  export BK_TEST_PROVIDER
  bk_test_init
  MOCK_AWS_TRUNCATE=1
  export MOCK_AWS_TRUNCATE
  out="$(bk backup --database app-mysql --force 2>&1)"
  rc=$?
  assert_status 8 "$rc" "a truncated object is rejected"
  assert_contains "$out" "size mismatch" "explains the mismatch"
}

test_cloudflare_r2_uses_its_explicit_endpoint() {
  BK_TEST_PROVIDER=cloudflare-r2
  export BK_TEST_PROVIDER
  bk_test_init
  bk backup --database app-mysql --force >/dev/null 2>&1
  assert_contains "$(mock_calls)" "aws-endpoint https://abcd1234.r2.cloudflarestorage.com" "R2 endpoint is passed to the CLI"
  assert_eq "auto" "$(jq -r '.storage.region' "$BACKUPKIT_ETC/config.json")" "R2 defaults to the auto region"
}

test_generic_s3_provider_keeps_its_own_endpoint() {
  BK_TEST_PROVIDER=s3
  export BK_TEST_PROVIDER
  bk_test_init
  bk backup --database app-mysql --force >/dev/null 2>&1
  assert_contains "$(mock_calls)" "aws-endpoint https://s3.example.test" "the configured endpoint is used"
}

test_delete_refuses_keys_outside_the_prefix() {
  bk_test_init
  # A stray object that BackupKit did not create, in the same bucket.
  stray="${MOCK_STORE_DIR}/someone-else/notes.txt"
  mkdir -p "$(dirname "$stray")"
  printf 'do not touch\n' >"$stray"

  mk_manifest app-mysql daily bk_20260101T020000Z_aaaaaa "2026-01-01T02:00:00Z" "daily"
  bk cleanup >/dev/null 2>&1

  assert_file_exists "$stray" "objects outside the configured prefix are never deleted"
}

run_tests
