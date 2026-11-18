# Roadmap and known gaps

This is the honest list of what BackupKit does **not** do yet. Everything in the
current release is listed in [README.md](../README.md) and
[architecture.md](architecture.md).

## Deliberately out of scope for now

| Not implemented | Why it is not there | Workaround today |
|---|---|---|
| Central dashboard / API server | the MVP is an agent, not a platform; a server would add a single point of failure and another thing to patch | `backupkit status --json` per host, polled by your monitoring |
| Prometheus/exporter integration | same reason; the JSON output is machine readable | scrape `backupkit status --json` with your own script, or parse `history.jsonl` |
| Redis / distributed scheduler | one host schedules only its own jobs; a distributed lock buys nothing when there is no coordination requirement | per-host cron and the per-database lock |
| Alerting on `backup is overdue` | the tool has no notion of "expected" beyond the schedule; a missed window is only visible in the logs | the catch-up cron entry, plus alerting on `history.jsonl` age |
| Object Lock / immutable buckets | provider-specific, and enabling it incorrectly makes retention impossible | enable versioning + Object Lock in the bucket's own settings |
| Incremental or differential dumps | logical dumps of a consistent snapshot are simpler and restorable in one step | run more frequent logical dumps; use binlog/WAL shipping for PITR |
| Point-in-time recovery | needs continuous WAL/binlog shipping, which is a different tool | MySQL binlog / PostgreSQL WAL archiving |
| Physical/raw volume snapshots | needs provider APIs and filesystem-consistent quiescing | `mysqldump`/`pg_dump`, or provider snapshots outside BackupKit |
| `mariadb-backup` / `pg_basebackup` | different consistency model, not requested for the MVP | logical dumps |
| Restore into a different server version automatically | version skew is silent data risk; the operator must decide | `backupkit restore --target`, after a rehearsal |
| Verifying a dump by restoring it automatically | automatic restores need scratch servers and credentials the agent should not hold | scheduled manual rehearsal, see [restore.md](restore.md#restore-rehearsal-checklist) |
| Encryption key rotation with re-encryption | re-encrypting means downloading, decrypting and re-uploading everything — an operator decision | add a second recipient, or re-run backups after rotation |
| Compression algorithms beyond zstd/gzip | adding xz/lz4 buys little and adds dependencies | `compression.algorithm` is an interface; a new arm is a small change |
| Database engines beyond MySQL/MariaDB and PostgreSQL | each engine needs its own dump/restore semantics and validation | the driver interface is one file plus one case arm |
| S3 multipart tuning knobs | the AWS CLI already handles multipart and retries | `storage.timeout_seconds`, `storage.retry.*` |
| Parallel backups of many databases | parallel dumps compete for IO and lock the same server | one run per database, sequential; add `--database` jobs to cron if servers differ |
| Resumable uploads | the CLI retries from the start; dumps are usually small enough | retry configuration, faster link, or a closer region |
| Windows support | the target platform is a Linux VPS | WSL |
| Non-bash implementations | bash + system utilities was the requirement | the CLI contract is documented if you want to reimplement the front end |

## Candidate next steps, in a sensible order

1. **Operational visibility without a server**: a `backupkit report --since 7d`
   command that summarises `history.jsonl`, and a documented pattern for pushing
   `status --json` into existing monitoring.
2. **Overdue detection**: store the expected next-run time in the manifest store
   and exit non-zero from `doctor` when a database is overdue — cheap, and it
   makes monitoring possible without a new component.
3. **`--dry-run` for `restore` that also runs a `--list` against the archive**
   (`pg_restore --list`, and a table inventory for MySQL) so more problems
   surface before the destructive step.
4. **Optional restore-test mode** that restores into a scratch database and
   compares a checksum of a row count, opt-in and off by default.
5. **Bucket-side immutability documentation**: a short guide for enabling
   versioning and Object Lock on R2/S3 that is compatible with BackupKit's
   delete-last ordering.
6. **Second storage target per database** (write to two buckets) for the
   "provider outage" case.

## Compatibility promises

- The manifest schema is versioned; a field is only removed in a new schema
  version, and readers ignore unknown fields.
- Exit codes are a public interface and will not be renumbered.
- Command-line flags may gain new options; existing ones keep their meaning.
- Configuration keys may gain new siblings; existing keys keep their meaning.
  A key that becomes meaningless will warn rather than fail.
