#!/usr/bin/env bash
# BackupKit - src/storage/s3.sh
#
# S3-compatible object storage (Cloudflare R2 and any generic S3 endpoint)
# through the AWS CLI. Uploads carry retries, explicit timeouts and a size
# verification step after the transfer; multipart uploads are handled by the
# AWS CLI itself for large files.

BK_AWS_MAJOR="${BK_AWS_MAJOR:-}"
BK_AWS_ENDPOINT_ARGS=""

bk_s3_bin() { printf 'aws'; }

bk_s3_init() {
  bk_have aws || bk_die "$BK_EXIT_DEPENDENCY" "aws CLI not found (run 'backupkit doctor' for install hints)"

  local ver
  ver="$(aws --version 2>&1 | head -1)"
  case "$ver" in
    aws-cli/2*) BK_AWS_MAJOR=2 ;;
    aws-cli/1*) BK_AWS_MAJOR=1 ;;
    *)          BK_AWS_MAJOR=2 ;;
  esac

  local access secret
  access="$(bk_storage_cred access_key '')"
  secret="$(bk_storage_cred secret_key '')"
  if [ -n "$access" ] && [ -n "$secret" ]; then
    export AWS_ACCESS_KEY_ID="$access"
    export AWS_SECRET_ACCESS_KEY="$secret"
  elif [ -n "${AWS_ACCESS_KEY_ID:-}" ] && [ -n "${AWS_SECRET_ACCESS_KEY:-}" ]; then
    bk_debug "using AWS credentials from the environment"
  else
    bk_warn "no storage credentials in secrets file and none in the environment; relying on instance profile / SSO"
  fi

  local region
  region="$(bk_cfg '.storage.region' '')"
  if [ -z "$region" ]; then
    case "$(bk_storage_provider)" in
      cloudflare-r2) region="auto" ;;
      *)             region="us-east-1" ;;
    esac
  fi
  export AWS_DEFAULT_REGION="$region"

  BK_AWS_ENDPOINT_ARGS=""
  local endpoint
  endpoint="$(bk_cfg '.storage.endpoint' '')"
  if [ -n "$endpoint" ]; then
    case "$(bk_storage_provider)" in
      cloudflare-r2)
        # R2 always needs an explicit, account-scoped endpoint.
        case "$endpoint" in
          https://*.r2.cloudflarestorage.com*) ;;
          *) bk_die "$BK_EXIT_CONFIG" "cloudflare-r2 endpoint must be https://<account_id>.r2.cloudflarestorage.com" ;;
        esac
        ;;
    esac
    BK_AWS_ENDPOINT_ARGS="--endpoint-url ${endpoint}"
  fi

  # Never let the CLI prompt or open a pager from cron.
  export AWS_PAGER=""
  export AWS_CLI_AUTO_PROMPT="off"
  return 0
}

bk_s3_uri() {
  printf 's3://%s/%s' "$(bk_storage_bucket)" "$1"
}

bk_s3_base_args() {
  # Emitted as one argument per line.
  local i
  if [ -n "$BK_AWS_ENDPOINT_ARGS" ]; then
    for i in $BK_AWS_ENDPOINT_ARGS; do printf '%s\n' "$i"; done
  fi
  printf '%s\n' --cli-connect-timeout 20
  printf '%s\n' --cli-read-timeout "$(bk_storage_timeout)"
  if [ "$BK_AWS_MAJOR" = "2" ]; then
    printf '%s\n' --no-cli-pager
  fi
}

bk_s3_upload() {
  local file="$1" key="$2" size dest
  size="$(bk_file_size "$file")"
  dest="$(bk_s3_uri "$key")"
  local args
  args=($(bk_s3_base_args))
  if [ "$BK_AWS_MAJOR" = "2" ]; then
    args+=(--no-progress)
  fi

  bk_with_retry "upload $key" "$(bk_storage_retry_attempts)" "$(bk_storage_retry_delay)" \
    "$(bk_s3_bin)" s3 cp "$file" "$dest" "${args[@]}" || return "$BK_EXIT_UPLOAD"

  # Verification: the object must exist and have exactly the local size.
  local remote
  remote="$(bk_storage_size "$key")"
  if [ "$remote" != "$size" ]; then
    bk_warn "upload verification failed for $key (size mismatch: local=$size remote=$remote)"
    return "$BK_EXIT_UPLOAD"
  fi
  return 0
}

bk_s3_put_string() {
  local str="$1" key="$2" dest
  dest="$(bk_s3_uri "$key")"
  local args
  args=($(bk_s3_base_args))
  if [ "$BK_AWS_MAJOR" = "2" ]; then
    args+=(--no-progress)
  fi
  printf '%s\n' "$str" | \
    bk_with_retry "upload $key" "$(bk_storage_retry_attempts)" "$(bk_storage_retry_delay)" \
      "$(bk_s3_bin)" s3 cp - "$dest" "${args[@]}" -
}

bk_s3_download() {
  local key="$1" file="$2" src
  src="$(bk_s3_uri "$key")"
  local args
  args=($(bk_s3_base_args))
  if [ "$BK_AWS_MAJOR" = "2" ]; then
    args+=(--no-progress)
  fi
  bk_with_retry "download $key" "$(bk_storage_retry_attempts)" "$(bk_storage_retry_delay)" \
    "$(bk_s3_bin)" s3 cp "$src" "$file" "${args[@]}"
}

bk_s3_get_string() {
  local key="$1" args
  args=($(bk_s3_base_args))
  bk_with_retry "read $key" "$(bk_storage_retry_attempts)" "$(bk_storage_retry_delay)" \
    "$(bk_s3_bin)" s3 cp "$(bk_s3_uri "$key")" - "${args[@]}"
}

bk_s3_delete() {
  local key="$1" args
  args=($(bk_s3_base_args))
  bk_with_retry "delete $key" "$(bk_storage_retry_attempts)" "$(bk_storage_retry_delay)" \
    "$(bk_s3_bin)" s3api delete-object --bucket "$(bk_storage_bucket)" --key "$key" "${args[@]}" \
    --output text >/dev/null
}

bk_s3_list() {
  local prefix="$1" args
  [ -n "$prefix" ] || return 0
  args=($(bk_s3_base_args))
  "$(bk_s3_bin)" s3api list-objects-v2 \
    --bucket "$(bk_storage_bucket)" \
    --prefix "$prefix" \
    --query 'Contents[].Key' \
    --output text "${args[@]}" 2>/dev/null | tr '\t' '\n' | grep -v '^None$' | grep -v '^$' || true
}

bk_s3_size() {
  local key="$1" out args
  args=($(bk_s3_base_args))
  out="$("$(bk_s3_bin)" s3api head-object --bucket "$(bk_storage_bucket)" --key "$key" \
    --query 'ContentLength' --output text "${args[@]}" 2>/dev/null)" || out=""
  case "$out" in
    ''|None|*[!0-9]*) printf -- '-1' ;;
    *) printf '%s' "$out" ;;
  esac
}

bk_s3_check() {
  local args
  args=($(bk_s3_base_args))
  if "$(bk_s3_bin)" s3api head-bucket --bucket "$(bk_storage_bucket)" "${args[@]}" >/dev/null 2>&1; then
    return 0
  fi
  # Fall back to a cheap listing: some providers reject HeadBucket.
  if "$(bk_s3_bin)" s3api list-objects-v2 --bucket "$(bk_storage_bucket)" --max-keys 1 \
    --query 'KeyCount' --output text "${args[@]}" >/dev/null 2>&1; then
    return 0
  fi
  bk_warn "storage check failed for bucket $(bk_storage_bucket)"
  return "$BK_EXIT_GENERAL"
}
