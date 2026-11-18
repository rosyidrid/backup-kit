#!/usr/bin/env bash
# BackupKit - src/drivers/mysql.sh
#
# MySQL / MariaDB logical backups with mysqldump, and restore with mysql.
#
# Credentials are never passed on the command line. They are written to a
# temporary --defaults-extra-file (0600) that is removed on exit.

bk_mysql_client_bin() {
  printf 'mysql'
}

bk_mysql_dump_bin() {
  if bk_have mysqldump; then printf 'mysqldump'; return 0; fi
  if bk_have mariadb-dump; then printf 'mariadb-dump'; return 0; fi
  printf 'mysqldump'
}

bk_mysql_required_cmds() {
  printf '%s %s\n' "$(bk_mysql_dump_bin)" "$(bk_mysql_client_bin)"
}

bk_mysql_host() { bk_db_field "$1" '.host' "$(bk_db_cred "$1" host '127.0.0.1')"; }
bk_mysql_port() { bk_db_field "$1" '.port' "$(bk_db_cred "$1" port '3306')"; }
bk_mysql_user() { bk_db_field "$1" '.user' "$(bk_db_cred "$1" user 'root')"; }
bk_mysql_socket() { bk_db_field "$1" '.socket' "$(bk_db_cred "$1" socket '')"; }

# bk_mysql_cnf DB_ID -> path of a 0600 option file, cleaned up on exit.
bk_mysql_cnf() {
  local id="$1" dir cnf pass user host port socket
  pass="$(bk_db_cred "$id" password '')"
  user="$(bk_mysql_user "$id")"
  host="$(bk_mysql_host "$id")"
  port="$(bk_mysql_port "$id")"
  socket="$(bk_mysql_socket "$id")"

  dir="$(bk_mkworkdir "mysqlcnf")"
  cnf="${dir}/client.cnf"
  (
    umask 077
    {
      printf '[client]\n'
      printf 'user=%s\n' "$user"
      [ -n "$pass" ] && printf 'password=%s\n' "$pass"
      if [ -n "$socket" ]; then
        printf 'socket=%s\n' "$socket"
      else
        printf 'host=%s\n' "$host"
        printf 'port=%s\n' "$port"
      fi
      printf 'default-character-set=utf8mb4\n'
    } >"$cnf"
  )
  chmod 600 "$cnf"
  printf '%s\n' "$cnf"
}

bk_mysql_server_version() {
  local id="$1" cnf
  cnf="$(bk_mysql_cnf "$id")"
  "$(bk_mysql_client_bin)" --defaults-extra-file="$cnf" -N -B -e 'SELECT VERSION()' 2>/dev/null | head -1
}

bk_mysql_client_version() {
  "$(bk_mysql_dump_bin)" --version 2>/dev/null | head -1
}

# bk_mysql_dump DB_ID OUTFILE ERRLOG -> 0 on success
bk_mysql_dump() {
  local id="$1" out="$2" err="$3" cnf dbname status
  cnf="$(bk_mysql_cnf "$id")"
  dbname="$(bk_db_name "$id")"

  local args
  args=(--defaults-extra-file="$cnf"
        --single-transaction
        --quick
        --routines
        --triggers
        --events)

  # --no-tablespaces keeps the required privileges minimal (no PROCESS).
  [ "$(bk_db_field "$id" '.tablespaces' 'false')" = "true" ] || args+=(--no-tablespaces)

  # GTID handling only exists on MySQL, not MariaDB; opt-in.
  [ "$(bk_db_field "$id" '.gtid_purged_off' 'false')" = "true" ] && args+=(--set-gtid-purged=OFF)

  # Consistency for non-transactional (MyISAM) tables. Opt-in because it locks.
  [ "$(bk_db_field "$id" '.lock_tables' 'false')" = "true" ] && args+=(--lock-tables)

  local opt
  while IFS= read -r opt; do
    [ -n "$opt" ] && args+=("$opt")
  done <<EOF
$(bk_db_extra_dump_opts "$id")
EOF

  : >"$err"
  ( umask 077; "$(bk_mysql_dump_bin)" "${args[@]}" -- "$dbname" >"$out" ) 2>"$err"
  status=$?

  if [ "$status" -ne 0 ]; then
    return "$BK_EXIT_DUMP"
  fi
  if [ ! -s "$out" ]; then
    bk_warn "mysqldump produced an empty file for database $id"
    return "$BK_EXIT_DUMP"
  fi
  # mysqldump writes a trailing "-- Dump completed on ..." footer. Its absence
  # means the dump was truncated, which a zero exit code alone would hide.
  if [ "$(bk_db_field "$id" '.verify_footer' 'true')" = "true" ]; then
    if ! tail -c 4096 "$out" 2>/dev/null | grep -q 'Dump completed'; then
      bk_warn "mysqldump output for $id has no 'Dump completed' footer; treating as failed"
      return "$BK_EXIT_DUMP"
    fi
  fi
  return 0
}

# bk_mysql_restore DB_ID INFILE TARGET_DB
bk_mysql_restore() {
  local id="$1" infile="$2" target="$3" cnf status
  cnf="$(bk_mysql_cnf "$id")"
  bk_need_cmd "$(bk_mysql_client_bin)"

  ( umask 077; "$(bk_mysql_client_bin)" --defaults-extra-file="$cnf" -- "$target" <"$infile" )
  status=$?
  [ "$status" -eq 0 ] || return "$BK_EXIT_RESTORE"
  return 0
}

bk_mysql_env_report() {
  local id="$1"
  printf 'client: %s\n' "$(bk_mysql_client_version)"
  printf 'server: %s\n' "$(bk_mysql_server_version "$id")"
}
