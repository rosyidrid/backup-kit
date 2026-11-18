# Test report

How BackupKit was tested for the 0.1.0 release, what the tests cover, what they
deliberately do not cover, and the raw results.

## How to reproduce

```bash
git clone git@github.com:rosyidrid/backup-kit.git
cd backup-kit
bash tests/run.sh                # everything (~5 minutes)
bash tests/run.sh retention      # one area, by test file name
```

Requirements: `bash`, `jq`, `zstd`, `gzip`, `sha256sum` (Linux) or `shasum`
(macOS). No database is contacted and no network call is made, in any test.

## Approach

- **No test framework dependency.** `tests/lib/helpers.sh` provides a tiny
  runner plus assertions, so the suite runs on a bare Ubuntu/Debian or macOS box.
- **Hermetic.** Every test uses a fresh `mktemp` tree with `BACKUPKIT_ETC`,
  `BACKUPKIT_STATE_DIR`, `BACKUPKIT_LOG_DIR`, `BACKUPKIT_IDENTITY` and
  `BACKUPKIT_CRON_FILE` pointed inside it, and `BK_ALLOW_INSECURE_PERMS=1` only
  to allow a `600`-only rule to be exercised separately.
- **Real code paths, mocked system boundaries.** `mysqldump`, `mysql`, `pg_dump`,
  `pg_dumpall`, `pg_restore`, `psql`, `age`, `age-keygen` and `aws` are replaced
  by scripts in `tests/mocks` that behave like the real tools and can be told to
  fail (`MOCK_MYSQLDUMP_FAIL`, `MOCK_AGE_FAIL`, `MOCK_AWS_FAIL_UPLOADS`,
  `MOCK_AWS_TRUNCATE`, ...). The real `zstd`/`gzip` and the real SHA-256 tools are
  used, so compression and checksum handling are genuinely exercised.
- **The S3 driver is tested for real** (retry, size verification, listings,
  deletes, endpoint handling) against the fake AWS CLI, which stores objects in a
  directory and answers `head-object`/`list-objects-v2` like the API does.
- **Offline by construction.** The `local` storage provider is the default in the
  suite; the S3 provider is exercised through the mock.

## Coverage by area

| File | Assertions | Covers |
|---|---|---|
| `test_01_config.sh` | 21 | valid config, plaintext acknowledgement, password in `config.json`, unknown provider, R2 endpoint shape, non-numeric retention, `globals` on MySQL, secret permissions, redaction in `config show`, invalid JSON |
| `test_02_backup_mysql.sh` | 37 | happy path (manifest, checksum vs. stored object, history), failed dump, missing footer, empty dump, password never in argv, one snapshot for daily+weekly, repeat run is a no-op, `--force`, type not due, `--dry-run` |
| `test_03_pipeline_failures.sh` | 12 | compression failure (exit 6), encryption failure (exit 7), previous backup preserved, no plaintext left behind |
| `test_04_storage.sh` | 17 | local provider validation, S3 upload + verification + manifest upload, retry until success, retries exhausted (exactly `max_attempts`), truncated object detected, R2 explicit endpoint and `auto` region, generic S3 endpoint, deletion refuses keys outside the prefix |
| `test_05_retention.sh` | 18 | keep exactly the policy count, dry-run, multi-tag snapshot surviving an expired category, newest never deleted, `0` disables deletion, untagged manifest untouched, failed manifest untouched, per-database override, artifacts removed with manifests, cleanup after a successful backup, `--no-cleanup` |
| `test_06_lock.sh` | 11 | concurrent run refused (exit 4), history records it, stale lock from a dead pid reclaimed, over-age lock reclaimed, lock released after success and after failure, per-database locking |
| `test_07_verify_restore.sh` | 27 | shallow and deep verify, tampered object detected (exit 9), unknown id (exit 13), target required, refusal without confirmation (exit 12) and no client call, dry-run (no download, no client call), real restore with `--yes`, failed backup refuses to restore, tampered object stops the restore, `list`, `status`, `list --json` |
| `test_08_deps_doctor.sh` | 27 | missing `mysqldump`/`zstd`/`age`/`aws` each stop the run (exit 3) and name the command, stage recorded in history, doctor healthy, doctor flags a missing client, no config file, recipient/key mismatch, insecure secret permissions, unknown command, `version` |
| `test_09_postgres.sh` | 18 | two artifacts (primary + globals), missing `PGDMP` header rejected, empty globals rejected, `pg_restore` with the right target and flags, globals restored through `psql` separately, globals restore needs no target, deep verify of both artifacts, primary restore of a manifest without a primary artifact fails cleanly |
| `test_10_scheduler.sh` | 22 | default times, config-driven weekly/monthly days, timezone, cron file written, idempotent install, uninstall removes ours, refuses a foreign file, no-op when absent, `--bin`/`--user` |
| `test_11_logging.sh` | 13 | no secret in the log, log lines are JSON, pipeline events present, history carries size/checksum/key/duration, console output clean, `config show` hides credentials |

## Results

Environment: macOS 15.8.3, stock bash 3.2.57, jq 1.7.1, zstd 1.5.7.

```
test_01_config.sh            21 assertion(s) passed, 0 failed (11 test function(s))
test_02_backup_mysql.sh      37 assertion(s) passed, 0 failed (10 test function(s))
test_03_pipeline_failures.sh 12 assertion(s) passed, 0 failed (4 test function(s))
test_04_storage.sh           17 assertion(s) passed, 0 failed (8 test function(s))
test_05_retention.sh         18 assertion(s) passed, 0 failed (11 test function(s))
test_06_lock.sh              11 assertion(s) passed, 0 failed (7 test function(s))
test_07_verify_restore.sh    27 assertion(s) passed, 0 failed (12 test function(s))
test_08_deps_doctor.sh       27 assertion(s) passed, 0 failed (12 test function(s))
test_09_postgres.sh          18 assertion(s) passed, 0 failed (8 test function(s))
test_10_scheduler.sh         22 assertion(s) passed, 0 failed (8 test function(s))
test_11_logging.sh           13 assertion(s) passed, 0 failed (6 test function(s))

test files: 11 passed, 0 failed
223 assertions, 0 failures
```

Because the code is written for bash 3.2+, the same suite is expected to pass on
Ubuntu's bash 5; `.github/workflows/tests.yml` runs it on Linux and macOS and
syntax-checks every shell file on both before running the suite.

Bugs the suite caught during development, all fixed:

1. `jq`'s `//` operator treats `false` as absent, so every explicit `false` in
   the configuration silently fell back to the caller's default — including
   `enabled: false` and `schedule.daily: false`. Replaced with an explicit null
   test.
2. Retention compared the age cutoff in the wrong direction, so nothing was ever
   deletable (`min_age_hours` behaved as "delete nothing").
3. `bk_log` wrote informational messages to stdout, which corrupted the values of
   functions whose output is captured (`bk_mkworkdir`, `bk_retention_apply`,
   `bk_restore_download_artifact`). All diagnostics now go to stderr.
4. Temperature registrations were lost because `bk_mkworkdir` runs inside a
   command substitution; the temp registry is now a file.
5. Cleanup relied on the exit trap running in the same shell as the registration,
   leaving stale work directories behind — caught by asserting the work root is
   empty after a run.
6. The verification stage keyed off the file extension (`.zst`), which never
   matches an encrypted artifact (`.zst.age`); it now sniffs the compression
   format from the magic bytes.
7. Restores validated the checksum inside a command substitution, where the
   failure only ended the subshell; the status is now checked by the caller.
8. A missing dependency or a failed dump produced no console message at all, only
   a history entry; failures now log the stage and the reason.

## What the tests do not cover

- **Real database servers.** No MySQL/PostgreSQL instance is contacted. Dump and
  restore argument construction and the failure handling around them are covered;
  server-side behaviour (privileges, version quirks, collations) is not.
- **Real object storage.** The S3 driver is tested against a mock that is
  faithful for the operations used. Provider-specific behaviour (R2 multipart
  minimum sizes, Wasabi `HeadBucket`, eventual consistency) needs a real bucket.
- **Real age encryption.** The `age` mock base64-encodes with a marker. The
  pipeline order, key handling and failure paths are covered; the cryptography is
  age's, and is not reimplemented here.
- **Restore into a scratch database with data comparison.** That is an operator
  rehearsal, documented in [restore.md](restore.md#restore-rehearsal-checklist),
  not an automated test.
- **Long-running stability** (multi-gigabyte dumps, hours-long restores) and
  performance characteristics.
- **Cron itself.** The generated file and its content are tested; whether the
  system's cron honours it is an integration concern, checked by `doctor` and in
  production.

## Manual checks performed

- `backupkit init` on a clean tree, then `config validate` against the shipped
  `config/config.example.json` → valid.
- End-to-end run against the `local` provider: backup → `list` → `status` →
  `verify --deep` → restore with `--yes` → `cleanup --dry-run` → `cleanup`.
- S3 path against the mock AWS CLI with `MOCK_AWS_FAIL_UPLOADS=2`: two failures,
  third attempt succeeds, manifest and artifact both present.
- `doctor` on a healthy install (exit 0), with a missing client, and with a
  world-readable secrets file (both exit non-zero).
