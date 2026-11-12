#!/usr/bin/env bash
# Bastion bring-up: wait/enable frr-k8s, bridges, then setup-clab-bastion.sh.
# Does NOT run KIND (make deploy). OpenPE must already be installed.
# Default: wait for existing frr-k8s (OPENPE_E2E_DEPLOY_FRRK8S=false).
#
# Usage:
#   export KUBECONFIG=/path/to/ocp/kubeconfig
#   set -a && source openshift/e2e/bastion.env.example && set +a
#   ./openshift/e2e/deploy-bastion.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${KUBECONFIG:-}" ]]; then
  echo "ERROR: KUBECONFIG must be set to the target OpenShift cluster" >&2
  exit 1
fi

export CLAB_EXECUTOR="${CLAB_EXECUTOR:-local}"
export CLAB_RUNTIME="${CLAB_RUNTIME:-docker}"
export OPENPE_CLAB_RUNTIME="${OPENPE_CLAB_RUNTIME:-${CLAB_RUNTIME}}"

DEPLOY_FRRK8S="${OPENPE_E2E_DEPLOY_FRRK8S:-false}"
OPENPE_NS="${OPENPE_E2E_NAMESPACE:-openshift-openperouter}"
FRRK8S_NAMESPACE="${FRRK8S_NAMESPACE:-openshift-frr-k8s}"
FRRK8S_SELECTOR="${FRRK8S_SELECTOR:-app=frr-k8s}"
FRRK8S_TIMEOUT="${FRRK8S_TIMEOUT:-5m}"

echo "=== deploy-bastion ==="
echo "  KUBECONFIG=${KUBECONFIG}"
echo "  CLAB_EXECUTOR=${CLAB_EXECUTOR} CLAB_RUNTIME=${CLAB_RUNTIME}"
echo "  OPENPE_E2E_DEPLOY_FRRK8S=${DEPLOY_FRRK8S}"
echo "  openperouter-namespace=${OPENPE_NS}"

oc get nodes >/dev/null

echo "=== Checking OpenPE prerequisites ==="
oc get ns "${OPENPE_NS}" >/dev/null || {
  echo "ERROR: ${OPENPE_NS} missing — install OpenPE first" >&2
  exit 1
}
if ! oc get crd underlays.network.openperouter.io >/dev/null 2>&1; then
  echo "ERROR: underlays.network.openperouter.io CRD missing — install OpenPE first" >&2
  exit 1
fi
echo "  CRD underlays.network.openperouter.io: present"
for ds in controller router; do
  if ! oc get daemonset "${ds}" -n "${OPENPE_NS}" >/dev/null 2>&1; then
    echo "ERROR: daemonset/${ds} missing in ${OPENPE_NS} — OpenPE not deployed?" >&2
    exit 1
  fi
  echo "  Waiting for daemonset/${ds} rollout..."
  oc rollout status "daemonset/${ds}" -n "${OPENPE_NS}" --timeout=300s
done
echo "=== OpenPE prerequisites OK ==="

if [[ "${DEPLOY_FRRK8S}" == "true" ]]; then
  bash "${SCRIPT_DIR}/deploy_frrk8s.sh"
else
  echo "Skipping frr-k8s deploy (OPENPE_E2E_DEPLOY_FRRK8S=${DEPLOY_FRRK8S})"
  oc get ns "${FRRK8S_NAMESPACE}" >/dev/null || {
    echo "ERROR: ${FRRK8S_NAMESPACE} missing; set OPENPE_E2E_DEPLOY_FRRK8S=true or enable CNO FRR first" >&2
    exit 1
  }
  echo "Waiting for existing FRR-K8s pods to be Ready in ${FRRK8S_NAMESPACE}"
  oc wait pod -n "${FRRK8S_NAMESPACE}" -l "${FRRK8S_SELECTOR}" \
    --for=create --timeout="${FRRK8S_TIMEOUT}"
  oc wait pod -n "${FRRK8S_NAMESPACE}" -l "${FRRK8S_SELECTOR}" \
    --for=condition=Ready --timeout="${FRRK8S_TIMEOUT}"
fi

bash "${SCRIPT_DIR}/setup-bastion-bridges.sh"
bash "${SCRIPT_DIR}/setup-clab-bastion.sh"

echo "=== deploy-bastion complete ==="
echo "Next: make e2e-bastion  # or ./openshift/e2e/e2e-bastion.sh"
echo "Standalone:"
echo "  ./openshift/e2e/configure-bastion-worker-net.sh"
echo "  ./openshift/e2e/run_tests-bastion.sh"
echo "Teardown:"
echo "  ./openshift/e2e/teardown-bastion-worker-net.sh"
echo "  ./openshift/e2e/teardown-clab.sh"
echo "  ./openshift/e2e/teardown_frrk8s.sh"
