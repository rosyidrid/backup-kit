# Usage

Every command is a plain process: cron, a systemd timer or a human can run it.
Diagnostics go to stderr, data (tables, JSON, dry-run plans) to stdout, so
`backupkit list --json | jq` is safe.

## Setup

```
backupkit init [--force] [--no-key]
backupkit config validate
backupkit config show            # credentials redacted
backupkit config path
backupkit doctor [--no-connect]
backupkit install-scheduler [--print] [--bin PATH] [--user USER]
backupkit uninstall-scheduler
```

`init` writes `config.json`, `secrets.json` and an age key, and refuses to
overwrite an existing file unless `--force` is given (secrets and keys are never
overwritten).

## Backup

```
backupkit backup [--all] [--database ID] [--type daily|weekly|monthly|auto]
                 [--force] [--dry-run] [--no-cleanup]
```

| Option | Behaviour |
|---|---|
| `--database ID` | only this database; repeatable, or comma separated |
| `--all` | every enabled database (the default) |
| `--type auto` | categories that are due today, from each database's schedule (default) |
| `--type daily` | that category; refused when it is not due today unless `--force` |
| `--force` | run even when not due, and take a fresh snapshot instead of reusing today's |
| `--dry-run` | report the plan; no dump, no upload, no cleanup |
| `--no-cleanup` | skip retention for this run |

Examples:

```bash
backupkit backup --all                       # what cron runs
backupkit backup --database app-mysql        # one database
backupkit backup --database app-mysql,app-pg --type daily
backupkit backup --all --dry-run
backupkit backup --database app-mysql --type monthly --force   # manual extra snapshot
```

The output shows each stage and ends with `backup ok: <id> (size, duration)`:

```
2026-03-01T02:00:01Z [info] backup start: db=app-mysql type=mysql types=[daily] id=bk_20260301T020001Z_9f2c14
2026-03-01T02:00:01Z [info] dump app-mysql (role=primary)
2026-03-01T02:00:12Z [info] upload vps-backups/app-mysql/daily/2026/03/bk_20260301T020001Z_9f2c14.zst.age (412.31 MiB)
2026-03-01T02:00:41Z [info] backup ok: bk_20260301T020001Z_9f2c14 (412.31 MiB, 40s)
2026-03-01T02:00:42Z [info] retention: removed 1 expired backup(s) for app-mysql
```

On Sunday the 1st, the later runs reuse the same snapshot:

```
2026-03-01T03:00:00Z [info] reusing snapshot bk_20260301T020001Z_9f2c14 and tagging [weekly]
```

## Inspect

```
backupkit list [--database ID] [--type TYPE] [--json] [--remote]
backupkit status [--json]
backupkit verify --id ID [--deep]
```

`list` reads the local manifest store, so it works when storage is unreachable;
`--remote` reconciles against the bucket instead (useful on a rebuilt host).

```
$ backupkit list
BACKUP ID                    TYPES              STATUS    CREATED (UTC)         SIZE       DURATION
bk_20260301T020001Z_9f2c14   daily,weekly,monthly verified 2026-03-01T02:00:01Z  412.31 MiB 40s
bk_20260228T020001Z_1a77bc   daily              verified  2026-02-28T02:00:01Z  409.88 MiB 39s

$ backupkit status
BackupKit 0.1.0 on vps-01
  timezone        : Asia/Jakarta
  storage         : cloudflare-r2 (company-backups)
  last run        : 2026-03-01T02:00:42Z [success] for app-mysql

DATABASE             TYPE       RETENTION (kept/limit)     LAST SUCCESS (UTC)     LOCK
app-mysql            mysql      daily=7/7 weekly=4/4 ...   2026-03-01T02:00:42Z   no
```

`verify --deep` downloads each artifact, checks the SHA-256 and the remote size,
then decrypts and fully decompresses it in a temporary directory. It is the
strongest check available without restoring — see [restore.md](restore.md).

## Retention

```
backupkit cleanup [--dry-run] [--database ID]
```

```bash
backupkit cleanup --dry-run
# 2026-03-01T09:14:02Z [info] retention check for app-mysql (daily=9/7 weekly=5/4 monthly=1/12)
# 2026-03-01T09:14:02Z [info] [dry-run] would delete bk_20260102T020001Z_ab12cd ...
# 2026-03-01T09:14:03Z [info] dry-run: 3 backup(s) would be deleted
backupkit cleanup
```

Cleanup normally runs automatically at the end of a successful backup. Run it
manually after changing retention or `prefix`. The rules are in
[configuration.md](configuration.md#retention).

## Restore

```
backupkit restore --id ID --target DATABASE [--role primary|globals] [--dry-run] [--yes]
backupkit restore --id ID --globals [--yes]
```

Destructive restores require either an interactive `yes` or `--yes`. Full
procedure, rehearsals and disaster recovery: [restore.md](restore.md).

## Cron

Installed by `backupkit install-scheduler` (`/etc/cron.d/backupkit`):

```
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CRON_TZ=Asia/Jakarta

0 2 * * *  root /usr/local/bin/backupkit backup --all --type daily   >> /var/log/backupkit/cron.log 2>&1
0 3 * * 0  root /usr/local/bin/backupkit backup --all --type weekly  >> /var/log/backupkit/cron.log 2>&1
0 4 1 * *  root /usr/local/bin/backupkit backup --all --type monthly >> /var/log/backupkit/cron.log 2>&1
30 6 * * * root /usr/local/bin/backupkit backup --all --type auto    >> /var/log/backupkit/cron.log 2>&1
```

Adapt the times to your maintenance window; keep the catch-up entry (or replace
it with `--type auto`) if you want missed windows to be replayed. Running the
same job twice is safe: the lock serialises runs and the reuse logic prevents a
second snapshot per day.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | success |
| 1 | generic error (usage, unexpected) |
| 2 | configuration error |
| 3 | missing dependency or unusable credential |
| 4 | another backup holds the lock (skipped, not a failure of the backup itself) |
| 5 | dump failed or failed validation |
| 6 | compression failed |
| 7 | encryption/decryption failed |
| 8 | upload failed, or the uploaded object failed verification |
| 9 | verification failed (checksum, size, download) |
| 10 | retention failed |
| 11 | restore failed |
| 12 | cancelled: confirmation was not given |
| 13 | not found: unknown backup id, missing manifest |

Cron treats any non-zero status as a failure and mails it to the cron owner;
combine with the optional Telegram notifications for immediate visibility.

## Routine operations

```bash
# daily: nothing to do, cron handles it. Weekly sanity check:
backupkit status
backupkit list | head -5

# monthly: prove a backup is actually restorable (see restore.md)
backupkit restore --id <latest> --target restore_drill --yes --dry-run

# after adding a database, or changing retention:
backupkit config validate && backupkit doctor
backupkit backup --database <new-id> --force
backupkit cleanup --dry-run
```

## Logs

- `/var/log/backupkit/backupkit.log` — JSON lines: `{"ts","level","event",...}`.
  Log lines carry `level`/`message`; pipeline events (`artifact_uploaded`,
  `backup_failed`, `retention_delete`, ...) carry structured fields.
- `/var/log/backupkit/cron.log` — stdout/stderr of the cron entries, i.e. the
  human-readable run log.
- `/var/lib/backupkit/history.jsonl` — append-only execution history
  (status, duration, size, checksum, key, error).

```bash
# last 10 failures
jq -c 'select(.status=="failed")' /var/lib/backupkit/history.jsonl | tail -10
# total bytes backed up this week
jq -s '[.[] | select(.status=="success") | .size_bytes] | add' /var/lib/backupkit/history.jsonl
```

Credentials never appear in these files: values from `secrets.json` are redacted
before anything is printed or written.
