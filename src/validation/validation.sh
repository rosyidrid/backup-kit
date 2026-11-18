#!/usr/bin/env bash
# BackupKit - src/validation/validation.sh
#
# Validation stages. A backup is only "verified" when the uploaded object
# exists, its size matches, and its SHA-256 matches the checksum computed
# before the upload.
#
# Limitation, stated explicitly in docs/restore.md: a matching checksum proves
# the bytes did not change in transit or at rest. It does not prove the dump
# can be restored. Only a restore rehearsal into a scratch database proves it.

bk_sha256() {
  local f="$1"
  [ -f "$f" ] || { printf ''; return 1; }
  if bk_have sha256sum; then
    sha256sum "$f" | awk '{print $1}'
  elif bk_have shasum; then
    shasum -a 256 "$f" | awk '{print $1}'
  else
    bk_die "$BK_EXIT_DEPENDENCY" "no SHA-256 tool found (need sha256sum or shasum)"
  fi
}

bk_sha256_file() {
  # Writes "<sha256>  <basename>" next to the artifact, and echoes the digest.
  local f="$1" sum
  sum="$(bk_sha256 "$f")" || return "$BK_EXIT_VERIFY"
  ( umask 077; printf '%s  %s\n' "$sum" "$(basename "$f")" >"${f}.sha256" )
  printf '%s' "$sum"
}

bk_stage_validate_artifact() {
  # bk_stage_validate_artifact FILE EXPECTED_SHA256 LABEL
  local f="$1" expected="$2" label="$3" actual
  [ -f "$f" ] || { bk_warn "$label: file missing"; return "$BK_EXIT_VERIFY"; }
  [ -s "$f" ] || { bk_warn "$label: file is empty"; return "$BK_EXIT_VERIFY"; }
  actual="$(bk_sha256 "$f")"
  if [ "$actual" != "$expected" ]; then
    bk_warn "$label: checksum mismatch (expected $expected, got $actual)"
    return "$BK_EXIT_VERIFY"
  fi
  return 0
}

bk_stage_validate_upload() {
  # bk_stage_validate_upload KEY EXPECTED_SIZE LABEL
  local key="$1" expected="$2" label="$3" remote
  remote="$(bk_storage_size "$key")"
  if [ "$remote" = "-1" ]; then
    bk_warn "$label: uploaded object not found: $key"
    return "$BK_EXIT_UPLOAD"
  fi
  if [ "$remote" != "$expected" ]; then
    bk_warn "$label: uploaded object size mismatch (expected $expected, got $remote)"
    return "$BK_EXIT_UPLOAD"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Full verify of one stored backup.
# bk_verify_backup BACKUP_ID [--deep]
# ---------------------------------------------------------------------------
bk_verify_backup() {
  local id="$1" deep="${2:-}" manifest tmp dir rc=0 key expected sha size
  bk_id_valid "$id" || bk_die "$BK_EXIT_GENERAL" "invalid backup id: $id"

  manifest="$(bk_manifest_read "$id")"
  if [ -z "$manifest" ]; then
    manifest="$(bk_manifest_fetch_remote "$id")" || true
  fi
  [ -n "$manifest" ] || bk_die "$BK_EXIT_NOTFOUND" "no manifest found for backup id $id"

  dir="$(bk_mkworkdir "verify")"
  tmp="${dir}/artifact"

  local artifacts count i=0
  artifacts="$(bk_manifest_field "$manifest" '.artifacts | length' '0')"
  if [ "$artifacts" -eq 0 ] 2>/dev/null; then
    bk_warn "manifest $id lists no artifacts"
    return "$BK_EXIT_VERIFY"
  fi

  while IFS= read -r key; do
    [ -n "$key" ] || continue
    i=$((i + 1))
    expected="$(printf '%s' "$manifest" | jq -r --argjson n "$((i - 1))" '.artifacts[$n].sha256 // empty')"
    sha="$(printf '%s' "$manifest" | jq -r --argjson n "$((i - 1))" '.artifacts[$n].size_bytes // 0')"

    bk_info "verifying artifact $i/$artifacts: $key"

    if ! bk_storage_download "$key" "$tmp"; then
      bk_warn "download failed: $key"
      rc="$BK_EXIT_VERIFY"
      continue
    fi

    if ! bk_stage_validate_artifact "$tmp" "$expected" "artifact $key"; then
      rc="$BK_EXIT_VERIFY"
      continue
    fi

    # Remote size check against the manifest.
    size="$(bk_storage_size "$key")"
    if [ "$size" != "$sha" ]; then
      bk_warn "remote size mismatch for $key (manifest=$sha remote=$size)"
      rc="$BK_EXIT_UPLOAD"
      continue
    fi

    if [ "$deep" = "--deep" ]; then
      # Prove the artifact really decrypts and decompresses end to end.
      local plain="${dir}/plain.$i" arch="${dir}/arch.$i"
      if bk_encryption_enabled; then
        if ! bk_decrypt "$tmp" "$plain"; then
          bk_warn "decryption failed for $key"
          rc="$BK_EXIT_ENCRYPT"
          continue
        fi
      else
        cp -- "$tmp" "$plain"
      fi
      case "$(bk_compress_magic "$plain")" in
        zstd)
          bk_need_cmd zstd
          if ! zstd -q -d -c "$plain" >"$arch" 2>/dev/null; then
            bk_warn "zstd decompression failed for $key"
            rc="$BK_EXIT_COMPRESS"
            continue
          fi ;;
        gzip)
          bk_need_cmd gzip
          if ! gzip -d -c "$plain" >"$arch" 2>/dev/null; then
            bk_warn "gzip decompression failed for $key"
            rc="$BK_EXIT_COMPRESS"
            continue
          fi ;;
        *)
          bk_warn "unknown compression format for $key"
          rc="$BK_EXIT_COMPRESS"
          continue ;;
      esac
      [ -s "$arch" ] || { bk_warn "decompressed artifact is empty for $key"; rc="$BK_EXIT_COMPRESS"; continue; }
      bk_info "artifact $i/$artifacts OK (checksum, decrypt, decompress)"
    else
      bk_info "artifact $i/$artifacts OK (checksum, remote size)"
    fi
    rm -f -- "$tmp" "$plain" 2>/dev/null || true
  done <<EOF
$(bk_manifest_artifact_keys "$manifest")
EOF

  if [ "$rc" -eq 0 ]; then
    bk_info "backup $id verified ($artifacts artifact(s))"
  fi
  return "$rc"
}

bk_manifest_fetch_remote() {
  # Locate a manifest by listing the database prefixes: the caller may not
  # know the database id when only the backup id is available.
  local id="$1" db_id type key
  for db_id in $(bk_db_ids); do
    for type in daily weekly monthly; do
      key="$(bk_storage_manifest_key "$db_id" "$type" "$id")"
      if [ "$(bk_storage_size "$key")" != "-1" ]; then
        bk_storage_get_string "$key"
        return 0
      fi
    done
  done
  return 1
}
