# Configuration

Two files, deliberately separate:

| File | Default path | Mode | Contents |
|---|---|---|---|
| Configuration | `/etc/backupkit/config.json` | `600` | timezone, storage, schedules, retention, database list |
| Secrets | `/etc/backupkit/secrets.json` | `600` (enforced) | passwords, storage keys, bot tokens |
| Age key | `/etc/backupkit/age.key` | `600` (enforced) | the private decryption key |

Credentials must live in `secrets.json`. A `password` field inside
`config.json` is rejected by `backupkit config validate`, and the file itself is
safe to paste into a ticket because `backupkit config show` redacts it.

Everything is validated before a run: `backupkit config validate` prints **all**
problems it finds, not just the first.

---

## Full reference

```jsonc
{
  "timezone": "Asia/Jakarta",          // any TZ identifier; used for dates and logs

  "storage": {
    "provider": "cloudflare-r2",       // cloudflare-r2 | s3 | local
    "bucket": "company-backups",
    "endpoint": "https://ACCOUNT_ID.r2.cloudflarestorage.com",
    "region": "auto",                  // R2: "auto"; AWS: e.g. "eu-central-1"
    "prefix": "vps-backups",           // key prefix; "" stores at the bucket root
    "timeout_seconds": 300,            // per request read timeout
    "retry": { "max_attempts": 3, "delay_seconds": 5 },

    "local": { "path": "/var/lib/backupkit-store" }   // only for provider: local
  },

  "encryption": {
    "enabled": true,                   // do not disable outside a lab
    "allow_plaintext": false,          // must be true if enabled is false
    "recipient": "age1...",            // age public key (from 'backupkit init')
    "recipients_file": "",             // optional age recipients file (-R)
    "recipients": [],                  // optional additional public keys
    "identity_file": "/etc/backupkit/age.key"
  },

  "compression": { "algorithm": "zstd", "level": 10 },   // zstd | gzip

  "retention": {
    "daily": 7, "weekly": 4, "monthly": 12,   // global defaults
    "min_age_hours": 0                        // never delete anything younger than this
  },

  "schedule": { "weekly_dow": 0, "monthly_dom": 1 },   // 0 = Sunday

  "notifications": {
    "telegram": {
      "enabled": false,
      "timeout_seconds": 10,
      "api_base": "https://api.telegram.org"
    }
  },

  "databases": [ /* see below */ ]
}
```

Every path in this document is a default; the environment can override the
config location (`BACKUPKIT_CONFIG`, `BACKUPKIT_SECRETS`, `BACKUPKIT_IDENTITY`,
`BACKUPKIT_ETC`, `BACKUPKIT_STATE_DIR`, `BACKUPKIT_LOG_DIR`, `BACKUPKIT_LOG_FILE`).

---

## Storage providers

### Cloudflare R2

```json
"storage": {
  "provider": "cloudflare-r2",
  "bucket": "company-backups",
  "endpoint": "https://<ACCOUNT_ID>.r2.cloudflarestorage.com",
  "region": "auto",
  "prefix": "vps-backups"
}
```

The endpoint is mandatory and must be an `*.r2.cloudflarestorage.com` URL:
R2 is account-scoped, so assuming an AWS-shaped endpoint would silently fail.
Credentials come from `secrets.json`:

```json
"storage": { "access_key": "...", "secret_key": "..." }
```

Create a token scoped to a single bucket with **Object Read & Write** only, and
do not reuse the global R2 API key of the account.

### Generic S3-compatible storage

```json
"storage": {
  "provider": "s3",
  "bucket": "my-bucket",
  "endpoint": "https://s3.eu-central-1.amazonaws.com",
  "region": "eu-central-1",
  "prefix": "backups"
}
```

Works with AWS S3, MinIO, Wasabi, Backblaze B2 (S3 API), Ceph RGW, ...
`http://` endpoints are only accepted for `localhost`/`127.0.0.1`, so credentials
cannot be sent in clear text to a remote host by accident. The endpoint may be
omitted for plain AWS S3 (the SDK default is used). Leave the credentials out of
`secrets.json` to use an instance profile, SSO or the ambient environment.

Provider-specific behaviour differs: `head-bucket` is used as the probe and a
listing is attempted as a fallback, because some providers reject `HeadBucket`.

### Local directory

```json
"storage": { "provider": "local", "local": { "path": "/mnt/backup-disk" } }
```

Useful for testing, air-gapped hosts and offline mirrors. Keys map to paths
below the root; Microsoft-style traversal (`..`), absolute keys and keys outside
the prefix are refused before any filesystem call.

---

## Databases

```jsonc
"databases": [
  {
    "id": "app-mysql",                // required, unique, [A-Za-z0-9._-], max 64
    "type": "mysql",                  // mysql | mariadb | postgres | postgresql
    "database": "appdb",              // database name on the server
    "host": "127.0.0.1",
    "port": 3306,
    "user": "backup",                 // may live here or in secrets.json
    "enabled": true,
    "schedule":  { "daily": true, "weekly": true, "monthly": true },
    "retention": { "daily": 7, "weekly": 4, "monthly": 12 },

    "dump_options": [],               // extra argv passed to mysqldump/pg_dump

    // MySQL only
    "tablespaces": false,             // false adds --no-tablespaces (needs no PROCESS)
    "gtid_purged_off": false,         // true adds --set-gtid-purged=OFF (MySQL, not MariaDB)
    "lock_tables": false,             // true adds --lock-tables; needed for MyISAM
    "verify_footer": true,            // check the "-- Dump completed" footer

    // PostgreSQL only
    "globals": true,                  // also dump roles via pg_dumpall --globals-only
    "pg_dump_compress": 0,            // internal archive compression (pipeline compresses anyway)
    "no_owner": false,                // true adds --no-owner (easier cross-owner restores)
    "no_acl": false,
    "restore_single_transaction": true,
    "restore_exit_on_error": true,
    "globals_database": "postgres",   // database used to replay globals
    "verify_header": true,            // check the PGDMP magic header
    "port": 5432
  }
]
```

### MySQL / MariaDB notes

- `--single-transaction --quick --routines --triggers --events` are always used.
  `--single-transaction` gives a consistent snapshot for InnoDB; MyISAM is not
  covered by it, so set `"lock_tables": true` if the database still contains
  MyISAM tables (this takes a read lock for the duration of the dump).
- `--no-tablespaces` is used so the backup account does not need the `PROCESS`
  privilege. Set `"tablespaces": true` only if you need tablespace definitions.
- Recommended account:

  ```sql
  CREATE USER 'backup'@'127.0.0.1' IDENTIFIED BY '...';
  GRANT SELECT, SHOW VIEW, TRIGGER, LOCK TABLES, EVENT, RELOAD, PROCESS, REPLICATION CLIENT
    ON *.* TO 'backup'@'127.0.0.1';
  ```

  (`RELOAD`/`PROCESS`/`REPLICATION CLIENT` are only needed for the
  corresponding options; see docs/security.md for a minimal set.)
- `mysqldump` and the server should be the same major version where possible;
  `backupkit doctor` warns when they differ.
- The dump is checked for the trailing `-- Dump completed` footer, so a
  truncated dump is rejected even when `mysqldump` exits 0.

### PostgreSQL notes

- `pg_dump --format=custom` is used. Internal compression is disabled by default
  (`pg_dump_compress: 0`) because the pipeline compresses the artifact itself.
- **`pg_dump` must be the same version as the server, or newer.** An older
  client refuses to read a newer server; `backupkit doctor` fails the check
  rather than letting the backup break at 02:00.
- Cluster roles and other global objects are not part of a database dump. With
  `"globals": true` BackupKit runs `pg_dumpall --globals-only` in the same run
  and stores it as a second artifact of the same backup, restorable separately
  with `backupkit restore --id ID --globals`.
- The custom-format magic header (`PGDMP`) is checked before upload.

---

## Secrets file

```json
{
  "storage": { "access_key": "...", "secret_key": "..." },
  "notifications": { "telegram": { "bot_token": "...", "chat_id": "..." } },
  "databases": {
    "app-mysql":  { "user": "backup", "password": "...", "host": "127.0.0.1", "port": 3306 },
    "app-postgres": { "user": "backup", "password": "..." }
  },
  "databases_default": { "user": "backup", "password": "", "host": "127.0.0.1" }
}
```

Per-database values win; `databases_default` fills the gaps. Values that are not
secrets (host, port, user) may live in either file — `config.json` is checked
first for those. Passwords are never passed on a command line: MySQL receives a
temporary `--defaults-extra-file`, PostgreSQL a temporary `PGPASSFILE`, both
`600` and removed when the process exits.

---

## Schedule and retention semantics

### When backups run

The scheduler installs three cron entries (times come from the default policy):

| Cron | Command | Meaning |
|---|---|---|
| `0 2 * * *` | `backupkit backup --all --type daily` | every day at 02:00 |
| `0 3 * * 0` | `backupkit backup --all --type weekly` | Sunday at 03:00 (`schedule.weekly_dow`) |
| `0 4 1 * *` | `backupkit backup --all --type monthly` | the 1st at 04:00 (`schedule.monthly_dom`) |
| `30 6 * * *` | `backupkit backup --all --type auto` | catch-up for missed windows |

`--type auto` picks the categories that are due today from each database's
`schedule` block. An explicit `--type` still refuses to run when that type is not
due today unless `--force` is given, so a manual run cannot fabricate an extra
weekly snapshot.

When several categories fall on the same day (Sunday the 1st), the first run
creates the snapshot and the later runs only add their tag to the existing
manifest. One dump, several retention categories — the run prints
`reusing snapshot ... and tagging [weekly]`, and the snapshot is deleted only
when it is out of policy for *all* of its tags.

A `mkdir`-based lock per database prevents overlapping runs (cron firing twice,
a slow dump overlapping the next slot). Stale locks (dead pid, or older than 6
hours) are reclaimed automatically.

### Retention

Retention is evaluated per database and per category:

```
daily: 7     keep the 7 newest verified backups tagged "daily"
weekly: 4    keep the 4 newest verified backups tagged "weekly"
monthly: 12  keep the 12 newest verified backups tagged "monthly"
```

Deletion rules, in order:

1. Only keys under the configured prefix are considered.
2. Only manifests with `status: "verified"` are eligible.
3. Only manifests that BackupKit wrote (recognised id format) are read.
4. A snapshot is deleted only when it exceeds the limit of **every** category it
   carries.
5. The newest verified backup of the database is never deleted.
6. `retention.<type>: 0` disables deletion for that category (keep forever).
7. `retention.min_age_hours` protects young backups (default `0`).
8. Cleanup runs after a backup only once that backup has been uploaded and
   verified. `cleanup --dry-run` shows the plan without touching anything.

`backupkit status` shows current usage, for example `daily=3/7 weekly=1/4
monthly=0/12`.

---

## Validation rules enforced by `backupkit config validate`

- `timezone` must be a valid TZ identifier.
- `storage.provider` must be `cloudflare-r2`, `s3` or `local`; each provider's
  required fields are checked (`endpoint` + `bucket` for R2, `bucket` for S3,
  `local.path` for local).
- `prefix` must be relative, with no spaces and no `..`.
- `encryption.enabled: false` requires `encryption.allow_plaintext: true`.
- `encryption.recipient` must start with `age1`.
- `compression.algorithm` must be `zstd` or `gzip`; `level` must be an integer.
- Telegram notifications require both `bot_token` and `chat_id` in secrets.
- `databases` must be a non-empty array; every `id` must match
  `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`; `type` and `database` are required; every
  `schedule` value must be boolean; every `retention` value must be a
  non-negative integer.
- `globals` is only allowed for PostgreSQL.
- A `password` in `config.json` is an error.
- Secrets and key files must be mode `600` (or `400`). `BK_ALLOW_INSECURE_PERMS=1`
  downgrades this to a warning and exists for local development only.
