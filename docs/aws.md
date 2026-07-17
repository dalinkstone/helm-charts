# Daytona BYOC — AWS / EKS

Single interactive script that creates an EKS cluster, S3 bucket, IAM identity, and deploys the daytona-region helm chart. You end up with a working BYOC region and a proxy URL to test sandbox creation against.

## Prerequisites

| Tool | Check |
|---|---|
| `aws` v2.34+ | `aws --version` |
| `eksctl` | `eksctl version` |
| `kubectl`, `helm`, `envsubst`, `yq`, `jq` | see [`README.md`](README.md) |

AWS account:

```bash
aws sts get-caller-identity     # must return your account
aws configure list              # confirm region default
```

The IAM principal running `up.sh` needs: `eksctl create cluster`, `iam:*`, `s3:*`, plus anything `eksctl` itself needs (VPC, CloudFormation, EC2, EKS).

DNS: a base domain you control (e.g. `byoc.example.com`). The script will print the records you must create after the LoadBalancer is up.

## Run

For the v0.199 canary, prefer the unattended reviewed-commit workflow:

```bash
mkdir -p scripts/aws-setup/.state
cp scripts/aws-setup/canary.env.example scripts/aws-setup/.state/canary.env
$EDITOR scripts/aws-setup/.state/canary.env
bash scripts/aws-setup/deploy-and-test.sh
```

It validates the expected AWS account and expiring session, executes all static
and Helm gates, writes prompt state mode 0600, deploys, runs live infrastructure
assertions plus SDK A/B/C and a dedicated network-smoke sandbox, and preserves
receipts without tearing down the environment. Credentials must arrive through
the environment (for example devflow `--aws-profile` and `--secret-env`), never
through the config file.

For an interactive bring-up:

```bash
cd <helm-charts repo root>
bash scripts/aws-setup/up.sh
```

You will be prompted for (defaults shown in `[brackets]`):

| Prompt | Default | Notes |
|---|---|---|
| Cluster name | `daytona-byoc-<timestamp>` | EKS cluster name (also used as Daytona region name unless overridden) |
| Public base DNS domain | — | e.g. `byoc.example.com`; **no default**, you must own it |
| Daytona region name | `<cluster name>` | Lowercase alnum `._-` |
| Email for Let's Encrypt | — | Any address you receive mail at |
| Daytona Cloud API URL | `https://app.daytona.io/api` | |
| Daytona Cloud admin API key | — | From <https://app.daytona.io/dashboard/keys>; **secret** (read with no echo) |
| AWS region | `us-east-1` | |
| S3 bucket name | `<cluster>-snapshots` | Globally unique |
| Runner credential mode | `static` | `static` (recommended for v1) or `irsa` |
| Daytona image profile | `parity` | `parity` or the explicit `v0.199-canary` |

Daytona component images are not prompted independently. The chart pins the
Docker-Hub-verified parity bundle
`v0.184.0-k8s-oss.3-amd64` for proxy, runner/embedded daemon,
snapshot-manager, SSH gateway, and runner-manager.

To test against the v0.199 control plane, first create the private runner image:

```bash
RUNNER_BINARY=/secure/path/runner-amd64 \
IMAGE_REF=<account>.dkr.ecr.<region>.amazonaws.com/daytona-runner:v0.199.0-byoc-amd64 \
PUSH=true AWS_REGION=<region> \
bash scripts/aws-setup/build-runner-image.sh
```

Then choose `v0.199-canary` in `up.sh` and enter that full image reference. The
profile is intentionally mixed: private v0.199 runner plus its embedded
sandbox daemon/toolbox; public v0.189 proxy, snapshot-manager, and SSH gateway;
and public v0.184 runner-manager. It is a controlled compatibility test, not a
vendor-supported production declaration.

The script saves your answers to `scripts/aws-setup/.state/prompts.env` so a re-run reuses them.
It also selects an EKS node instance type that satisfies the script's minimum
vCPU requirement and your regional quota, unless you override it with
`OMC_INSTANCE_TYPE`.

## What the script does (step by step)

1. **EKS cluster** via `eksctl` with `iam.withOIDC: true` and a managed sandbox node group labeled `daytona-sandbox-c=true` + tainted `sandbox=true:NoSchedule` on **Ubuntu 24.04** (`amiFamily: Ubuntu2404`). The node group starts with two nodes, keeps a minimum of two, allows scale-out to four, carries Cluster Autoscaler discovery/IAM configuration, and defaults to a 250 GiB root volume. The setup does not install the autoscaler controller. ~15 min. After cluster create, an explicit `omc::verify_node_ubuntu "24.04"` gate fails-fast if any sandbox node is on a different Ubuntu version — no exceptions, no override flag.
2. **S3 bucket** with public access blocked by default.
3. **IAM**: either an IAM user with access keys (static mode) OR an IAM role with an IRSA trust policy bound to the runner ServiceAccount (irsa mode). The minimum S3 policy is attached either way.
4. **kubeconfig** via `aws eks update-kubeconfig`.
5. **daytona namespace** created.
6. **ingress-nginx** + **cert-manager** installed via helm. A `letsencrypt-prod` ClusterIssuer with HTTP-01 challenge is applied.
7. **LoadBalancer wait**: the script polls the `ingress-nginx-controller` Service until the AWS NLB hostname is allocated. ~3-5 min.
8. **DNS records**: the script prints exactly the records you must create. Create them in Route53 (or your DNS provider) and wait for propagation (~30-300s).
9. **SSH gateway keypairs** generated into `.state/`, then **values-region.yaml render** from `scripts/aws-setup/values-region.yaml.tmpl` with your prompt answers. The snapshot-manager uses REAL AWS S3 (`storage.driver: s3`) — the one backend with the full multipart semantics the registry needs; runners share the same bucket for backups + build context.
10. **`helm install daytona-region`** waits up to 10 min for the proxy + snapshot-manager + runner DaemonSet to come up, then the **post-registration finalize** (`omc::region_sshgateway_finalize`) fetches the region-scoped ssh-gateway api key (an org key 403s on session validation), rolls it into the release (`.state/values-sshgateway-key.yaml`), bounces the gateway pod, and PATCHes the region's `sshGatewayUrl` with the gateway LoadBalancer address.

## Verify

```bash
# All pods running?
kubectl -n daytona get pods

# Runner DaemonSet up?
kubectl -n daytona get ds
kubectl -n daytona describe ds -l app.kubernetes.io/component=runner

# Runner main container ready?
kubectl -n daytona logs daemonset/daytona-region-runner -c runner --tail=30

# Host-side docker + sysbox installed via the docker-installer sidecar?
kubectl -n daytona logs daemonset/daytona-region-runner -c docker-installer --tail=30

# AWS env vars correctly injected?
kubectl -n daytona exec daemonset/daytona-region-runner -c runner -- env | grep AWS_
```

## Smoke test (manual)

1. Open <https://app.daytona.io/dashboard/regions>; your region appears.
2. Open <https://app.daytona.io/dashboard/sandboxes> and click "Create sandbox".
3. Choose your BYOC region.
4. Pick any public image (e.g. `python:3.12-slim`).
5. Click "Create". Sandbox should reach `Ready` within ~60s.

If the sandbox reaches `Ready`, the deployment is working.

## Smoke test (programmatic)

```bash
export DAYTONA_API_URL=https://app.daytona.io/api
export DAYTONA_API_KEY=<your-key>
export REGION_NAME=<region-name-from-up.sh>
bash scripts/aws-setup/e2e.sh
```

This uses the SDK smoke test — it creates+deletes sandboxes via the public API.

For the customer failure mode, keep one newly created sandbox running and run:

```bash
SANDBOX_CONTAINER=<docker-container-id-or-name> \
ITERATIONS=300 INTERVAL_SECONDS=2 \
bash scripts/aws-setup/network-smoke.sh
```

The diagnostic records the deployed bundle, stale `SBX_*` iptables jumps,
runner-to-toolbox TCP connectivity on port 2280, sandbox DNS, direct-IP egress,
Docker events, kernel network messages, and conntrack usage. Reports are stored
under `scripts/aws-setup/.state/`.

## Teardown

```bash
bash scripts/aws-setup/teardown.sh
```

The teardown:

1. Helm uninstalls daytona-region
2. Deletes the daytona namespace
3. `eksctl delete cluster` (also removes the NLB + VPC if eksctl created them)
4. Empties + deletes the S3 bucket
5. Deletes the IAM user/role + access keys + attached policies
6. Cleans up the `.state/` directory and kubeconfig context

~10-15 min total. Confirm with `aws eks describe-cluster --name <name>` → `ResourceNotFoundException`.

## Known gaps

- **`credentialMode: irsa` is non-functional at runtime** because the upstream daytona-runner hard-requires non-empty `AWS_ACCESS_KEY_ID`/`SECRET` env vars. See [`issues-summary.md`](issues-summary.md). Use `credentialMode: static`.
- **Wildcard `*.proxy.<base>` TLS** is not auto-issued by HTTP-01. Sandbox subdomains either reuse the proxy's cert (if your proxy chains it) or need a DNS-01 wildcard cert (see [`troubleshooting.md`](troubleshooting.md)).
- **ECR private image pulls** are not wired through `imagePullSecrets` — the Daytona control plane brokers them centrally. ECR repo creation is optional.

## State files

| File | Mode | Purpose |
|---|---|---|
| `scripts/aws-setup/.state/prompts.env` | 600 | Saved prompt answers |
| `scripts/aws-setup/.state/iam-keys.env` | 600 | IAM access keys (static mode) |
| `scripts/aws-setup/.state/cluster.yaml` | 644 | eksctl cluster config |
| `scripts/aws-setup/.state/values-sshgateway-key.yaml` | 600 | Region-scoped ssh-gateway key overlay — pass with `-f` on every manual `helm upgrade` |
| `scripts/aws-setup/.state/ssh-client{,.pub}`, `ssh-gateway-host` | 600 | SSH gateway keypairs (reused on re-runs) |
| `scripts/aws-setup/.state/values-region.yaml` | 600 | Rendered helm values (contains IAM secret + Daytona API key) |

The state dir is wiped by `teardown.sh`. Keep `iam-keys.env` secret — it is `chmod 600`.
