# Security

Security decisions here are deliberate and mostly enforced in code, not in
documentation. This file states what is protected, what is assumed, and what is
explicitly out of scope.

## Threat model

| Threat | Mitigation |
|---|---|
| Object storage is read by someone who should not see the data | artifacts are encrypted with age before upload; brute-forcing the bucket yields ciphertext |
| Bucket credentials leak (CI log, shell history, backup of a backup) | least-privilege, bucket-scoped token; credentials never appear in logs or on command lines |
| An attacker with the ciphertext steals the key from the bucket | the private key never leaves the VPS and is never uploaded |
| Credentials appear in logs or process listings | passwords go into `600` option files (`--defaults-extra-file`, `PGPASSFILE`), never argv; secret values are redacted from every log line and console message |
| A bug deletes the wrong object in the bucket | deletion is limited to keys under the configured prefix that BackupKit itself recorded in a verified manifest |
| A failed backup destroys the previous good one | retention runs only after the new artifact is uploaded and verified; temp files are removed only when the run completes |
| A rogue config file leaks or executes code | configuration is JSON parsed with `jq`; nothing is `eval`ed or sourced; every value is validated |
| Someone injects a flag through config into a command line | array-based argv construction, identifiers restricted to `[A-Za-z0-9._-]`, empty arguments are dropped |
| Concurrent cron runs corrupt each other | per-database `mkdir` lock with stale detection |

## Assumptions (stated, not hidden)

- **The VPS itself is trusted.** Root on the VPS can read the age key, the
  secrets file, and the plaintext dump while it exists. BackupKit defends the
  data at rest in object storage and in transit, not against a compromised host.
- **The restore host is trusted.** Restoring requires the private key and
  superuser credentials.
- **The object storage provider is honest-but-curious at worst.** We rely on TLS
  and client-side encryption; server-side encryption features are not used.
- **Losing the private key means losing the data.** That is the point of
  client-side encryption. Keep an offline copy.

## Credentials

| Credential | Where it lives | Notes |
|---|---|---|
| Database password | `secrets.json` (600) | passed via `--defaults-extra-file` / `PGPASSFILE`, both 600 and deleted on exit |
| Storage access key / secret | `secrets.json` (600) | exported to the AWS CLI's environment for the child process only |
| age private key | `/etc/backupkit/age.key` (600) | never uploaded, never logged, needed for every restore |
| Telegram bot token | `secrets.json` (600) | optional; notifications are best-effort |

Enforced rules:

- A `password` field in `config.json` fails validation.
- `secrets.json` and the key file must be mode `600` or `400`, checked at load
  time and by `doctor`. `BK_ALLOW_INSECURE_PERMS=1` downgrades this to a warning
  and is for local development only.
- Logs are redacted: values under keys matching `pass|secret|token|key|credential`
  in `secrets.json` are replaced with `[REDACTED]` before anything is printed or
  written. Values shorter than 4 characters are skipped so that a one-character
  key cannot shred unrelated messages.
- The log file is created with the process umask (`077`), the state directory is
  `700`, and manifests are written atomically at `600`.

### Recommended MySQL backup account

```sql
CREATE USER 'backup'@'127.0.0.1' IDENTIFIED BY '<strong-password>';
GRANT SELECT, SHOW VIEW, TRIGGER, LOCK TABLES, EVENT
  ON *.* TO 'backup'@'127.0.0.1';
-- add only if you enable the corresponding option:
--   PROCESS          for --tablespaces
--   RELOAD           for --lock-tables on MyISAM-heavy servers
--   REPLICATION CLIENT for consistent binlog position reporting
```

`SELECT, SHOW VIEW, TRIGGER, LOCK TABLES, EVENT` covers the default
`mysqldump --single-transaction --quick --routines --triggers --events
--no-tablespaces`. Never use `root` when a scoped account will do.

### Recommended PostgreSQL backup account

```sql
CREATE ROLE backup LOGIN PASSWORD '<strong-password>';
GRANT CONNECT ON DATABASE appdb TO backup;
GRANT USAGE ON SCHEMA public TO backup;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO backup;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO backup;
```

`pg_dump` also needs read access to sequences and to `pg_catalog` (granted by
default). A `pg_dumpall --globals-only` dump requires superuser, so if you enable
`globals` you must accept a more privileged account for that job — or skip
globals and manage roles with your configuration management system.

### Recommended R2 / S3 token

- Scope the token to the single bucket, with **Object Read & Write** only.
- No bucket administration, no account-level permissions, no other buckets.
- Rotate on a schedule; store the token only in `secrets.json`.

## Key management

```bash
age-keygen -o /etc/backupkit/age.key    # backupkit init does this for you
age-keygen -y /etc/backupkit/age.key    # derive the public key
```

- Keep two offline copies of the private key (password manager + safe).
- `doctor` refuses to pass when the identity file does not match
  `encryption.recipient`, which catches the classic "rotated the key, forgot the
  config" failure before it silently produces unreadable backups.
- To add a second recipient (for example an escrow key held by someone else) add
  it to `encryption.recipients`; age encrypts to all recipients at once, so
  either key can decrypt.

## Store a copy of the key with the data?

No. That would collapse the whole point: anyone with bucket access and the key
would have the data. Keep keys offline, keep ciphertext in the bucket.

## Transport and storage details

- Uploads use the AWS CLI over HTTPS. `endpoint` for the `s3` provider must be
  `https://`, unless it points at `localhost`/`127.0.0.1`.
- No credential material is written to object storage; manifests contain object
  keys, sizes and checksums only.
- The `local` storage provider writes `600` files, and refuses keys with `..`,
  absolute paths, spaces or backslashes, so a manifest cannot be used to write
  outside the storage root.

## What is not protected

- **A compromised VPS.** Root can read the plaintext dump while it exists, read
  the age key, and read every credential.
- **Ransomware that deletes the bucket.** BackupKit has no immutable/Object-Lock
  support yet (see [roadmap.md](roadmap.md)); enable Object Lock or a
  versioning-based lifecycle rule on the bucket side if that is in your threat
  model.
- **Traffic analysis.** Object names reveal database ids, types and dates. Use a
  neutral `prefix`, and database ids that do not leak business information, if
  that matters. Object sizes reveal rough data volumes.
- **Restore-time mistakes.** A correct confirmation prompt is not a substitute
  for a rehearsal and for keeping production targets out of the drill command.

## Reporting a vulnerability

Please do not open a public issue with exploit details. Open a minimal issue
asking for a private channel, or contact the maintainer directly. Include the
version (`backupkit version`), the platform, and a reproduction that does not
involve real credentials or production data.

## Security review checklist for contributors

- No credential, hostname, IP or internal project name in code, examples, docs
  or fixtures.
- No new `eval`, no `source` of user-supplied files, no string-interpolated
  command lines with untrusted values.
- New external input is validated against an allow-list pattern.
- New log output goes through `bk_log`, so it is redacted.
- New deletion paths check `bk_storage_key_allowed` first.
- New files under the state directory are created `600`/`700` and registered for
  cleanup.
