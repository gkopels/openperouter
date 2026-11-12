#!/usr/bin/env bash
# Bastion e2e lifecycle:
#   deploy-bastion.sh → configure-bastion-worker-net.sh → run_tests-bastion.sh
# EXIT (unless OPENPE_E2E_SKIP_TEARDOWN=true):
#   teardown-bastion-worker-net.sh → teardown-clab.sh
# FRR-K8s is a lab/CI prerequisite (not deployed or torn down here).
#
# Usage:
#   export KUBECONFIG=/path/to/ocp/kubeconfig
#   set -a && source openshift/e2e/bastion.env.example && set +a
#   ./openshift/e2e/e2e-bastion.sh
#   # or: make e2e-bastion

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${KUBECONFIG:-}" ]]; then
  echo "ERROR: KUBECONFIG must be set to the target OpenShift cluster" >&2
  exit 1
fi

export CLAB_EXECUTOR="${CLAB_EXECUTOR:-local}"
export CLAB_RUNTIME="${CLAB_RUNTIME:-docker}"
export OPENPE_CLAB_RUNTIME="${OPENPE_CLAB_RUNTIME:-${CLAB_RUNTIME}}"
export CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-${OPENPE_CLAB_RUNTIME:-docker}}"

SKIP_TEARDOWN="${OPENPE_E2E_SKIP_TEARDOWN:-false}"
TEST_RC=0

teardown() {
  local causing_rc=$?
  local td_rc=0
  if [[ "${SKIP_TEARDOWN}" == "true" ]]; then
    echo "=== SKIP all teardown (OPENPE_E2E_SKIP_TEARDOWN=true) ==="
  else
    echo "=== EXIT trap: teardown-bastion-worker-net ==="
    bash "${SCRIPT_DIR}/teardown-bastion-worker-net.sh" || {
      echo "ERROR: teardown-bastion-worker-net failed" >&2
      td_rc=1
    }
    echo "=== EXIT trap: teardown-clab ==="
    bash "${SCRIPT_DIR}/teardown-clab.sh" || {
      echo "ERROR: teardown-clab failed" >&2
      td_rc=1
    }
  fi
  if [[ "${TEST_RC}" -ne 0 ]]; then
    exit "${TEST_RC}"
  fi
  if [[ "${causing_rc}" -ne 0 ]]; then
    exit "${causing_rc}"
  fi
  exit "${td_rc}"
}

trap teardown EXIT

echo "=== e2e-bastion lifecycle ==="
echo "  KUBECONFIG=${KUBECONFIG}"
echo "  CLAB_RUNTIME=${CLAB_RUNTIME} CONTAINER_RUNTIME=${CONTAINER_RUNTIME}"
echo "  OPENPE_E2E_SKIP_TEARDOWN=${SKIP_TEARDOWN}"

bash "${SCRIPT_DIR}/deploy-bastion.sh"

echo "=== configure worker underlay IPs ==="
bash "${SCRIPT_DIR}/configure-bastion-worker-net.sh"

set +e
bash "${SCRIPT_DIR}/run_tests-bastion.sh"
TEST_RC=$?
set -e

if [[ "${TEST_RC}" -ne 0 ]]; then
  echo "ERROR: run_tests-bastion.sh exited ${TEST_RC}" >&2
fi

exit "${TEST_RC}"
