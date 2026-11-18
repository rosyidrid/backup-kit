#!/usr/bin/env bash
# BackupKit - src/drivers/driver.sh
#
# Database driver dispatch. Adding a database engine means adding one file in
# this directory and one case arm here.

bk_driver_kind() {
  # bk_driver_kind DB_ID -> mysql | postgres
  local type
  type="$(bk_db_type "$1")"
  case "$type" in
    mysql|mariadb)          printf 'mysql' ;;
    postgres|postgresql)    printf 'postgres' ;;
    *)                      printf '' ;;
  esac
}

bk_driver_required_cmds() {
  case "$(bk_driver_kind "$1")" in
    mysql)    bk_mysql_required_cmds ;;
    postgres) bk_pg_required_cmds ;;
    *)        printf '' ;;
  esac
}

# bk_driver_dump DB_ID ROLE OUTFILE ERRLOG
# ROLE is "primary" for the database dump, "globals" for cluster roles.
bk_driver_dump() {
  local id="$1" role="$2" out="$3" err="$4"
  case "$(bk_driver_kind "$id")" in
    mysql)
      [ "$role" = "primary" ] || bk_die "$BK_EXIT_CONFIG" "role '$role' is not supported for mysql database $id"
      bk_mysql_dump "$id" "$out" "$err"
      ;;
    postgres)
      if [ "$role" = "globals" ]; then
        bk_pg_dump_globals "$id" "$out" "$err"
      else
        bk_pg_dump "$id" "$out" "$err"
      fi
      ;;
    *)
      bk_die "$BK_EXIT_CONFIG" "unsupported database type for $id"
      ;;
  esac
}

# bk_driver_restore DB_ID ROLE INFILE TARGET
bk_driver_restore() {
  local id="$1" role="$2" infile="$3" target="$4"
  case "$(bk_driver_kind "$id")" in
    mysql)
      bk_mysql_restore "$id" "$infile" "$target"
      ;;
    postgres)
      if [ "$role" = "globals" ]; then
        bk_pg_restore_globals "$id" "$infile"
      else
        bk_pg_restore "$id" "$infile" "$target"
      fi
      ;;
    *)
      bk_die "$BK_EXIT_CONFIG" "unsupported database type for $id"
      ;;
  esac
}

bk_driver_tool_versions() {
  # Compact JSON with the client versions used, for the manifest.
  local id="$1"
  case "$(bk_driver_kind "$id")" in
    mysql)
      jq -cn --arg dump "$(bk_mysql_client_version)" --arg server "$(bk_mysql_server_version "$id")" \
        '{dump:$dump,server:$server}'
      ;;
    postgres)
      jq -cn --arg dump "$(bk_pg_client_version)" --arg server "$(bk_pg_server_version "$id")" \
        '{dump:$dump,server:$server}'
      ;;
    *) printf '{}' ;;
  esac
}
