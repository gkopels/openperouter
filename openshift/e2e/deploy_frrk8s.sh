#!/usr/bin/env bash
# Deploy FRR-K8s through the OpenShift Cluster Network Operator.
# Shared by bastion (deploy-bastion / e2e-bastion) and virtual OCP (deploy.sh).
# Idempotent: safe to re-run when additionalRoutingCapabilities is already set.
# Records openshift/e2e/.e2e-bastion-state/frrk8s-enabled-by-e2e only when this
# run patches CNO — so teardown_frrk8s.sh does not remove pre-existing shared FRR.
# (Dir name is bastion-oriented; marker is only consumed if teardown_frrk8s runs.)
# e2e env-overrides (debug log / poll interval) are applied only in that same case.
#
# Concurrent bastion jobs (not supported): if A enables FRR (marker) and B starts
# and sees FRR already on, B deletes the marker — A's EXIT may then leave FRR
# (leak, usually safer). Worse: A tearing down while B still runs can strip FRR
# out from under B. Use one e2e job at a time, or OPENPE_E2E_DEPLOY_FRRK8S=false
# + OPENPE_E2E_TEARDOWN_FRRK8S=false when FRR is shared lab infra.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${SCRIPT_DIR}/.e2e-bastion-state"
MARKER="${STATE_DIR}/frrk8s-enabled-by-e2e"

FRRK8S_NAMESPACE="${FRRK8S_NAMESPACE:-openshift-frr-k8s}"
FRRK8S_SELECTOR="${FRRK8S_SELECTOR:-app=frr-k8s}"
FRRK8S_TIMEOUT="${FRRK8S_TIMEOUT:-5m}"
# oc wait --for=create needs a recent oc/kubectl (same requirement as deploy-bastion.sh).

if ! oc get networks.operator.openshift.io cluster >/dev/null 2>&1; then
  echo "ERROR: networks.operator.openshift.io/cluster not found — OpenShift CNO required" >&2
  echo "  (this script enables FRR via CNO additionalRoutingCapabilities; not for plain Kubernetes)" >&2
  exit 1
fi

# Parse providers as JSON list (avoid brittle string match on jsonpath join).
cno_providers_json() {
  oc get networks.operator.openshift.io cluster -o json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("[]")
    sys.exit(0)
arc = (d.get("spec") or {}).get("additionalRoutingCapabilities") or {}
print(json.dumps(arc.get("providers") or []))
'
}

cno_frr_enabled() {
  python3 -c '
import json, sys
providers = json.loads(sys.argv[1])
sys.exit(0 if "FRR" in providers else 1)
' "$1"
}

PROVIDERS_JSON="$(cno_providers_json)"
if cno_frr_enabled "${PROVIDERS_JSON}"; then
  PROVIDERS="$(python3 -c 'import json,sys; print(" ".join(json.loads(sys.argv[1])))' "${PROVIDERS_JSON}")"
  echo "CNO FRR already enabled (providers: ${PROVIDERS}); not claiming ownership"
  echo "  Skipping namespace/env-overrides mutation (shared FRR tuning left alone)"
  # Drop a stale marker from a prior run so EXIT does not remove shared FRR.
  rm -f "${MARKER}"
else
  echo "Creating FRR-K8s namespace and e2e env-overrides (this run enables FRR)"
  oc create namespace "${FRRK8S_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -
  oc apply -f - <<EOFCM
apiVersion: v1
kind: ConfigMap
metadata:
  name: env-overrides
  namespace: ${FRRK8S_NAMESPACE}
data:
  frrk8s-loglevel: "--log-level=debug"
  frrk8s-poll-interval: "--poll-interval=5s"
EOFCM

  # Append FRR; do not replace other providers that may already be set.
  PATCH_JSON="$(python3 -c '
import json, sys
providers = json.loads(sys.argv[1])
if "FRR" not in providers:
    providers = list(providers) + ["FRR"]
print(json.dumps({"spec": {"additionalRoutingCapabilities": {"providers": providers}}}))
' "${PROVIDERS_JSON}")"
  echo "Enabling FRR in CNO additionalRoutingCapabilities (append; was ${PROVIDERS_JSON})"
  oc patch networks.operator.openshift.io cluster --type=merge -p "${PATCH_JSON}"
  mkdir -p "${STATE_DIR}"
  # Marker records providers before this run so teardown can restore (not wipe peers).
  python3 -c '
import json, sys
from datetime import datetime, timezone
prev = json.loads(sys.argv[1])
json.dump({"enabledAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "providersBefore": prev}, sys.stdout)
print()
' "${PROVIDERS_JSON}" > "${MARKER}"
  echo "Recorded ${MARKER} for post-e2e teardown (this run enabled FRR)"
fi

echo "Waiting for FRR-K8s pods to be ready"
oc wait pod -n "${FRRK8S_NAMESPACE}" -l "${FRRK8S_SELECTOR}" \
    --for=create --timeout="${FRRK8S_TIMEOUT}"
oc wait pod -n "${FRRK8S_NAMESPACE}" -l "${FRRK8S_SELECTOR}" \
    --for=condition=Ready --timeout="${FRRK8S_TIMEOUT}"

echo "FRR-K8s is ready in ${FRRK8S_NAMESPACE}"
