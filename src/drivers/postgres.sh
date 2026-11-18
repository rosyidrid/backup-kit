#!/usr/bin/env bash
# BackupKit - src/drivers/postgres.sh
#
# PostgreSQL logical backups with pg_dump (custom format), optional global
# objects with pg_dumpall --globals-only, and restore with pg_restore/psql.
#
# Credentials go into a temporary PGPASSFILE (0600), never into argv.

bk_pg_dump_bin() { printf 'pg_dump'; }
bk_pg_dumpall_bin() { printf 'pg_dumpall'; }
bk_pg_restore_bin() { printf 'pg_restore'; }
bk_pg_psql_bin() { printf 'psql'; }

bk_pg_required_cmds() {
  printf 'pg_dump pg_restore psql\n'
}

bk_pg_host() { bk_db_field "$1" '.host' "$(bk_db_cred "$1" host '127.0.0.1')"; }
bk_pg_port() { bk_db_field "$1" '.port' "$(bk_db_cred "$1" port '5432')"; }
bk_pg_user() { bk_db_field "$1" '.user' "$(bk_db_cred "$1" user 'postgres')"; }

# bk_pg_passfile DB_ID -> path of a 0600 pgpass file, cleaned up on exit.
bk_pg_passfile() {
  local id="$1" dir file pass host port user db
  pass="$(bk_db_cred "$id" password '')"
  host="$(bk_pg_host "$id")"
  port="$(bk_pg_port "$id")"
  user="$(bk_pg_user "$id")"
  db="$(bk_db_name "$id")"

  dir="$(bk_mkworkdir "pgpass")"
  file="${dir}/pgpass"
  if [ -n "$pass" ]; then
    (
      umask 077
      printf '%s:%s:*:%s:%s\n' "$host" "$port" "$user" "$pass" >"$file"
    )
  else
    # No password in secrets: rely on peer/trust auth or ~/.pgpass.
    : >"$file"
  fi
  chmod 600 "$file"
  printf '%s\n' "$file"
}

bk_pg_common_args() {
  local id="$1"
  printf '%s\n' \
    --host "$(bk_pg_host "$id")" \
    --port "$(bk_pg_port "$id")" \
    --username "$(bk_pg_user "$id")" \
    --no-password
}

bk_pg_server_version() {
  local id="$1" passfile
  passfile="$(bk_pg_passfile "$id")"
  local args
  args=($(bk_pg_common_args "$id"))
  PGPASSFILE="$passfile" "$(bk_pg_psql_bin)" "${args[@]}" --dbname "$(bk_db_name "$id")" -tAc 'SHOW server_version' 2>/dev/null | head -1
}

bk_pg_client_version() {
  "$(bk_pg_dump_bin)" --version 2>/dev/null | head -1
}

# bk_pg_dump DB_ID OUTFILE ERRLOG
bk_pg_dump() {
  local id="$1" out="$2" err="$3" passfile status
  passfile="$(bk_pg_passfile "$id")"

  local args
  args=($(bk_pg_common_args "$id"))
  args+=(--format=custom --file="$out")
  # Internal archive compression is disabled by default because the pipeline
  # compresses the artifact itself; double compression wastes CPU for no gain.
  args+=(--compress="$(bk_db_field "$id" '.pg_dump_compress' '0')")
  [ "$(bk_db_field "$id" '.no_owner' 'false')" = "true" ] && args+=(--no-owner)
  [ "$(bk_db_field "$id" '.no_acl' 'false')" = "true" ] && args+=(--no-acl)

  local opt
  while IFS= read -r opt; do
    [ -n "$opt" ] && args+=("$opt")
  done <<EOF
$(bk_db_extra_dump_opts "$id")
EOF

  : >"$err"
  PGPASSFILE="$passfile" "$(bk_pg_dump_bin)" "${args[@]}" --dbname "$(bk_db_name "$id")" 2>"$err"
  status=$?

  [ "$status" -eq 0 ] || return "$BK_EXIT_DUMP"
  [ -s "$out" ] || { bk_warn "pg_dump produced an empty file for $id"; return "$BK_EXIT_DUMP"; }

  # pg_dump custom format has a magic header; check it instead of trusting the
  # exit status alone.
  if [ "$(bk_db_field "$id" '.verify_header' 'true')" = "true" ]; then
    if ! head -c 5 "$out" | grep -q 'PGDMP'; then
      bk_warn "pg_dump output for $id is not a custom-format archive (missing PGDMP header)"
      return "$BK_EXIT_DUMP"
    fi
  fi
  return 0
}

# bk_pg_dump_globals DB_ID OUTFILE ERRLOG
bk_pg_dump_globals() {
  local id="$1" out="$2" err="$3" passfile status
  passfile="$(bk_pg_passfile "$id")"

  local args
  args=($(bk_pg_common_args "$id"))
  args+=(--globals-only --file="$out")

  : >"$err"
  PGPASSFILE="$passfile" "$(bk_pg_dumpall_bin)" "${args[@]}" 2>"$err"
  status=$?

  [ "$status" -eq 0 ] || return "$BK_EXIT_DUMP"
  [ -s "$out" ] || { bk_warn "pg_dumpall --globals-only produced an empty file for $id"; return "$BK_EXIT_DUMP"; }
  return 0
}

# bk_pg_restore DB_ID INFILE TARGET_DB
bk_pg_restore() {
  local id="$1" infile="$2" target="$3" passfile status
  passfile="$(bk_pg_passfile "$id")"
  bk_need_cmd "$(bk_pg_restore_bin)"

  local args
  args=($(bk_pg_common_args "$id"))
  args+=(--dbname "$target" --clean --if-exists)
  [ "$(bk_db_field "$id" '.restore_single_transaction' 'true')" = "true" ] && args+=(--single-transaction)
  [ "$(bk_db_field "$id" '.restore_exit_on_error' 'true')" = "true" ] && args+=(--exit-on-error)
  [ "$(bk_db_field "$id" '.no_owner' 'false')" = "true" ] && args+=(--no-owner)

  PGPASSFILE="$passfile" "$(bk_pg_restore_bin)" "${args[@]}" "$infile"
  status=$?
  [ "$status" -eq 0 ] || return "$BK_EXIT_RESTORE"
  return 0
}

# bk_pg_restore_globals DB_ID INFILE
bk_pg_restore_globals() {
  local id="$1" infile="$2" passfile status
  passfile="$(bk_pg_passfile "$id")"
  bk_need_cmd "$(bk_pg_psql_bin)"

  local args
  args=($(bk_pg_common_args "$id"))
  args+=(--dbname "$(bk_db_field "$id" '.globals_database' 'postgres')" --set ON_ERROR_STOP=on -f "$infile")

  PGPASSFILE="$passfile" "$(bk_pg_psql_bin)" "${args[@]}"
  status=$?
  [ "$status" -eq 0 ] || return "$BK_EXIT_RESTORE"
  return 0
}
