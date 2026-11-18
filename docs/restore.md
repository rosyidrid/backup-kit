# Restore

A backup you have never restored is a hypothesis. This document covers the
supported restore paths, the limits of automated validation, and how to rehearse
a restore so that the real one is boring.

## What is stored

Each backup consists of one or more **artifacts** plus a **manifest**:

```
<prefix>/<db-id>/<type>/<YYYY>/<MM>/<backup-id>.primary.zst.age     # the dump
<prefix>/<db-id>/<type>/<YYYY>/<MM>/<backup-id>.globals.zst.age     # postgres roles, optional
<prefix>/<db-id>/<type>/<YYYY>/<MM>/<backup-id>.manifest.json       # record of the above
```

The manifest records the object key, size and SHA-256 of every artifact, the
database it came from, when it was taken, and which retention categories it
satisfies. Restore always follows the manifest, never a filename guess.

## The limits of validation

`backupkit verify --id ID --deep` proves that:

- the object exists in storage;
- its size matches the manifest;
- its SHA-256 matches the checksum computed before the upload;
- it decrypts with the local key;
- it decompresses into a non-empty dump;
- for MySQL, the dump carries the `-- Dump completed` footer; for PostgreSQL,
  the archive carries the `PGDMP` header.

It does **not** prove that the dump can be restored. A dump can be complete and
still fail to replay because of a server version change, a missing role, a
collation the target does not have, disk space, or a corrupted table that
`mysqldump` read happily. Only restoring into a scratch database proves that.

Therefore: run a **restore rehearsal** on a schedule (monthly is a reasonable
starting point) and treat a backup as unverified until it has been through one.

## Inspecting before restoring

```bash
backupkit list --json | jq -r '.[] | [.id, .types, .created_at, .size] | @tsv'
backupkit verify --id bk_20260301T020001Z_9f2c14 --deep
backupkit restore --id bk_20260301T020001Z_9f2c14 --target restore_drill --dry-run
```

`--dry-run` prints the plan (manifest, target, role) and downloads nothing.

## MySQL / MariaDB

```bash
# 1. prepare an empty target database (never restore over the live one)
mysql -h 127.0.0.1 -u root -p -e \
  "CREATE DATABASE IF NOT EXISTS restore_drill CHARACTER SET utf8mb4;"

# 2. restore
backupkit restore --id bk_20260301T020001Z_9f2c14 --target restore_drill

# 3. it prints the plan and asks for confirmation
#    This will OVERWRITE database 'restore_drill' on vps-01 with backup bk_...
#    Type exactly "yes" to continue:
```

What happens underneath: the artifact is downloaded, its SHA-256 is checked
against the manifest, it is decrypted and decompressed, and the plaintext is
piped into `mysql <target>` using a temporary `--defaults-extra-file`. Databases
must already exist: BackupKit does not run `CREATE DATABASE`.

Score the result:

```bash
mysql -h 127.0.0.1 -u root -p restore_drill -e \
  "SHOW TABLES; SELECT COUNT(*) FROM your_main_table;"
```

For a scripted drill, use `--yes` and put the comparison in your own monitoring:

```bash
backupkit restore --id "$ID" --target restore_drill --yes
```

## PostgreSQL

```bash
# 1. prepare an empty target database (owner must be able to create objects)
psql -h 127.0.0.1 -U postgres -c "CREATE DATABASE restore_drill OWNER app;"

# 2. restore the database itself
backupkit restore --id bk_20260301T020001Z_9f2c14 --target restore_drill

# 3. restore cluster roles and global objects, separately
backupkit restore --id bk_20260301T020001Z_9f2c14 --globals
```

The database restore runs `pg_restore --clean --if-exists --single-transaction
--exit-on-error` (all configurable per database, see
[configuration.md](configuration.md#postgresql-notes)), so it either applies
fully or rolls back.

Global objects (roles, tablespaces) are only present when the database has
`"globals": true` in its configuration. Replaying globals requires superuser
rights; on a fresh cluster restore the globals *before* the database, because
the dump may reference roles that do not exist yet.

## Using the artifacts without BackupKit

Backups are deliberately readable with standard tools. Given an age key and the
`aws` CLI:

```bash
aws s3 cp --endpoint-url "$R2_ENDPOINT" \
  "s3://company-backups/vps-backups/app-mysql/daily/2026/03/bk_20260301T020001Z_9f2c14.zst.age" - \
  | age -d -i /etc/backupkit/age.key \
  | zstd -d \
  | mysql -h 127.0.0.1 -u root -p restore_drill
```

Nothing about the format is proprietary: `zstd` (or `gzip`) plus `age`. This is
the escape hatch if BackupKit itself is unavailable.

## Restore rehearsal checklist

```bash
# 1. pick the newest backup of each database
backupkit list --json | jq -r '.[0].id'

# 2. verify it end to end
backupkit verify --id "$ID" --deep

# 3. restore into a scratch database and compare row counts
backupkit restore --id "$ID" --target restore_drill --yes
mysql -e "SELECT COUNT(*) FROM t" restore_drill
mysql -e "SELECT COUNT(*) FROM t" production     # compare

# 4. drop the scratch database
mysql -e "DROP DATABASE restore_drill"
```

Record the date of the last successful rehearsal somewhere outside the VPS. An
untested backup is an assumption, and assumptions fail exactly when you need
them.

## Disaster recovery on a rebuilt host

1. Install BackupKit (`scripts/install.sh`).
2. Restore the age key from its offline copy to `/etc/backupkit/age.key`
   (mode 600). **Without this key, nothing in the bucket can be decrypted.**
3. Recreate `config.json` and `secrets.json` (or restore them from your
   configuration management system).
4. `backupkit config validate && backupkit doctor`
5. Find the backup to restore:
   ```bash
   backupkit list --remote | head -20
   ```
   `--remote` reads the bucket instead of the (now empty) local manifest store.
6. Restore the data:
   ```bash
   backupkit restore --id <id> --target <database>
   # and, if the cluster itself is new:
   backupkit restore --id <id> --globals
   ```
7. Re-run `backupkit backup --all` and confirm the new backups land in the same
   prefix.

## Safety rules encoded in the tool

- A restore never starts without an explicit confirmation (`yes`, or `--yes`).
  Without a TTY and without `--yes` it exits with code 12.
- A primary restore requires `--target`; there is no implicit "restore into the
  source database" shortcut.
- A backup whose manifest says `status: failed` cannot be restored (exit 11).
- A checksum mismatch stops the restore before any client runs (exit 9).
- Backups are never deleted by a restore, and a failed restore does not touch
  the stored objects.
