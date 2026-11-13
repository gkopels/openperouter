#!/usr/bin/env bash
# Bastion bring-up: require Ready FRR-K8s, bridges, then setup-clab-bastion.sh.
# Does NOT run KIND (make deploy). OpenPE and FRR-K8s must already be installed
# (CI or lab provisions CNO FRR; this script only waits for readiness).
#
# OPENPE_E2E_BASTION_PHASE:
#   all      — prereqs + fabric (default; standalone deploy-bastion)
#   prereqs  — OpenPE + FRR-K8s checks only (no bridges/clab)
#   fabric   — bridges + setup-clab-bastion only (caller already checked prereqs)
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

PHASE="${OPENPE_E2E_BASTION_PHASE:-all}"
OPENPE_NS="${OPENPE_E2E_NAMESPACE:-openshift-openperouter}"
FRRK8S_NAMESPACE="${FRRK8S_NAMESPACE:-openshift-frr-k8s}"
FRRK8S_SELECTOR="${FRRK8S_SELECTOR:-app=frr-k8s}"
FRRK8S_TIMEOUT="${FRRK8S_TIMEOUT:-5m}"

echo "=== deploy-bastion ==="
echo "  KUBECONFIG=${KUBECONFIG}"
echo "  phase=${PHASE}"
echo "  CLAB_EXECUTOR=${CLAB_EXECUTOR} CLAB_RUNTIME=${CLAB_RUNTIME}"
echo "  openperouter-namespace=${OPENPE_NS}"
echo "  frrk8s-namespace=${FRRK8S_NAMESPACE} (prerequisite)"

oc get nodes >/dev/null

check_prereqs() {
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

  echo "=== Checking FRR-K8s prerequisite ==="
  oc get ns "${FRRK8S_NAMESPACE}" >/dev/null || {
    echo "ERROR: ${FRRK8S_NAMESPACE} missing — provision CNO FRR / FRR-K8s before bastion e2e" >&2
    echo "  (lab or CI must enable additionalRoutingCapabilities providers FRR; bastion does not patch CNO)" >&2
    exit 1
  }
  echo "Waiting for FRR-K8s pods to be Ready in ${FRRK8S_NAMESPACE} (selector ${FRRK8S_SELECTOR}, timeout ${FRRK8S_TIMEOUT})"
  if ! oc wait pod -n "${FRRK8S_NAMESPACE}" -l "${FRRK8S_SELECTOR}" \
    --for=create --timeout="${FRRK8S_TIMEOUT}"; then
    echo "ERROR: no FRR-K8s pods matched ${FRRK8S_SELECTOR} in ${FRRK8S_NAMESPACE} within ${FRRK8S_TIMEOUT}" >&2
    oc get pods -n "${FRRK8S_NAMESPACE}" -o wide >&2 || true
    exit 1
  fi
  if ! oc wait pod -n "${FRRK8S_NAMESPACE}" -l "${FRRK8S_SELECTOR}" \
    --for=condition=Ready --timeout="${FRRK8S_TIMEOUT}"; then
    echo "ERROR: FRR-K8s pods in ${FRRK8S_NAMESPACE} did not become Ready within ${FRRK8S_TIMEOUT}" >&2
    oc get pods -n "${FRRK8S_NAMESPACE}" -o wide >&2 || true
    exit 1
  fi
  echo "=== FRR-K8s prerequisite OK ==="
}

run_fabric() {
  bash "${SCRIPT_DIR}/setup-bastion-bridges.sh"
  bash "${SCRIPT_DIR}/setup-clab-bastion.sh"
}

case "${PHASE}" in
  prereqs)
    check_prereqs
    echo "=== deploy-bastion prereqs-only complete ==="
    ;;
  fabric)
    run_fabric
    echo "=== deploy-bastion fabric complete ==="
    ;;
  all)
    check_prereqs
    run_fabric
    echo "=== deploy-bastion complete ==="
    echo "Next: make e2e-bastion  # or ./openshift/e2e/e2e-bastion.sh"
    echo "Standalone:"
    echo "  ./openshift/e2e/configure-bastion-worker-net.sh"
    echo "  ./openshift/e2e/run_tests-bastion.sh"
    echo "Teardown:"
    echo "  ./openshift/e2e/teardown-bastion-worker-net.sh"
    echo "  ./openshift/e2e/teardown-clab.sh"
    ;;
  *)
    echo "ERROR: unknown OPENPE_E2E_BASTION_PHASE=${PHASE} (use all|prereqs|fabric)" >&2
    exit 1
    ;;
esac
