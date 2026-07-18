#!/usr/bin/env bash
# scripts/aws-setup/roll-runner.sh — gracefully replace ONE EKS-hosted runner.
#
# The command is intentionally all-or-nothing from the operator's perspective:
#
#   ./roll-runner.sh              # list runners in the configured region
#   ./roll-runner.sh <runner-id>  # drain, replace, re-enable, and verify it
#
# A roll performs these steps:
#   1. validate the exact runner id and require a healthy schedulable peer
#   2. map the runner API address to its Kubernetes pod, EKS node, and ASG EC2
#   3. make the runner unschedulable, stop/back up its sandboxes, and drain it
#   4. terminate its EC2 instance (the managed node group replaces capacity)
#   5. wait for a different Ready pod and a fresh Daytona runner heartbeat
#   6. clear draining/unschedulable and require two healthy runners again
#
# Re-running the same command resumes a roll that stopped after the drain phase.
# Never run this concurrently for two runners in the same two-runner region.
#
# Requires DAYTONA_API_KEY with read:sandboxes + read/write:runners in the same
# organization as the region. DAYTONA_API_URL and REGION_ID may be exported or
# stored in scripts/aws-setup/.state/prompts.env.
set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_lib/common.sh
source "$SCRIPT_DIR/../_lib/common.sh"
STATE_DIR="$(omc::state_dir "$SCRIPT_DIR")"
[[ -f "$STATE_DIR/prompts.env" ]] && { set -a; . "$STATE_DIR/prompts.env"; set +a; }

omc::need_cmd curl jq kubectl aws base64 sed
: "${DAYTONA_API_URL:?set DAYTONA_API_URL (or put it in .state/prompts.env)}"
: "${DAYTONA_API_KEY:?set DAYTONA_API_KEY (read:sandboxes + read/write:runners, same org as the region)}"

NAMESPACE="${NAMESPACE:-daytona}"
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-west-2}}"
ROLL_TIMEOUT_SECONDS="${ROLL_TIMEOUT_SECONDS:-1200}"
ROLL_POLL_SECONDS="${ROLL_POLL_SECONDS:-10}"
[[ "$ROLL_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ && "$ROLL_POLL_SECONDS" =~ ^[1-9][0-9]*$ ]] \
  || omc::die "ROLL_TIMEOUT_SECONDS and ROLL_POLL_SECONDS must be positive integers."
HTTP_BODY="$(mktemp "${TMPDIR:-/tmp}/daytona-roll-runner.XXXXXX")"
roll_started=0
roll_completed=0

cleanup() {
  local rc=$?
  rm -f "$HTTP_BODY"
  if [[ "$rc" -ne 0 && "$roll_started" -eq 1 && "$roll_completed" -eq 0 ]]; then
    omc::log WARN "Roll did not complete. The target may remain unschedulable/draining; fix the reported error and re-run this command with the same runner id. Do not roll its peer."
  fi
  exit "$rc"
}
trap cleanup EXIT

# Body is written to the owner-only temporary file; status code is printed.
http() {
  local method="$1" url="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -sS -m 30 -o "$HTTP_BODY" -w '%{http_code}' -X "$method" \
      -H "Authorization: Bearer $DAYTONA_API_KEY" \
      -H 'Content-Type: application/json' -d "$body" "$url"
  else
    curl -sS -m 30 -o "$HTTP_BODY" -w '%{http_code}' -X "$method" \
      -H "Authorization: Bearer $DAYTONA_API_KEY" "$url"
  fi
}

require_http_200() {
  local operation="$1" code="$2"
  [[ "$code" == "200" ]] || omc::die "$operation failed (HTTP $code): $(cat "$HTTP_BODY")"
}

fetch_runners() {
  local code
  code="$(http GET "${DAYTONA_API_URL}/runners?regionId=${REGION_ID}")"
  require_http_200 "GET /runners" "$code"
  cat "$HTTP_BODY"
}

runner_record() {
  local runners_json="$1" runner_id="$2"
  printf '%s' "$runners_json" | jq -c --arg id "$runner_id" \
    '[.[] | select(.id == $id)][0] // empty'
}

healthy_peer_count() {
  local runners_json="$1" runner_id="$2"
  printf '%s' "$runners_json" | jq --arg id "$runner_id" \
    '[.[] | select(.id != $id and .state == "ready" and (.unschedulable != true) and (.draining != true))] | length'
}

list_mine() {
  local runner_id="$1" code
  code="$(http GET "${DAYTONA_API_URL}/sandbox?limit=100")"
  require_http_200 "GET /sandbox" "$code"
  jq -c --arg id "$runner_id" '[.items[] | select(.runnerId == $id)]' "$HTTP_BODY"
}

wait_for_zero_sandboxes() {
  local runner_id="$1" elapsed=0 left
  while (( elapsed <= ROLL_TIMEOUT_SECONDS )); do
    left="$(list_mine "$runner_id" | jq 'length')"
    omc::log INFO "  sandboxes still on ${runner_id}: ${left}"
    [[ "$left" -eq 0 ]] && return 0
    sleep "$ROLL_POLL_SECONDS"
    elapsed=$((elapsed + ROLL_POLL_SECONDS))
  done
  return 1
}

wait_for_instance_termination() {
  local instance_id="$1" elapsed=0 state
  while (( elapsed <= ROLL_TIMEOUT_SECONDS )); do
    state="$(aws ec2 describe-instances --instance-ids "$instance_id" \
      --region "$AWS_REGION" --query 'Reservations[0].Instances[0].State.Name' \
      --output text 2>/dev/null || true)"
    omc::log INFO "  instance ${instance_id}: ${state:-unknown}"
    [[ "$state" == "terminated" ]] && return 0
    sleep "$ROLL_POLL_SECONDS"
    elapsed=$((elapsed + ROLL_POLL_SECONDS))
  done
  return 1
}

wait_for_replacement_pod() {
  local selector="$1" old_uids="$2" elapsed=0 pods candidate
  while (( elapsed <= ROLL_TIMEOUT_SECONDS )); do
    pods="$(kubectl -n "$NAMESPACE" get pods -l "$selector" -o json)"
    candidate="$(printf '%s' "$pods" | jq -c --argjson old "$old_uids" '
      [.items[]
       | select(.metadata.uid as $uid | ($old | index($uid)) == null)
       | select(.status.phase == "Running")
       | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))][0] // empty')"
    if [[ -n "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
    omc::log INFO "  waiting for a different Ready runner pod..."
    sleep "$ROLL_POLL_SECONDS"
    elapsed=$((elapsed + ROLL_POLL_SECONDS))
  done
  return 1
}

wait_for_fresh_runner() {
  local runner_id="$1" expected_ip="$2" old_last_checked="$3"
  local elapsed=0 runners target state api_url api_ip last_checked
  while (( elapsed <= ROLL_TIMEOUT_SECONDS )); do
    runners="$(fetch_runners)"
    target="$(runner_record "$runners" "$runner_id")"
    if [[ -n "$target" ]]; then
      state="$(printf '%s' "$target" | jq -r '.state // empty')"
      api_url="$(printf '%s' "$target" | jq -r '.apiUrl // empty')"
      api_ip="$(printf '%s' "$api_url" | sed -E 's#^https?://##; s#:.*$##')"
      last_checked="$(printf '%s' "$target" | jq -r '.lastChecked // empty')"
      if [[ "$state" == "ready" && "$api_ip" == "$expected_ip" && \
            ( -z "$old_last_checked" || "$last_checked" != "$old_last_checked" ) ]]; then
        printf '%s' "$target"
        return 0
      fi
      omc::log INFO "  runner heartbeat: state=${state:-absent} api=${api_ip:-absent} expected=${expected_ip}"
    else
      omc::log INFO "  runner is not registered yet..."
    fi
    sleep "$ROLL_POLL_SECONDS"
    elapsed=$((elapsed + ROLL_POLL_SECONDS))
  done
  return 1
}

# Region id — use the rendered secret when REGION_ID is not explicitly set.
REGION_ID="${REGION_ID:-$(kubectl -n "$NAMESPACE" get secret daytona-region-region-config \
  -o jsonpath='{.data.id}' 2>/dev/null | base64 -d || true)}"
[[ -n "$REGION_ID" ]] || omc::die "REGION_ID not found. Set REGION_ID=... (the *_XXXX region id) and re-run."

runners="$(fetch_runners)"
RUNNER_ID="${1:-}"
if [[ -z "$RUNNER_ID" ]]; then
  ready_count="$(printf '%s' "$runners" | jq '[.[] | select(.state == "ready" and (.unschedulable != true) and (.draining != true))] | length')"
  echo "Runners in region ${REGION_ID} (${ready_count} ready+schedulable):" >&2
  printf '%s' "$runners" | jq -r '.[] | "  \(.id)  \(.name)  state=\(.state) unschedulable=\(.unschedulable // false)"' >&2
  echo >&2
  echo "Usage: $0 <runner-id>" >&2
  exit 0
fi

[[ "$RUNNER_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
  || omc::die "Invalid runner id '$RUNNER_ID'. Copy the complete UUID from '$0' with no arguments."

target="$(runner_record "$runners" "$RUNNER_ID")"
[[ -n "$target" ]] || omc::die "Runner '$RUNNER_ID' does not exist in region '$REGION_ID'. Run '$0' to list exact ids."

runner_name="$(printf '%s' "$target" | jq -r '.name')"
runner_state="$(printf '%s' "$target" | jq -r '.state // empty')"
runner_unschedulable="$(printf '%s' "$target" | jq -r '.unschedulable // false')"
runner_api_url="$(printf '%s' "$target" | jq -r '.apiUrl // empty')"
runner_ip="$(printf '%s' "$runner_api_url" | sed -E 's#^https?://##; s#:.*$##')"
old_last_checked="$(printf '%s' "$target" | jq -r '.lastChecked // empty')"

[[ "$runner_state" == "ready" ]] || omc::die "Runner '$RUNNER_ID' is state='$runner_state', not ready; refusing an automatic roll."
[[ -n "$runner_ip" ]] || omc::die "Runner '$RUNNER_ID' has no usable apiUrl; cannot map it to an EKS node."

peers="$(healthy_peer_count "$runners" "$RUNNER_ID")"
(( peers >= 1 )) || omc::die "No other ready+schedulable runner exists. Restore or add peer capacity before rolling '$RUNNER_ID'."

# Finish every discovery/auth check before changing Daytona scheduling state.
aws sts get-caller-identity --region "$AWS_REGION" >/dev/null \
  || omc::die "AWS authentication failed. Refresh the selected profile before rolling."
kubectl get --raw='/readyz' >/dev/null \
  || omc::die "kubectl cannot authenticate to the cluster. Refresh AWS credentials/kubeconfig before rolling."

nodes_json="$(kubectl get nodes -o json)"
node="$(printf '%s' "$nodes_json" | jq -r --arg ip "$runner_ip" '
  [.items[] | select(any(.status.addresses[]?; .type == "InternalIP" and .address == $ip))]
  | if length == 1 then .[0].metadata.name else empty end')"
[[ -n "$node" ]] || omc::die "Could not uniquely map runner API IP '$runner_ip' to a Kubernetes node."

node_json="$(kubectl get node "$node" -o json)"
old_node_uid="$(printf '%s' "$node_json" | jq -r '.metadata.uid')"
[[ "$(printf '%s' "$node_json" | jq -r '.metadata.labels["daytona-sandbox-c"] // empty')" == "true" ]] \
  || omc::die "Node '$node' is not labelled daytona-sandbox-c=true; refusing to terminate it."
nodegroup="$(printf '%s' "$node_json" | jq -r '.metadata.labels["eks.amazonaws.com/nodegroup"] // empty')"
[[ -n "$nodegroup" ]] || omc::die "Node '$node' is not part of an EKS managed node group; refusing to terminate it."
provider_id="$(printf '%s' "$node_json" | jq -r '.spec.providerID // empty')"
instance_id="${provider_id##*/}"
[[ "$instance_id" =~ ^i-[0-9a-f]+$ ]] || omc::die "Node '$node' has unexpected providerID '$provider_id'."

pods_json="$(kubectl -n "$NAMESPACE" get pods -o json)"
pod="$(printf '%s' "$pods_json" | jq -r --arg node "$node" '
  [.items[]
   | select(.spec.nodeName == $node)
   | select(.metadata.labels["daytona.io/manual-runner"] == "true"
            or .metadata.labels["app.kubernetes.io/component"] == "runner")
   | select(any(.spec.containers[]?; any(.ports[]?; .containerPort == 3000))) ]
  | if length == 1 then .[0].metadata.name else empty end')"
[[ -n "$pod" ]] || omc::die "Could not uniquely identify the runner pod on node '$node'."

pod_json="$(kubectl -n "$NAMESPACE" get pod "$pod" -o json)"
replicaset="$(printf '%s' "$pod_json" | jq -r '[.metadata.ownerReferences[]? | select(.kind == "ReplicaSet")][0].name // empty')"
daemonset="$(printf '%s' "$pod_json" | jq -r '[.metadata.ownerReferences[]? | select(.kind == "DaemonSet")][0].name // empty')"
if [[ -n "$replicaset" ]]; then
  controller_kind="deployment"
  controller_name="$(kubectl -n "$NAMESPACE" get rs "$replicaset" -o json | jq -r '[.metadata.ownerReferences[]? | select(.kind == "Deployment")][0].name // empty')"
  [[ -n "$controller_name" ]] || omc::die "Runner ReplicaSet '$replicaset' is not controlled by a Deployment."
elif [[ -n "$daemonset" ]]; then
  controller_kind="daemonset"
  controller_name="$daemonset"
else
  omc::die "Runner pod '$pod' is not controlled by a Deployment or DaemonSet; refusing an automatic roll."
fi
selector="$(kubectl -n "$NAMESPACE" get "$controller_kind" "$controller_name" -o json | jq -r '
  .spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")')"
[[ -n "$selector" ]] || omc::die "$controller_kind '$controller_name' has no usable matchLabels selector."
old_controller_pod_uids="$(kubectl -n "$NAMESPACE" get pods -l "$selector" -o json | jq -c '[.items[].metadata.uid]')"

asg="$(aws autoscaling describe-auto-scaling-instances --instance-ids "$instance_id" \
  --region "$AWS_REGION" --query 'AutoScalingInstances[0].AutoScalingGroupName' --output text)"
[[ -n "$asg" && "$asg" != "None" ]] || omc::die "Instance '$instance_id' is not in an Auto Scaling group."
desired="$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$asg" \
  --region "$AWS_REGION" --query 'AutoScalingGroups[0].DesiredCapacity' --output text)"
[[ "$desired" =~ ^[0-9]+$ ]] && (( desired >= 2 )) \
  || omc::die "ASG '$asg' desired capacity is '$desired'; refusing a roll below two nodes."

omc::log INFO "Target: runner=$runner_name id=$RUNNER_ID pod=$pod node=$node instance=$instance_id nodegroup=$nodegroup"
omc::log INFO "Healthy peer runners: $peers; ASG desired capacity: $desired"
roll_started=1

if [[ "$runner_unschedulable" == "true" ]]; then
  omc::log INFO "Runner is already unschedulable; resuming its interrupted roll."
else
  omc::log INFO "Marking $RUNNER_ID unschedulable..."
  code="$(http PATCH "${DAYTONA_API_URL}/runners/${RUNNER_ID}/scheduling" '{"unschedulable":true}')"
  require_http_200 "scheduling PATCH" "$code"
fi

mine="$(list_mine "$RUNNER_ID")"
count="$(printf '%s' "$mine" | jq 'length')"
omc::log INFO "$RUNNER_ID hosts $count sandbox(es); stopping each to back it up before replacement..."
printf '%s' "$mine" | jq -r '.[].id' | while IFS= read -r sandbox_id; do
  [[ -z "$sandbox_id" ]] && continue
  code="$(http POST "${DAYTONA_API_URL}/sandbox/${sandbox_id}/stop")"
  [[ "$code" =~ ^2[0-9][0-9]$ ]] \
    || omc::die "Stopping sandbox '$sandbox_id' failed (HTTP $code): $(cat "$HTTP_BODY")"
  omc::log INFO "  stop $sandbox_id -> HTTP $code"
done

omc::log INFO "Marking $RUNNER_ID draining..."
code="$(http PATCH "${DAYTONA_API_URL}/runners/${RUNNER_ID}/draining" '{"draining":true}')"
require_http_200 "draining PATCH" "$code"

omc::log INFO "Waiting for $RUNNER_ID to hold zero sandboxes..."
wait_for_zero_sandboxes "$RUNNER_ID" \
  || omc::die "$RUNNER_ID still owns sandboxes after ${ROLL_TIMEOUT_SECONDS}s; node was NOT terminated."

# Recheck the peer immediately before the destructive AWS call.
runners="$(fetch_runners)"
peers="$(healthy_peer_count "$runners" "$RUNNER_ID")"
(( peers >= 1 )) || omc::die "The peer runner is no longer healthy; node was NOT terminated."

omc::log INFO "Terminating managed-node-group instance $instance_id; ASG '$asg' will replace it..."
aws ec2 terminate-instances --instance-ids "$instance_id" --region "$AWS_REGION" >/dev/null
wait_for_instance_termination "$instance_id" \
  || omc::die "Instance '$instance_id' did not reach terminated within ${ROLL_TIMEOUT_SECONDS}s."

# The process is provably gone; remove its stale API object so the Deployment
# can create a replacement immediately instead of waiting for node eviction.
if kubectl -n "$NAMESPACE" get pod "$pod" >/dev/null 2>&1; then
  omc::log INFO "Removing stale pod object $pod after EC2 termination..."
  kubectl -n "$NAMESPACE" delete pod "$pod" --grace-period=0 --force --wait=false >/dev/null
fi

omc::log INFO "Waiting for $controller_kind '$controller_name' to create a different Ready pod..."
replacement="$(wait_for_replacement_pod "$selector" "$old_controller_pod_uids")" \
  || omc::die "No replacement runner pod became Ready within ${ROLL_TIMEOUT_SECONDS}s."
new_pod="$(printf '%s' "$replacement" | jq -r '.metadata.name')"
new_node="$(printf '%s' "$replacement" | jq -r '.spec.nodeName')"
new_node_json="$(kubectl get node "$new_node" -o json)"
new_node_uid="$(printf '%s' "$new_node_json" | jq -r '.metadata.uid')"
new_provider_id="$(printf '%s' "$new_node_json" | jq -r '.spec.providerID // empty')"
new_instance_id="${new_provider_id##*/}"
[[ "$new_node_uid" != "$old_node_uid" && "$new_instance_id" != "$instance_id" ]] \
  || omc::die "Pod '$new_pod' is not on a provably new node/instance; refusing to re-enable scheduling."
new_ip="$(printf '%s' "$new_node_json" | jq -r '[.status.addresses[] | select(.type == "InternalIP")][0].address // empty')"
[[ -n "$new_ip" ]] || omc::die "Replacement node '$new_node' has no InternalIP."

omc::log INFO "Replacement pod $new_pod is Ready on $new_node ($new_ip); waiting for fresh Daytona heartbeat..."
wait_for_fresh_runner "$RUNNER_ID" "$new_ip" "$old_last_checked" >/dev/null \
  || omc::die "Runner '$RUNNER_ID' did not report a fresh ready heartbeat from '$new_ip' within ${ROLL_TIMEOUT_SECONDS}s."

omc::log INFO "Clearing draining and restoring scheduling only after the fresh heartbeat..."
code="$(http PATCH "${DAYTONA_API_URL}/runners/${RUNNER_ID}/draining" '{"draining":false}')"
require_http_200 "clear draining PATCH" "$code"
code="$(http PATCH "${DAYTONA_API_URL}/runners/${RUNNER_ID}/scheduling" '{"unschedulable":false}')"
require_http_200 "restore scheduling PATCH" "$code"

runners="$(fetch_runners)"
target="$(runner_record "$runners" "$RUNNER_ID")"
[[ "$(printf '%s' "$target" | jq -r '.state')" == "ready" ]] \
  || omc::die "Replacement runner is not ready after scheduling restore."
[[ "$(printf '%s' "$target" | jq -r '.unschedulable // false')" == "false" ]] \
  || omc::die "Replacement runner remains unschedulable."
[[ "$(printf '%s' "$target" | jq -r '.draining // false')" == "false" ]] \
  || omc::die "Replacement runner remains draining."
healthy_total="$(printf '%s' "$runners" | jq '[.[] | select(.state == "ready" and (.unschedulable != true) and (.draining != true))] | length')"
(( healthy_total >= 2 )) || omc::die "Roll finished but only $healthy_total ready+schedulable runner(s) are registered."

roll_completed=1
omc::log INFO "ROLL COMPLETE: $RUNNER_ID replaced $pod/$node with $new_pod/$new_node; $healthy_total runners are ready+schedulable."
