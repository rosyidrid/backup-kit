# Troubleshooting

Start here:

```bash
backupkit doctor                 # environment, credentials, storage, locks
backupkit config validate        # every configuration problem at once
tail -50 /var/log/backupkit/cron.log
jq -c 'select(.status=="failed")' /var/lib/backupkit/history.jsonl | tail -5
```

`doctor` runs a live connection test (`SELECT 1`) against every enabled database
and compares client/server versions, so most credential and version problems are
caught before a scheduled run. Add `--no-connect` when the database is
intentionally unreachable from where you are testing.

## Exit code map

| Code | Meaning | First thing to check |
|---|---|---|
| 2 | configuration invalid | `backupkit config validate` output |
| 3 | missing command or unusable credential | `backupkit doctor`, then install the package |
| 4 | lock held (another run in progress) | `/var/lib/backupkit/locks/`, `backupkit status` |
| 5 | dump failed or failed validation | `jq -r .error history.jsonl \| tail -1` |
| 6 | compression failed | disk space, `zstd --version` |
| 7 | encryption/decryption failed | `age.key` present, mode 600, matches `recipient` |
| 8 | upload failed or failed verification | bucket, endpoint, credentials, network |
| 9 | verification failed | object changed or truncated in storage |
| 10 | retention failed | storage write/delete permissions |
| 11 | restore failed | client error output, target database exists |
| 12 | confirmation not given | re-run with `--yes` if you are sure |
| 13 | unknown backup id / missing manifest | `backupkit list --remote` |

## Common problems

### `config file not found: /etc/backupkit/config.json`

`backupkit init` was never run, or you are looking at a different directory.
Check with `backupkit config path` and `echo $BACKUPKIT_ETC`.

### `secrets file (.../secrets.json) must be readable by the owner only, found permissions 644`

```bash
sudo chmod 600 /etc/backupkit/secrets.json /etc/backupkit/age.key
```

This is enforced on purpose. `BK_ALLOW_INSECURE_PERMS=1` downgrades it to a
warning and exists only for local development.

### `missing required command: mysqldump` / `pg_dump` / `zstd` / `age` / `aws`

The pipeline refuses to start rather than producing a partial backup. Install the
package for the feature your config enables:

```bash
sudo apt-get install -y jq zstd gzip age awscli default-mysql-client postgresql-client
```

A missing dependency is recorded in history with `"stage":"dependency"`.

### `pg_dump: error: server version: 16.x; pg_dump version: 14.x`

`pg_dump` must be the same version as the server or newer. Install the client
from the PGDG repository for the server's major version, or point the config at a
newer client binary. `doctor` fails this check before the backup runs.

### `mysqldump: Got error: 1045: Access denied for user`

`doctor` prints the same error with more context. Verify the user, host
(`127.0.0.1` vs `localhost` vs `%`), and that the password in `secrets.json` is
current. Remember MySQL treats `localhost` (socket) and `127.0.0.1` (TCP) as
different accounts.

### `mysqldump: Error: 'Access denied; you need (at least one of) the PROCESS privilege(s)'`

Enable `"tablespaces": true` in that database's config and grant `PROCESS`, or
leave the default (`--no-tablespaces`).

### Backup fails with `mysqldump output ... has no 'Dump completed' footer`

`mysqldump` exited 0 but the file is truncated — usually the server died, the
dump hit a timeout, or disk space ran out mid-write. Check free space on
`/var/lib/backupkit`, then re-run. Set `"verify_footer": false` only if you know
your server does not emit the footer (it always does by default).

### `upload verification failed ... (size mismatch: local=… remote=…)`

The object in storage is not the size that was uploaded: a proxy truncated the
body, or a lifecycle rule interfered. Check the provider's limits (R2 multipart
minimum part size, request size limits) and the network path. The backup is
marked failed and the previous backups are untouched.

### `upload failed: ... (attempt 3/3)`

The retry loop already tried. Check:

```bash
aws s3api head-bucket --bucket <bucket> --endpoint-url <endpoint>
```

Common causes: wrong `endpoint` for the provider, wrong region, token without
`Object Write`, bucket deleted, clock skew with SigV4, proxy blocking outbound
HTTPS.

### `cloudflare-r2 endpoint must be https://<account_id>.r2.cloudflarestorage.com`

R2 endpoints are account-scoped. Copy the endpoint from the R2 dashboard; it
contains your account id. Generic S3 providers need `"provider": "s3"`.

### `another backup is already running for <id>; skipping` (exit 4)

Expected when cron fires while a slow dump is still running. `backupkit status`
shows the lock. If no run is actually in progress (the box was rebooted mid-run),
the lock is reclaimed automatically: dead pid, or older than 6 hours. To clear it
now:

```bash
sudo rm -rf /var/lib/backupkit/locks/db-<id>.lock
```

### `skip <id>: no backup type is due now`

Working as intended: `--type weekly` on a Wednesday does nothing unless you pass
`--force`. The catch-up cron entry uses `--type auto`, which picks whatever is
due.

### Backup ran but `list` is empty

`list` reads the local manifest store. On a rebuilt host use
`backupkit list --remote`, which reads the bucket. Check that
`/var/lib/backupkit` is the same path the run used (`BACKUPKIT_STATE_DIR`).

### Retention does not delete anything

By design, when any of these is true: the manifests say `verified` but carry no
tag; `retention.<type>` is `0`; the backup is the newest verified one;
`min_age_hours` has not elapsed; the object is not under the configured
`prefix`. Run `backupkit cleanup --dry-run` and read the plan, then check
`backupkit status` for `kept/limit` per category.

### Restore refuses to run

- Exit 12: no TTY and no `--yes`. Confirmation is required for every destructive
  restore.
- `--target <database> is required for a primary restore`: add the target.
- `backup <id> is marked as failed`: pick another id from `backupkit list`.
- `checksum validation failed`: the artifact changed in storage; try an older
  backup and investigate the bucket.

### `age: error: no identity matched any of the recipients`

The key at `encryption.identity_file` is not the private counterpart of
`encryption.recipient`. `backupkit doctor` reports this as
`identity does not match .encryption.recipient`. Recover the matching key from
your offline copy; a mismatched key cannot decrypt existing backups.

### Cron runs but nothing happens

```bash
grep CRON /var/log/syslog | tail -20      # did cron fire?
cat /var/log/backupkit/cron.log           # what the last runs printed
```

Check that the cron file executes a binary that exists (`install-scheduler
--print` shows the exact command line) and that `CRON_TZ` is what you expect.
Cron's `PATH` is set explicitly in the generated file; a user-level install needs
the absolute path to the launcher.

### Notifications never arrive

Notifications are best-effort and never fail a backup, so failures are only
logged:

```bash
jq -c 'select(.message | test("telegram"))' /var/log/backupkit/backupkit.log | tail -5
```

Check the token and chat id in `secrets.json`, and that the host can reach
`https://api.telegram.org` (firewall, proxy, DNS).

### Disk fills up during a backup

Dumps are written under `/var/lib/backupkit/tmp` before upload. Size it for the
largest uncompressed database plus its compressed copy. `doctor` warns when free
space drops below 1 GiB.

```bash
du -sh /var/lib/backupkit/tmp
find /var/lib/backupkit/tmp -maxdepth 1 -type d   # leftovers from a killed run
```

Leftover directories from a killed run are safe to delete: the run's own exit
trap removes them on normal exit, abnormal exit codes (kill -9, power loss) can
leave them behind.

## Diagnostics to attach to a bug report

```bash
backupkit version
backupkit status --json
backupkit doctor --no-connect
backupkit config show                 # already redacted, safe to share
jq -c . /var/lib/backupkit/history.jsonl | tail -20
tail -50 /var/log/backupkit/backupkit.log
```

Never paste `secrets.json`, `age.key`, or an unredacted run log.
