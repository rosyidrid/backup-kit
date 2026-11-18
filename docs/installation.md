# Installation

Target platforms: Ubuntu 20.04+, Debian 11+ (any Linux with bash 3.2+ works).
BackupKit also runs on macOS, which is handy for testing the CLI locally.

## 1. Packages

Everything except the database clients is available from the distribution:

```bash
sudo apt-get update
sudo apt-get install -y \
  jq zstd gzip curl ca-certificates awscli age

# then the client for the database you back up:
sudo apt-get install -y default-mysql-client     # MySQL / MariaDB backup
sudo apt-get install -y postgresql-client        # PostgreSQL backup
```

| Package | Why | Required |
|---|---|---|
| `jq` | JSON parsing for config, manifests and logs | yes |
| `age` | encrypts every artifact before upload | yes, unless plaintext is explicitly allowed |
| `zstd` | compression (fallback: `gzip`) | recommended |
| `awscli` | R2 / S3 upload | yes for R2 and S3 |
| `default-mysql-client` | `mysqldump`, `mysql` | for MySQL/MariaDB |
| `postgresql-client` | `pg_dump`, `pg_restore`, `pg_dumpall`, `psql` | for PostgreSQL |
| `curl` | Telegram notifications | optional |

> **PostgreSQL clients**: install the matching or newer major version. `pg_dump`
> older than the server cannot read the server. On Ubuntu, use the PGDG
> repository if the distribution version is older than your database.

## 2. Install BackupKit

```bash
git clone git@github.com:rosyidrid/backup-kit.git
cd backup-kit
sudo ./scripts/install.sh --deps
```

What the installer does:

- verifies required commands, lists optional ones that are missing;
- copies `bin/`, `src/`, `config/`, `docs/` to `/usr/local/lib/backupkit`;
- creates the launcher `/usr/local/bin/backupkit`;
- creates `/etc/backupkit`, `/var/lib/backupkit`, `/var/log/backupkit` with mode
  `700` and **never** touches their contents if they already exist.

Useful flags: `--prefix ~/.local --no-sudo` (user-level install),
`--dry-run`, `--lib DIR`.

Manual install, if you prefer to be explicit:

```bash
sudo install -d -m 700 /usr/local/lib/backupkit
sudo cp -R bin src config docs VERSION LICENSE README.md CHANGELOG.md /usr/local/lib/backupkit/
sudo chmod 755 /usr/local/lib/backupkit/bin/backupkit
sudo ln -sf /usr/local/lib/backupkit/bin/backupkit /usr/local/bin/backupkit
sudo install -d -m 700 /etc/backupkit /var/lib/backupkit /var/log/backupkit
```

The launcher resolves its own location, so it works through the symlink and from
any working directory.

## 3. Initialise the configuration

```bash
sudo backupkit init
```

This writes:

- `/etc/backupkit/config.json` (mode 600) — copy of `config/config.example.json`
- `/etc/backupkit/secrets.json` (mode 600) — copy of the secrets template
- `/etc/backupkit/age.key` (mode 600) — a new age key pair, if `age-keygen` exists

`init` never overwrites an existing config, secrets file or key. It prints the
age public key; put it in `encryption.recipient`.

```bash
sudo backupkit config path        # show where the files are
```

## 4. Configure

```bash
sudo nano /etc/backupkit/config.json     # storage, timezone, databases
sudo nano /etc/backupkit/secrets.json    # credentials
sudo chmod 600 /etc/backupkit/config.json
sudo chown root:root /etc/backupkit/config.json /etc/backupkit/secrets.json
```

Ready-to-adapt examples: [configuration.md](configuration.md). Rule of thumb:
`config.json` is shareable, `secrets.json` never leaves the host, `age.key`
never leaves the host and is backed up offline.

## 5. Verify before trusting it

```bash
sudo backupkit config validate     # every problem, all at once
sudo backupkit doctor              # dependencies, credentials, storage, locks
sudo backupkit backup --all --dry-run
sudo backupkit backup --all        # a real run
sudo backupkit list
sudo backupkit verify --id <id> --deep
```

`doctor` performs a live connection test per database (`SELECT 1`) and checks the
client/server version pairing. Use `--no-connect` when the database is
intentionally unreachable.

## 6. Schedule it

```bash
sudo backupkit install-scheduler          # writes /etc/cron.d/backupkit
backupkit install-scheduler --print       # review first, no changes
```

The generated file sets `CRON_TZ` from `config.timezone` and runs the daily,
weekly, monthly and catch-up jobs (see
[configuration.md](configuration.md#schedule-and-retention-semantics)). Cron
needs no reload for `/etc/cron.d` files.

Alternatives:

- `crontab -e` for a user-level install:
  ```
  0 2 * * * /home/deploy/.local/bin/backupkit backup --all --type daily >> /home/deploy/backupkit.log 2>&1
  ```
- systemd timer, if you prefer journald over files:
  ```ini
  # /etc/systemd/system/backupkit-backup.service
  [Unit]
  Description=BackupKit database backup
  [Service]
  Type=oneshot
  ExecStart=/usr/local/bin/backupkit backup --all --type auto
  ```
  ```ini
  # /etc/systemd/system/backupkit-backup.timer
  [Unit]
  Description=Run BackupKit daily
  [Timer]
  OnCalendar=*-*-* 02:00:00
  Persistent=true
  [Install]
  WantedBy=timers.target
  ```
  `Persistent=true` replays a missed run after downtime; the lock and the reuse
  logic make that safe.

## 7. Log rotation (optional)

Logs are JSON lines in `/var/log/backupkit/backupkit.log`:

```
# /etc/logrotate.d/backupkit
/var/log/backupkit/*.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    create 0600 root root
}
```

## 8. Upgrading

```bash
cd backup-kit && git pull
sudo ./scripts/install.sh            # replaces program files only
backupkit doctor
```

Configuration and state are preserved. The manifest schema is versioned
(`schema_version`), so an older manifest stays readable.

## 9. Uninstalling

```bash
sudo ./scripts/uninstall.sh          # program + cron, keeps config/state/logs
sudo ./scripts/uninstall.sh --purge  # also config, state and logs (asks "yes")
```

`--purge` warns before deleting `/etc/backupkit`, because that is where the
private key lives. Objects already in the bucket are never deleted by the
uninstaller.

## Troubleshooting the install

| Symptom | Cause | Fix |
|---|---|---|
| `missing required command: jq` | package not installed | `apt-get install -y jq` |
| `secrets file ... must be readable by the owner only` | wrong mode | `chmod 600 /etc/backupkit/secrets.json` |
| `config file not found` | `init` never ran, or a non-default `BACKUPKIT_ETC` | `backupkit init`, check `backupkit config path` |
| `aws CLI not found` | `awscli` missing (only needed for R2/S3) | `apt-get install -y awscli` or use the `local` provider |
| `identity file not found` | key path mismatch | set `encryption.identity_file`, or restore the key |

See [troubleshooting.md](troubleshooting.md) for run-time problems.
