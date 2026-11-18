#!/usr/bin/env bash
# BackupKit - src/commands/restore_cmd.sh
# 'backupkit restore --id ID --target DB [--role primary|globals] [--dry-run] [--yes]'

bk_restore_usage() {
  cat <<'EOF'
Usage: backupkit restore --id BACKUP_ID --target DATABASE [options]

Options:
  --id ID          backup id, as shown by 'backupkit list'
  --target DB      database to restore into (required for a primary restore)
  --role primary   restore the database dump (default)
  --globals        restore PostgreSQL global objects (roles) instead
  --dry-run        download nothing, change nothing, print the plan
  --yes            skip the interactive confirmation (scripted drills)

The target database must already exist. A primary restore is destructive: the
current contents of --target are replaced.
EOF
}

bk_cmd_restore() {
  local id="" target="" role="primary" dry=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --id)      id="${2-}"; shift 2 ;;
      --target)  target="${2-}"; shift 2 ;;
      --role)
        [ -n "${2-}" ] || bk_die "$BK_EXIT_GENERAL" "--role requires a value"
        case "$2" in
          primary|globals) role="$2" ;;
          *) bk_die "$BK_EXIT_GENERAL" "invalid --role: $2 (primary|globals)" ;;
        esac
        shift 2 ;;
      --globals) role="globals"; shift ;;
      --dry-run) dry="--dry-run"; shift ;;
      --yes)     BK_YES=1; shift ;;
      -h|--help) bk_restore_usage; return 0 ;;
      *) bk_die "$BK_EXIT_GENERAL" "unknown option for restore: $1" ;;
    esac
  done

  [ -n "$id" ] || bk_die "$BK_EXIT_GENERAL" "restore requires --id BACKUP_ID"

  bk_config_load
  bk_state_init
  bk_storage_init_provider

  if [ -n "$dry" ]; then
    bk_restore_run "$id" --role "$role" --target "$target" --dry-run
  else
    bk_restore_run "$id" --role "$role" --target "$target"
  fi
}
