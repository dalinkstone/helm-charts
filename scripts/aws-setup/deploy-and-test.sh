#!/usr/bin/env bash
# One unattended entrypoint: static gates, AWS bring-up, live infra, E2E, smoke.
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_FILE="${1:-$SCRIPT_DIR/.state/canary.env}"
if [[ -f "$CONFIG_FILE" ]]; then
  set -a
  # Operator-selected non-secret config file.
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
  set +a
elif [[ $# -gt 0 ]]; then
  echo "ERROR: config file not found: $CONFIG_FILE" >&2
  exit 1
fi

: "${EXPECTED_COMMIT:?Set EXPECTED_COMMIT to the reviewed branch HEAD}"
: "${CLUSTER_NAME:?Set CLUSTER_NAME}"
: "${BASE_DOMAIN:?Set BASE_DOMAIN}"
: "${REGION_NAME:?Set REGION_NAME}"
: "${CLUSTER_ISSUER_EMAIL:?Set CLUSTER_ISSUER_EMAIL}"
: "${AWS_REGION:?Set AWS_REGION}"
: "${S3_BUCKET:?Set S3_BUCKET}"
: "${RUNNER_IMAGE_REF:?Set RUNNER_IMAGE_REF to the verified v0.199 runner image}"
: "${DAYTONA_API_KEY:?DAYTONA_API_KEY must be forwarded by devflow}"
: "${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN must be forwarded by devflow}"

cd "$REPO_ROOT"
actual_commit="$(git rev-parse HEAD)"
[[ "$actual_commit" == "$EXPECTED_COMMIT" ]] \
  || { echo "ERROR: expected HEAD $EXPECTED_COMMIT, found $actual_commit" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] \
  || { echo "ERROR: worktree must be clean before provisioning" >&2; git status --short >&2; exit 1; }

export DAYTONA_API_URL="${DAYTONA_API_URL:-https://app.daytona.io/api}"
export RUNNER_AWS_CREDENTIAL_MODE="${RUNNER_AWS_CREDENTIAL_MODE:-static}"
export DAYTONA_IMAGE_PROFILE="${DAYTONA_IMAGE_PROFILE:-v0.199-canary}"
export AWS_NODE_VOLUME_SIZE_GB="${AWS_NODE_VOLUME_SIZE_GB:-250}"
export OMC_NONINTERACTIVE=1 OMC_YES=1

bash "$SCRIPT_DIR/preflight.sh"

echo "=== Static gates ==="
helm unittest charts/daytona-region
for check in scripts/_lib/check/*.sh; do
  bash "$check"
done
helm lint charts/daytona-region -f charts/daytona-region/tests/fixtures/baseline.values.yaml

if [[ "${BUILD_RUNNER_IMAGE:-false}" == "true" ]]; then
  runner_builder="build-runner-image.sh"
  if [[ "${RUNNER_SOURCE_BUILD:-false}" == "true" ]]; then
    runner_builder="build-runner-v0199-source.sh"
  fi
  IMAGE_REF="$RUNNER_IMAGE_REF" PUSH=true AWS_REGION="$AWS_REGION" \
    bash "$SCRIPT_DIR/$runner_builder"
else
  registry="${RUNNER_IMAGE_REF%%/*}"
  repository_and_tag="${RUNNER_IMAGE_REF#*/}"
  repository="${repository_and_tag%:*}"
  image_tag="${repository_and_tag##*:}"
  if [[ "$registry" == *.dkr.ecr.*.amazonaws.com ]]; then
    resolved_runner_digest="$(aws ecr describe-images --region "$AWS_REGION" --repository-name "$repository" \
      --image-ids "imageTag=$image_tag" --query 'imageDetails[0].imageDigest' --output text)" \
      || { echo "ERROR: runner image not found in ECR: $RUNNER_IMAGE_REF" >&2; exit 1; }
    : "${RUNNER_IMAGE_DIGEST:?Set RUNNER_IMAGE_DIGEST to the sha256 digest produced by the verified build}"
    [[ "$resolved_runner_digest" == "$RUNNER_IMAGE_DIGEST" ]] \
      || { echo "ERROR: runner image digest mismatch: expected $RUNNER_IMAGE_DIGEST, found $resolved_runner_digest" >&2; exit 1; }
  else
    docker manifest inspect "$RUNNER_IMAGE_REF" >/dev/null \
      || { echo "ERROR: runner image manifest not found: $RUNNER_IMAGE_REF" >&2; exit 1; }
    resolved_runner_digest="${RUNNER_IMAGE_DIGEST:-registry-manifest-verified}"
  fi
  echo "Verified existing runner image: $RUNNER_IMAGE_REF ($resolved_runner_digest)"
fi

if [[ "${BUILD_RUNNER_IMAGE:-false}" == "true" ]]; then
  registry="${RUNNER_IMAGE_REF%%/*}"
  repository_and_tag="${RUNNER_IMAGE_REF#*/}"
  repository="${repository_and_tag%:*}"
  image_tag="${repository_and_tag##*:}"
  resolved_runner_digest="$(aws ecr describe-images --region "$AWS_REGION" --repository-name "$repository" \
    --image-ids "imageTag=$image_tag" --query 'imageDetails[0].imageDigest' --output text)"
  [[ "$resolved_runner_digest" == sha256:* ]] \
    || { echo "ERROR: pushed runner image digest could not be resolved" >&2; exit 1; }
  echo "Built, validated, pushed, and resolved runner image: $RUNNER_IMAGE_REF ($resolved_runner_digest)"
fi

STATE_DIR="$SCRIPT_DIR/.state"
mkdir -p "$STATE_DIR"
umask 077
prompts_tmp="$(mktemp "$STATE_DIR/prompts.env.XXXXXX")"
trap 'rm -f "$prompts_tmp"' EXIT INT TERM
{
  printf 'export CLUSTER_NAME=%q\n' "$CLUSTER_NAME"
  printf 'export BASE_DOMAIN=%q\n' "$BASE_DOMAIN"
  printf 'export REGION_NAME=%q\n' "$REGION_NAME"
  printf 'export CLUSTER_ISSUER_EMAIL=%q\n' "$CLUSTER_ISSUER_EMAIL"
  printf 'export DAYTONA_API_URL=%q\n' "$DAYTONA_API_URL"
  printf 'export AWS_REGION=%q\n' "$AWS_REGION"
  printf 'export S3_BUCKET=%q\n' "$S3_BUCKET"
  printf 'export RUNNER_AWS_CREDENTIAL_MODE=%q\n' "$RUNNER_AWS_CREDENTIAL_MODE"
  printf 'export AWS_NODE_VOLUME_SIZE_GB=%q\n' "$AWS_NODE_VOLUME_SIZE_GB"
  printf 'export DAYTONA_IMAGE_PROFILE=%q\n' "$DAYTONA_IMAGE_PROFILE"
  printf 'export RUNNER_IMAGE_REF=%q\n' "$RUNNER_IMAGE_REF"
  [[ -n "${AWS_NODE_VM_SIZE:-}" ]] && printf 'export AWS_NODE_VM_SIZE=%q\n' "$AWS_NODE_VM_SIZE"
} > "$prompts_tmp"
chmod 600 "$prompts_tmp"
mv "$prompts_tmp" "$STATE_DIR/prompts.env"
trap - EXIT INT TERM

bash "$SCRIPT_DIR/up.sh"
bash "$SCRIPT_DIR/infra-test.sh"

if [[ "${RUN_STAGE_C:-true}" == "true" ]]; then
  : "${DAYTONA_ORG_ID:?RUN_STAGE_C=true requires DAYTONA_ORG_ID}"
  DAYTONA_ORG_ID="$DAYTONA_ORG_ID" bash "$SCRIPT_DIR/test/ecr-setup.sh"
  e2e_stage_c=false
else
  e2e_stage_c=true
fi

redact_stream() {
  python3 -c '
import os, sys
secrets = [os.environ.get("DAYTONA_API_KEY", ""), os.environ.get("CLOUDFLARE_API_TOKEN", "")]
secrets = [value for value in secrets if value]
for line in sys.stdin:
    for value in secrets:
        line = line.replace(value, "[REDACTED]")
    sys.stdout.write(line)
'
}

e2e_report="$STATE_DIR/e2e-$(date -u +%Y%m%dT%H%M%SZ).log"
SKIP_STAGE_C="$e2e_stage_c" bash "$SCRIPT_DIR/e2e.sh" 2>&1 \
  | redact_stream | tee "$e2e_report"
chmod 600 "$e2e_report"

if [[ "${RUN_NETWORK_SMOKE:-true}" == "true" ]]; then
  bash "$SCRIPT_DIR/network-e2e.sh"
fi

receipt="$STATE_DIR/deployment-receipt-$(date -u +%Y%m%dT%H%M%SZ).txt"
{
  echo "result=PASS"
  echo "completed=$(date -u +%FT%TZ)"
  echo "commit=$actual_commit"
  echo "aws_account=$EXPECTED_AWS_ACCOUNT_ID"
  echo "aws_region=$AWS_REGION"
  echo "cluster=$CLUSTER_NAME"
  echo "daytona_region=$REGION_NAME"
  echo "runner_image=$RUNNER_IMAGE_REF"
  echo "runner_image_digest=$resolved_runner_digest"
  echo "infra_receipts=$STATE_DIR/infra-test-*.log"
  echo "e2e_receipt=$e2e_report"
  echo "network_receipts=$STATE_DIR/network-smoke-*.log"
  echo "teardown=NOT_RUN"
} > "$receipt"
chmod 600 "$receipt"
echo "All deployment gates passed. Receipt: $receipt"
echo "The deployment remains running; teardown requires an explicit operator action."
