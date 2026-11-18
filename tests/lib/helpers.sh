#!/usr/bin/env bash
# BackupKit test helper library.
#
# Design notes:
#  - No external test framework: the project must be testable with a bare
#    Ubuntu/Debian or macOS box.
#  - Every test runs against a throwaway directory tree; nothing touches the
#    real /etc/backupkit, /var/lib/backupkit or any production database.
#  - Database clients, age and the AWS CLI are replaced by mocks in
#    tests/mocks so failure paths (dump error, upload error, retry) are
#    reproducible.

set -o pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
PROJECT_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"
MOCKS_DIR="${TESTS_DIR}/mocks"
BK_BIN="${PROJECT_ROOT}/bin/backupkit"

BK_TEST_PASS=0
BK_TEST_FAIL=0
BK_TEST_CURRENT=""

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------
bk_test_fail() {
  BK_TEST_FAIL=$((BK_TEST_FAIL + 1))
  printf '  FAIL %s: %s\n' "$BK_TEST_CURRENT" "$1"
  if [ -n "${2-}" ]; then
    printf '%s\n' "$2" | sed 's/^/       /'
  fi
}

bk_test_pass() {
  BK_TEST_PASS=$((BK_TEST_PASS + 1))
  printf '  ok   %s: %s\n' "$BK_TEST_CURRENT" "$1"
}

assert_eq() {
  # assert_eq EXPECTED ACTUAL LABEL
  if [ "$1" = "$2" ]; then
    bk_test_pass "${3:-equal}"
  else
    bk_test_fail "${3:-equal}" "expected: [$1]
actual:   [$2]"
  fi
}

assert_ne() {
  if [ "$1" != "$2" ]; then
    bk_test_pass "${3:-different}"
  else
    bk_test_fail "${3:-different}" "both values are [$1]"
  fi
}

assert_contains() {
  # assert_contains HAYSTACK NEEDLE LABEL
  case "$1" in
    *"$2"*) bk_test_pass "${3:-contains}" ;;
    *) bk_test_fail "${3:-contains}" "did not find [$2] in:
$1" ;;
  esac
}

assert_empty() {
  if [ -z "$1" ]; then bk_test_pass "${2:-empty}"; else bk_test_fail "${2:-empty}" "value was [$1]"; fi
}

assert_not_empty() {
  if [ -n "$1" ]; then bk_test_pass "${2:-not empty}"; else bk_test_fail "${2:-not empty}" "value was empty"; fi
}

assert_file_exists() {
  if [ -f "$1" ]; then bk_test_pass "${2:-file exists}"; else bk_test_fail "${2:-file exists}" "missing: $1"; fi
}

assert_file_missing() {
  if [ ! -e "$1" ]; then bk_test_pass "${2:-file missing}"; else bk_test_fail "${2:-file missing}" "unexpected: $1"; fi
}

assert_status() {
  # assert_status EXPECTED ACTUAL LABEL
  assert_eq "$1" "$2" "${3:-exit status}"
}

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
bk_test_setup() {
  # Idempotent: bk_test_init calls this too, and the per-test temp tree must
  # stay stable so the runner can collect results from a known path.
  if [ -n "${BK_TEST_TMP:-}" ] && [ -d "${BK_TEST_TMP:-}" ]; then
    return 0
  fi
  BK_TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/backupkit-test.XXXXXX")"
  BK_TEST_COUNT_FILE="${BK_TEST_TMP}/.counts"
  export BACKUPKIT_ETC="${BK_TEST_TMP}/etc"
  export BACKUPKIT_STATE_DIR="${BK_TEST_TMP}/state"
  export BACKUPKIT_LOG_DIR="${BK_TEST_TMP}/log"
  export BACKUPKIT_LOG_FILE="${BK_TEST_TMP}/log/backupkit.log"
  export BK_LOG_FILE="${BK_TEST_TMP}/log/backupkit.log"
  export BACKUPKIT_IDENTITY="${BACKUPKIT_ETC}/age.key"
  export BACKUPKIT_CRON_FILE="${BK_TEST_TMP}/cron.d/backupkit"
  export MOCK_STORE_DIR="${BK_TEST_TMP}/store"
  export MOCK_AWS_ROOT="${BK_TEST_TMP}/aws-root"
  export MOCK_LOG="${BK_TEST_TMP}/mock.log"
  export MOCK_COUNTER_DIR="${BK_TEST_TMP}/counters"
  export BK_ALLOW_INSECURE_PERMS=1
  # info level: several assertions check the operator facing messages.
  export BK_LOG_LEVEL="${BK_LOG_LEVEL:-info}"

  mkdir -p "$BACKUPKIT_ETC" "$BACKUPKIT_STATE_DIR" "$BACKUPKIT_LOG_DIR" \
           "$MOCK_STORE_DIR" "$MOCK_AWS_ROOT" "$MOCK_COUNTER_DIR" "${BK_TEST_TMP}/cron.d"
  chmod 700 "$BACKUPKIT_ETC"
  : >"$MOCK_LOG"

  # Mocks first in PATH so mysqldump/mysql/age/aws resolve to them.
  export PATH="${MOCKS_DIR}:${PATH}"
  export MYSQLDUMP_BIN="mysqldump"
  export MYSQL_BIN="mysql"
}

bk_test_teardown() {
  [ -n "${BK_TEST_TMP:-}" ] && [ -d "$BK_TEST_TMP" ] && rm -rf -- "$BK_TEST_TMP"
  BK_TEST_TMP=""
  BK_TEST_COUNT_FILE=""
}

# write_config [EXTRA_JQ_FILTER]
write_config() {
  local extra="${1-}"
  local storage_provider="${BK_TEST_PROVIDER:-local}"
  local json
  json="$(cat <<'EOF'
{
  "timezone": "Asia/Jakarta",
  "storage": { "provider": "local", "local": { "path": "/PLACEHOLDER" }, "prefix": "backups",
               "retry": { "max_attempts": 3, "delay_seconds": 1 }, "timeout_seconds": 10 },
  "encryption": { "enabled": true, "recipient": "age1testrecipient0000000000000000000000000000000000000000000000000000",
                  "identity_file": "/PLACEHOLDER_KEY" },
  "compression": { "algorithm": "zstd", "level": 3 },
  "retention": { "daily": 7, "weekly": 4, "monthly": 12, "min_age_hours": 0 },
  "schedule": { "weekly_dow": 0, "monthly_dom": 1 },
  "notifications": { "telegram": { "enabled": false } },
  "databases": [
    { "id": "app-mysql", "type": "mysql", "database": "appdb",
      "host": "127.0.0.1", "port": 3306, "user": "backup", "enabled": true,
      "schedule": { "daily": true, "weekly": true, "monthly": true },
      "retention": { "daily": 7, "weekly": 4, "monthly": 12 } },
    { "id": "app-pg", "type": "postgres", "database": "appdb",
      "host": "127.0.0.1", "port": 5432, "user": "backup", "enabled": true,
      "schedule": { "daily": true, "weekly": true, "monthly": false },
      "retention": { "daily": 2, "weekly": 2, "monthly": 2 }, "globals": true }
  ]
}
EOF
)"
  json="$(printf '%s' "$json" \
    | sed -e "s|/PLACEHOLDER_KEY|${BACKUPKIT_IDENTITY}|" \
          -e "s|/PLACEHOLDER|${MOCK_STORE_DIR}|")"

  if [ "$storage_provider" = "s3" ]; then
    json="$(printf '%s' "$json" | jq -c '.storage = {provider:"s3",bucket:"test-bucket",endpoint:"https://s3.example.test",region:"us-east-1",prefix:"backups",retry:{max_attempts:3,delay_seconds:1},timeout_seconds:10}')"
  elif [ "$storage_provider" = "cloudflare-r2" ]; then
    json="$(printf '%s' "$json" | jq -c '.storage = {provider:"cloudflare-r2",bucket:"test-bucket",endpoint:"https://abcd1234.r2.cloudflarestorage.com",region:"auto",prefix:"backups",retry:{max_attempts:3,delay_seconds:1},timeout_seconds:10}')"
  fi

  if [ -n "$extra" ]; then
    json="$(printf '%s' "$json" | jq -c "$extra")"
  fi

  printf '%s\n' "$json" | jq . >"$BACKUPKIT_ETC/config.json"
  chmod 600 "$BACKUPKIT_ETC/config.json"
  BK_TEST_CONFIG_JSON="$json"
}

write_secrets() {
  mkdir -p "$BACKUPKIT_ETC"
  cat >"$BACKUPKIT_ETC/secrets.json" <<'EOF'
{
  "storage": { "access_key": "test-access-key", "secret_key": "test-secret-key" },
  "notifications": { "telegram": { "bot_token": "", "chat_id": "" } },
  "databases": {
    "app-mysql": { "user": "backup", "password": "s3cr3t-mysql", "host": "127.0.0.1", "port": 3306 },
    "app-pg": { "user": "backup", "password": "s3cr3t-pg", "host": "127.0.0.1", "port": 5432 }
  }
}
EOF
  chmod 600 "$BACKUPKIT_ETC/secrets.json"
}

write_key() {
  # A fake but well-formed identity file (the age mock accepts anything).
  mkdir -p "$BACKUPKIT_ETC"
  cat >"$BACKUPKIT_IDENTITY" <<'EOF'
# created: 2026-01-01T00:00:00Z
# public key: age1testrecipient0000000000000000000000000000000000000000000000000000
AGE-SECRET-KEY-1TESTTESTTESTTESTTESTTESTTESTTESTTESTTESTTESTTESTTESTTESTTESTTEST
EOF
  chmod 600 "$BACKUPKIT_IDENTITY"
}

bk_test_init() {
  # Standard starting point for a test.
  bk_test_setup
  write_key
  write_secrets
  write_config "${1-}"
}

# ---------------------------------------------------------------------------
# Running the CLI
# ---------------------------------------------------------------------------
bk() {
  "$BK_BIN" "$@"
}

# make_stub NAME BODY... -> creates an executable stub and puts its directory
# first in PATH. Used to simulate broken tools (compressor, etc).
make_stub() {
  local name="$1"
  shift
  local dir="${BK_TEST_TMP}/stubs"
  mkdir -p "$dir"
  {
    printf '#!/usr/bin/env bash\n'
    printf '%s\n' "$@"
  } >"${dir}/${name}"
  chmod +x "${dir}/${name}"
  case ":${PATH}:" in
    *":${dir}:"*) ;;
    *) PATH="${dir}:${PATH}"; export PATH ;;
  esac
}

# path_without CMD... -> PATH where those commands are shadowed away.
# Everything else (mocks included) is symlinked into a private directory, so a
# single missing dependency can be tested in isolation.
path_without() {
  local dir="${BK_TEST_TMP}/path-no"
  local p f bn skip c
  mkdir -p "$dir"
  local old_ifs="$IFS"
  IFS=':'
  for p in $PATH; do
    [ -d "$p" ] || continue
    for f in "$p"/*; do
      [ -x "$f" ] || continue
      [ -d "$f" ] && continue
      bn="$(basename "$f")"
      skip=0
      for c in "$@"; do
        [ "$bn" = "$c" ] && skip=1
      done
      [ "$skip" = "1" ] && continue
      [ -e "${dir}/${bn}" ] && continue
      ln -s "$f" "${dir}/${bn}" 2>/dev/null || true
    done
  done
  IFS="$old_ifs"
  PATH="$dir"
  export PATH
}

# ---------------------------------------------------------------------------
# Mock state helpers
# ---------------------------------------------------------------------------
mock_calls() {
  # All mock invocations recorded so far.
  [ -f "$MOCK_LOG" ] && cat "$MOCK_LOG" || true
}

mock_call_count() {
  # mock_call_count PATTERN -> number of matching lines (exactly one number,
  # even when grep finds nothing and exits 1).
  local count="0"
  if [ -f "$MOCK_LOG" ]; then
    count="$(grep -c "$1" "$MOCK_LOG" 2>/dev/null || true)"
  fi
  printf '%s' "${count:-0}"
}

mock_reset() {
  : >"$MOCK_LOG"
  rm -rf "${MOCK_COUNTER_DIR:?}" 2>/dev/null || true
  mkdir -p "$MOCK_COUNTER_DIR"
}

# ---------------------------------------------------------------------------
# Misc conveniences
# ---------------------------------------------------------------------------
today_dow() { TZ=Asia/Jakarta date +%w; }
today_dom() { TZ=Asia/Jakarta date +%d; }

# jq filter that makes weekly and monthly due today, so the reuse path can be
# exercised on any day of the week.
due_schedule_jq() {
  printf '.schedule.weekly_dow = %s | .schedule.monthly_dom = %s' "$(today_dow)" "$(today_dom)"
}

latest_backup_id() {
  [ -d "$BACKUPKIT_STATE_DIR/manifests" ] || return 0
  ls "$BACKUPKIT_STATE_DIR/manifests" 2>/dev/null | sed 's/\.json$//' | sort -r | head -1
}

count_files() {
  find "$1" -type f 2>/dev/null | wc -l | tr -d ' '
}

# Artifacts only: excludes the *.manifest.json records, so "did the dump get
# uploaded?" is not confused with "did the manifest get uploaded?".
count_artifacts() {
  find "$1" -type f ! -name '*.manifest.json' 2>/dev/null | wc -l | tr -d ' '
}

# The cron file path the CLI would use (mirrors bk_cron_file in the scheduler
# module, which is not sourced by the test harness).
bk_cron_file() {
  printf '%s' "${BACKUPKIT_CRON_FILE}"
}

manifest_json() {
  cat "${BACKUPKIT_STATE_DIR}/manifests/$1.json" 2>/dev/null
}

history_dump() {
  cat "$BACKUPKIT_STATE_DIR/history.jsonl" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Synthetic manifests (for retention tests without running real dumps)
# ---------------------------------------------------------------------------# mk_manifest DB_ID TYPE ID CREATED TYPES_CSV [STATUS]
mk_manifest() {
  local db_id="$1" type="$2" id="$3" created="$4" types="$5" status="${6:-verified}"
  local artifact_key manifest_key art_path man_path
  local year month

  year="$(printf '%s' "$id" | cut -c4-7)"
  month="$(printf '%s' "$id" | cut -c8-9)"
  artifact_key="backups/${db_id}/${type}/${year}/${month}/${id}.primary.zst.age"
  manifest_key="backups/${db_id}/${type}/${year}/${month}/${id}.manifest.json"

  art_path="${MOCK_STORE_DIR}/${artifact_key}"
  man_path="${MOCK_STORE_DIR}/${manifest_key}"
  mkdir -p "$(dirname "$art_path")" "$(dirname "$man_path")"
  printf 'fake-artifact-%s\n' "$id" >"$art_path"

  mkdir -p "${BACKUPKIT_STATE_DIR}/manifests"
  local types_json="[]"
  if [ -n "$types" ]; then
    types_json="$(printf '%s' "$types" | jq -R 'split(",")')"
  fi
  jq -cn \
    --arg id "$id" \
    --argjson schema_version 1 \
    --arg db_id "$db_id" \
    --arg type "$type" \
    --argjson types "$types_json" \
    --arg created "$created" \
    --arg status "$status" \
    --arg key "$artifact_key" \
    --arg sha "$(printf 'fake-artifact-%s\n' "$id" | shasum -a 256 | awk '{print $1}')" \
    --argjson size "$(wc -c <"$art_path" | tr -d ' ')" \
    '{schema_version:$schema_version,id:$id,status:$status,
      database:{id:$db_id,type:"mysql",name:"appdb"},
      types:$types,primary_type:$type,created_at:$created,created_local:$created,
      timezone:"Asia/Jakarta",host:"testhost",backupkit_version:"0.1.0",
      duration_seconds:1,
      artifacts:[{role:"primary",key:$key,sha256:$sha,size_bytes:$size,size_human:"1 B",
                  compression:"zstd",encryption:"age"}],
      tool_versions:{},retention:{daily:7,weekly:4,monthly:12},error:""}' >"$man_path"
  cp -- "$man_path" "${BACKUPKIT_STATE_DIR}/manifests/${id}.json"
}

# mk_many_manifests DB TYPE COUNT [TYPES] -> COUNT manifests, one per day back
mk_many_manifests() {
  local db="$1" type="$2" count="$3" types="${4:-$2}"
  local i day id created
  i=1
  while [ "$i" -le "$count" ]; do
    day="$(printf '%02d' "$i")"
    id="bk_202601${day}T020000Z_aa$(printf '%04d' "$i")"
    created="2026-01-${day}T02:00:00Z"
    mk_manifest "$db" "$type" "$id" "$created" "$types"
    i=$((i + 1))
  done
}

count_manifests() {
  # count_manifests DB [TYPE]
  local db="$1" type="${2-}"
  if [ -n "$type" ]; then
    find "${MOCK_STORE_DIR}/backups/${db}/${type}" -name '*.manifest.json' 2>/dev/null | wc -l | tr -d ' '
  else
    find "${MOCK_STORE_DIR}/backups/${db}" -name '*.manifest.json' 2>/dev/null | wc -l | tr -d ' '
  fi
}

# ---------------------------------------------------------------------------
# Test runner
# ---------------------------------------------------------------------------
run_tests() {
  local names name rc total=0 counts p f
  local sum_pass=0 sum_fail=0
  names="$(declare -F 2>/dev/null | awk '{print $3}' | grep '^test_' || true)"
  if [ -z "$names" ]; then
    printf 'no tests defined\n'
    return 1
  fi

  for name in $names; do
    total=$((total + 1))
    BK_TEST_CURRENT="$name"
    printf '\n%s\n' "$name"
    bk_test_setup
    BK_TEST_PASS=0
    BK_TEST_FAIL=0
    (
      "$name" </dev/null
      printf '%s %s\n' "$BK_TEST_PASS" "$BK_TEST_FAIL" >"$BK_TEST_COUNT_FILE"
    )
    rc=$?
    if [ -f "$BK_TEST_COUNT_FILE" ]; then
      counts="$(cat "$BK_TEST_COUNT_FILE")"
      p="$(printf '%s' "$counts" | awk '{print $1 + 0}')"
      f="$(printf '%s' "$counts" | awk '{print $2 + 0}')"
    else
      p=0
      f=0
    fi
    if [ "$rc" -ne 0 ]; then
      f=$((f + 1))
      printf '  FAIL %s: test aborted with status %s (see the message above)\n' "$name" "$rc"
    fi
    sum_pass=$((sum_pass + p))
    sum_fail=$((sum_fail + f))
    bk_test_teardown
  done

  printf '\n%s: %s assertion(s) passed, %s failed (%s test function(s))\n' \
    "$(basename "$0")" "$sum_pass" "$sum_fail" "$total"
  [ "$sum_fail" -eq 0 ] || return 1
  return 0
}
