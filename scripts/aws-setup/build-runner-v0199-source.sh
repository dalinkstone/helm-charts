#!/usr/bin/env bash
# Rebuild the official v0.199 runner with the BYOC object-storage compatibility
# patch. The produced image keeps the upstream Dockerfile/runtime layout.
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_FILE="$SCRIPT_DIR/patches/daytona-runner-v0.199-object-storage.patch"
RUNNER_VERSION="${RUNNER_VERSION:-v0.199.0}"
RUNNER_SOURCE_REPOSITORY="${RUNNER_SOURCE_REPOSITORY:-https://github.com/daytonaio/daytona-ai.git}"
IMAGE_REF="${IMAGE_REF:-}"
PUSH="${PUSH:-false}"
KEEP_BUILD_ROOT="${KEEP_BUILD_ROOT:-false}"

[[ -n "$IMAGE_REF" ]] || { echo "ERROR: set IMAGE_REF=registry/repository:tag" >&2; exit 1; }
for command_name in docker file git; do
  command -v "$command_name" >/dev/null || { echo "ERROR: $command_name is required" >&2; exit 1; }
done
docker info >/dev/null 2>&1 || { echo "ERROR: a running Docker daemon is required" >&2; exit 1; }
[[ -f "$PATCH_FILE" ]] || { echo "ERROR: patch not found: $PATCH_FILE" >&2; exit 1; }

build_root="$(mktemp -d -t daytona-runner-v0199.XXXXXXXX)"
computer_use_image="daytona-computer-use-build:${RUNNER_VERSION#v}"
computer_use_container="daytona-computer-use-extract-$$"
runner_inspect_container="daytona-runner-inspect-$$"
cleanup() {
  docker rm -f "$computer_use_container" "$runner_inspect_container" >/dev/null 2>&1 || true
  if [[ "$KEEP_BUILD_ROOT" != "true" ]]; then
    rm -rf "$build_root"
  else
    echo "Build root preserved: $build_root" >&2
  fi
}
trap cleanup EXIT INT TERM

source_root="$build_root/daytona-ai"
echo "Cloning Daytona runner source at $RUNNER_VERSION..." >&2
git clone --quiet --depth 1 --branch "$RUNNER_VERSION" "$RUNNER_SOURCE_REPOSITORY" "$source_root"
git -C "$source_root" apply --unidiff-zero --check "$PATCH_FILE"
git -C "$source_root" apply --unidiff-zero "$PATCH_FILE"
git -C "$source_root" diff --check

# The upstream v0.199.0 tag intentionally ignores go.work.sum, but
# hack/computer-use/Dockerfile still copies that file into its build context.
# Generate the checksum from the exact tagged workspace with its declared Go
# toolchain. An empty placeholder or a checksum copied from another revision
# can hide dependency drift and will fail later in the Docker build.
if [[ ! -s "$source_root/go.work.sum" ]]; then
  go_workspace_version="$(awk '$1 == "go" { print $2; exit }' "$source_root/go.work")"
  [[ "$go_workspace_version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] \
    || { echo "ERROR: could not determine Go version from $source_root/go.work" >&2; exit 1; }
  echo "Generating missing go.work.sum with Go $go_workspace_version..." >&2
  docker run --rm \
    --user "$(id -u):$(id -g)" \
    --env HOME=/tmp \
    --env GOCACHE=/tmp/go-build \
    --env GOMODCACHE=/tmp/go-mod \
    --volume "$source_root:/src" \
    --workdir /src \
    "golang:$go_workspace_version" \
    go list -mod=readonly all >/dev/null
fi
[[ -s "$source_root/go.work.sum" ]] \
  || { echo "ERROR: failed to generate $source_root/go.work.sum" >&2; exit 1; }

echo "Building the upstream computer-use artifact for linux/amd64..." >&2
docker build --platform linux/amd64 \
  --tag "$computer_use_image" \
  --file "$source_root/hack/computer-use/Dockerfile" \
  "$source_root"
mkdir -p "$source_root/dist/libs"
docker create --platform linux/amd64 --name "$computer_use_container" "$computer_use_image" >/dev/null
docker cp "$computer_use_container:/app/computer-use" "$source_root/dist/libs/computer-use-amd64"
docker rm "$computer_use_container" >/dev/null
chmod 0755 "$source_root/dist/libs/computer-use-amd64"

image_version="${RUNNER_VERSION}-object-storage"
echo "Building the patched upstream runner image for linux/amd64..." >&2
docker build --platform linux/amd64 \
  --file "$source_root/apps/runner/Dockerfile" \
  --build-arg "VERSION=$image_version" \
  --tag "$IMAGE_REF" \
  "$source_root"

[[ "$(docker image inspect "$IMAGE_REF" --format '{{.Os}}/{{.Architecture}}')" == "linux/amd64" ]] \
  || { echo "ERROR: built image is not linux/amd64" >&2; exit 1; }
docker create --platform linux/amd64 --name "$runner_inspect_container" --entrypoint /bin/true "$IMAGE_REF" >/dev/null
docker cp "$runner_inspect_container:/usr/local/bin/daytona-runner" "$build_root/daytona-runner"
docker rm "$runner_inspect_container" >/dev/null
file "$build_root/daytona-runner" | grep -Eq 'ELF 64-bit.*x86-64|ELF 64-bit.*x86_64' \
  || { file "$build_root/daytona-runner" >&2; echo "ERROR: runner is not a linux/amd64 ELF" >&2; exit 1; }

if [[ "$PUSH" == "true" ]]; then
  command -v aws >/dev/null || { echo "ERROR: aws is required for PUSH=true" >&2; exit 1; }
  registry="${IMAGE_REF%%/*}"
  repository_and_tag="${IMAGE_REF#*/}"
  repository="${repository_and_tag%:*}"
  image_tag="${repository_and_tag##*:}"
  aws_region="${AWS_REGION:-$(printf '%s' "$registry" | cut -d. -f4)}"
  [[ "$registry" == *.dkr.ecr.*.amazonaws.com ]] \
    || { echo "ERROR: PUSH=true currently supports ECR image references only" >&2; exit 1; }
  aws ecr describe-repositories --region "$aws_region" --repository-names "$repository" >/dev/null 2>&1 \
    || aws ecr create-repository --region "$aws_region" --repository-name "$repository" >/dev/null
  aws ecr get-login-password --region "$aws_region" \
    | docker login --username AWS --password-stdin "$registry"
  docker push "$IMAGE_REF"
  digest="$(aws ecr describe-images --region "$aws_region" --repository-name "$repository" \
    --image-ids "imageTag=$image_tag" --query 'imageDetails[0].imageDigest' --output text)"
  echo "Pushed runner image: $IMAGE_REF@$digest" >&2
else
  echo "Built runner image: $IMAGE_REF" >&2
fi
