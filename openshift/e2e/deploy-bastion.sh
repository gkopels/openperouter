#!/usr/bin/env bash
# Bastion bring-up: sanity_check → bridges → setup-clab-bastion.
# OPENPE_E2E_BASTION_PHASE=all|prereqs|fabric (default: all).
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

echo "=== deploy-bastion ==="
echo "  KUBECONFIG=${KUBECONFIG}"
echo "  phase=${PHASE}"
echo "  CLAB_EXECUTOR=${CLAB_EXECUTOR} CLAB_RUNTIME=${CLAB_RUNTIME}"
echo "  openperouter-namespace=openshift-openperouter"
echo "  frrk8s-namespace=openshift-frr-k8s (prerequisite)"

# Cluster must already have OpenPE + FRR-K8s; this only verifies readiness.
sanity_check() {
  echo "=== sanity_check ==="
  oc get nodes >/dev/null

  echo "=== Checking OpenPE prerequisites ==="
  oc get ns openshift-openperouter >/dev/null || {
    echo "ERROR: openshift-openperouter missing — install OpenPE first" >&2
    exit 1
  }
  if ! oc get crd underlays.network.openperouter.io >/dev/null 2>&1; then
    echo "ERROR: underlays.network.openperouter.io CRD missing — install OpenPE first" >&2
    exit 1
  fi
  echo "  CRD underlays.network.openperouter.io: present"
  for ds in controller router; do
    if ! oc get daemonset "${ds}" -n openshift-openperouter >/dev/null 2>&1; then
      echo "ERROR: daemonset/${ds} missing in openshift-openperouter — OpenPE not deployed?" >&2
      exit 1
    fi
    echo "  Waiting for daemonset/${ds} rollout..."
    oc rollout status "daemonset/${ds}" -n openshift-openperouter --timeout=300s
  done
  echo "=== OpenPE prerequisites OK ==="

  echo "=== Checking FRR-K8s prerequisite ==="
  oc get ns openshift-frr-k8s >/dev/null || {
    echo "ERROR: openshift-frr-k8s missing — provision CNO FRR / FRR-K8s before bastion e2e" >&2
    echo "  (lab or CI must enable additionalRoutingCapabilities providers FRR; bastion does not patch CNO)" >&2
    exit 1
  }
  echo "Waiting for FRR-K8s pods to be Ready in openshift-frr-k8s (selector app=frr-k8s, timeout 5m)"
  if ! oc wait pod -n openshift-frr-k8s -l app=frr-k8s \
    --for=create --timeout=5m; then
    echo "ERROR: no FRR-K8s pods matched app=frr-k8s in openshift-frr-k8s within 5m" >&2
    oc get pods -n openshift-frr-k8s -o wide >&2 || true
    exit 1
  fi
  if ! oc wait pod -n openshift-frr-k8s -l app=frr-k8s \
    --for=condition=Ready --timeout=5m; then
    echo "ERROR: FRR-K8s pods in openshift-frr-k8s did not become Ready within 5m" >&2
    oc get pods -n openshift-frr-k8s -o wide >&2 || true
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
    sanity_check
    echo "=== deploy-bastion prereqs-only complete ==="
    ;;
  fabric)
    run_fabric
    echo "=== deploy-bastion fabric complete ==="
    ;;
  all)
    sanity_check
    run_fabric
    echo "=== deploy-bastion complete ==="
    echo "Next: ./openshift/e2e/e2e-bastion.sh"
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
