#!/usr/bin/env bash
# Create one dedicated sandbox, run network-smoke.sh against it, then delete it.
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

values="$(helm -n "${NAMESPACE:-daytona}" get values "${RELEASE:-daytona-region}" -o json)"
REGION_NAME="$(jq -r '.regionName // empty' <<<"$values")"
DAYTONA_API_URL="$(jq -r '.daytonaApiUrl // empty' <<<"$values")"
DAYTONA_API_KEY="$(jq -r '.daytonaApiKey // empty' <<<"$values")"
: "${REGION_NAME:?live Helm release has no regionName}"
: "${DAYTONA_API_URL:?live Helm release has no daytonaApiUrl}"
: "${DAYTONA_API_KEY:?live Helm release has no daytonaApiKey}"

command -v python3 >/dev/null || { echo "ERROR: python3 is required" >&2; exit 1; }
PYTHON_BIN=python3
if "$PYTHON_BIN" -c 'import daytona' 2>/dev/null; then
  :
elif [[ -x "$STATE_DIR/.venv/bin/python" ]] \
  && "$STATE_DIR/.venv/bin/python" -c 'import daytona' 2>/dev/null; then
  PYTHON_BIN="$STATE_DIR/.venv/bin/python"
else
  python3 -m venv "$STATE_DIR/.venv" \
    || { echo "ERROR: failed to create venv; install python3-venv" >&2; exit 1; }
  PYTHON_BIN="$STATE_DIR/.venv/bin/python"
  "$STATE_DIR/.venv/bin/pip" install --quiet 'daytona==0.183.*'
fi

DAYTONA_API_URL="$DAYTONA_API_URL" \
DAYTONA_API_KEY="$DAYTONA_API_KEY" \
REGION_NAME="$REGION_NAME" \
NETWORK_SMOKE_SCRIPT="$SCRIPT_DIR/network-smoke.sh" \
"$PYTHON_BIN" - <<'PY'
import os
import subprocess
from daytona import Daytona, DaytonaConfig, Image
try:
    from daytona import CreateSandboxFromImageParams
except ImportError:
    from daytona.common import CreateSandboxFromImageParams

client = Daytona(DaytonaConfig(
    api_key=os.environ["DAYTONA_API_KEY"],
    api_url=os.environ["DAYTONA_API_URL"],
    target=os.environ["REGION_NAME"],
))
sandbox = None
try:
    print("Creating dedicated network-smoke sandbox from alpine:3.21", flush=True)
    sandbox = client.create(
        CreateSandboxFromImageParams(image=Image.base("alpine:3.21")),
        timeout=300,
    )
    print(f"Network-smoke sandbox ready: {sandbox.id}", flush=True)
    env = os.environ.copy()
    env["SANDBOX_CONTAINER"] = sandbox.id
    subprocess.run(["bash", env["NETWORK_SMOKE_SCRIPT"]], env=env, check=True)
finally:
    if sandbox is not None:
        print(f"Deleting network-smoke sandbox: {sandbox.id}", flush=True)
        client.delete(sandbox)
PY
