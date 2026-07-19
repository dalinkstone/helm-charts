# syntax=docker/dockerfile:1

# Canary bridge image: retain the known-working BYOC image userland while
# replacing the runner executable with an authenticated private release asset.
# For production, prefer the Dockerfile/base image shipped with that release.
ARG BASE_IMAGE=daytonaio/daytona-runner:v0.184.0-k8s-oss.3-amd64
FROM ${BASE_IMAGE}

USER root
COPY --chmod=0755 runner-amd64 /usr/local/bin/daytona-runner

RUN test -x /usr/local/bin/daytona-runner
