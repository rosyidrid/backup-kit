#!/usr/bin/env bash
# PostgreSQL: custom-format dumps, global objects, and restoring them apart
# from the database itself.

. "$(dirname "$0")/lib/helpers.sh"

pg_backup() {
  bk backup --database app-pg --force >/dev/null 2>&1
  latest_backup_id
}

test_postgres_backup_writes_two_artifacts() {
  bk_test_init
  out="$(bk backup --database app-pg --force 2>&1)"
  rc=$?
  assert_status 0 "$rc" "postgres backup exits 0"
  id="$(latest_backup_id)"
  manifest="$(manifest_json "$id")"
  assert_eq "2" "$(printf '%s' "$manifest" | jq -r '.artifacts | length')" "primary + globals artifacts"
  assert_eq "globals,primary" "$(printf '%s' "$manifest" | jq -r '.artifacts | map(.role) | sort | join(",")')" "both roles recorded"
  assert_eq "2" "$(count_artifacts "$MOCK_STORE_DIR")" "both objects were uploaded"
}

test_postgres_dump_missing_header_is_rejected() {
  bk_test_init
  MOCK_PGDUMP_NOHDR=1
  export MOCK_PGDUMP_NOHDR
  out="$(bk backup --database app-pg --force 2>&1)"
  rc=$?
  assert_status 5 "$rc" "a file that is not a custom-format archive is rejected"
  assert_contains "$out" "PGDMP" "names the expected header"
}

test_postgres_globals_empty_is_rejected() {
  bk_test_init
  MOCK_PGDUMP_EMPTY=1
  export MOCK_PGDUMP_EMPTY
  rc=0
  bk backup --database app-pg --force >/dev/null 2>&1 || rc=$?
  assert_status 5 "$rc" "an empty globals dump is rejected"
}

test_postgres_restore_primary_uses_pg_restore() {
  bk_test_init
  id="$(pg_backup)"
  mock_reset
  out="$(bk restore --id "$id" --target restored_pg --yes 2>&1)"
  rc=$?
  assert_status 0 "$rc" "restore exits 0"
  assert_contains "$(mock_calls)" "pg_restore" "pg_restore was used"
  assert_contains "$(mock_calls)" "--dbname restored_pg" "restored into the requested target"
  assert_contains "$(mock_calls)" "--clean --if-exists" "overwrites cleanly"
}

test_postgres_globals_restore_is_a_separate_operation() {
  bk_test_init
  id="$(pg_backup)"
  mock_reset
  out="$(bk restore --id "$id" --globals --yes 2>&1)"
  rc=$?
  assert_status 0 "$rc" "globals restore exits 0"
  assert_contains "$(mock_calls)" "psql-globals-restore-bytes" "psql received the globals file"
  assert_eq "0" "$(mock_call_count 'pg_restore')" "the database itself was not restored"
}

test_postgres_globals_restore_does_not_need_a_target() {
  bk_test_init
  id="$(pg_backup)"
  out="$(bk restore --id "$id" --globals --yes 2>&1)"
  rc=$?
  assert_status 0 "$rc" "no --target required for globals"
}

test_postgres_verify_deep_handles_both_artifacts() {
  bk_test_init
  id="$(pg_backup)"
  out="$(bk verify --id "$id" --deep 2>&1)"
  rc=$?
  assert_status 0 "$rc" "deep verify passes for both artifacts"
  assert_contains "$out" "2 artifact(s)" "counts both"
}

test_postgres_restore_of_a_globals_only_manifest() {
  bk_test_init
  # A manifest that only carries globals must refuse a primary restore.
  mk_manifest app-pg daily bk_20260101T020000Z_dd0001 "2026-01-01T02:00:00Z" "daily"
  out="$(bk restore --id bk_20260101T020000Z_dd0001 --target x --yes 2>&1)"
  rc=$?
  assert_ne "0" "$rc" "primary restore fails cleanly when there is no primary artifact"
}

run_tests
