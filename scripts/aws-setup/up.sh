#!/usr/bin/env bash
# scripts/aws-setup/up.sh — K8s-native Daytona BYOC bring-up on AWS EKS.
#
# Single interactive entrypoint that:
#   1. prompts for cluster name, base domain, region, credentials
#   2. creates EKS cluster (with OIDC) + node pool with daytona-sandbox-c label + taint
#   3. creates S3 bucket (snapshots + build context)
#   4. creates IAM user + access keys (static mode) OR IAM role (IRSA mode)
#   5. updates kubeconfig
#   6. installs ingress-nginx + cert-manager + Let's Encrypt ClusterIssuer
#   7. waits for LoadBalancer hostname, prints DNS records to create
#   8. waits for operator to confirm DNS propagation
#   9. generates SSH gateway keypairs, renders values-region.yaml.tmpl and
#      helm-installs daytona-region
#  10. post-registration: swaps in the region-scoped ssh-gateway api key and
#      advertises the gateway LoadBalancer to Daytona Cloud
#   10. prints the proxy URL for sandbox-create testing
#
# Idempotent: re-runnable if interrupted. State persists in .state/.
# Operator runs against a real AWS account; this script never executes in CI.
# See docs/aws.md for the deployment guide.
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_lib/common.sh
source "$SCRIPT_DIR/../_lib/common.sh"
# shellcheck source=../_lib/sku-data.sh
source "$SCRIPT_DIR/../_lib/sku-data.sh"
# shellcheck source=../_lib/sku-aws.sh
source "$SCRIPT_DIR/../_lib/sku-aws.sh"

omc::need_cmd aws eksctl kubectl helm envsubst yq jq ssh-keygen openssl curl

STATE_DIR="$(omc::state_dir "$SCRIPT_DIR")"
PROMPTS_FILE="$STATE_DIR/prompts.env"
VALUES_OUT="$STATE_DIR/values-region.yaml"
CLUSTER_CONFIG="$STATE_DIR/cluster.yaml"
TRUST_POLICY="$STATE_DIR/trust-policy.json"
S3_POLICY="$STATE_DIR/s3-policy.json"
CLUSTER_AUTOSCALER_POLICY="$STATE_DIR/cluster-autoscaler-policy.json"
CLUSTER_AUTOSCALER_VALUES="$STATE_DIR/cluster-autoscaler-values.yaml"
RUNNER_MANAGER_AUTH_FILE="$STATE_DIR/runner-manager-auth.env"

# Stable, per-deployment bootstrap credentials. The manager uses API_KEY for
# its own protected endpoints; SYSTEM_API_TOKEN authenticates its one-time
# /system/config call to each chart-managed runner. Both remain in mode-0600
# state and Kubernetes Secrets, never command-line arguments or ConfigMaps.
if [[ -f "$RUNNER_MANAGER_AUTH_FILE" ]]; then
  # shellcheck source=/dev/null
  . "$RUNNER_MANAGER_AUTH_FILE"
else
  umask 077
  RUNNER_MANAGER_API_KEY="$(openssl rand -hex 32)"
  RUNNER_SYSTEM_API_TOKEN="$(openssl rand -hex 32)"
  {
    printf 'export RUNNER_MANAGER_API_KEY=%q\n' "$RUNNER_MANAGER_API_KEY"
    printf 'export RUNNER_SYSTEM_API_TOKEN=%q\n' "$RUNNER_SYSTEM_API_TOKEN"
  } > "$RUNNER_MANAGER_AUTH_FILE"
  chmod 600 "$RUNNER_MANAGER_AUTH_FILE"
fi
: "${RUNNER_MANAGER_API_KEY:?runner-manager auth state is missing RUNNER_MANAGER_API_KEY}"
: "${RUNNER_SYSTEM_API_TOKEN:?runner-manager auth state is missing RUNNER_SYSTEM_API_TOKEN}"

# Re-use prompts from prior partial run, if any.
if [[ -f "$PROMPTS_FILE" ]]; then
  omc::log INFO "Loading saved prompts from $PROMPTS_FILE"
  set -a
  # shellcheck source=/dev/null
  . "$PROMPTS_FILE"
  set +a
else
  omc::log INFO "No saved prompts found; honoring pre-set environment values and prompting only for missing inputs."
fi

# === 1. Interactive prompts ==================================================
omc::log INFO "=== Daytona BYOC: AWS EKS bring-up ==="
omc::log INFO "NOTE: this assumes your base domain's DNS is hosted on Cloudflare."
omc::log INFO "      TLS certs (DNS-01) and the proxy/snapshot DNS records are created via"
omc::log INFO "      the Cloudflare API, so you'll be asked for a Cloudflare API token below"
omc::log INFO "      (Zone:Read + Zone DNS:Edit, scoped to your domain's zone)."
omc::prompt CLUSTER_NAME "Cluster name" "daytona-byoc-$(date +%Y%m%d-%H%M%S)"
omc::prompt BASE_DOMAIN  "Public base DNS domain (e.g. byoc.example.com)"
omc::prompt_secret CLOUDFLARE_API_TOKEN "Cloudflare API token (Zone:Read + Zone DNS:Edit)"
omc::prompt REGION_NAME  "Daytona region name" "${CLUSTER_NAME}"
omc::prompt CLUSTER_ISSUER_EMAIL "Email for Let's Encrypt ClusterIssuer"
omc::prompt DAYTONA_API_URL "Daytona Cloud API URL" "https://app.daytona.io/api"
omc::prompt_secret DAYTONA_API_KEY "Daytona Cloud admin API key"
omc::prompt AWS_REGION   "AWS region" "us-east-1"
omc::prompt S3_BUCKET    "S3 bucket name (snapshots + build context)" "${CLUSTER_NAME}-snapshots"
omc::prompt RUNNER_AWS_CREDENTIAL_MODE "Runner credential mode (static or irsa)" "static"
omc::prompt DAYTONA_IMAGE_PROFILE "Daytona image profile (parity or v0.199-canary)" "parity"
omc::prompt AWS_NODE_VOLUME_SIZE_GB "Sandbox node root volume size in GiB" "250"
omc::prompt RUNNER_MIN_COUNT "Minimum ready runners / EKS sandbox nodes" "3"
omc::prompt RUNNER_MAX_COUNT "Maximum runners / EKS sandbox nodes" "10"
omc::prompt RUNNER_SCALE_UP_THRESHOLD "Runner availability score that triggers scale-up" "25"
omc::prompt RUNNER_SCALE_DOWN_THRESHOLD "Runner availability score that triggers scale-down" "75"
omc::prompt RUNNER_MAXIMUM_CONCURRENT_INITIALIZING "Maximum runners initializing concurrently" "2"
omc::prompt RUNNER_MAXIMUM_CONCURRENT_DRAINING "Maximum runners draining concurrently" "1"
omc::prompt RUNNER_SCALE_DOWN_STABILIZATION_SECONDS "Unschedulable stabilization delay before scale-down" "30"
CLUSTER_AUTOSCALER_CHART_VERSION="${CLUSTER_AUTOSCALER_CHART_VERSION:-9.58.0}"

if [[ "$RUNNER_AWS_CREDENTIAL_MODE" != "static" && "$RUNNER_AWS_CREDENTIAL_MODE" != "irsa" ]]; then
  omc::die "RUNNER_AWS_CREDENTIAL_MODE must be 'static' or 'irsa' (got: $RUNNER_AWS_CREDENTIAL_MODE)"
fi
if [[ ! "$AWS_NODE_VOLUME_SIZE_GB" =~ ^[0-9]+$ ]] || (( AWS_NODE_VOLUME_SIZE_GB < 100 )); then
  omc::die "AWS_NODE_VOLUME_SIZE_GB must be an integer >= 100 (got: $AWS_NODE_VOLUME_SIZE_GB)"
fi
if [[ ! "$RUNNER_MIN_COUNT" =~ ^[0-9]+$ ]] || (( RUNNER_MIN_COUNT < 3 )); then
  omc::die "RUNNER_MIN_COUNT must be an integer >= 3 (got: $RUNNER_MIN_COUNT)"
fi
if [[ ! "$RUNNER_MAX_COUNT" =~ ^[0-9]+$ ]] || (( RUNNER_MAX_COUNT < RUNNER_MIN_COUNT )); then
  omc::die "RUNNER_MAX_COUNT must be an integer >= RUNNER_MIN_COUNT ($RUNNER_MIN_COUNT; got: $RUNNER_MAX_COUNT)"
fi
if [[ ! "$RUNNER_SCALE_UP_THRESHOLD" =~ ^[0-9]+$ ]] || (( RUNNER_SCALE_UP_THRESHOLD < 1 || RUNNER_SCALE_UP_THRESHOLD > 99 )); then
  omc::die "RUNNER_SCALE_UP_THRESHOLD must be an integer from 1 through 99 (got: $RUNNER_SCALE_UP_THRESHOLD)"
fi
if [[ ! "$RUNNER_SCALE_DOWN_THRESHOLD" =~ ^[0-9]+$ ]] || (( RUNNER_SCALE_DOWN_THRESHOLD < 1 || RUNNER_SCALE_DOWN_THRESHOLD > 100 || RUNNER_SCALE_DOWN_THRESHOLD <= RUNNER_SCALE_UP_THRESHOLD )); then
  omc::die "RUNNER_SCALE_DOWN_THRESHOLD must be greater than RUNNER_SCALE_UP_THRESHOLD and <= 100 (got: $RUNNER_SCALE_DOWN_THRESHOLD)"
fi
for count_var in RUNNER_MAXIMUM_CONCURRENT_INITIALIZING RUNNER_MAXIMUM_CONCURRENT_DRAINING RUNNER_SCALE_DOWN_STABILIZATION_SECONDS; do
  count_value="${!count_var}"
  if [[ ! "$count_value" =~ ^[0-9]+$ ]] || (( count_value < 1 )); then
    omc::die "$count_var must be a positive integer (got: $count_value)"
  fi
done

# A private v0.199 runner also supplies the embedded sandbox daemon/toolbox.
# The remaining tags are the newest public combination selected for this
# controlled compatibility canary; this is not a claim of vendor support.
DAYTONA_IMAGE_BUNDLE_NAME=""
DAYTONA_ALLOW_VERSION_SKEW=false
DAYTONA_PROXY_IMAGE_TAG=""
DAYTONA_SNAPSHOT_MANAGER_IMAGE_TAG=""
DAYTONA_SSH_GATEWAY_IMAGE_TAG=""
DAYTONA_RUNNER_MANAGER_IMAGE_TAG=""
RUNNER_MANAGER_IMAGE_REGISTRY="docker.io"
RUNNER_MANAGER_IMAGE_REPOSITORY="daytonaio/daytona-runner-manager"
RUNNER_IMAGE_REGISTRY="docker.io"
RUNNER_IMAGE_REPOSITORY="daytonaio/daytona-runner"
RUNNER_IMAGE_TAG=""
case "$DAYTONA_IMAGE_PROFILE" in
  parity)
    ;;
  v0.199-canary)
    omc::prompt RUNNER_IMAGE_REF \
      "Private v0.199 runner image (registry/repository:tag)" \
      "${RUNNER_IMAGE_REF:-}"
    [[ "$RUNNER_IMAGE_REF" == */*:* ]] \
      || omc::die "RUNNER_IMAGE_REF must be registry/repository:tag (got: $RUNNER_IMAGE_REF)"
    omc::prompt RUNNER_MANAGER_IMAGE_REF \
      "Patched v0.199-compatible runner-manager image (registry/repository:tag)" \
      "${RUNNER_MANAGER_IMAGE_REF:-}"
    [[ "$RUNNER_MANAGER_IMAGE_REF" == */*:* ]] \
      || omc::die "RUNNER_MANAGER_IMAGE_REF must be registry/repository:tag (got: $RUNNER_MANAGER_IMAGE_REF)"
    RUNNER_IMAGE_REGISTRY="${RUNNER_IMAGE_REF%%/*}"
    runner_image_path="${RUNNER_IMAGE_REF#*/}"
    RUNNER_IMAGE_REPOSITORY="${runner_image_path%:*}"
    RUNNER_IMAGE_TAG="${runner_image_path##*:}"
    RUNNER_MANAGER_IMAGE_REGISTRY="${RUNNER_MANAGER_IMAGE_REF%%/*}"
    runner_manager_image_path="${RUNNER_MANAGER_IMAGE_REF#*/}"
    RUNNER_MANAGER_IMAGE_REPOSITORY="${runner_manager_image_path%:*}"
    DAYTONA_RUNNER_MANAGER_IMAGE_TAG="${runner_manager_image_path##*:}"
    DAYTONA_IMAGE_BUNDLE_NAME="control-v0.199-runner-canary"
    DAYTONA_ALLOW_VERSION_SKEW=true
    DAYTONA_PROXY_IMAGE_TAG="v0.189.0-amd64"
    DAYTONA_SNAPSHOT_MANAGER_IMAGE_TAG="v0.189.0-amd64"
    DAYTONA_SSH_GATEWAY_IMAGE_TAG="v0.189.0-amd64"
    ;;
  *)
    omc::die "DAYTONA_IMAGE_PROFILE must be 'parity' or 'v0.199-canary' (got: $DAYTONA_IMAGE_PROFILE)"
    ;;
esac

# Persist prompts so re-runs reuse them.
{
  printf 'export CLUSTER_NAME=%q\n' "$CLUSTER_NAME"
  printf 'export BASE_DOMAIN=%q\n'  "$BASE_DOMAIN"
  printf 'export REGION_NAME=%q\n'  "$REGION_NAME"
  printf 'export CLUSTER_ISSUER_EMAIL=%q\n' "$CLUSTER_ISSUER_EMAIL"
  printf 'export DAYTONA_API_URL=%q\n' "$DAYTONA_API_URL"
  printf 'export AWS_REGION=%q\n'   "$AWS_REGION"
  printf 'export S3_BUCKET=%q\n'    "$S3_BUCKET"
  printf 'export RUNNER_AWS_CREDENTIAL_MODE=%q\n' "$RUNNER_AWS_CREDENTIAL_MODE"
  printf 'export AWS_NODE_VOLUME_SIZE_GB=%q\n' "$AWS_NODE_VOLUME_SIZE_GB"
  printf 'export RUNNER_MIN_COUNT=%q\n' "$RUNNER_MIN_COUNT"
  printf 'export RUNNER_MAX_COUNT=%q\n' "$RUNNER_MAX_COUNT"
  printf 'export RUNNER_SCALE_UP_THRESHOLD=%q\n' "$RUNNER_SCALE_UP_THRESHOLD"
  printf 'export RUNNER_SCALE_DOWN_THRESHOLD=%q\n' "$RUNNER_SCALE_DOWN_THRESHOLD"
  printf 'export RUNNER_MAXIMUM_CONCURRENT_INITIALIZING=%q\n' "$RUNNER_MAXIMUM_CONCURRENT_INITIALIZING"
  printf 'export RUNNER_MAXIMUM_CONCURRENT_DRAINING=%q\n' "$RUNNER_MAXIMUM_CONCURRENT_DRAINING"
  printf 'export RUNNER_SCALE_DOWN_STABILIZATION_SECONDS=%q\n' "$RUNNER_SCALE_DOWN_STABILIZATION_SECONDS"
  printf 'export CLUSTER_AUTOSCALER_CHART_VERSION=%q\n' "$CLUSTER_AUTOSCALER_CHART_VERSION"
  printf 'export DAYTONA_IMAGE_PROFILE=%q\n' "$DAYTONA_IMAGE_PROFILE"
  printf 'export RUNNER_IMAGE_REF=%q\n' "${RUNNER_IMAGE_REF:-}"
  printf 'export RUNNER_MANAGER_IMAGE_REF=%q\n' "${RUNNER_MANAGER_IMAGE_REF:-}"
} > "$PROMPTS_FILE"
chmod 600 "$PROMPTS_FILE"
omc::log INFO "Prompts saved: $PROMPTS_FILE"

# === 1.5 Quota-aware instance type selection ================================
# Sandbox managed node group needs >= 4 vCPU per node within L-1216C47A quota.
if [[ -z "${AWS_NODE_VM_SIZE:-}" ]]; then
  AWS_NODE_VM_SIZE="$(omc::aws_select_instance_type "$AWS_REGION" 4 OMC_INSTANCE_TYPE)"
  printf 'export AWS_NODE_VM_SIZE=%q\n' "$AWS_NODE_VM_SIZE" >> "$PROMPTS_FILE"
fi
omc::log INFO "Using AWS instance type: $AWS_NODE_VM_SIZE"

# === 2. EKS cluster ==========================================================
omc::log INFO "=== Step 2/11: EKS cluster ==="
# eksctl resolves the Ubuntu2404 AMI family only for k8s versions Canonical has
# published a 24.04 image for IN THIS REGION; a hardcoded version without one
# fails with "unable to determine AMI ... image family Ubuntu2404". Honor an
# explicit EKS_VERSION, else auto-detect the newest EKS-supported version that
# has a 24.04 AMI in the region.
if [[ -z "${EKS_VERSION:-}" ]]; then
  EKS_VERSION="$(omc::aws_eks_ubuntu2404_version "$AWS_REGION" || true)"
  [[ -n "$EKS_VERSION" ]] || omc::die "No Canonical Ubuntu 24.04 EKS AMI found in $AWS_REGION. Set EKS_VERSION=<x.yy> and re-run. List options: aws ec2 describe-images --region $AWS_REGION --owners 099720109477 --filters 'Name=name,Values=ubuntu-eks/k8s_*/*24.04*amd64*' --query 'Images[].Name' --output text | grep -oE 'k8s_[0-9]+\\.[0-9]+' | sort -u"
fi
omc::log INFO "EKS version (Ubuntu 24.04 AMI available in $AWS_REGION): $EKS_VERSION"
CLUSTER_AUTOSCALER_IMAGE_TAG="${CLUSTER_AUTOSCALER_IMAGE_TAG:-v${EKS_VERSION}.0}"
if [[ "$CLUSTER_AUTOSCALER_IMAGE_TAG" != "v${EKS_VERSION}."* ]]; then
  omc::die "Cluster Autoscaler minor must match EKS $EKS_VERSION (got: $CLUSTER_AUTOSCALER_IMAGE_TAG)"
fi
{
  printf 'export EKS_VERSION=%q\n' "$EKS_VERSION"
  printf 'export CLUSTER_AUTOSCALER_IMAGE_TAG=%q\n' "$CLUSTER_AUTOSCALER_IMAGE_TAG"
} >> "$PROMPTS_FILE"
if eksctl get cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  omc::log INFO "EKS cluster $CLUSTER_NAME already exists in $AWS_REGION"
else
  cat > "$CLUSTER_CONFIG" <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_REGION}
  version: "${EKS_VERSION}"

iam:
  withOIDC: true

managedNodeGroups:
  - name: sandbox
    # Runner-manager and the EKS node group share one capacity envelope. Three
    # nodes stay warm by default; Cluster Autoscaler may grow the pool to the
    # configured maximum when runner-manager creates pending placeholders.
    desiredCapacity: ${RUNNER_MIN_COUNT}
    minSize: ${RUNNER_MIN_COUNT}
    maxSize: ${RUNNER_MAX_COUNT}
    instanceType: ${AWS_NODE_VM_SIZE}
    amiFamily: Ubuntu2404
    # Cluster Autoscaler ASG auto-discovery requires both tags. Keep these even
    # though the controller uses a dedicated IRSA identity.
    tags:
      k8s.io/cluster-autoscaler/enabled: "true"
      k8s.io/cluster-autoscaler/${CLUSTER_NAME}: "owned"
    labels:
      daytona-sandbox-c: "true"
    taints:
      - key: sandbox
        value: "true"
        effect: NoSchedule
    volumeSize: ${AWS_NODE_VOLUME_SIZE_GB}
EOF
  omc::log INFO "Creating EKS cluster (this takes 15-20 min)..."
  eksctl create cluster -f "$CLUSTER_CONFIG"
fi

nodegroup_scaling="$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name sandbox \
  --region "$AWS_REGION" --query 'nodegroup.scalingConfig' --output json)"
current_min="$(jq -r '.minSize' <<<"$nodegroup_scaling")"
current_max="$(jq -r '.maxSize' <<<"$nodegroup_scaling")"
current_desired="$(jq -r '.desiredSize' <<<"$nodegroup_scaling")"
if (( current_desired > RUNNER_MAX_COUNT )); then
  omc::die "Current sandbox node-group desired capacity ($current_desired) exceeds requested RUNNER_MAX_COUNT ($RUNNER_MAX_COUNT). Let runner-manager drain idle capacity first; up.sh will not force an unsafe scale-in."
fi
desired_target="$current_desired"
if (( desired_target < RUNNER_MIN_COUNT )); then
  desired_target="$RUNNER_MIN_COUNT"
fi
if [[ "$current_min" != "$RUNNER_MIN_COUNT" || "$current_max" != "$RUNNER_MAX_COUNT" || "$current_desired" -lt "$RUNNER_MIN_COUNT" ]]; then
  omc::log INFO "Reconciling sandbox node group: min=$RUNNER_MIN_COUNT desired=$desired_target max=$RUNNER_MAX_COUNT"
  aws eks update-nodegroup-config --cluster-name "$CLUSTER_NAME" --nodegroup-name sandbox \
    --region "$AWS_REGION" \
    --scaling-config "minSize=$RUNNER_MIN_COUNT,maxSize=$RUNNER_MAX_COUNT,desiredSize=$desired_target" \
    >/dev/null
  aws eks wait nodegroup-active --cluster-name "$CLUSTER_NAME" --nodegroup-name sandbox --region "$AWS_REGION"
fi

# === 3. S3 bucket ============================================================
omc::log INFO "=== Step 3/11: S3 bucket ==="
if aws s3api head-bucket --bucket "$S3_BUCKET" >/dev/null 2>&1; then
  omc::log INFO "S3 bucket $S3_BUCKET already exists"
else
  if [[ "$AWS_REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$S3_BUCKET" --region "$AWS_REGION"
  else
    aws s3api create-bucket --bucket "$S3_BUCKET" --region "$AWS_REGION" \
      --create-bucket-configuration "LocationConstraint=$AWS_REGION"
  fi
  omc::log INFO "Created S3 bucket: $S3_BUCKET"
fi

# === 4. IAM (static user OR IRSA role) =======================================
omc::log INFO "=== Step 4/11: IAM (mode=$RUNNER_AWS_CREDENTIAL_MODE) ==="

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
S3_POLICY_NAME="${CLUSTER_NAME}-s3"
cat > "$S3_POLICY" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:GetBucketLocation",
      "s3:ListBucketMultipartUploads",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts"
    ],
    "Resource": [
      "arn:aws:s3:::${S3_BUCKET}",
      "arn:aws:s3:::${S3_BUCKET}/*"
    ]
  }]
}
EOF

S3_POLICY_ARN=""
if aws iam get-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${S3_POLICY_NAME}" >/dev/null 2>&1; then
  S3_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${S3_POLICY_NAME}"
  omc::log INFO "Reusing IAM policy: $S3_POLICY_ARN"
else
  S3_POLICY_ARN="$(aws iam create-policy \
    --policy-name "$S3_POLICY_NAME" \
    --policy-document "file://$S3_POLICY" \
    --query 'Policy.Arn' --output text)"
  omc::log INFO "Created IAM policy: $S3_POLICY_ARN"
fi

IAM_ACCESS_KEY=""
IAM_SECRET_KEY=""
IRSA_ROLE_ARN=""

if [[ "$RUNNER_AWS_CREDENTIAL_MODE" == "static" ]]; then
  IAM_USER="${CLUSTER_NAME}-daytona"
  if ! aws iam get-user --user-name "$IAM_USER" >/dev/null 2>&1; then
    aws iam create-user --user-name "$IAM_USER" >/dev/null
    omc::log INFO "Created IAM user: $IAM_USER"
  fi
  aws iam attach-user-policy --user-name "$IAM_USER" --policy-arn "$S3_POLICY_ARN" 2>/dev/null || true

  IAM_KEYS_FILE="$STATE_DIR/iam-keys.env"
  if [[ -f "$IAM_KEYS_FILE" ]]; then
    # shellcheck source=/dev/null
    . "$IAM_KEYS_FILE"
    omc::log INFO "Reusing IAM access keys from $IAM_KEYS_FILE"
  else
    KEY_JSON="$(aws iam create-access-key --user-name "$IAM_USER")"
    IAM_ACCESS_KEY="$(echo "$KEY_JSON" | jq -r .AccessKey.AccessKeyId)"
    IAM_SECRET_KEY="$(echo "$KEY_JSON" | jq -r .AccessKey.SecretAccessKey)"
    {
      printf 'export IAM_ACCESS_KEY=%q\n' "$IAM_ACCESS_KEY"
      printf 'export IAM_SECRET_KEY=%q\n' "$IAM_SECRET_KEY"
    } > "$IAM_KEYS_FILE"
    chmod 600 "$IAM_KEYS_FILE"
    omc::log INFO "Created IAM access keys (saved to $IAM_KEYS_FILE, 0600)"
  fi
else
  # IRSA mode: trust policy bound to cluster OIDC + runner SA.
  OIDC_HOST="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --query 'cluster.identity.oidc.issuer' --output text | sed 's|https://||')"
  RUNNER_SA="${CLUSTER_NAME}-daytona-region-runner"
  IRSA_ROLE_NAME="${CLUSTER_NAME}-runner-irsa"
  cat > "$TRUST_POLICY" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_HOST}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_HOST}:aud": "sts.amazonaws.com",
        "${OIDC_HOST}:sub": "system:serviceaccount:daytona:${RUNNER_SA}"
      }
    }
  }]
}
EOF
  if aws iam get-role --role-name "$IRSA_ROLE_NAME" >/dev/null 2>&1; then
    IRSA_ROLE_ARN="$(aws iam get-role --role-name "$IRSA_ROLE_NAME" --query 'Role.Arn' --output text)"
    omc::log INFO "Reusing IRSA role: $IRSA_ROLE_ARN"
  else
    IRSA_ROLE_ARN="$(aws iam create-role \
      --role-name "$IRSA_ROLE_NAME" \
      --assume-role-policy-document "file://$TRUST_POLICY" \
      --query 'Role.Arn' --output text)"
    omc::log INFO "Created IRSA role: $IRSA_ROLE_ARN"
  fi
  aws iam attach-role-policy --role-name "$IRSA_ROLE_NAME" --policy-arn "$S3_POLICY_ARN" 2>/dev/null || true
  omc::log WARN "IRSA mode: upstream runner currently hard-requires non-empty AWS_ACCESS_KEY_ID/SECRET."
  omc::log WARN "See docs/issues-summary.md. For working v1 tests, use --static."
fi

# === 5. kubeconfig ===========================================================
omc::log INFO "=== Step 5/11: kubeconfig ==="
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"
kubectl config current-context

# === 5b. ENFORCE Ubuntu 24.04 on the sandbox node pool ======================
# The Daytona helm chart docker-installer targets Ubuntu 24.04 (noble) .deb
# packages directly. NO EXCEPTIONS — fail-fast if anything else.
omc::verify_node_ubuntu "24.04" "daytona-sandbox-c=true" 300

# === 5b2. Enforce the configured warm-runner minimum =========================
# Each sandbox node runs exactly one runner. Keep three ready by default so a
# roll or loss still leaves two healthy peers for scheduling and migration.
READY_SANDBOX_NODES="$(kubectl get nodes -l daytona-sandbox-c=true --no-headers 2>/dev/null | awk '$2=="Ready"{c++} END{print c+0}')"
if [[ "${READY_SANDBOX_NODES:-0}" -lt "$RUNNER_MIN_COUNT" ]]; then
  omc::die "Need >= $RUNNER_MIN_COUNT Ready sandbox nodes (have ${READY_SANDBOX_NODES:-0}); check the sandbox node-group scaling configuration."
fi
omc::log INFO "Ready sandbox nodes: $READY_SANDBOX_NODES (configured minimum: $RUNNER_MIN_COUNT)"

# === 5c. CoreDNS must tolerate the sandbox taint ============================
# The only node pool is tainted sandbox=true:NoSchedule. CoreDNS (kube-system
# Deployment) won't schedule without tolerating it, leaving the cluster with no
# DNS — so in-cluster calls (region registration -> app.daytona.io) fail to
# resolve. Patch it before installing anything that needs DNS.
omc::log INFO "=== Step 5c: CoreDNS sandbox-taint toleration ==="
omc::coredns_tolerate_taint sandbox true NoSchedule

# === 5d. Cluster Autoscaler (AWS node-capacity actuator) =====================
# Runner-manager owns Daytona capacity decisions and creates anti-affined
# placeholder Pods. Cluster Autoscaler is the separate Kubernetes controller
# that turns an unschedulable placeholder into an EKS managed-node-group scale
# operation. It uses a dedicated IRSA role; human AWS SSO is not involved.
omc::log INFO "=== Step 6/11: Cluster Autoscaler $CLUSTER_AUTOSCALER_IMAGE_TAG (chart $CLUSTER_AUTOSCALER_CHART_VERSION) ==="
CLUSTER_AUTOSCALER_POLICY_NAME="${CLUSTER_NAME}-cluster-autoscaler"
CLUSTER_AUTOSCALER_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${CLUSTER_AUTOSCALER_POLICY_NAME}"
CLUSTER_AUTOSCALER_ROLE_NAME="${CLUSTER_NAME:0:40}-cluster-autoscaler"
cat > "$CLUSTER_AUTOSCALER_POLICY" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DescribeAutoScalingInstances",
        "autoscaling:DescribeLaunchConfigurations",
        "autoscaling:DescribeScalingActivities",
        "autoscaling:DescribeTags",
        "ec2:DescribeImages",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeLaunchTemplateVersions",
        "ec2:GetInstanceTypesFromInstanceRequirements",
        "eks:DescribeNodegroup"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "autoscaling:SetDesiredCapacity",
        "autoscaling:TerminateInstanceInAutoScalingGroup"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/k8s.io/cluster-autoscaler/enabled": "true",
          "aws:ResourceTag/k8s.io/cluster-autoscaler/${CLUSTER_NAME}": "owned"
        }
      }
    }
  ]
}
EOF
if ! aws iam get-policy --policy-arn "$CLUSTER_AUTOSCALER_POLICY_ARN" >/dev/null 2>&1; then
  CLUSTER_AUTOSCALER_POLICY_ARN="$(aws iam create-policy \
    --policy-name "$CLUSTER_AUTOSCALER_POLICY_NAME" \
    --policy-document "file://$CLUSTER_AUTOSCALER_POLICY" \
    --query 'Policy.Arn' --output text)"
fi

eksctl create iamserviceaccount \
  --cluster "$CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --namespace kube-system \
  --name cluster-autoscaler \
  --role-name "$CLUSTER_AUTOSCALER_ROLE_NAME" \
  --attach-policy-arn "$CLUSTER_AUTOSCALER_POLICY_ARN" \
  --override-existing-serviceaccounts \
  --approve

cat > "$CLUSTER_AUTOSCALER_VALUES" <<EOF
fullnameOverride: cluster-autoscaler
cloudProvider: aws
awsRegion: ${AWS_REGION}
autoDiscovery:
  clusterName: ${CLUSTER_NAME}
image:
  tag: ${CLUSTER_AUTOSCALER_IMAGE_TAG}
rbac:
  serviceAccount:
    create: false
    name: cluster-autoscaler
priorityClassName: system-cluster-critical
extraArgs:
  balance-similar-node-groups: "true"
  expander: least-waste
  scan-interval: 10s
  scale-down-unneeded-time: 10m
  skip-nodes-with-system-pods: "false"
tolerations:
  - key: sandbox
    operator: Equal
    value: "true"
    effect: NoSchedule
EOF
helm repo add autoscaler https://kubernetes.github.io/autoscaler --force-update
helm repo update autoscaler
helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \
  --namespace kube-system \
  --version "$CLUSTER_AUTOSCALER_CHART_VERSION" \
  --values "$CLUSTER_AUTOSCALER_VALUES" \
  --wait --timeout 10m
kubectl -n kube-system rollout status deployment/cluster-autoscaler --timeout=10m
autoscaler_image="$(kubectl -n kube-system get deployment cluster-autoscaler \
  -o jsonpath='{.spec.template.spec.containers[0].image}')"
[[ "$autoscaler_image" == *":${CLUSTER_AUTOSCALER_IMAGE_TAG}" ]] \
  || omc::die "Cluster Autoscaler image mismatch: expected tag $CLUSTER_AUTOSCALER_IMAGE_TAG, got $autoscaler_image"

# === 7. Namespace ============================================================
omc::log INFO "=== Step 7/11: daytona namespace ==="
kubectl create namespace daytona --dry-run=client -o yaml | kubectl apply -f -

# === 8. ingress-nginx + cert-manager + ClusterIssuer =========================
omc::log INFO "=== Step 8/11: ingress-nginx + cert-manager ==="
omc::ingress_nginx_install
omc::cert_manager_install
# Wildcard SANs (*.proxy.<domain>) for per-sandbox preview certs can only be
# issued via DNS-01. If a Cloudflare API token is supplied, use the DNS-01
# issuer and enable the wildcard SAN; otherwise install the HTTP-01 issuer and
# keep the proxy cert NON-wildcard so it actually issues (Let's Encrypt cannot
# satisfy a wildcard over HTTP-01). See docs/troubleshooting.md.
if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  omc::cluster_issuer_apply_cf_dns01 "$CLUSTER_ISSUER_EMAIL" "$CLOUDFLARE_API_TOKEN"
  PROXY_WILDCARD_TLS=true
else
  omc::cluster_issuer_apply "$CLUSTER_ISSUER_EMAIL"
  PROXY_WILDCARD_TLS=false
fi
export PROXY_WILDCARD_TLS

# === 9. Wait for LoadBalancer + DNS records ==================================
omc::log INFO "=== Step 9/11: Wait for LoadBalancer + DNS ==="
LB_TARGET="$(omc::wait_lb_address ingress-nginx ingress-nginx-controller 300)"
omc::log INFO "LoadBalancer target: $LB_TARGET"
if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  # Cloudflare token present -> create the routing records programmatically
  # (proxy / *.proxy / snapshots -> the NLB) instead of asking the operator to
  # do it by hand, so the whole run is unattended.
  omc::cloudflare_region_dns "$CLOUDFLARE_API_TOKEN" "$BASE_DOMAIN" "$LB_TARGET"
  omc::log INFO "Waiting 45s for DNS to propagate before continuing..."
  sleep 45
else
  omc::print_dns_records "$BASE_DOMAIN" "$LB_TARGET"
  omc::confirm "Have you created the DNS records above and waited for propagation?" \
    || omc::die "Aborted by operator. Re-run after creating DNS records."
fi

# === 10. SSH keys + render values + helm install =============================
omc::log INFO "=== Step 10/11: helm install daytona-region ==="
omc::ssh_keys_ensure "$STATE_DIR"
export CLUSTER_NAME BASE_DOMAIN REGION_NAME DAYTONA_API_URL DAYTONA_API_KEY \
       AWS_REGION S3_BUCKET RUNNER_AWS_CREDENTIAL_MODE \
       IAM_ACCESS_KEY IAM_SECRET_KEY IRSA_ROLE_ARN INTERNAL_REGISTRY_HOST="" \
       DAYTONA_IMAGE_BUNDLE_NAME DAYTONA_ALLOW_VERSION_SKEW \
       DAYTONA_PROXY_IMAGE_TAG DAYTONA_SNAPSHOT_MANAGER_IMAGE_TAG \
       DAYTONA_SSH_GATEWAY_IMAGE_TAG DAYTONA_RUNNER_MANAGER_IMAGE_TAG \
       RUNNER_MANAGER_IMAGE_REGISTRY RUNNER_MANAGER_IMAGE_REPOSITORY \
       RUNNER_MANAGER_API_KEY RUNNER_SYSTEM_API_TOKEN \
       RUNNER_MIN_COUNT RUNNER_MAX_COUNT \
       RUNNER_SCALE_UP_THRESHOLD RUNNER_SCALE_DOWN_THRESHOLD \
       RUNNER_MAXIMUM_CONCURRENT_INITIALIZING RUNNER_MAXIMUM_CONCURRENT_DRAINING \
       RUNNER_SCALE_DOWN_STABILIZATION_SECONDS \
       RUNNER_IMAGE_REGISTRY RUNNER_IMAGE_REPOSITORY RUNNER_IMAGE_TAG
omc::render_template "$SCRIPT_DIR/values-region.yaml.tmpl" "$VALUES_OUT"
omc::helm_install_wait daytona-region "$SCRIPT_DIR/../../charts/daytona-region" daytona "$VALUES_OUT"

# === 11. Region-scoped ssh-gateway key + sshGatewayUrl =======================
# Cannot happen earlier: the key only exists after the registration hook has
# created the region during helm install.
omc::log INFO "=== Step 11/11: finalize ssh-gateway (region-scoped key) ==="
omc::region_sshgateway_finalize daytona daytona-region \
  "$SCRIPT_DIR/../../charts/daytona-region" "$VALUES_OUT" \
  "$DAYTONA_API_URL" "$DAYTONA_API_KEY"

# === Summary =================================================================
cat >&2 <<EOF

==================== BRING-UP COMPLETE ====================
Proxy URL:         https://proxy.${BASE_DOMAIN}
Snapshot manager:  https://snapshots.${BASE_DOMAIN}
Image profile:     ${DAYTONA_IMAGE_PROFILE}
Runner image:      ${RUNNER_IMAGE_REGISTRY}/${RUNNER_IMAGE_REPOSITORY}:${RUNNER_IMAGE_TAG:-<chart-appVersion>}
Runner capacity:   min=${RUNNER_MIN_COUNT} max=${RUNNER_MAX_COUNT} (EKS managed nodes)
Node autoscaler:   ${CLUSTER_AUTOSCALER_IMAGE_TAG} (Helm chart ${CLUSTER_AUTOSCALER_CHART_VERSION})

Next steps:
  1. Open the Daytona Cloud dashboard for ${REGION_NAME}
  2. Verify the runner is registered: kubectl -n daytona get pods
  3. Create a snapshot in this region, then a sandbox from it (web UI or API)
  4. Run the SDK smoke test:    bash $SCRIPT_DIR/e2e.sh
  5. Run network diagnostics:   bash $SCRIPT_DIR/network-smoke.sh
  6. Teardown when done:        bash $SCRIPT_DIR/teardown.sh

Future manual upgrades MUST pass both values files or SSH breaks:
  helm upgrade daytona-region charts/daytona-region -n daytona \\
    -f $VALUES_OUT \\
    -f $STATE_DIR/values-sshgateway-key.yaml

State persisted in: $STATE_DIR
===========================================================
EOF
