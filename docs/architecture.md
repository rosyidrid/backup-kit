# Architecture

## Shape

BackupKit is a **lightweight distributed backup agent**: one independent copy per
VPS, no central server, no shared database, no daemon.

```
┌───────────────────────────── VPS A ─────────────────────────────┐
│ cron → backupkit backup --all                                   │
│   bin/backupkit (CLI)  →  src/ modules                          │
│   /etc/backupkit      configuration (600) + secrets (600) + key │
│   /var/lib/backupkit  manifests, history.jsonl, locks, tmp      │
│   /var/log/backupkit  backupkit.log (JSON lines), cron.log      │
└───────────────────────────────┬─────────────────────────────────┘
                                │ HTTPS, S3 API
                ┌───────────────▼────────────────┐
                │ Cloudflare R2 / generic S3     │
                └────────────────────────────────┘
┌───────────────────────────── VPS B ─────────────────────────────┐
│ identical, independent installation                             │
└─────────────────────────────────────────────────────────────────┘
```

Consequences of the design:

- Adding a VPS is installing the agent and writing its config. Nothing else
  changes, no registration step, no shared namespace.
- A VPS that is down, misconfigured or offline affects only its own backups.
- There is no single point of failure and no server to keep patched — at the cost
  of having no central view. Cross-host reporting is intentionally out of scope
  (see [roadmap.md](roadmap.md)); each host can be polled with
  `backupkit status --json`.

## Modules

```
bin/backupkit                 entry point: argument dispatch, umask 077, exit trap
src/core/common.sh            exit codes, portable helpers, temp registry
src/core/log.sh               structured logging + secret redaction
src/core/config.sh            config/secrets loading and full validation
src/core/state.sh             manifest store, history, state directories
src/core/manifest.sh          manifest construction and queries
src/core/lock.sh              per-database mkdir lock with stale reclaim
src/drivers/driver.sh         database driver dispatch
src/drivers/mysql.sh          mysqldump / mysql
src/drivers/postgres.sh       pg_dump / pg_dumpall / pg_restore / psql
src/compression/compression.sh  zstd/gzip compress, decompress, magic sniffing
src/encryption/encryption.sh  age encrypt/decrypt to a recipient
src/storage/storage.sh        provider dispatch, key construction and validation, retry
src/storage/s3.sh             Cloudflare R2 and generic S3 through the AWS CLI
src/storage/local.sh          local directory provider
src/validation/validation.sh  checksums, upload verification, full verify
src/retention/retention.sh    inventory, policy evaluation, deletion
src/restore/restore.sh        download, verify, decrypt, decompress, replay
src/notifications/notify.sh   optional Telegram notifications (best-effort)
src/commands/*.sh             one file per CLI command
```

Modules are sourced by `bin/backupkit` in dependency order and talk to each other
through plain functions. There is no plugin system: an extension point is a
switch arm plus a file.

Adding a database engine = one `src/drivers/<engine>.sh` plus a case arm in
`driver.sh`. Adding a storage provider = one `src/storage/<provider>.sh` plus a
case arm in `storage.sh`. Neither requires touching the pipeline.

## Backup pipeline

```
 1  acquire the per-database lock              (skip + exit 4 when held)
 2  reuse check: can today's snapshot serve this type?  (tag it and exit 0)
 3  dependency check for this database
 4  dump                                        (mysqldump / pg_dump / pg_dumpall)
 5  dump sanity: non-empty, footer/header marker
 6  compress                                    (zstd or gzip)
 7  encrypt                                     (age, public key only)
 8  artifact sanity: exists, non-empty
 9  checksum                                    (SHA-256)
10  upload with retry                           (S3 API or local)
11  verify the uploaded object                  (exists + exact size)
12  write manifest locally, upload manifest
13  append to history.jsonl
14  notify (best-effort, never fails the run)
15  retention for this database (only after a verified upload)
16  remove temporary files
```

Anything that fails between 4 and 11 marks the run as `failed`, writes a
local-only failed manifest, records the stage in history, sends a notification
and exits with the stage's code. Previous backups are untouched: nothing is
deleted before the new artifact is verified.

Why this order matters:

- Compression before encryption: encrypted data is incompressible, so
  compressing first is the only order that saves space.
- Checksum before upload: the checksum is computed on the bytes that will be
  uploaded, so upload verification can compare size and integrity.
- Manifest after upload verification: a manifest is a promise that the object is
  there. Writing it before the upload succeeded would create records for objects
  that do not exist, and retention would later delete nothing while `list`
  claimed a backup existed.
- Retention last: cleanup must never be able to run against a backup set that the
  new backup did not join.

## Exit codes

Stable contract, also listed in [usage.md](usage.md#exit-codes):

```
0 success     1 generic     2 config      3 dependency   4 locked
5 dump        6 compress    7 encrypt     8 upload       9 verify
10 retention  11 restore    12 cancelled  13 not found
```

A run over several databases returns the first non-zero stage code, having
attempted every database.

## Manifest schema

`schema_version: 1`. One manifest per backup, stored next to the artifacts and
mirrored locally in `/var/lib/backupkit/manifests/<id>.json`.

```json
{
  "schema_version": 1,
  "id": "bk_20260301T020001Z_9f2c14",
  "status": "verified",
  "database": { "id": "app-mysql", "type": "mysql", "name": "appdb" },
  "types": ["daily", "weekly"],
  "primary_type": "daily",
  "created_at": "2026-03-01T02:00:01Z",
  "created_local": "2026-03-01 09:00:01 WIB",
  "timezone": "Asia/Jakarta",
  "host": "vps-01",
  "backupkit_version": "0.1.0",
  "duration_seconds": 40,
  "artifacts": [
    {
      "role": "primary",
      "key": "vps-backups/app-mysql/daily/2026/03/bk_20260301T020001Z_9f2c14.primary.zst.age",
      "sha256": "…",
      "size_bytes": 432339712,
      "size_human": "412.31 MiB",
      "compression": "zstd",
      "encryption": "age"
    }
  ],
  "tool_versions": { "dump": "mysqldump  Ver 8.0.36", "server": "8.0.36" },
  "retention": { "daily": 7, "weekly": 4, "monthly": 12 },
  "error": ""
}
```

- `types` is the set of retention categories this snapshot satisfies. A snapshot
  that served daily, weekly and monthly on the same day carries all three tags
  and is deleted only when out of policy for all of them.
- `status: "failed"` manifests are never uploaded and never eligible for
  deletion; they exist locally so the operator can see what happened.
- The local store is a cache of the bucket: `list` works offline, and
  `list --remote` rebuilds the view from storage when the host was rebuilt.

## Object layout

```
<prefix>/<db-id>/<primary-type>/<YYYY>/<MM>/<backup-id>.primary.<comp>[.age]
<prefix>/<db-id>/<primary-type>/<YYYY>/<MM>/<backup-id>.globals.<comp>[.age]
<prefix>/<db-id>/<primary-type>/<YYYY>/<MM>/<backup-id>.manifest.json
```

- Backup ids are `bk_<UTC timestamp>_<random>` and are validated against a strict
  pattern before being used in any path or key.
- Keys are constructed in exactly one place (`bk_storage_key`) and validated
  before every upload, download and delete. A key that is not under the
  configured prefix cannot be touched, which is what makes "never delete an
  object BackupKit does not recognise" enforceable rather than aspirational.
- Snapshots live under the path of the type they were created for, which keeps
  the listing meaningful; the tags in the manifest decide retention.

## Snapshot reuse

When daily, weekly and monthly fall on the same day, three cron entries fire.
The first creates the snapshot; the others:

1. list the database's manifests, newest first;
2. take the newest verified one created no earlier than the start of today
   (in the configured timezone) and confirm all of its artifacts still exist;
3. add the missing tag to that manifest and re-upload it;
4. exit 0 with `reused`.

If any artifact has disappeared, the reuse check fails and a fresh snapshot is
taken. `--force` always takes a fresh snapshot.

## Retention algorithm

1. List objects under `<prefix>/<db-id>/`, keep the `*.manifest.json` records.
2. Read each manifest (local copy first, download only if missing) and build a
   table: creation epoch, id, tags, status, keys. Sort newest first.
3. For each category with a limit > 0, rank the eligible manifests and record
   each one's rank within that category.
4. A manifest is deletable when it is out of policy for **every** tag it carries,
   is not the newest verified backup, is older than `min_age_hours`, and carries
   at least one known tag.
5. Delete artifacts first, manifest last. A crash in between leaves a manifest
   whose artifacts are gone, which `verify` and `restore` report as a failure
   rather than silently restoring a partial backup.
6. `--dry-run` prints the plan and deletes nothing.

## Locking

A per-database `mkdir` lock at `/var/lib/backupkit/locks/db-<id>.lock` containing
the pid, host and start time. `mkdir` is atomic on every supported filesystem and
needs no `flock(1)`, which macOS does not ship — one implementation everywhere.
A lock is reclaimed when the owning pid is gone or when it is older than 6 hours,
covering both a killed process and pid reuse. Locks are released on success,
failure and interruption (exit trap). Different databases never block each other.

## Logging and history

Two independent records:

- **Log** (`/var/log/backupkit/backupkit.log`): JSON lines, `{"ts","level",
  "event",...}`. Log lines carry `level` and `message`; structured events
  (`artifact_uploaded`, `backup_failed`, `retention_delete`) carry the fields of
  the thing that happened. Diagnostics go to stderr, data to stdout.
- **History** (`/var/lib/backupkit/history.jsonl`): append-only run records with
  status, duration, size, checksum, key and error. `status` is one of `success`,
  `reused` or `failed`.

Secret values are redacted before any write. Both files are `600`.

## Failure isolation

| Failure | Effect |
|---|---|
| one database fails | other databases in the same run still run; the exit code is the first failure |
| notification fails | warning only; the backup result is unchanged |
| storage unreachable | upload fails after retries; the run fails; the previous backups stay |
| state directory lost | backups continue; `list --remote` rebuilds the view; retention re-reads manifests from the bucket |
| object storage unavailable for reads | backups still run (upload only); `list` and retention fall back to the local manifest store |

## Technology choices

| Choice | Why |
|---|---|
| bash + system utilities | zero runtime to install and patch beyond the standard toolchain; nothing to keep alive |
| `jq` | one dependency that gives JSON parsing, querying and construction without `eval` |
| `age` | auditable, small, file-oriented; no key server, no PKI, easy offline key handling |
| `zstd` (fallback `gzip`) | speed and integrity checking; `gzip` for minimal systems |
| AWS CLI for S3 | maintained multipart upload, retries and endpoint handling instead of reimplementing SigV4 |
| logical dumps, not snapshots | no guest-agent or filesystem hooks needed; portable across providers and easy to restore selectively |
| `mkdir` lock | no `flock` on macOS, no daemon to coordinate |

### Documented assumptions

- Target platform is Debian/Ubuntu with bash 3.2+; macOS is supported for
  development and testing. The code avoids bash 4-only features (no associative
  arrays, no `mapfile`, no `${var,,}`).
- Cron is assumed present. systemd timers are documented as an alternative.
- "Day" boundaries for reuse and retention use the configured `timezone`, while
  timestamps are stored in UTC. A snapshot taken at 23:30 local and another at
  01:00 local count as different days.
- Compression of an empty dump is a failure, not a valid backup: a database with
  no tables still produces a dump with statements, so an empty artifact is
  always a symptom.
- The bucket is writable by only this host's token; two hosts writing the same
  `prefix` and database id would share a manifest namespace and are not
  supported (give each host its own `prefix`).
