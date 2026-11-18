# BackupKit

**Lightweight, self-hosted database backup automation for VPS infrastructure with S3-compatible object storage.**

BackupKit runs on each VPS it protects. There is no central server, no database,
no daemon and no dashboard: a cron entry runs a CLI, the CLI produces an
encrypted, checksummed dump and pushes it to object storage, and everything that
matters is recorded in a signed-off manifest.

```
   ┌────────────────────────────── VPS ──────────────────────────────┐
   │  cron  →  backupkit backup --all                                 │
   │             ├─ lock            (no overlapping runs)             │
   │             ├─ mysqldump / pg_dump  (logical dump)               │
   │             ├─ zstd                 (compression)                │
   │             ├─ age                  (public-key encryption)      │
   │             ├─ sha256 + size        (validation)                 │
   │             ├─ upload + verify      (object storage)             │
   │             ├─ manifest             (what, where, checksum)      │
   │             └─ retention            (only after a verified upload)│
   │  state: /var/lib/backupkit   config: /etc/backupkit               │
   └───────────────────────────────┬──────────────────────────────────┘
                                   │  S3 API (TLS)
                    ┌──────────────▼───────────────┐
                    │  Cloudflare R2 / any S3      │
                    │  bucket (encrypted objects)  │
                    └──────────────────────────────┘
```

## Why it works this way

- **Independent hosts.** Every VPS can back up on its own; no host depends on
  another and none of them needs network access to a database server.
- **No plaintext ever leaves the host.** Artifacts are encrypted with
  [age](https://age-encryption.org/) before upload. The private key stays on the
  VPS, outside the bucket.
- **Success means verified.** A dump is only "verified" after the artifact
  exists, its size matches and its SHA-256 matches the checksum computed before
  the upload.
- **One snapshot, several categories.** When a daily, weekly and monthly run
  coincide, the existing snapshot is re-tagged instead of dumped again.
- **Nothing is deleted while it is still needed.** Retention deletes only
  objects BackupKit created, recorded in a verified manifest, out of policy for
  *every* category they carry, and never the newest verified backup.
- **It keeps working when monitoring does not.** Notifications are optional and
  best-effort; a Telegram outage cannot fail a backup.

## Requirements

| Component | Needed for | Notes |
|---|---|---|
| bash 3.2+ | everything | macOS stock bash works; Ubuntu ships 5.x |
| jq | everything | config parsing, manifests, logs |
| mysqldump + mysql | MySQL/MariaDB backups | or `mariadb-dump` |
| pg_dump, pg_restore, psql, pg_dumpall | PostgreSQL backups | client must be >= server version |
| zstd (recommended) or gzip | compression | |
| age / age-keygen | encryption | **required unless you explicitly opt out** |
| aws CLI | R2 / S3 upload | not needed for the `local` provider |
| curl | Telegram notifications | optional |
| coreutils (`sha256sum` or `shasum`) | checksums | |

## Quick start (Ubuntu/Debian)

```bash
git clone git@github.com:rosyidrid/backup-kit.git
cd backup-kit
sudo ./scripts/install.sh --deps          # installs jq, age, zstd, awscli

sudo backupkit init                       # config.json, secrets.json, age key
sudo nano /etc/backupkit/config.json      # set timezone, storage, databases
sudo nano /etc/backupkit/secrets.json     # credentials (mode 600)

sudo backupkit config validate
sudo backupkit doctor
sudo backupkit backup --all --dry-run
sudo backupkit backup --all
sudo backupkit list
sudo backupkit install-scheduler
```

The system install keeps `/etc/backupkit` (700, root) and
`/var/lib/backupkit` (700, root), so the commands above need root. For a
user-level install run `./scripts/install.sh --prefix ~/.local --no-sudo` and
then use the CLI as that user with
`BACKUPKIT_ETC=~/.config/backupkit` and
`BACKUPKIT_STATE_DIR=~/.local/state/backupkit`.

The age public key printed by `backupkit init` goes into
`encryption.recipient`; the private key in `/etc/backupkit/age.key` must be
backed up **offline** — lose it and the backups become unreadable.

## Commands

```
backupkit init                    create config/secrets/key
backupkit config validate|show|path
backupkit doctor                  dependencies, credentials, storage, locks
backupkit backup --all|--database ID|--type daily [--dry-run] [--no-cleanup]
backupkit list [--remote] [--json]
backupkit status [--json]
backupkit verify --id ID [--deep]
backupkit restore --id ID --target DB [--dry-run] [--yes]
backupkit restore --id ID --globals [--yes]
backupkit cleanup [--dry-run] [--database ID]
backupkit install-scheduler | uninstall-scheduler
```

Exit codes are stable and documented in [docs/architecture.md](docs/architecture.md#exit-codes).

## Documentation

| Document | Contents |
|---|---|
| [docs/installation.md](docs/installation.md) | Ubuntu/Debian install, packages, permissions, systemd timers |
| [docs/configuration.md](docs/configuration.md) | every configuration key, MySQL/PostgreSQL/R2 examples, retention and schedule semantics |
| [docs/usage.md](docs/usage.md) | command reference, cron examples, exit codes, routine operations |
| [docs/restore.md](docs/restore.md) | restore procedures, dry runs, restore rehearsal, disaster recovery |
| [docs/security.md](docs/security.md) | threat model, credentials, key management, least privilege |
| [docs/architecture.md](docs/architecture.md) | components, pipeline, manifest schema, object layout, design decisions |
| [docs/troubleshooting.md](docs/troubleshooting.md) | common errors and how to diagnose them |
| [docs/test-report.md](docs/test-report.md) | what the test suite covers and the raw results |
| [docs/roadmap.md](docs/roadmap.md) | what is deliberately not implemented yet |

## What BackupKit is not

- Not a continuous replication or point-in-time recovery tool: it takes logical
  dumps on a schedule.
- Not a monitoring system: it reports, it does not alert on missed backups by
  itself (see the optional Telegram notifications and the catch-up cron entry).
- Not a central dashboard, and it will not become one in the MVP. Each host owns
  its own backups.

## Testing

```bash
bash tests/run.sh              # full suite
bash tests/run.sh retention    # one area
```

Tests run entirely against mocks in `tests/mocks` (database clients, age and the
AWS CLI) and a temporary directory tree. No production database, credential or
network endpoint is involved.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Security issues: please read
[docs/security.md](docs/security.md) first and avoid opening a public issue with
exploit details.

## License

MIT — see [LICENSE](LICENSE).
