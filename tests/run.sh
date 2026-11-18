#!/usr/bin/env bash
# BackupKit test suite runner.
#
#   tests/run.sh            run everything
#   tests/run.sh config     run test files whose name contains "config"

set -o pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
filter="${1-}"

overall=0
passed_files=0
failed_files=0

for t in "${TESTS_DIR}"/test_*.sh; do
  [ -f "$t" ] || continue
  if [ -n "$filter" ]; then
    case "$(basename "$t")" in
      *"$filter"*) ;;
      *) continue ;;
    esac
  fi
  printf '\n================ %s ================\n' "$(basename "$t")"
  if bash "$t"; then
    passed_files=$((passed_files + 1))
  else
    failed_files=$((failed_files + 1))
    overall=1
  fi
done

printf '\n================ summary ================\n'
printf 'test files: %s passed, %s failed\n' "$passed_files" "$failed_files"
exit "$overall"
