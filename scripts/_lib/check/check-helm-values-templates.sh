#!/usr/bin/env bash
# Static QA gate: render each scripts/<cloud>-setup/values-region.yaml.tmpl
# with its matching test/fixtures/byoc-prompt-set-<cloud>.env, then helm template +
# helm lint against charts/daytona-region to confirm the rendered values are valid
# for the K8s-native chart surface.
# This is the STATIC SUBSTITUTE for cloud QA — operator runs real-cloud separately.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT" || exit 1

FAIL=0

check_template() {
  local label="$1" tmpl="$2" fixture="$3" chart="$4"
  echo ""
  echo "=== $label ==="
  if [[ ! -f "$tmpl" ]]; then
    echo "MISSING template: $tmpl"
    FAIL=1
    return
  fi
  if [[ ! -f "$fixture" ]]; then
    echo "MISSING fixture: $fixture"
    FAIL=1
    return
  fi

  local out
  out="$(mktemp -t byoc-values-XXXXXX.yaml)"
  (
    set -a
    # shellcheck disable=SC1090
    . "$fixture"
    set +a
    envsubst < "$tmpl" > "$out"
  )

  local remaining
  remaining="$(grep -c '\${' "$out" 2>/dev/null || true)"
  if [[ "$remaining" -gt 0 ]]; then
    echo "FAIL [$label]: $remaining unresolved \${...} placeholders after envsubst"
    grep -nE '\${' "$out" | head -10
    rm -f "$out"
    FAIL=1
    return
  fi

  local rendered
  rendered="$(mktemp -t byoc-rendered-XXXXXX.yaml)"
  if ! helm template byoc-test "./$chart" -f "$out" >"$rendered" 2>"$out.helm.err"; then
    echo "FAIL [$label]: helm template failed"
    head -20 "$out.helm.err"
    rm -f "$out" "$out.helm.err" "$rendered"
    FAIL=1
    return
  fi

  if ! helm lint "./$chart" -f "$out" >/dev/null 2>"$out.lint.err"; then
    echo "FAIL [$label]: helm lint failed"
    head -20 "$out.lint.err"
    rm -f "$out" "$out.helm.err" "$out.lint.err" "$rendered"
    FAIL=1
    return
  fi

  # All Daytona compute-plane components must render from one exact bundle.
  # This is intentionally static: Docker Hub availability is verified when the
  # chart appVersion is changed, while CI prevents later per-component drift.
  local expected_tag rendered_components rendered_tags
  expected_tag="$(yq -r '.appVersion' "$chart/Chart.yaml")"
  rendered_components="$(
    grep -oE 'daytonaio/daytona-(proxy|runner|snapshot-manager|ssh-gateway|runner-manager):' "$rendered" \
      | sed 's/:$//' \
      | sort -u
  )"
  rendered_tags="$(
    grep -oE 'daytonaio/daytona-(proxy|runner|snapshot-manager|ssh-gateway|runner-manager):[^"[:space:]]+' "$rendered" \
      | sed 's/.*://' \
      | sort -u
  )"
  if [[ "$(printf '%s\n' "$rendered_components" | grep -c .)" -ne 5 ]]; then
    echo "FAIL [$label]: expected all 5 Daytona components in the rendered bundle"
    printf '%s\n' "$rendered_components" | sed 's/^/    /'
    rm -f "$out" "$out.helm.err" "$out.lint.err" "$rendered"
    FAIL=1
    return
  fi
  if [[ "$rendered_tags" != "$expected_tag" ]]; then
    echo "FAIL [$label]: Daytona image tags are not in chart appVersion parity"
    echo "  expected: $expected_tag"
    echo "  rendered tags:"
    printf '%s\n' "$rendered_tags" | sed 's/^/    /'
    rm -f "$out" "$out.helm.err" "$out.lint.err" "$rendered"
    FAIL=1
    return
  fi

  echo "OK [$label]: envsubst clean + helm template + helm lint + image parity ($expected_tag)"
  rm -f "$out" "$out.helm.err" "$out.lint.err" "$rendered"
}

for cloud in aws azure gcs; do
  check_template "BYOC region: $cloud" \
    "scripts/${cloud}-setup/values-region.yaml.tmpl" \
    "scripts/${cloud}-setup/.tests/byoc-prompt-set.env" \
    "charts/daytona-region"
done

if helm template parity-negative ./charts/daytona-region \
  -f charts/daytona-region/tests/fixtures/baseline.values.yaml \
  --set services.runner.image.tag=v0.189.0-amd64 >/dev/null 2>&1; then
  echo "FAIL: chart accepted a runner-only image version override"
  FAIL=1
else
  echo "OK: chart rejects unapproved Daytona image version skew"
fi

if ! helm template skew-canary ./charts/daytona-region \
  -f charts/daytona-region/tests/fixtures/baseline.values.yaml \
  --set imageBundle.allowVersionSkew=true \
  --set imageBundle.name=control-v0.199-runner-canary \
  --set services.runner.image.repository=example.invalid/daytona-runner \
  --set services.runner.image.tag=v0.199.0-byoc-amd64 >/dev/null 2>&1; then
  echo "FAIL: chart rejected an explicitly named and approved canary bundle"
  FAIL=1
else
  echo "OK: chart accepts explicitly named Daytona image skew"
fi

echo ""
if [[ $FAIL -eq 0 ]]; then
  echo "OK: all 3 cloud values templates render and lint clean"
else
  echo "FAILED: one or more cloud templates failed validation"
fi
exit $FAIL
