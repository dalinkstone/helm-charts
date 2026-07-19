#!/usr/bin/env bash
# Rebuild the v0.199-compatible runner-manager from one reviewed source commit.
# This uses the original upstream Dockerfile; it does not patch image layers,
# extract/decompile a release binary, or run install.sh on an EC2 instance.
set -euo pipefail
IFS=$'\n\t'

RUNNER_MANAGER_SOURCE_REPOSITORY="${RUNNER_MANAGER_SOURCE_REPOSITORY:-https://github.com/daytonaio/daytona-ai.git}"
RUNNER_MANAGER_SOURCE_COMMIT="${RUNNER_MANAGER_SOURCE_COMMIT:-}"
RUNNER_MANAGER_VERSION="${RUNNER_MANAGER_VERSION:-v0.184.0-k8s-oss.5-v0199-api-autoscale}"
IMAGE_REF="${IMAGE_REF:-}"
PUSH="${PUSH:-false}"
KEEP_BUILD_ROOT="${KEEP_BUILD_ROOT:-false}"

[[ -n "$IMAGE_REF" ]] || { echo "ERROR: set IMAGE_REF=registry/repository:tag" >&2; exit 1; }
[[ "$RUNNER_MANAGER_SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] \
  || { echo "ERROR: set RUNNER_MANAGER_SOURCE_COMMIT to the reviewed 40-character source commit" >&2; exit 1; }
for command_name in docker file git; do
  command -v "$command_name" >/dev/null || { echo "ERROR: $command_name is required" >&2; exit 1; }
done
docker info >/dev/null 2>&1 || { echo "ERROR: a running Docker daemon is required" >&2; exit 1; }

build_root="$(mktemp -d -t daytona-runner-manager.XXXXXXXX)"
inspect_container="daytona-runner-manager-inspect-$$"
cleanup() {
  docker rm -f "$inspect_container" >/dev/null 2>&1 || true
  if [[ "$KEEP_BUILD_ROOT" != "true" ]]; then
    rm -rf "$build_root"
  else
    echo "Build root preserved: $build_root" >&2
  fi
}
trap cleanup EXIT INT TERM

source_root="$build_root/daytona-ai"
git init --quiet "$source_root"
git -C "$source_root" remote add origin "$RUNNER_MANAGER_SOURCE_REPOSITORY"
git -C "$source_root" fetch --quiet --depth 1 origin "$RUNNER_MANAGER_SOURCE_COMMIT"
git -C "$source_root" checkout --quiet --detach FETCH_HEAD
actual_commit="$(git -C "$source_root" rev-parse HEAD)"
[[ "$actual_commit" == "$RUNNER_MANAGER_SOURCE_COMMIT" ]] \
  || { echo "ERROR: expected source $RUNNER_MANAGER_SOURCE_COMMIT, found $actual_commit" >&2; exit 1; }
[[ -z "$(git -C "$source_root" status --porcelain)" ]] \
  || { echo "ERROR: runner-manager source worktree is not clean" >&2; exit 1; }

echo "Building runner-manager from $actual_commit for linux/amd64..." >&2
docker buildx build \
  --platform linux/amd64 \
  --file "$source_root/apps/runner-manager/Dockerfile" \
  --target runner-manager \
  --build-arg "VERSION=$RUNNER_MANAGER_VERSION" \
  --tag "$IMAGE_REF" \
  --load \
  "$source_root"

[[ "$(docker image inspect "$IMAGE_REF" --format '{{.Os}}/{{.Architecture}}')" == "linux/amd64" ]] \
  || { echo "ERROR: built image is not linux/amd64" >&2; exit 1; }
docker create --platform linux/amd64 --name "$inspect_container" --entrypoint /bin/true "$IMAGE_REF" >/dev/null
docker cp "$inspect_container:/usr/local/bin/daytona-runner-manager" "$build_root/daytona-runner-manager"
docker rm "$inspect_container" >/dev/null
file "$build_root/daytona-runner-manager" | grep -Eq 'ELF 64-bit.*x86-64|ELF 64-bit.*x86_64' \
  || { file "$build_root/daytona-runner-manager" >&2; echo "ERROR: runner-manager is not a linux/amd64 ELF" >&2; exit 1; }
binary_digest="$(shasum -a 256 "$build_root/daytona-runner-manager" | awk '{print $1}')"

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
  image_digest="$(aws ecr describe-images --region "$aws_region" --repository-name "$repository" \
    --image-ids "imageTag=$image_tag" --query 'imageDetails[0].imageDigest' --output text)"
  echo "Pushed runner-manager image: $IMAGE_REF@$image_digest" >&2
else
  image_digest="$(docker image inspect "$IMAGE_REF" --format '{{index .RepoDigests 0}}' 2>/dev/null || true)"
  echo "Built runner-manager image: $IMAGE_REF" >&2
fi

echo "source_commit=$actual_commit"
echo "binary_sha256=$binary_digest"
echo "image_digest=${image_digest:-local-only}"
