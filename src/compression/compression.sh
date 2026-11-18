#!/usr/bin/env bash
# BackupKit - src/compression/compression.sh
#
# Compression stage. zstd is preferred (faster, better ratio, integrity check
# built in); gzip is the broadly available fallback.

bk_compression_algo() {
  bk_cfg '.compression.algorithm' 'zstd'
}

bk_compression_level() {
  bk_cfg '.compression.level' '10'
}

bk_compression_ext() {
  case "$(bk_compression_algo)" in
    zstd) printf 'zst' ;;
    gzip) printf 'gz' ;;
    *)    printf 'bin' ;;
  esac
}

bk_compression_ext_for() {
  case "$1" in
    zstd) printf 'zst' ;;
    gzip) printf 'gz' ;;
    *)    printf 'bin' ;;
  esac
}

bk_compression_required_cmds() {
  case "$(bk_compression_algo)" in
    zstd) printf 'zstd\n' ;;
    gzip) printf 'gzip\n' ;;
  esac
}

# bk_compress IN OUT
bk_compress() {
  local in="$1" out="$2" algo level status
  algo="$(bk_compression_algo)"
  level="$(bk_compression_level)"

  case "$algo" in
    zstd)
      bk_need_cmd zstd
      zstd -q -T0 -"$level" -f -o "$out" "$in"
      status=$?
      ;;
    gzip)
      bk_need_cmd gzip
      gzip -"$level" -c "$in" >"$out"
      status=$?
      ;;
    *)
      bk_die "$BK_EXIT_CONFIG" "unsupported compression algorithm: $algo"
      ;;
  esac

  if [ "$status" -ne 0 ] || [ ! -s "$out" ]; then
    return "$BK_EXIT_COMPRESS"
  fi
  return 0
}

# bk_decompress IN OUT  (auto-detects zstd by magic, falls back to extension)
bk_decompress() {
  local in="$1" out="$2" status
  case "$in" in
    *.zst)
      bk_need_cmd zstd
      zstd -q -d -f -o "$out" "$in"; status=$? ;;
    *.gz)
      bk_need_cmd gzip
      gzip -d -c "$in" >"$out"; status=$? ;;
    *)
      bk_die "$BK_EXIT_COMPRESS" "cannot determine compression format for $in"
      ;;
  esac
  [ "$status" -eq 0 ] || return "$BK_EXIT_COMPRESS"
  [ -s "$out" ] || return "$BK_EXIT_COMPRESS"
  return 0
}

# bk_compress_magic FILE -> zstd | gzip | unknown
#
# Sniffing the file header is more reliable than trusting an extension: an
# encrypted artifact is named .zst.age, and a manifest could be stale.
bk_compress_magic() {
  local f="$1" magic
  [ -f "$f" ] || { printf 'unknown'; return 0; }
  magic="$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')"
  case "$magic" in
    28b52ffd*) printf 'zstd' ;;
    1f8b*)     printf 'gzip' ;;
    *)         printf 'unknown' ;;
  esac
}

# bk_decompress_auto IN OUT -> decompress by sniffing the header
bk_decompress_auto() {
  local in="$1" out="$2"
  case "$(bk_compress_magic "$in")" in
    zstd) bk_need_cmd zstd; zstd -q -d -f -o "$out" "$in" || return "$BK_EXIT_COMPRESS" ;;
    gzip) bk_need_cmd gzip; gzip -d -c "$in" >"$out" || return "$BK_EXIT_COMPRESS" ;;
    *)    bk_warn "cannot detect the compression format of $in"; return "$BK_EXIT_COMPRESS" ;;
  esac
  [ -s "$out" ] || return "$BK_EXIT_COMPRESS"
  return 0
}
