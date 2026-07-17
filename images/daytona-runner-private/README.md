# Private Daytona runner canary image

This image overlays an authenticated `runner-amd64` release artifact onto the
known-working public BYOC runner image. The runner embeds the sandbox
`daemon-amd64` (toolbox) and `daytona-computer-use` binaries, so the build script
does not accept the image until both are extracted successfully at runtime.

Build from an already downloaded artifact:

```bash
RUNNER_BINARY=/secure/path/runner-amd64 \
IMAGE_REF=123456789012.dkr.ecr.us-east-1.amazonaws.com/daytona-runner:v0.199.0-byoc-amd64 \
bash scripts/aws-setup/build-runner-image.sh
```

Or let the script use authenticated GitHub CLI access:

```bash
GH_REPOSITORY=daytonaio/daytona-ai \
RUNNER_VERSION=v0.199.0 \
IMAGE_REF=123456789012.dkr.ecr.us-east-1.amazonaws.com/daytona-runner:v0.199.0-byoc-amd64 \
bash scripts/aws-setup/build-runner-image.sh
```

Set `PUSH=true` to log into the target ECR registry, create the repository when
needed, and push the verified image. The raw private binary is copied only into
a temporary build context and is removed when the script exits.
