#!/usr/bin/env bash
# BackupKit - src/commands/verify.sh
# 'backupkit verify --id BACKUP_ID [--deep]'

bk_cmd_verify() {
  local id="" deep=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --id)   id="${2-}"; shift 2 ;;
      --deep) deep="--deep"; shift ;;
      -h|--help)
        cat <<'EOF'
Usage: backupkit verify --id BACKUP_ID [--deep]

Downloads every artifact of the backup, checks the SHA-256 recorded in the
manifest, and confirms the object size in storage.

--deep additionally decrypts and fully decompresses each artifact to prove the
pipeline is reversible. Even --deep is not a restore test: see docs/restore.md.
EOF
        return 0 ;;
      *) bk_die "$BK_EXIT_GENERAL" "unknown option for verify: $1" ;;
    esac
  done

  [ -n "$id" ] || bk_die "$BK_EXIT_GENERAL" "verify requires --id BACKUP_ID"

  bk_config_load
  bk_state_init
  bk_storage_init_provider

  bk_verify_backup "$id" "$deep"
}
