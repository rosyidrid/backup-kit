#!/usr/bin/env bash
# BackupKit - src/core/lock.sh
#
# Mutual exclusion between backup runs, and a guard against cron starting the
# same job twice.
#
# Uses an atomic mkdir lock instead of flock: flock(1) is not present on macOS
# and this keeps one implementation for every supported platform. Stale locks
# (dead pid, or older than the stale timeout) are reclaimed.

BK_LOCK_ACTIVE=""
BK_LOCK_STALE_SECONDS="${BK_LOCK_STALE_SECONDS:-21600}" # 6h

bk_lock_path() {
  # Lock names are restricted so a crafted name cannot escape the lock dir.
  local name="$1"
  case "$name" in
    ''|*/*|*..*) return 1 ;;
  esac
  printf '%s/%s.lock' "$BK_LOCK_DIR" "$name"
}

bk_pid_alive() {
  local pid="$1"
  [ -n "$pid" ] || return 1
  case "$pid" in *[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null
}

bk_lock_is_stale() {
  local dir="$1" pid started now
  pid="$(cat "${dir}/pid" 2>/dev/null || printf '')"
  started="$(cat "${dir}/started_epoch" 2>/dev/null || printf '0')"
  now="$(date +%s)"

  # Reclaim if the owner process is gone.
  if ! bk_pid_alive "$pid"; then
    return 0
  fi
  # Reclaim if the owner claimed the lock too long ago (pid reuse / hung run).
  if [ "$started" -gt 0 ] 2>/dev/null && [ $((now - started)) -gt "$BK_LOCK_STALE_SECONDS" ]; then
    return 0
  fi
  return 1
}

bk_lock_acquire() {
  # bk_lock_acquire NAME [TIMEOUT_SECONDS]
  local name="$1" timeout="${2:-0}" dir waited=0
  dir="$(bk_lock_path "$name")" || return 1
  bk_state_init

  while :; do
    if mkdir "$dir" 2>/dev/null; then
      chmod 700 "$dir" 2>/dev/null || true
      printf '%s\n' "$$" >"${dir}/pid"
      printf '%s\n' "$(date +%s)" >"${dir}/started_epoch"
      printf '%s\n' "$BK_HOSTNAME" >"${dir}/host"
      printf '%s\n' "${BK_RUN_ID:-}" >"${dir}/run_id"
      BK_LOCK_ACTIVE="$dir"
      return 0
    fi

    if bk_lock_is_stale "$dir"; then
      bk_warn "reclaiming stale lock: $dir"
      rm -rf -- "$dir" 2>/dev/null || true
      continue
    fi

    if [ "$timeout" -le 0 ]; then
      local owner
      owner="$(cat "${dir}/pid" 2>/dev/null || printf 'unknown')"
      return 1
    fi
    [ "$waited" -ge "$timeout" ] && return 1
    sleep 1
    waited=$((waited + 1))
  done
}

bk_lock_release() {
  local dir="${BK_LOCK_ACTIVE:-}"
  [ -n "$dir" ] || return 0
  # Only remove the lock if we still own it.
  if [ "$(cat "${dir}/pid" 2>/dev/null || printf '')" = "$$" ]; then
    rm -rf -- "$dir" 2>/dev/null || true
  fi
  BK_LOCK_ACTIVE=""
}

bk_lock_held() {
  # bk_lock_held NAME -> 0 when a live, non-stale lock exists
  local dir
  dir="$(bk_lock_path "$1")" || return 1
  [ -d "$dir" ] || return 1
  bk_lock_is_stale "$dir" && return 1
  return 0
}
