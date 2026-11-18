#!/usr/bin/env bash
# BackupKit - src/storage/local.sh
#
# Local directory storage provider. Used by the test suite, for offline
# mirrors, and to validate the pipeline without touching the network.

bk_local_root() {
  local root
  root="$(bk_cfg '.storage.local.path' '')"
  [ -n "$root" ] || bk_die "$BK_EXIT_CONFIG" "storage.local.path is required for the local provider"
  printf '%s' "$root"
}

bk_local_init() {
  local root
  root="$(bk_local_root)"
  mkdir -p "$root" 2>/dev/null || bk_die "$BK_EXIT_CONFIG" "cannot create local storage root: $root"
  [ -w "$root" ] || bk_die "$BK_EXIT_CONFIG" "local storage root is not writable: $root"
}

bk_local_path() {
  # Resolve a key to an absolute path, refusing anything outside the root.
  local key="$1" root path
  root="$(bk_local_root)"
  bk_storage_key_valid "$key" || bk_die "$BK_EXIT_UPLOAD" "invalid storage key: $key"
  path="${root%/}/${key}"
  case "$path" in
    "${root%/}"/*) printf '%s' "$path" ;;
    *) bk_die "$BK_EXIT_UPLOAD" "storage key escapes local root: $key" ;;
  esac
}

bk_local_upload() {
  local file="$1" key="$2" dest dir
  dest="$(bk_local_path "$key")"
  dir="$(dirname "$dest")"
  mkdir -p "$dir" || return "$BK_EXIT_UPLOAD"
  ( umask 077; cp -- "$file" "${dest}.part.$$" ) || return "$BK_EXIT_UPLOAD"
  mv -f "${dest}.part.$$" "$dest" || return "$BK_EXIT_UPLOAD"
  return 0
}

bk_local_put_string() {
  local str="$1" key="$2" dest dir
  dest="$(bk_local_path "$key")"
  dir="$(dirname "$dest")"
  mkdir -p "$dir" || return "$BK_EXIT_UPLOAD"
  ( umask 077; printf '%s\n' "$str" >"${dest}.part.$$" ) || return "$BK_EXIT_UPLOAD"
  mv -f "${dest}.part.$$" "$dest" || return "$BK_EXIT_UPLOAD"
  return 0
}

bk_local_download() {
  local key="$1" file="$2" src
  src="$(bk_local_path "$key")"
  [ -f "$src" ] || return "$BK_EXIT_NOTFOUND"
  ( umask 077; cp -- "$src" "$file" ) || return "$BK_EXIT_VERIFY"
  return 0
}

bk_local_get_string() {
  local key="$1" src
  src="$(bk_local_path "$key")"
  [ -f "$src" ] || return "$BK_EXIT_NOTFOUND"
  cat "$src"
}

bk_local_delete() {
  local key="$1" src
  src="$(bk_local_path "$key")"
  [ -e "$src" ] || return 0
  rm -f -- "$src" || return "$BK_EXIT_RETENTION"
  return 0
}

bk_local_list() {
  local prefix="$1" root dir
  root="$(bk_local_root)"
  dir="${root%/}/${prefix}"
  [ -d "$dir" ] || return 0
  (cd "$root" && find "$prefix" -type f 2>/dev/null | sed -e 's|^\./||' | sort)
}

bk_local_size() {
  local key="$1" src
  src="$(bk_local_path "$key")"
  [ -f "$src" ] || { printf -- '-1'; return 0; }
  bk_file_size "$src"
}

bk_local_check() {
  local root
  root="$(bk_local_root)"
  [ -d "$root" ] || { bk_warn "local storage root missing: $root"; return "$BK_EXIT_GENERAL"; }
  [ -w "$root" ] || { bk_warn "local storage root not writable: $root"; return "$BK_EXIT_GENERAL"; }
  return 0
}
