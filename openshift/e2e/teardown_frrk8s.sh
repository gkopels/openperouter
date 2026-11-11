#!/usr/bin/env bash
# Reverse CNO FRR enablement if deploy_frrk8s.sh recorded that e2e enabled it.
# Does not delete the frr-k8s namespace or env-overrides ConfigMap — only CNO
# providers (virtual OCP deploy.sh rarely calls this; bastion e2e EXIT does).
#
# OPENPE_E2E_TEARDOWN_FRRK8S:
#   false — skip (default for telco QE: CNO FRR is shared lab infra)
#   true  — require marker; restore providersBefore (only if this job enabled FRR)
#   force — always drop FRR from the current providers list (ignores marker JSON);
#           works with or without a marker
# Pair with OPENPE_E2E_DEPLOY_FRRK8S=true when this job owns CNO FRR.
# Concurrent jobs on one cluster are not supported (see deploy_frrk8s.sh header).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${SCRIPT_DIR}/.e2e-bastion-state"
MARKER="${STATE_DIR}/frrk8s-enabled-by-e2e"

TEARDOWN="${OPENPE_E2E_TEARDOWN_FRRK8S:-false}"
FRRK8S_NAMESPACE="${FRRK8S_NAMESPACE:-openshift-frr-k8s}"
FRRK8S_SELECTOR="${FRRK8S_SELECTOR:-app=frr-k8s}"

echo "=== teardown-frrk8s ==="
echo "  OPENPE_E2E_TEARDOWN_FRRK8S=${TEARDOWN}"

if [[ "${TEARDOWN}" == "false" ]]; then
  echo "Skipping frr-k8s / CNO FRR teardown"
  exit 0
fi

if [[ "${TEARDOWN}" != "force" && ! -f "${MARKER}" ]]; then
  echo "No marker at ${MARKER} (FRR was already enabled before e2e); leaving CNO unchanged"
  exit 0
fi

if ! oc get networks.operator.openshift.io cluster >/dev/null 2>&1; then
  echo "ERROR: networks.operator.openshift.io/cluster not found — OpenShift CNO required" >&2
  exit 1
fi

if [[ "${TEARDOWN}" == "force" ]]; then
  echo "Force: dropping FRR from current providers (ignoring marker restore)"
else
  echo "Reverting CNO FRR via marker providersBefore (preserve other providers)"
fi
# argv: marker path, mode — VAR=value before oc does not apply to python3 after |.
PATCH_JSON="$(
  oc get networks.operator.openshift.io cluster -o json 2>/dev/null | python3 -c '
import json, os, sys

marker = sys.argv[1] if len(sys.argv) > 1 else ""
mode = sys.argv[2] if len(sys.argv) > 2 else "true"

try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
arc = (d.get("spec") or {}).get("additionalRoutingCapabilities") or {}
current = list(arc.get("providers") or [])

if mode == "force":
    # Always drop FRR only; do not restore providersBefore.
    new = [p for p in current if p != "FRR"]
else:
    prev = None
    if marker and os.path.isfile(marker):
        raw = open(marker).read().strip()
        try:
            meta = json.loads(raw)
            if isinstance(meta, dict) and "providersBefore" in meta:
                prev = list(meta.get("providersBefore") or [])
        except json.JSONDecodeError:
            # Legacy marker was a bare timestamp → treat as empty before-list.
            prev = []
    if prev is not None:
        new = prev
    else:
        new = [p for p in current if p != "FRR"]

if not new:
    print(json.dumps([{"op": "remove", "path": "/spec/additionalRoutingCapabilities"}]))
else:
    print(json.dumps([{
        "op": "add",
        "path": "/spec/additionalRoutingCapabilities",
        "value": {"providers": new},
    }]))
' "${MARKER}" "${TEARDOWN}"
)"

PATCH_OK=0
if [[ -n "${PATCH_JSON}" ]]; then
  if oc patch networks.operator.openshift.io cluster --type=json -p "${PATCH_JSON}"; then
    PATCH_OK=1
  else
    echo "ERROR: failed to patch CNO additionalRoutingCapabilities; keeping marker for retry" >&2
  fi
else
  echo "ERROR: no patch generated; keeping marker for retry" >&2
fi

if [[ "${PATCH_OK}" -ne 1 ]]; then
  exit 1
fi

echo "Waiting for frr-k8s pods to terminate (best-effort)"
# CNO may delete the operands; don't fail the whole e2e on slow cleanup
for _ in $(seq 1 60); do
  count="$(oc get pods -n "${FRRK8S_NAMESPACE}" -l "${FRRK8S_SELECTOR}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${count}" == "0" ]]; then
    break
  fi
  sleep 5
done
oc get pods -n "${FRRK8S_NAMESPACE}" -l "${FRRK8S_SELECTOR}" 2>/dev/null || true

# Only drop ownership after a successful CNO revert.
rm -f "${MARKER}"
rmdir "${STATE_DIR}" 2>/dev/null || true

echo "=== teardown-frrk8s complete ==="
