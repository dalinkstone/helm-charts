#!/usr/bin/env bash
# Binary assertions against a live AWS/EKS Daytona region. No resources mutate.
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_lib/common.sh
source "$SCRIPT_DIR/../_lib/common.sh"
# shellcheck source=../_lib/infra-test.sh
source "$SCRIPT_DIR/../_lib/infra-test.sh"

STATE_DIR="$(omc::state_dir "$SCRIPT_DIR")"
PROMPTS_FILE="$STATE_DIR/prompts.env"
if [[ -f "$PROMPTS_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  . "$PROMPTS_FILE"
  set +a
fi

omc::need_cmd aws kubectl helm jq yq curl openssl

NAMESPACE="${NAMESPACE:-daytona}"
RELEASE="${RELEASE:-daytona-region}"
TIMEOUT="${INFRA_TEST_TIMEOUT:-600s}"
RUNNER_MIN_COUNT="${RUNNER_MIN_COUNT:-3}"
RUNNER_MAX_COUNT="${RUNNER_MAX_COUNT:-10}"
CLUSTER_AUTOSCALER_CHART_VERSION="${CLUSTER_AUTOSCALER_CHART_VERSION:-9.58.0}"
CLUSTER_AUTOSCALER_IMAGE_TAG="${CLUSTER_AUTOSCALER_IMAGE_TAG:-v${EKS_VERSION:-1.36}.0}"
RECEIPT="${INFRA_TEST_RECEIPT:-$STATE_DIR/infra-test-$(date -u +%Y%m%dT%H%M%SZ).log}"
mkdir -p "$STATE_DIR"
umask 077
exec > >(tee "$RECEIPT") 2>&1

values="$(helm -n "$NAMESPACE" get values "$RELEASE" -o json)"
REGION_NAME="$(jq -r '.regionName // empty' <<<"$values")"
DAYTONA_API_URL="$(jq -r '.daytonaApiUrl // empty' <<<"$values")"
DAYTONA_API_KEY="$(jq -r '.daytonaApiKey // empty' <<<"$values")"
BASE_DOMAIN="$(jq -r '.baseDomain // empty' <<<"$values")"
[[ -n "$REGION_NAME" && -n "$DAYTONA_API_URL" && -n "$DAYTONA_API_KEY" && -n "$BASE_DOMAIN" ]] \
  || omc::die "live Helm values are missing regionName, daytonaApiUrl, daytonaApiKey, or baseDomain"

identity="$(aws sts get-caller-identity --output json)"
account_id="$(jq -r '.Account' <<<"$identity")"
principal_arn="$(jq -r '.Arn' <<<"$identity")"
aws_region="$(jq -r '.services.runner.env.AWS_REGION // empty' <<<"$values")"
[[ -n "${CLUSTER_NAME:-}" ]] || omc::die "CLUSTER_NAME is missing from $PROMPTS_FILE"

echo "Daytona AWS live infrastructure test"
echo "started=$(date -u +%FT%TZ) commit=$(git -C "$SCRIPT_DIR/../.." rev-parse HEAD)"
echo "account=$account_id principal=$principal_arn aws_region=$aws_region region=$REGION_NAME"

nodes="$(kubectl get nodes -l daytona-sandbox-c=true -o json)"
ready_nodes="$(jq '[.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length' <<<"$nodes")"
(( ready_nodes >= RUNNER_MIN_COUNT )) || omc::die "expected at least $RUNNER_MIN_COUNT Ready daytona-sandbox-c nodes; found $ready_nodes"
bad_taints="$(jq '[.items[] | select(any(.spec.taints[]?; .key == "sandbox" and .value == "true" and .effect == "NoSchedule") | not)] | length' <<<"$nodes")"
(( bad_taints == 0 )) || omc::die "$bad_taints sandbox nodes lack sandbox=true:NoSchedule"
echo "PASS nodes: $ready_nodes Ready, labelled, and correctly tainted"

nodegroup_scaling="$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name sandbox \
  --region "$aws_region" --query 'nodegroup.scalingConfig' --output json)"
[[ "$(jq -r '.minSize' <<<"$nodegroup_scaling")" == "$RUNNER_MIN_COUNT" ]] \
  || omc::die "sandbox node-group minimum does not match runner minimum $RUNNER_MIN_COUNT"
[[ "$(jq -r '.maxSize' <<<"$nodegroup_scaling")" == "$RUNNER_MAX_COUNT" ]] \
  || omc::die "sandbox node-group maximum does not match runner maximum $RUNNER_MAX_COUNT"

autoscaler_chart="$(helm -n kube-system list -f '^cluster-autoscaler$' -o json \
  | jq -r '.[0].chart // empty')"
[[ "$autoscaler_chart" == "cluster-autoscaler-${CLUSTER_AUTOSCALER_CHART_VERSION}" ]] \
  || omc::die "expected Cluster Autoscaler chart $CLUSTER_AUTOSCALER_CHART_VERSION; found ${autoscaler_chart:-absent}"
kubectl -n kube-system rollout status deployment/cluster-autoscaler --timeout="$TIMEOUT"
autoscaler="$(kubectl -n kube-system get deployment cluster-autoscaler -o json)"
autoscaler_image="$(jq -r '.spec.template.spec.containers[0].image' <<<"$autoscaler")"
[[ "$autoscaler_image" == *":${CLUSTER_AUTOSCALER_IMAGE_TAG}" ]] \
  || omc::die "Cluster Autoscaler image '$autoscaler_image' does not use $CLUSTER_AUTOSCALER_IMAGE_TAG"
autoscaler_args="$(jq -r '.spec.template.spec.containers[0].command[]?, .spec.template.spec.containers[0].args[]?' <<<"$autoscaler")"
grep -Fq -- "--node-group-auto-discovery=asg:tag=k8s.io/cluster-autoscaler/enabled,k8s.io/cluster-autoscaler/$CLUSTER_NAME" <<<"$autoscaler_args" \
  || omc::die "Cluster Autoscaler is not configured for tagged ASG auto-discovery of $CLUSTER_NAME"
autoscaler_role="$(kubectl -n kube-system get serviceaccount cluster-autoscaler \
  -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}')"
[[ "$autoscaler_role" == arn:aws:iam::*:role/* ]] \
  || omc::die "Cluster Autoscaler service account lacks an IRSA role annotation"
kubectl -n kube-system get configmap cluster-autoscaler-status >/dev/null
echo "PASS autoscaling actuator: node-group=$RUNNER_MIN_COUNT..$RUNNER_MAX_COUNT chart=$CLUSTER_AUTOSCALER_CHART_VERSION image=$CLUSTER_AUTOSCALER_IMAGE_TAG IRSA=enabled"

components=(proxy snapshot-manager ssh-gateway)
if kubectl -n "$NAMESPACE" get deploy \
  -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/component=runnermanager" \
  -o name | grep -q .; then
  components+=(runnermanager)
fi
for component in "${components[@]}"; do
  deployment="$(kubectl -n "$NAMESPACE" get deploy \
    -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/component=$component" \
    -o jsonpath='{.items[0].metadata.name}')"
  [[ -n "$deployment" ]] || omc::die "deployment for component $component not found"
  kubectl -n "$NAMESPACE" rollout status "deployment/$deployment" --timeout="$TIMEOUT"
done
runner_ds="$(kubectl -n "$NAMESPACE" get ds \
  -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/component=runner" \
  -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$runner_ds" ]] || omc::die "runner DaemonSet not found"
kubectl -n "$NAMESPACE" rollout status "daemonset/$runner_ds" --timeout="$TIMEOUT"
echo "PASS rollouts: ${#components[@]} Deployments and runner DaemonSet"

runner_pod_count="$(kubectl -n "$NAMESPACE" get pods \
  -l 'app.kubernetes.io/component=runner,daytona.io/runner=true' -o json \
  | jq '[.items[] | select(.status.phase == "Running") | select(any(.status.containerStatuses[]?; .name == "runner" and .ready == true))] | length')"
(( runner_pod_count >= RUNNER_MIN_COUNT )) || omc::die "expected at least $RUNNER_MIN_COUNT running runner pods; found $runner_pod_count"
echo "PASS runner pods: $runner_pod_count running"

certificates="$(kubectl -n "$NAMESPACE" get certificate -o json)"
certificate_count="$(jq '.items | length' <<<"$certificates")"
(( certificate_count >= 2 )) || omc::die "expected proxy and snapshot certificates; found $certificate_count"
while IFS= read -r certificate; do
  kubectl -n "$NAMESPACE" wait --for=condition=Ready "certificate/$certificate" --timeout="$TIMEOUT"
done < <(jq -r '.items[].metadata.name' <<<"$certificates")
omc::infra::assert_cert_is_real "proxy.$BASE_DOMAIN"
omc::infra::assert_cert_is_real "snapshots.$BASE_DOMAIN"
echo "PASS TLS: $certificate_count certificates Ready and serving non-placeholder issuers"

expected_bundle="$(jq -r '.imageBundle.name // empty' <<<"$values")"
[[ -n "$expected_bundle" ]] || expected_bundle="parity-$(yq -r '.appVersion' "$SCRIPT_DIR/../../charts/daytona-region/Chart.yaml")"
workloads="$(kubectl -n "$NAMESPACE" get deploy,ds \
  -l "app.kubernetes.io/instance=$RELEASE" -o json)"
expected_bundle_components='["proxy","snapshot-manager","ssh-gateway","runner"]'
if ((${#components[@]} == 4)); then
  expected_bundle_components='["proxy","snapshot-manager","runnermanager","ssh-gateway","runner"]'
fi
expected_bundle_count="$(jq 'length' <<<"$expected_bundle_components")"
bundle_workload_count="$(jq --argjson components "$expected_bundle_components" '[.items[] | select(.metadata.labels["app.kubernetes.io/component"] as $c | $components | index($c))] | length' <<<"$workloads")"
(( bundle_workload_count == expected_bundle_count )) || omc::die "expected $expected_bundle_count Daytona image-bundle workloads; found $bundle_workload_count"
bundle_mismatches="$(jq --arg bundle "$expected_bundle" \
  --argjson components "$expected_bundle_components" \
  '[.items[] | select(.metadata.labels["app.kubernetes.io/component"] as $c | $components | index($c)) | select(.spec.template.metadata.annotations["daytona.io/image-bundle"] != $bundle)] | length' \
  <<<"$workloads")"
(( bundle_mismatches == 0 )) || omc::die "$bundle_mismatches Daytona workloads lack expected image-bundle annotation '$expected_bundle'"

runner_registry="$(jq -r '.services.runner.image.registry // empty' <<<"$values")"
[[ -n "$runner_registry" ]] || runner_registry="docker.io"
runner_repository="$(jq -r '.services.runner.image.repository // empty' <<<"$values")"
runner_tag="$(jq -r '.services.runner.image.tag // empty' <<<"$values")"
[[ -n "$runner_repository" && -n "$runner_tag" ]] || omc::die "live values do not pin the runner repository and tag"
expected_runner_image="${runner_registry}/${runner_repository}:${runner_tag}"
kubectl -n "$NAMESPACE" get ds "$runner_ds" -o json \
  | jq -e --arg image "$expected_runner_image" 'any(.spec.template.spec.containers[]; .name == "runner" and .image == $image)' >/dev/null \
  || omc::die "runner DaemonSet does not run expected main container image $expected_runner_image"
if ((${#components[@]} == 4)); then
  manager_registry="$(jq -r '.services.runnermanager.image.registry // "docker.io"' <<<"$values")"
  manager_repository="$(jq -r '.services.runnermanager.image.repository // empty' <<<"$values")"
  manager_tag="$(jq -r '.services.runnermanager.image.tag // empty' <<<"$values")"
  [[ -n "$manager_repository" && -n "$manager_tag" ]] || omc::die "live values do not pin runner-manager repository and tag"
  expected_manager_image="${manager_registry}/${manager_repository}:${manager_tag}"
  manager_image="$(kubectl -n "$NAMESPACE" get deploy \
    -l 'app.kubernetes.io/component=runnermanager' -o json \
    | jq -r '.items[0].spec.template.spec.containers[] | select(.name == "runnermanager") | .image')"
  [[ "$manager_image" == "$expected_manager_image" ]] \
    || omc::die "runner-manager runs '$manager_image', expected '$expected_manager_image'"
  manager_env="$(kubectl -n "$NAMESPACE" get deploy \
    -l 'app.kubernetes.io/component=runnermanager' -o json \
    | jq '.items[0].spec.template.spec.containers[] | select(.name == "runnermanager") | .env')"
  [[ "$(jq -r '.[] | select(.name == "MIN_RUNNERS") | .value' <<<"$manager_env")" == "$RUNNER_MIN_COUNT" ]] \
    || omc::die "runner-manager MIN_RUNNERS does not match node-group minimum $RUNNER_MIN_COUNT"
  [[ "$(jq -r '.[] | select(.name == "MAX_RUNNERS") | .value' <<<"$manager_env")" == "$RUNNER_MAX_COUNT" ]] \
    || omc::die "runner-manager MAX_RUNNERS does not match node-group maximum $RUNNER_MAX_COUNT"

  # The v0.199 compatibility path is entirely chart-managed: runner processes
  # live in the DaemonSet, never ad-hoc Deployments, and no route-rewrite proxy
  # is allowed to mask a stale manager binary.
  runner_deployment_count="$(kubectl -n "$NAMESPACE" get deploy -o json \
    | jq --arg image "$expected_runner_image" '[.items[] | select(any(.spec.template.spec.containers[]?; .image == $image))] | length')"
  (( runner_deployment_count == 0 )) \
    || omc::die "found $runner_deployment_count standalone runner Deployment(s); expected DaemonSet-only runners"
  if kubectl -n "$NAMESPACE" get deploy daytona-api-compat >/dev/null 2>&1; then
    omc::die "legacy daytona-api-compat Deployment is present; patched runner-manager must call v0.199 directly"
  fi
fi
echo "PASS image bundle: $expected_bundle; runner=$expected_runner_image manager=${expected_manager_image:-disabled}"

region_config="$(kubectl -n "$NAMESPACE" get secret \
  -l "app.kubernetes.io/instance=$RELEASE,app.kubernetes.io/component=region-config" \
  -o json | jq '.items[0]')"
region_id="$(jq -r '.data.id | @base64d' <<<"$region_config")"
regions_json="$(curl -fsS --max-time 30 -H "Authorization: Bearer $DAYTONA_API_KEY" "$DAYTONA_API_URL/regions")"
region_matches="$(jq --arg id "$region_id" --arg name "$REGION_NAME" '
  (if type == "array" then . else (.items // .result // .data // []) end)
  | [.[] | select(.id == $id and .name == $name)] | length' <<<"$regions_json")"
(( region_matches == 1 )) || omc::die "live Daytona region $REGION_NAME/$region_id not found exactly once"

runners_json="$(curl -fsS --max-time 30 -G -H "Authorization: Bearer $DAYTONA_API_KEY" \
  --data-urlencode "regionId=$region_id" "$DAYTONA_API_URL/runners")"
ready_runners="$(jq --arg id "$region_id" --arg name "$REGION_NAME" '
  (if type == "array" then . else (.items // .result // .data // []) end)
  | [.[] | select(((.regionId // (if (.region | type) == "object" then .region.id else .region end)) == $id or .region == $name) and .state == "ready" and (.unschedulable != true) and (.draining != true))]
  | length' <<<"$runners_json")"
(( ready_runners >= RUNNER_MIN_COUNT )) || omc::die "expected at least $RUNNER_MIN_COUNT ready Daytona runners for $REGION_NAME; found $ready_runners"
echo "PASS Daytona registration: region=$region_id ready_runners=$ready_runners"

if [[ -n "${EXPECTED_RUNNER_APP_VERSION:-}" ]]; then
  matching_versions="$(jq --arg id "$region_id" --arg version "$EXPECTED_RUNNER_APP_VERSION" '
    (if type == "array" then . else (.items // .result // .data // []) end)
    | [.[] | select((.regionId // (if (.region | type) == "object" then .region.id else .region end)) == $id and .state == "ready" and .appVersion == $version)]
    | length' <<<"$runners_json")"
  (( matching_versions >= RUNNER_MIN_COUNT )) \
    || omc::die "expected $RUNNER_MIN_COUNT ready runners at appVersion $EXPECTED_RUNNER_APP_VERSION; found $matching_versions"
  echo "PASS runner app version: $matching_versions ready runners report $EXPECTED_RUNNER_APP_VERSION"
fi

if [[ -n "${EXPECTED_RUNTIME_RUNNER_IMAGE:-}" ]]; then
  runtime_pods="$(kubectl -n "$NAMESPACE" get pods -l 'daytona.io/manual-runner=true' -o json)"
  matching_images="$(jq --arg image "$EXPECTED_RUNTIME_RUNNER_IMAGE" '
    [.items[] | select(.status.phase == "Running")
      | select(any(.spec.containers[]; .name == "runner" and .image == $image))] | length' <<<"$runtime_pods")"
  (( matching_images >= 2 )) \
    || omc::die "expected two running manual runner pods on $EXPECTED_RUNTIME_RUNNER_IMAGE; found $matching_images"
  echo "PASS runtime runner image: $matching_images pods use $EXPECTED_RUNTIME_RUNNER_IMAGE"
fi

snapshot_bucket="$(jq -r '.services.snapshotManager.storage.s3.bucket // empty' <<<"$values")"
runner_bucket="$(jq -r '.services.runner.env.AWS_DEFAULT_BUCKET // empty' <<<"$values")"
[[ -n "$snapshot_bucket" && "$snapshot_bucket" == "$runner_bucket" ]] \
  || omc::die "S3 wiring mismatch: snapshot-manager='$snapshot_bucket' runner='$runner_bucket'"
aws s3api head-bucket --bucket "$snapshot_bucket"
live_runner_pod="$(kubectl -n "$NAMESPACE" get pods -o json \
  | jq -r '.items[] | select(.status.phase == "Running") | select(any(.spec.containers[]; .name == "runner")) | .metadata.name' \
  | head -1)"
[[ -n "$live_runner_pod" ]] || omc::die "no managed runner pod with a runner container found"
pod_bucket="$(kubectl -n "$NAMESPACE" exec "$live_runner_pod" -c runner -- printenv AWS_DEFAULT_BUCKET)"
[[ "$pod_bucket" == "$snapshot_bucket" ]] \
  || omc::die "managed runner pod uses bucket '$pod_bucket', expected '$snapshot_bucket'"
echo "PASS S3 wiring: Helm values, live runner env, and reachable bucket all match ($snapshot_bucket)"

chmod 600 "$RECEIPT"
echo "completed=$(date -u +%FT%TZ) result=PASS receipt=$RECEIPT"
