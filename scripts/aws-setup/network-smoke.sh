#!/usr/bin/env bash
# Repeatedly exercise the exact paths implicated in the customer incident:
# runner-node -> sandbox toolbox:2280, sandbox DNS, and sandbox direct-IP
# egress. This is read-only and writes a timestamped report under .state/.
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$SCRIPT_DIR/.state"
PROMPTS_FILE="$STATE_DIR/prompts.env"
if [[ -f "$PROMPTS_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  . "$PROMPTS_FILE"
  set +a
fi

NAMESPACE="${NAMESPACE:-daytona}"
ITERATIONS="${ITERATIONS:-60}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-2}"
TOOLBOX_PORT="${TOOLBOX_PORT:-2280}"
EGRESS_HOST="${EGRESS_HOST:-1.1.1.1}"
EGRESS_PORT="${EGRESS_PORT:-443}"
api_host="${DAYTONA_API_URL:-https://app.daytona.io/api}"
api_host="${api_host#*://}"
DNS_NAME="${DNS_NAME:-${api_host%%/*}}"
SANDBOX_CONTAINER="${SANDBOX_CONTAINER:-}"
mkdir -p "$STATE_DIR"
REPORT="${REPORT:-$STATE_DIR/network-smoke-$(date -u +%Y%m%dT%H%M%SZ).log}"

for cmd in kubectl jq; do
  command -v "$cmd" >/dev/null || { echo "ERROR: $cmd is required" >&2; exit 1; }
done
[[ "$ITERATIONS" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: ITERATIONS must be a positive integer" >&2; exit 1; }
[[ "$INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || { echo "ERROR: INTERVAL_SECONDS must be a non-negative integer" >&2; exit 1; }

exec > >(tee "$REPORT") 2>&1

echo "Daytona AWS network smoke test"
echo "started=$(date -u +%FT%TZ) namespace=$NAMESPACE iterations=$ITERATIONS interval=${INTERVAL_SECONDS}s"
echo "dns=$DNS_NAME direct_egress=$EGRESS_HOST:$EGRESS_PORT toolbox_port=$TOOLBOX_PORT"
echo

echo "== Deployed image bundle =="
kubectl -n "$NAMESPACE" get pods -o json | jq -r '
  .items[]
  | select(.metadata.annotations["daytona.io/image-bundle"] != null)
  | [
      .metadata.name,
      .spec.nodeName,
      .metadata.annotations["daytona.io/image-bundle"],
      .metadata.annotations["daytona.io/image-version"],
      ([.spec.containers[].image] | join(","))
    ] | @tsv'
echo

runner_pods=()
while IFS= read -r runner_pod; do
  [[ -n "$runner_pod" ]] && runner_pods+=("$runner_pod")
done < <(
  kubectl -n "$NAMESPACE" get pods -l 'app.kubernetes.io/component=runner,daytona.io/runner=true' \
    -o json | jq -r '.items[] | select(.status.phase == "Running") | .metadata.name'
)
[[ "${#runner_pods[@]}" -gt 0 ]] || { echo "ERROR: no running runner DaemonSet pods"; exit 1; }

host_exec() {
  local pod="$1"
  shift
  kubectl -n "$NAMESPACE" exec "$pod" -c docker-installer -- \
    nsenter -t 1 -m -u -n -i -- "$@"
}

echo "== Host policy and runtime state =="
for pod in "${runner_pods[@]}"; do
  echo "-- $pod --"
  host_exec "$pod" sh -c '
    echo "node=$(hostname) docker=$(docker version --format "{{.Server.Version}}" 2>/dev/null || echo unavailable)"
    echo "resolver:"; sed "s/^/  /" /etc/resolv.conf
    echo "host-staged sandbox binary hashes:"
    sha256sum /usr/local/bin/.tmp/binaries/daemon-amd64 \
      /usr/local/bin/.tmp/binaries/daytona-computer-use 2>/dev/null || true
    echo "SBX jumps (must be empty while networkPolicy.enabled=false):"
    iptables -w -S DOCKER-USER 2>/dev/null | grep SBX || true
    iptables -w -S INPUT 2>/dev/null | grep SBX || true
    echo "containers:"
    docker ps --format "  {{.ID}}\t{{.Names}}\t{{.Image}}"
  '
done
echo

container_rows=()
for pod in "${runner_pods[@]}"; do
  while IFS=$'\t' read -r cid cname cimage; do
    [[ -n "$cid" ]] && container_rows+=("$pod"$'\t'"$cid"$'\t'"$cname"$'\t'"$cimage")
  done < <(host_exec "$pod" docker ps --format '{{.ID}}\t{{.Names}}\t{{.Image}}')
done

if [[ -z "$SANDBOX_CONTAINER" ]]; then
  if [[ "${#container_rows[@]}" -eq 1 ]]; then
    SANDBOX_CONTAINER="$(printf '%s' "${container_rows[0]}" | cut -f2)"
    echo "Auto-selected the only running sandbox container: $SANDBOX_CONTAINER"
  else
    echo "Found ${#container_rows[@]} running sandbox containers:" >&2
    for row in "${container_rows[@]}"; do
      IFS=$'\t' read -r pod cid cname cimage <<<"$row"
      printf '  pod=%s id=%s name=%s image=%s\n' "$pod" "$cid" "$cname" "$cimage" >&2
    done
    echo "ERROR: set SANDBOX_CONTAINER=<id-or-name> when zero or multiple sandboxes are running" >&2
    exit 2
  fi
fi

selected_pod=""
selected_id=""
for row in "${container_rows[@]}"; do
  IFS=$'\t' read -r pod cid cname _ <<<"$row"
  if [[ "$cid" == "$SANDBOX_CONTAINER"* || "$cname" == *"$SANDBOX_CONTAINER"* ]]; then
    selected_pod="$pod"
    selected_id="$cid"
    break
  fi
done
if [[ -z "$selected_id" && "${#container_rows[@]}" -eq 1 ]]; then
  selected_pod="$(printf '%s' "${container_rows[0]}" | cut -f1)"
  selected_id="$(printf '%s' "${container_rows[0]}" | cut -f2)"
  echo "Requested sandbox name was not present in the Docker name; selected the only running container: $selected_id"
fi
[[ -n "$selected_id" ]] || { echo "ERROR: sandbox container not found: $SANDBOX_CONTAINER"; exit 1; }

sandbox_ip="$(host_exec "$selected_pod" docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$selected_id")"
[[ -n "$sandbox_ip" ]] || { echo "ERROR: no Docker IP for $selected_id"; exit 1; }

echo
echo "== Selected sandbox =="
echo "runner_pod=$selected_pod container=$selected_id ip=$sandbox_ip"
host_exec "$selected_pod" docker inspect "$selected_id" \
  --format 'state={{json .State}} networks={{json .NetworkSettings.Networks}}'
echo "toolbox listener inside sandbox:"
host_exec "$selected_pod" docker exec "$selected_id" sh -c \
  "(ss -lntp 2>/dev/null || netstat -lntp 2>/dev/null || true) | grep ':${TOOLBOX_PORT}' || true"
echo "injected sandbox binary hash:"
host_exec "$selected_pod" docker exec "$selected_id" sh -c \
  'sha256sum /usr/local/bin/daytona 2>/dev/null || true'
echo

failures=0
skips=0
for ((i=1; i<=ITERATIONS; i++)); do
  timestamp="$(date -u +%FT%TZ)"
  toolbox=FAIL
  dns=FAIL
  egress=FAIL

  if host_exec "$selected_pod" timeout 3 bash -c \
    "exec 3<>/dev/tcp/${sandbox_ip}/${TOOLBOX_PORT}; exec 3>&-" >/dev/null 2>&1; then
    toolbox=PASS
  fi

  if host_exec "$selected_pod" docker exec "$selected_id" sh -c \
    'if command -v getent >/dev/null; then getent hosts "$1"; elif command -v nslookup >/dev/null; then nslookup "$1"; else exit 77; fi' \
    sh "$DNS_NAME" >/dev/null 2>&1; then
    dns=PASS
  else
    rc=$?
    [[ "$rc" -eq 77 ]] && { dns=SKIP; skips=$((skips + 1)); }
  fi

  if host_exec "$selected_pod" docker exec "$selected_id" sh -c '
    if command -v python3 >/dev/null; then
      python3 -c "import socket; s=socket.create_connection((\"$1\",int(\"$2\")),3); s.close()"
    elif command -v bash >/dev/null && command -v timeout >/dev/null; then
      timeout 3 bash -c "exec 3<>/dev/tcp/$1/$2; exec 3>&-"
    else
      exit 77
    fi
  ' sh "$EGRESS_HOST" "$EGRESS_PORT" >/dev/null 2>&1; then
    egress=PASS
  else
    rc=$?
    [[ "$rc" -eq 77 ]] && { egress=SKIP; skips=$((skips + 1)); }
  fi

  echo "$timestamp iteration=$i toolbox=$toolbox dns=$dns egress=$egress"
  [[ "$toolbox" == FAIL || "$dns" == FAIL || "$egress" == FAIL ]] && failures=$((failures + 1))
  [[ "$i" -lt "$ITERATIONS" ]] && sleep "$INTERVAL_SECONDS"
done

echo
echo "== Final diagnostics =="
host_exec "$selected_pod" sh -c '
  echo "docker events from the last 10 minutes:"
  docker events --since 10m --until 0s 2>/dev/null | tail -n 100 || true
  echo "kernel/network messages:"
  journalctl -k --since "10 minutes ago" --no-pager 2>/dev/null \
    | grep -Ei "conntrack|veth|docker|bridge|network|nf_" | tail -n 100 || true
  echo "conntrack usage:"
  printf "count="; cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || true
  printf "max="; cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || true
'

echo "completed=$(date -u +%FT%TZ) failed_iterations=$failures skipped_checks=$skips report=$REPORT"
[[ "$failures" -eq 0 ]] || exit 1
