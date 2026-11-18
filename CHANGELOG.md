# Changelog

All notable changes to BackupKit are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and the project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Nothing yet.

## [0.1.0] - 2026-03-01

First release: a working agent for 5 VPS hosts, not a proof of concept.

### Added

- **CLI**: `init`, `backup`, `list`, `status`, `verify`, `restore`, `cleanup`,
  `config validate|show|path`, `doctor`, `install-scheduler`,
  `uninstall-scheduler`, `version`.
- **MySQL/MariaDB backups** with `mysqldump --single-transaction --quick
  --routines --triggers --events`, credentials passed through a temporary
  `600` `--defaults-extra-file`, and a `-- Dump completed` footer check so a
  truncated dump is rejected even when `mysqldump` exits 0.
- **PostgreSQL backups** with `pg_dump --format=custom`, a `PGDMP` header check,
  and optional cluster globals (`pg_dumpall --globals-only`) stored as a second
  artifact of the same backup and restorable on its own.
- **Compression** with `zstd` (default) or `gzip`, chosen by config, plus magic
  sniffing so decompression does not depend on file names.
- **Encryption** with `age` to a configured recipient; the private key stays on
  the host. Plaintext uploads require an explicit `allow_plaintext`
  acknowledgement and are refused by validation otherwise.
- **Storage abstraction** with two providers: Cloudflare R2 (explicit
  account-scoped endpoint) and generic S3-compatible storage, both through the
  AWS CLI, with retries, request timeouts, upload size verification and
  provider-specific probing. A `local` directory provider supports tests,
  offline mirrors and air-gapped hosts.
- **Validation pipeline**: lock, dump, dump sanity, compress, encrypt, artifact
  sanity, SHA-256, upload, upload verification, manifest, history, notification,
  retention, temp cleanup — each stage with its own exit code.
- **Manifest-based bookkeeping**: every stored backup has a manifest recorded
  next to the objects and mirrored locally, so `list` works offline and
  retention and restore never guess from file names.
- **Snapshot reuse**: when daily, weekly and monthly coincide, one dump is
  tagged with all matching categories instead of producing three backups.
- **Retention**: per database and per category, driven by manifests, deleting
  only objects under the configured prefix that are out of policy for every tag
  they carry, never the newest verified backup, never a `failed` manifest,
  never an unrecognised object, with `--dry-run`, a `min_age_hours` guard and a
  `0 means keep forever` rule.
- **Locking**: per-database `mkdir` lock with stale detection (dead pid or older
  than 6 hours) and release on success, failure and signal.
- **Restore utilities**: list, download, checksum verify, decrypt, decompress,
  MySQL restore, PostgreSQL restore, PostgreSQL globals restore, `--dry-run`,
  and mandatory confirmation (`yes` prompt or `--yes`).
- **Structured logging**: JSON lines with `ts`/`level`/`event`/`run_id`/`host`
  and pipeline events; append-only `history.jsonl` with status, duration, size,
  checksum, key and error. Secret values are redacted from every message, and
  credentials never reach a command line.
- **Optional Telegram notifications** for success, failure, reuse, retention and
  restore; strictly best-effort so an outage cannot fail a backup.
- **`doctor`** checking core tools, config and secret permissions, key/recipient
  match, compressor, storage reachability, per-database client binaries,
  client/server version compatibility, live connectivity, stale locks and cron
  installation.
- **Cron installation** writing `/etc/cron.d/backupkit` with `CRON_TZ` from the
  config, plus a catch-up entry; idempotent install and a safe uninstall that
  refuses to remove a file it did not create.
- **Installer** (`scripts/install.sh`) with dependency checking, optional
  `apt-get` installation, prefixes for user-level installs and `--dry-run`; and
  an uninstaller that keeps configuration, state and key data unless `--purge`
  is explicitly confirmed.
- **Small project footprint**: bash 3.2+-compatible modules, `jq` as the only
  hard dependency, no daemon, no database, no network service.
- **Test suite** (`tests/run.sh`): 223 assertions across configuration
  validation, dump failure modes, compression and encryption failures, upload
  failure and retry, size mismatch detection, checksum tampering, retention
  rules, concurrent and stale locking, restore workflows and confirmation,
  PostgreSQL globals, missing dependencies, scheduler handling, log hygiene and
  secret redaction. All of it runs against mocks in `tests/mocks`; no production
  database or credential is involved.

### Security

- Secrets and the age key must be mode `600` (or `400`); enforced at load time
  and by `doctor`.
- A `password` key inside `config.json` fails validation.
- Deletion and download of an object are refused unless its key lives under the
  configured storage prefix.
- Temporary credential files are created `600` under a `700` directory and
  removed on exit; state and lock directories are `700`; manifests are written
  atomically at `600`.
- Configuration is parsed as JSON with `jq`; nothing is `eval`ed, no user
  supplied file is sourced, and identifiers used in paths are validated.

### Known gaps

Listed honestly in [docs/roadmap.md](docs/roadmap.md) — no central dashboard, no
Object Lock support, no incremental dumps or point-in-time recovery, no
automatic restore testing.

[Unreleased]: https://github.com/rosyidrid/backup-kit/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/rosyidrid/backup-kit/releases/tag/v0.1.0
