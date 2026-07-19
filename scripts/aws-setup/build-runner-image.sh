#!/usr/bin/env bash
# Build and verify a private Daytona runner image for the v0.199 compatibility
# canary. No cluster resources are changed. PUSH=true optionally publishes the
# verified image to ECR.
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RUNNER_VERSION="${RUNNER_VERSION:-v0.199.0}"
GH_REPOSITORY="${GH_REPOSITORY:-daytonaio/daytona-ai}"
BASE_IMAGE="${BASE_IMAGE:-daytonaio/daytona-runner:v0.184.0-k8s-oss.3-amd64}"
IMAGE_REF="${IMAGE_REF:-}"
PUSH="${PUSH:-false}"

command -v docker >/dev/null || { echo "ERROR: docker is required" >&2; exit 1; }
command -v file >/dev/null || { echo "ERROR: file is required" >&2; exit 1; }
command -v sha256sum >/dev/null || command -v shasum >/dev/null \
  || { echo "ERROR: sha256sum or shasum is required" >&2; exit 1; }
[[ -n "$IMAGE_REF" ]] || {
  echo "ERROR: set IMAGE_REF=registry/repository:tag" >&2
  exit 1
}

build_context="$(mktemp -d -t daytona-runner-build.XXXXXXXX)"
trap 'rm -rf "$build_context"' EXIT INT TERM

if [[ -n "${RUNNER_BINARY:-}" ]]; then
  [[ -f "$RUNNER_BINARY" ]] || { echo "ERROR: RUNNER_BINARY not found: $RUNNER_BINARY" >&2; exit 1; }
  cp "$RUNNER_BINARY" "$build_context/runner-amd64"
else
  command -v gh >/dev/null || { echo "ERROR: gh is required when RUNNER_BINARY is unset" >&2; exit 1; }
  echo "Downloading runner-amd64 from private release ${GH_REPOSITORY}@${RUNNER_VERSION}..." >&2
  gh release download "$RUNNER_VERSION" --repo "$GH_REPOSITORY" \
    --pattern runner-amd64 --output "$build_context/runner-amd64"
fi

chmod 0755 "$build_context/runner-amd64"
file "$build_context/runner-amd64" | grep -Eq 'ELF 64-bit.*x86-64|ELF 64-bit.*x86_64' || {
  file "$build_context/runner-amd64" >&2
  echo "ERROR: runner-amd64 is not a linux/amd64 ELF" >&2
  exit 1
}

if command -v sha256sum >/dev/null; then
  sha256sum "$build_context/runner-amd64"
else
  shasum -a 256 "$build_context/runner-amd64"
fi

cp "$REPO_ROOT/images/daytona-runner-private/Dockerfile" "$build_context/Dockerfile"
docker build --platform linux/amd64 --pull \
  --build-arg "BASE_IMAGE=$BASE_IMAGE" \
  --tag "$IMAGE_REF" "$build_context"

echo "Verifying that the runner extracts its sandbox daemon/toolbox assets..." >&2
docker run --rm --platform linux/amd64 --entrypoint /bin/sh \
  -e DAYTONA_API_URL=http://127.0.0.1 \
  -e SERVER_URL=http://127.0.0.1 \
  -e API_TOKEN=installer \
  -e AWS_REGION=us-east-1 \
  -e AWS_ENDPOINT_URL=http://127.0.0.1 \
  -e AWS_ACCESS_KEY_ID=installer \
  -e AWS_SECRET_ACCESS_KEY=installer \
  -e AWS_DEFAULT_BUCKET=installer \
  -e SSH_PUBLIC_KEY=installer \
  "$IMAGE_REF" -c '
    set -eu
    cd /usr/local/bin
    rm -rf .tmp/binaries
    ./daytona-runner >/tmp/daytona-runner-extract.log 2>&1 &
    runner_pid=$!
    extracted=false
    for _ in $(seq 1 60); do
      if [ -s .tmp/binaries/daemon-amd64 ] && [ -s .tmp/binaries/daytona-computer-use ]; then
        extracted=true
        break
      fi
      kill -0 "$runner_pid" 2>/dev/null || true
      sleep 1
    done
    kill -9 "$runner_pid" 2>/dev/null || true
    wait "$runner_pid" 2>/dev/null || true
    if [ "$extracted" != true ]; then
      tail -n 100 /tmp/daytona-runner-extract.log >&2 || true
      echo "ERROR: runner did not extract daemon-amd64 and daytona-computer-use" >&2
      exit 1
    fi
    test -x .tmp/binaries/daemon-amd64
    test -x .tmp/binaries/daytona-computer-use
    sha256sum .tmp/binaries/daemon-amd64 .tmp/binaries/daytona-computer-use
  '

if [[ "$PUSH" == "true" ]]; then
  command -v aws >/dev/null || { echo "ERROR: aws is required for PUSH=true" >&2; exit 1; }
  registry="${IMAGE_REF%%/*}"
  repository_and_tag="${IMAGE_REF#*/}"
  repository="${repository_and_tag%:*}"
  aws_region="${AWS_REGION:-$(printf '%s' "$registry" | cut -d. -f4)}"
  account_id="${registry%%.*}"
  [[ "$registry" == *.dkr.ecr.*.amazonaws.com ]] || {
    echo "ERROR: PUSH=true currently supports ECR image references only" >&2
    exit 1
  }
  aws ecr describe-repositories --region "$aws_region" --repository-names "$repository" >/dev/null 2>&1 \
    || aws ecr create-repository --region "$aws_region" --repository-name "$repository" >/dev/null
  aws ecr get-login-password --region "$aws_region" \
    | docker login --username AWS --password-stdin "$account_id.dkr.ecr.$aws_region.amazonaws.com"
  docker push "$IMAGE_REF"
fi

echo "Verified runner image: $IMAGE_REF" >&2
echo "Use with: DAYTONA_IMAGE_PROFILE=v0.199-canary RUNNER_IMAGE_REF=$IMAGE_REF bash scripts/aws-setup/up.sh" >&2
