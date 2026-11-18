# Contributing to BackupKit

Thanks for considering a contribution. BackupKit backs up other people's data,
so the review bar is "would I trust this with a production database?".

## Priorities

In order: **data safety, reliability, simplicity, security, maintainability,
extensibility.** A simpler change that is obviously safe beats a clever one that
needs three paragraphs of argument.

## Before you start

For anything larger than a small fix, open an issue describing the problem and
your intended approach. BackupKit deliberately avoids a central server, a
dashboard, Redis and a distributed scheduler; proposals that add those need to
argue why the agent-only model cannot carry the feature.

## Development setup

```bash
git clone git@github.com:rosyidrid/backup-kit.git
cd backup-kit

# Nothing to build: bash + jq + (zstd|gzip) + sha256sum|shasum are enough.
bash tests/run.sh                     # full suite (~5 minutes)
bash tests/run.sh retention           # one area by file name
bash tests/run.sh --help 2>/dev/null  # n/a; see tests/run.sh
```

Run the CLI against a throwaway directory tree instead of your machine:

```bash
export BACKUPKIT_ETC=$(mktemp -d)/etc
export BACKUPKIT_STATE_DIR=$(mktemp -d)/state
export BACKUPKIT_LOG_DIR=$(mktemp -d)/log
export BACKUPKIT_LOG_FILE="$BACKUPKIT_LOG_DIR/backupkit.log"
export PATH="$PWD/tests/mocks:$PATH"      # fake mysqldump/mysql/pg_*/age/aws
bash bin/backupkit init --no-key
bash bin/backupkit config validate
```

`tests/mocks` contains stand-ins for the database clients, `age` and the AWS
CLI, driven by environment variables (`MOCK_MYSQLDUMP_FAIL`, `MOCK_AGE_FAIL`,
`MOCK_AWS_FAIL_UPLOADS`, ...). Use them to reproduce failure paths.

## Code conventions

- bash, compatible with **bash 3.2+** (macOS stock bash): no associative arrays,
  no `mapfile`/`readarray`, no `${var,,}`/`${var^^}`, no `declare -n`.
- One responsibility per module in `src/`; functions are prefixed by domain
  (`bk_`, `bk_mysql_`, `bk_storage_`, ...).
- A function that returns data prints it to stdout and is captured by the
  caller. Diagnostics go through `bk_log` (stderr). **Never** log to stdout from
  a function whose output is captured.
- Errors are explicit. `bk_die CODE MESSAGE` for unrecoverable problems; unless
  in a command substitution, remember that it exits only the subshell — check
  the status of captured calls.
- Use the existing exit codes; a new failure class needs a new documented code.
- Build command lines with arrays and quote expansions. No string concatenation
  into a shell command.
- Validate external input against an allow-list pattern (`bk_db_id_valid`,
  `bk_storage_key_valid`).
- Prefer `mktemp` + `bk_mkworkdir` and register temporary paths for cleanup.

## Adding a feature

1. Write the failing test first (`tests/test_*.sh`), using mocks rather than a
   real database.
2. Implement the smallest change that passes it.
3. Update the docs that the change contradicts: `README.md`,
   `docs/configuration.md` (new keys), `docs/usage.md` (new flags),
   `docs/architecture.md` (new modules, pipeline, manifest fields),
   `docs/security.md` (new credentials or trust assumptions), `CHANGELOG.md`.
4. Run the full suite.
5. Confirm no secret, hostname, IP, domain or internal project name leaked into
   code, examples, docs or fixtures.

## Security review checklist

Every pull request that touches logging, credentials, deletion, restore or
configuration must answer these:

- Do new log lines go through `bk_log` (and therefore redaction)?
- Is any new secret passed on a command line, or written outside a `600` file?
- Does any new deletion path call `bk_storage_key_allowed` first?
- Is any new value interpolated into a command or path without validation?
- Could a failure of the new code leave the previous backup set damaged?
- Is a new dependency justified, and is it optional unless strictly required?
- Does the change keep working when storage, notifications or the database is
  unreachable?

## Test expectations

- New behaviour needs a test that fails without the change.
- Failure paths matter more than happy paths; the suite covers dump, compress,
  encrypt, upload, retry, checksum, retention, lock and restore failures.
- Tests must be hermetic: temporary directories only, no network, no real
  credentials, no production database.
- Keep the mock layer realistic: if you change how a tool is invoked, update the
  corresponding mock so the test still exercises the real code path.

## Commits and pull requests

- Conventional Commits: `fix(retention): ...`, `feat(postgres): ...`,
  `docs(...)`, `test(...)`, `chore(...)`.
- Subject in the imperative mood, ≤ 72 characters; the body explains *why*.
- One logical change per commit; keep diffs reviewable.
- In the pull request, state what you ran (`bash tests/run.sh`), what changed,
  and anything you could not test. Note explicitly any user-visible behaviour
  change.

## Reporting bugs

Include: `backupkit version`, `backupkit status --json`, `backupkit doctor
--no-connect`, `backupkit config show` (already redacted), the relevant
`history.jsonl` entries and the last lines of `backupkit.log`.

Never include `secrets.json`, `age.key`, or a raw dump.

## Reporting a security issue

Do not open a public issue with exploit details. Ask for a private channel in a
minimal issue, or contact the maintainer directly, and include the version and a
reproduction without real credentials or production data. See
[docs/security.md](docs/security.md).

## License

By contributing you agree that your contribution is licensed under the MIT
License (see [LICENSE](LICENSE)).
