#!/usr/bin/env bash
# Bastion e2e lifecycle:
#   prereqs → fabric (bridges+clab) → configure-bastion-worker-net → run_tests-bastion
# EXIT (unless OPENPE_E2E_SKIP_TEARDOWN=true):
#   teardown only for phases that actually mutated (armed immediately before mutation).
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
# Armed only immediately before the matching mutation (after its prereqs).
CLEANUP_CLAB=0
CLEANUP_WORKER_NET=0

teardown() {
  local causing_rc=$?
  local td_rc=0
  if [[ "${SKIP_TEARDOWN}" == "true" ]]; then
    echo "=== SKIP all teardown (OPENPE_E2E_SKIP_TEARDOWN=true) ==="
  else
    if [[ "${CLEANUP_WORKER_NET}" -eq 1 ]]; then
      echo "=== EXIT trap: teardown-bastion-worker-net ==="
      bash "${SCRIPT_DIR}/teardown-bastion-worker-net.sh" || {
        echo "ERROR: teardown-bastion-worker-net failed" >&2
        td_rc=1
      }
    else
      echo "=== EXIT trap: skip worker-net teardown (not armed; no worker-net mutation) ==="
    fi
    if [[ "${CLEANUP_CLAB}" -eq 1 ]]; then
      echo "=== EXIT trap: teardown-clab ==="
      bash "${SCRIPT_DIR}/teardown-clab.sh" || {
        echo "ERROR: teardown-clab failed" >&2
        td_rc=1
      }
    else
      echo "=== EXIT trap: skip clab teardown (not armed; no fabric mutation) ==="
    fi
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

# Prerequisite checks only — do not arm cleanup yet (failed FRR/OpenPE must not
# touch an existing fabric or worker network).
OPENPE_E2E_BASTION_PHASE=prereqs bash "${SCRIPT_DIR}/deploy-bastion.sh"

# First fabric mutation: arm clab cleanup for partial setup failures.
CLEANUP_CLAB=1
OPENPE_E2E_BASTION_PHASE=fabric bash "${SCRIPT_DIR}/deploy-bastion.sh"

echo "=== configure worker underlay IPs ==="
# First worker-net mutation: arm worker-net cleanup.
CLEANUP_WORKER_NET=1
bash "${SCRIPT_DIR}/configure-bastion-worker-net.sh"

set +e
bash "${SCRIPT_DIR}/run_tests-bastion.sh"
TEST_RC=$?
set -e

if [[ "${TEST_RC}" -ne 0 ]]; then
  echo "ERROR: run_tests-bastion.sh exited ${TEST_RC}" >&2
fi

exit "${TEST_RC}"
