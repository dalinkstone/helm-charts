#!/usr/bin/env bash
# scripts/aws-setup/teardown.sh — K8s-native Daytona BYOC teardown on AWS EKS.
# Pairs with up.sh. Idempotent. Continues on error to keep cleaning.
#
# Reverse-create order:
#   1.  delete Daytona runners + region, then helm/namespace resources
#   2.  release Service type=LoadBalancer ELBs so VPC deletion cannot hang
#   3.  eksctl delete cluster (VPC, nodegroup, cluster IAM roles)
#   4.  empty all S3 versions and delete the bucket
#   5.  delete IAM user/role/policy + the orphaned OIDC provider
#   6.  remove Stage-C registry/IAM/cache resources and Cloudflare records
#   7.  cleanup local .state/ + kubeconfig
set -uo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_lib/common.sh
source "$SCRIPT_DIR/../_lib/common.sh"

STATE_DIR="$(omc::state_dir "$SCRIPT_DIR")"
PROMPTS_FILE="$STATE_DIR/prompts.env"
IAM_KEYS_FILE="$STATE_DIR/iam-keys.env"
ECR_STATE_FILE="$SCRIPT_DIR/test/.state/ecr.env"

if [[ ! -f "$PROMPTS_FILE" ]]; then
  omc::log WARN "$PROMPTS_FILE missing — cannot determine cluster identity"
  omc::log WARN "Set CLUSTER_NAME, AWS_REGION, S3_BUCKET env vars manually OR re-run up.sh first"
fi

if [[ -f "$PROMPTS_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  . "$PROMPTS_FILE"
  set +a
fi
if [[ -f "$IAM_KEYS_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  . "$IAM_KEYS_FILE"
  set +a
fi

ECR_PULLER_ROLE_NAME=""
ECR_CACHE_PREFIX=""
DAYTONA_REGISTRY_ID=""
DAYTONA_REGISTRY_ENDPOINT=""
if [[ -f "$ECR_STATE_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$ECR_STATE_FILE"
  set +a
fi

: "${CLUSTER_NAME:?CLUSTER_NAME is required (set in $PROMPTS_FILE or env)}"
: "${AWS_REGION:?AWS_REGION is required}"

omc::log INFO "=== Daytona BYOC: AWS teardown for cluster '$CLUSTER_NAME' ==="
omc::confirm "This will DELETE the EKS cluster + S3 bucket + IAM resources for '$CLUSTER_NAME'. Proceed?" \
  || { omc::log INFO "Aborted by operator."; exit 0; }

omc::need_cmd aws eksctl kubectl helm jq curl

# Resolve cloud-side state from the live release before deleting Kubernetes
# secrets. Ambient credentials win; live Helm values fill any missing fields.
if helm status daytona-region -n daytona >/dev/null 2>&1; then
  LIVE_VALUES="$(helm get values daytona-region -n daytona -o json 2>/dev/null || echo '{}')"
  REGION_NAME="${REGION_NAME:-$(jq -r '.regionName // empty' <<<"$LIVE_VALUES")}"
  BASE_DOMAIN="${BASE_DOMAIN:-$(jq -r '.baseDomain // empty' <<<"$LIVE_VALUES")}"
  DAYTONA_API_URL="${DAYTONA_API_URL:-$(jq -r '.daytonaApiUrl // empty' <<<"$LIVE_VALUES")}"
  DAYTONA_API_KEY="${DAYTONA_API_KEY:-$(jq -r '.daytonaApiKey // empty' <<<"$LIVE_VALUES")}"
fi
DAYTONA_API_URL="${DAYTONA_API_URL:-https://app.daytona.io/api}"
REGION_ID="$(kubectl -n daytona get secret \
  -l 'app.kubernetes.io/component=region-config' -o json 2>/dev/null \
  | jq -r '.items[0].data.id // empty | @base64d' 2>/dev/null || true)"

# === 1. Daytona Cloud runners + region ======================================
if [[ -n "${DAYTONA_API_KEY:-}" && -n "${REGION_NAME:-}" ]]; then
  regions_json="$(curl -sS --max-time 30 -H "Authorization: Bearer $DAYTONA_API_KEY" \
    "$DAYTONA_API_URL/regions" 2>/dev/null || echo '[]')"
  if [[ -z "$REGION_ID" ]]; then
    REGION_ID="$(jq -r --arg name "$REGION_NAME" '
      (if type == "array" then . else (.items // .result // .data // []) end)
      | .[]? | select(.name == $name) | .id' <<<"$regions_json" | head -1)"
  fi

  runners_json="$(curl -sS --max-time 30 -H "Authorization: Bearer $DAYTONA_API_KEY" \
    "$DAYTONA_API_URL/runners" 2>/dev/null || echo '[]')"
  while IFS= read -r runner_id; do
    [[ -n "$runner_id" ]] || continue
    http="$(curl -sS --max-time 30 -o /dev/null -w '%{http_code}' -X DELETE \
      -H "Authorization: Bearer $DAYTONA_API_KEY" \
      "$DAYTONA_API_URL/runners/$runner_id" 2>/dev/null || echo 000)"
    case "$http" in
      200|204|404) omc::log INFO "Daytona runner $runner_id removed (HTTP $http)" ;;
      *) omc::log WARN "Daytona runner $runner_id delete returned HTTP $http" ;;
    esac
  done < <(jq -r --arg id "$REGION_ID" --arg name "$REGION_NAME" '
    (if type == "array" then . else (.items // .result // .data // []) end)
    | .[]?
    | select(.regionId == $id or .region.id == $id or .region == $name)
    | .id' <<<"$runners_json")

  if [[ -n "$REGION_ID" ]]; then
    http=000
    for _attempt in 1 2 3 4 5 6; do
      http="$(curl -sS --max-time 30 -o /dev/null -w '%{http_code}' -X DELETE \
        -H "Authorization: Bearer $DAYTONA_API_KEY" \
        "$DAYTONA_API_URL/regions/$REGION_ID" 2>/dev/null || echo 000)"
      [[ "$http" != "400" && "$http" != "409" ]] && break
      sleep 5
    done
    case "$http" in
      200|204|404) omc::log INFO "Daytona region $REGION_NAME removed (HTTP $http)" ;;
      *) omc::log WARN "Daytona region $REGION_NAME delete returned HTTP $http; verify no live sandboxes remain" ;;
    esac
  fi
else
  omc::log WARN "DAYTONA_API_KEY or REGION_NAME unavailable; skipping Daytona Cloud deregistration"
fi

# === 2. helm uninstall + delete namespace ====================================
if kubectl get ns daytona >/dev/null 2>&1; then
  helm uninstall daytona-region -n daytona --wait --timeout 5m 2>/dev/null \
    && omc::log INFO "helm uninstalled daytona-region" \
    || omc::log WARN "helm uninstall failed or release not found"
  kubectl delete namespace daytona --wait=false 2>/dev/null \
    && omc::log INFO "namespace daytona deletion initiated" \
    || omc::log WARN "namespace daytona delete failed or absent"
fi

# Cluster Autoscaler is cluster infrastructure, separate from daytona-region.
# Remove its Helm release and IRSA stack before deleting EKS so no IAM policy
# attachment is left behind if cluster deletion is interrupted.
if helm status cluster-autoscaler -n kube-system >/dev/null 2>&1; then
  helm uninstall cluster-autoscaler -n kube-system --wait --timeout 5m \
    && omc::log INFO "helm uninstalled cluster-autoscaler" \
    || omc::log WARN "cluster-autoscaler helm uninstall failed"
fi
if eksctl get iamserviceaccount --cluster "$CLUSTER_NAME" --region "$AWS_REGION" \
  --namespace kube-system --name cluster-autoscaler >/dev/null 2>&1; then
  eksctl delete iamserviceaccount --cluster "$CLUSTER_NAME" --region "$AWS_REGION" \
    --namespace kube-system --name cluster-autoscaler --wait --approve \
    && omc::log INFO "Cluster Autoscaler IRSA service account deleted" \
    || omc::log WARN "Cluster Autoscaler IRSA service-account delete failed; cluster deletion will retry stack cleanup"
fi

# === 2b. Release cloud load balancers BEFORE deleting the VPC ================
# Service type=LoadBalancer (ingress-nginx-controller, ssh-gateway) provisions
# ELBs whose ENIs + security groups pin the VPC. If they outlive the helm
# uninstall, eksctl's VPC delete hangs. Delete them explicitly and wait so AWS
# releases the ELBs first. Also capture the IAM OIDC provider id while the
# cluster still exists (eksctl delete does NOT remove it -> leak otherwise).
OIDC_ISSUER="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'cluster.identity.oidc.issuer' --output text 2>/dev/null || true)"
if kubectl cluster-info >/dev/null 2>&1; then
  while IFS= read -r lb_line; do
    [[ -z "$lb_line" ]] && continue
    lb_ns="${lb_line%%/*}"; lb_name="${lb_line##*/}"
    kubectl delete svc "$lb_name" -n "$lb_ns" --wait=true --timeout=3m 2>/dev/null \
      && omc::log INFO "released LoadBalancer svc $lb_line" || true
  done < <(kubectl get svc -A \
      -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null)
fi

# === 3. eksctl delete cluster ================================================
if eksctl get cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  omc::log INFO "Deleting EKS cluster (this takes 10-15 min)..."
  eksctl delete cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --wait \
    && omc::log INFO "EKS cluster deleted" \
    || omc::log WARN "eksctl delete cluster reported errors (check AWS console)"
else
  omc::log INFO "EKS cluster $CLUSTER_NAME not found in $AWS_REGION (already gone)"
fi

# === 4. S3 bucket ============================================================
if [[ -n "${S3_BUCKET:-}" ]]; then
  if aws s3api head-bucket --bucket "$S3_BUCKET" >/dev/null 2>&1; then
    aws s3 rm "s3://$S3_BUCKET" --recursive --region "$AWS_REGION" >/dev/null 2>&1 || true
    while true; do
      versions="$(aws s3api list-object-versions --bucket "$S3_BUCKET" --region "$AWS_REGION" --output json 2>/dev/null || echo '{}')"
      delete_count="$(jq '(.Versions // []) + (.DeleteMarkers // []) | length' <<<"$versions")"
      (( delete_count > 0 )) || break
      delete_file="$(mktemp "$STATE_DIR/s3-delete.XXXXXX.json")"
      jq '{Objects: [(.Versions // [])[], (.DeleteMarkers // [])[] | {Key, VersionId}], Quiet: true}' \
        <<<"$versions" > "$delete_file"
      aws s3api delete-objects --bucket "$S3_BUCKET" --region "$AWS_REGION" \
        --delete "file://$delete_file" >/dev/null
      rm -f "$delete_file"
    done
    aws s3api delete-bucket --bucket "$S3_BUCKET" --region "$AWS_REGION" \
      && omc::log INFO "S3 bucket $S3_BUCKET deleted" \
      || omc::log WARN "S3 bucket delete failed; inspect remaining versions and multipart uploads"
  else
    omc::log INFO "S3 bucket $S3_BUCKET not found"
  fi
fi

# === 5. IAM cleanup ==========================================================
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
S3_POLICY_NAME="${CLUSTER_NAME}-s3"

if [[ -n "$ACCOUNT_ID" ]]; then
  S3_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${S3_POLICY_NAME}"

  # Static mode: IAM user + keys
  IAM_USER="${CLUSTER_NAME}-daytona"
  if aws iam get-user --user-name "$IAM_USER" >/dev/null 2>&1; then
    aws iam list-access-keys --user-name "$IAM_USER" \
      --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null \
      | tr '\t' '\n' \
      | while IFS= read -r key; do
          [[ -z "$key" ]] && continue
          aws iam delete-access-key --user-name "$IAM_USER" --access-key-id "$key" \
            && omc::log INFO "deleted access key $key" \
            || true
        done
    aws iam detach-user-policy --user-name "$IAM_USER" --policy-arn "$S3_POLICY_ARN" 2>/dev/null || true
    aws iam delete-user --user-name "$IAM_USER" \
      && omc::log INFO "IAM user $IAM_USER deleted" \
      || omc::log WARN "IAM user delete failed"
  fi

  # IRSA mode: role
  IRSA_ROLE_NAME="${CLUSTER_NAME}-runner-irsa"
  if aws iam get-role --role-name "$IRSA_ROLE_NAME" >/dev/null 2>&1; then
    aws iam detach-role-policy --role-name "$IRSA_ROLE_NAME" --policy-arn "$S3_POLICY_ARN" 2>/dev/null || true
    aws iam delete-role --role-name "$IRSA_ROLE_NAME" \
      && omc::log INFO "IRSA role $IRSA_ROLE_NAME deleted" \
      || omc::log WARN "IRSA role delete failed"
  fi

  # The shared policy
  if aws iam get-policy --policy-arn "$S3_POLICY_ARN" >/dev/null 2>&1; then
    aws iam delete-policy --policy-arn "$S3_POLICY_ARN" \
      && omc::log INFO "IAM policy $S3_POLICY_NAME deleted" \
      || omc::log WARN "IAM policy delete failed (still attached somewhere?)"
  fi

  # Dedicated Cluster Autoscaler IRSA policy. The eksctl-managed role should
  # already be gone; defensively detach any remaining role before deletion.
  CLUSTER_AUTOSCALER_POLICY_NAME="${CLUSTER_NAME}-cluster-autoscaler"
  CLUSTER_AUTOSCALER_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${CLUSTER_AUTOSCALER_POLICY_NAME}"
  if aws iam get-policy --policy-arn "$CLUSTER_AUTOSCALER_POLICY_ARN" >/dev/null 2>&1; then
    while IFS= read -r role_name; do
      [[ -n "$role_name" && "$role_name" != "None" ]] || continue
      aws iam detach-role-policy --role-name "$role_name" --policy-arn "$CLUSTER_AUTOSCALER_POLICY_ARN" 2>/dev/null || true
      if [[ "$role_name" == *-cluster-autoscaler ]]; then
        aws iam delete-role --role-name "$role_name" 2>/dev/null || true
      fi
    done < <(aws iam list-entities-for-policy --policy-arn "$CLUSTER_AUTOSCALER_POLICY_ARN" \
      --query 'PolicyRoles[].RoleName' --output text 2>/dev/null | tr '\t' '\n')
    aws iam delete-policy --policy-arn "$CLUSTER_AUTOSCALER_POLICY_ARN" \
      && omc::log INFO "IAM policy $CLUSTER_AUTOSCALER_POLICY_NAME deleted" \
      || omc::log WARN "Cluster Autoscaler IAM policy delete failed"
  fi

  # IAM OIDC provider (created by eksctl `withOIDC`; NOT removed by cluster delete)
  if [[ -n "${OIDC_ISSUER:-}" && "$OIDC_ISSUER" != "None" ]]; then
    OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_ISSUER#https://}"
    if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" >/dev/null 2>&1; then
      aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_ARN" \
        && omc::log INFO "IAM OIDC provider deleted" \
        || omc::log WARN "OIDC provider delete failed"
    else
      omc::log INFO "IAM OIDC provider already gone"
    fi
  fi
fi

# === 6. Stage-C ECR verification resources ==================================
# Never remove RUNNER_IMAGE_REF or its repository: it is user-supplied canary
# input. Only ecr-setup.sh's named registry registration, role, and ecr-public
# pull-through cache resources are in scope here.
if [[ -n "$DAYTONA_REGISTRY_ID" && -n "$DAYTONA_REGISTRY_ENDPOINT" && -n "${DAYTONA_API_KEY:-}" ]]; then
  http="$(curl -sS --max-time 30 -o /dev/null -w '%{http_code}' -X DELETE \
    -H "Authorization: Bearer $DAYTONA_API_KEY" \
    "$DAYTONA_API_URL/$DAYTONA_REGISTRY_ENDPOINT/$DAYTONA_REGISTRY_ID" 2>/dev/null || echo 000)"
  case "$http" in
    200|204|404) omc::log INFO "Daytona ECR test registration removed (HTTP $http)" ;;
    *) omc::log WARN "Daytona ECR test registration delete returned HTTP $http" ;;
  esac
fi

if [[ -n "$ECR_PULLER_ROLE_NAME" ]] && aws iam get-role --role-name "$ECR_PULLER_ROLE_NAME" >/dev/null 2>&1; then
  while IFS= read -r policy_name; do
    [[ -n "$policy_name" ]] || continue
    aws iam delete-role-policy --role-name "$ECR_PULLER_ROLE_NAME" --policy-name "$policy_name" 2>/dev/null || true
  done < <(aws iam list-role-policies --role-name "$ECR_PULLER_ROLE_NAME" \
    --query 'PolicyNames[]' --output text 2>/dev/null | tr '\t' '\n')
  aws iam delete-role --role-name "$ECR_PULLER_ROLE_NAME" \
    && omc::log INFO "ECR test puller role $ECR_PULLER_ROLE_NAME deleted" \
    || omc::log WARN "ECR test puller role delete failed"
fi

if [[ -n "$ECR_CACHE_PREFIX" ]]; then
  while IFS= read -r repository; do
    [[ -n "$repository" && "$repository" != "None" ]] || continue
    aws ecr delete-repository --repository-name "$repository" --region "$AWS_REGION" --force >/dev/null 2>&1 \
      && omc::log INFO "ECR test cache repository deleted: $repository" || true
  done < <(aws ecr describe-repositories --region "$AWS_REGION" \
    --query "repositories[?starts_with(repositoryName, '${ECR_CACHE_PREFIX}/')].repositoryName" \
    --output text 2>/dev/null | tr '\t' '\n')
  aws ecr delete-pull-through-cache-rule --ecr-repository-prefix "$ECR_CACHE_PREFIX" \
    --region "$AWS_REGION" >/dev/null 2>&1 \
    && omc::log INFO "ECR test cache rule $ECR_CACHE_PREFIX deleted" || true
fi

# === 6b. Cloudflare records ==================================================
if [[ -n "${BASE_DOMAIN:-}" && -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  omc::cloudflare_delete_dns "$CLOUDFLARE_API_TOKEN" "$BASE_DOMAIN" || true
else
  omc::log WARN "BASE_DOMAIN or CLOUDFLARE_API_TOKEN unavailable; Cloudflare records were not removed"
fi

# === 7. Local state ==========================================================
if [[ -d "$STATE_DIR" ]]; then
  rm -rf "$STATE_DIR"
  omc::log INFO "removed $STATE_DIR"
fi
kubectl config delete-context "$CLUSTER_NAME" 2>/dev/null || true
kubectl config delete-cluster "$CLUSTER_NAME" 2>/dev/null || true

cat >&2 <<EOF

==================== TEARDOWN COMPLETE ====================
Verify with:
  aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION
    (expect ResourceNotFoundException)
  aws s3api head-bucket --bucket ${S3_BUCKET:-<none>} 2>&1
    (expect 404)
  aws iam get-user --user-name ${CLUSTER_NAME}-daytona 2>&1
    (expect NoSuchEntity)
===========================================================
EOF
