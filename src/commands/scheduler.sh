#!/usr/bin/env bash
# BackupKit - src/commands/scheduler.sh
#
# Cron installation. A single daily job would work, but three explicit jobs
# keep the documented times (02:00 / 03:00 Sunday / 04:00 on the 1st) and the
# reuse logic in the backup pipeline collapses them into one snapshot when
# they coincide.

bk_cron_file() {
  printf '%s' "${BACKUPKIT_CRON_FILE:-/etc/cron.d/backupkit}"
}

bk_cron_installed() {
  local f
  f="$(bk_cron_file)"
  [ -f "$f" ] && grep -q 'Managed by BackupKit' "$f" 2>/dev/null
}

bk_cron_payload() {
  local bin="$1" user="$2" timezone="$3" weekly_dow="$4" monthly_dom="$5" logdir="$6"
  cat <<EOF
# Managed by BackupKit. Do not edit by hand: use 'backupkit install-scheduler'.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CRON_TZ=${timezone}

# daily 02:00, weekly 03:00, monthly 04:00 (times are in CRON_TZ above)
0 2 * * * ${user} ${bin} backup --all --type daily >> ${logdir}/cron.log 2>&1
0 3 * * ${weekly_dow} ${user} ${bin} backup --all --type weekly >> ${logdir}/cron.log 2>&1
0 4 ${monthly_dom} * * ${user} ${bin} backup --all --type monthly >> ${logdir}/cron.log 2>&1

# Safety net: if a long job overran and a slot was missed, catch up daily.
# remove this line if you prefer strict windows only.
30 6 * * * ${user} ${bin} backup --all --type auto >> ${logdir}/cron.log 2>&1
EOF
}

bk_cmd_install_scheduler() {
  local bin="/usr/local/bin/backupkit" user="root" print_only=0 tz="" file
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --bin)  bin="${2-}"; shift 2 ;;
      --user) user="${2-}"; shift 2 ;;
      --print) print_only=1; shift ;;
      -h|--help)
        cat <<'EOF'
Usage: backupkit install-scheduler [--bin PATH] [--user USER] [--print]

  --bin    path to the backupkit executable (default: /usr/local/bin/backupkit)
  --user   user field for /etc/cron.d entries (default: root)
  --print  print the cron file instead of installing it
EOF
        return 0 ;;
      *) bk_die "$BK_EXIT_GENERAL" "unknown option for install-scheduler: $1" ;;
    esac
  done

  bk_config_load 2>/dev/null || true
  tz="${BK_TZ:-Asia/Jakarta}"

  local weekly_dow monthly_dom
  weekly_dow="$(bk_cfg '.schedule.weekly_dow' '0')"
  monthly_dom="$(bk_cfg '.schedule.monthly_dom' '1')"

  local payload
  payload="$(bk_cron_payload "$bin" "$user" "$tz" "$weekly_dow" "$monthly_dom" "$BK_LOG_DIR")"

  if [ "$print_only" = "1" ]; then
    printf '%s\n' "$payload"
    return 0
  fi

  file="$(bk_cron_file)"
  if [ ! -d "$(dirname "$file")" ]; then
    bk_die "$BK_EXIT_GENERAL" "cron directory $(dirname "$file") not found; is cron installed?"
  fi
  if [ -w "$(dirname "$file")" ]; then
    printf '%s\n' "$payload" >"$file" || bk_die "$BK_EXIT_GENERAL" "cannot write $file"
    chmod 644 "$file"
    bk_info "installed cron entries in $file (timezone $tz)"
  else
    bk_info "$(dirname "$file") is not writable; printing instead"
    printf '%s\n' "$payload"
    printf '\nSave the block above as %s (mode 644) or re-run with sudo.\n' "$file"
    return "$BK_EXIT_GENERAL"
  fi
  return 0
}

bk_cmd_uninstall_scheduler() {
  local file
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) printf 'Usage: backupkit uninstall-scheduler\n'; return 0 ;;
      *) bk_die "$BK_EXIT_GENERAL" "unknown option for uninstall-scheduler: $1" ;;
    esac
  done

  file="$(bk_cron_file)"
  if [ ! -f "$file" ]; then
    bk_info "no cron file at $file; nothing to do"
    return 0
  fi
  if ! grep -q 'Managed by BackupKit' "$file" 2>/dev/null; then
    bk_die "$BK_EXIT_GENERAL" "refusing to remove $file: it was not created by BackupKit"
  fi
  rm -f -- "$file" || bk_die "$BK_EXIT_GENERAL" "cannot remove $file (try with sudo)"
  bk_info "removed $file"
  return 0
}
