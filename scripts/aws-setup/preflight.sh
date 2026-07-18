#!/usr/bin/env bash
# Fail-fast safety checks for an unattended AWS canary deployment.
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_lib/common.sh
source "$SCRIPT_DIR/../_lib/common.sh"

omc::need_cmd aws jq curl python3

: "${EXPECTED_AWS_ACCOUNT_ID:?Set EXPECTED_AWS_ACCOUNT_ID to the account that may receive the canary}"
: "${DAYTONA_API_KEY:?DAYTONA_API_KEY must be forwarded into the sandbox}"
: "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN must be forwarded into the sandbox}"

AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
MIN_VCPU_QUOTA="${MIN_VCPU_QUOTA:-8}"
MIN_CREDENTIAL_LIFETIME_SECONDS="${MIN_CREDENTIAL_LIFETIME_SECONDS:-10800}"
DAYTONA_API_URL="${DAYTONA_API_URL:-https://app.daytona.io/api}"

identity="$(aws sts get-caller-identity --output json)"
account_id="$(jq -r '.Account' <<<"$identity")"
principal_arn="$(jq -r '.Arn' <<<"$identity")"
[[ "$account_id" == "$EXPECTED_AWS_ACCOUNT_ID" ]] \
  || omc::die "AWS account mismatch: expected $EXPECTED_AWS_ACCOUNT_ID, authenticated to $account_id"

expiration="${AWS_CREDENTIAL_EXPIRATION:-}"
[[ -n "$expiration" ]] \
  || omc::die "AWS_CREDENTIAL_EXPIRATION is missing. Use devflow --aws-profile with an expiring STS/SSO profile."
remaining_seconds="$(python3 - "$expiration" <<'PY'
from datetime import datetime, timezone
import sys

value = sys.argv[1].replace("Z", "+00:00")
expires = datetime.fromisoformat(value)
if expires.tzinfo is None:
    expires = expires.replace(tzinfo=timezone.utc)
print(int((expires - datetime.now(timezone.utc)).total_seconds()))
PY
)"
(( remaining_seconds >= MIN_CREDENTIAL_LIFETIME_SECONDS )) \
  || omc::die "AWS session expires too soon (${remaining_seconds}s remain; require ${MIN_CREDENTIAL_LIFETIME_SECONDS}s)"

quota="$(aws service-quotas get-service-quota \
  --service-code ec2 --quota-code L-1216C47A --region "$AWS_REGION" \
  --query 'Quota.Value' --output text)"
python3 - "$quota" "$MIN_VCPU_QUOTA" <<'PY' \
  || omc::die "EC2 On-Demand Standard vCPU quota is $quota; require at least $MIN_VCPU_QUOTA"
import sys
raise SystemExit(0 if float(sys.argv[1]) >= float(sys.argv[2]) else 1)
PY

daytona_http="$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer $DAYTONA_API_KEY" "$DAYTONA_API_URL/regions")"
[[ "$daytona_http" =~ ^2[0-9][0-9]$ ]] \
  || omc::die "Daytona regions API preflight failed with HTTP $daytona_http"

cloudflare_ok="$(curl -sS --max-time 20 \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  https://api.cloudflare.com/client/v4/user/tokens/verify | jq -r '.success')"
[[ "$cloudflare_ok" == "true" ]] || omc::die "Cloudflare token verification failed"
if [[ -n "${BASE_DOMAIN:-}" ]]; then
  cloudflare_zone_id="$(omc::cloudflare_zone_id "$CLOUDFLARE_API_TOKEN" "$BASE_DOMAIN" || true)"
  [[ -n "$cloudflare_zone_id" ]] \
    || omc::die "Cloudflare token cannot access the zone for $BASE_DOMAIN or any parent domain"
fi

if [[ "${BUILD_RUNNER_IMAGE:-false}" == "true" ]]; then
  omc::need_cmd docker file
  if [[ "${RUNNER_SOURCE_BUILD:-false}" != "true" ]]; then
    omc::need_cmd gh
  fi
  docker info >/dev/null 2>&1 \
    || omc::die "BUILD_RUNNER_IMAGE=true requires a Docker-in-Docker-capable sandbox with a running daemon"
fi

cat <<EOF
AWS deployment preflight passed
  account:              $account_id
  principal:            $principal_arn
  region:               $AWS_REGION
  credential expiration:$expiration (${remaining_seconds}s remain)
  standard vCPU quota:  $quota
  Daytona API:          reachable and authorized
  Cloudflare API:       token valid
  Cloudflare DNS zone:  accessible for ${BASE_DOMAIN:-<checked during bring-up>}
EOF
