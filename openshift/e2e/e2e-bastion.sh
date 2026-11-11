#!/usr/bin/env bash
# Bastion / OCP e2e lifecycle (CI entrypoint):
#   1) deploy-bastion.sh       — wait for shared frr-k8s + bridges + clab
#   2) configure-bastion-worker-net.sh — worker underlay IPs from nodelink
#   3) run_tests.sh            — focused Ginkgo suite
#   EXIT trap (always, unless OPENPE_E2E_SKIP_TEARDOWN=true):
#   4) teardown-bastion-worker-net.sh — flush worker underlay IPs first
#   5) teardown-clab.sh        — destroy fabric; keep toswitch*/mgmt
#   6) teardown_frrk8s.sh      — no-op by default (shared CNO FRR); only if
#                                OPENPE_E2E_TEARDOWN_FRRK8S=true and marker set
#
# Worker-net teardown runs before clab so oc debug / the API still work.
#
# This is the OCP/bastion counterpart to KIND "make deploy && make e2etests && make clean".
# It does NOT run KIND "make deploy". OpenPE (underlay CRDs + controller/router
# DaemonSets) and CNO FRR must already be installed on telco QE clusters
# (CI installs operators / FRR before this job).
#
# Usage (on bastion):
#   export KUBECONFIG=/path/to/ocp/kubeconfig
#   set -a && source openshift/e2e/bastion.env.example && set +a
#   ./openshift/e2e/e2e-bastion.sh
#
#   # or: make e2e-bastion
#
# Debug: OPENPE_E2E_SKIP_TEARDOWN=true skips *all* EXIT cleanup (worker-net IPs,
# clab fabric, and CNO FRR) — not fabric-only. For selective cleanup use
# OPENPE_E2E_TEARDOWN_WORKER_NET / OPENPE_E2E_TEARDOWN_FRRK8S instead.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${KUBECONFIG:-}" ]]; then
  echo "ERROR: KUBECONFIG must be set to the target OpenShift cluster" >&2
  exit 1
fi

export OPENPE_E2E_PROVIDER="${OPENPE_E2E_PROVIDER:-bastion}"
export CLAB_EXECUTOR="${CLAB_EXECUTOR:-local}"
export CLAB_RUNTIME="${CLAB_RUNTIME:-podman}"
export OPENPE_CLAB_RUNTIME="${OPENPE_CLAB_RUNTIME:-${CLAB_RUNTIME}}"
# Ginkgo must use rootful podman (same as setup-clab's sudo podman).
export CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-${SCRIPT_DIR}/podman-root.sh}"

SKIP_TEARDOWN="${OPENPE_E2E_SKIP_TEARDOWN:-false}"
TEST_RC=0

# EXIT trap must not mask deploy/test status: prefer TEST_RC, then the status
# that triggered EXIT, then a teardown failure.
teardown() {
  local causing_rc=$?
  local td_rc=0
  if [[ "${SKIP_TEARDOWN}" == "true" ]]; then
    echo "=== SKIP all teardown (OPENPE_E2E_SKIP_TEARDOWN=true): worker-net + clab + frrk8s ==="
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
    # Remove CNO FRR if this e2e run enabled it (see deploy_frrk8s.sh marker).
    echo "=== EXIT trap: teardown-frrk8s ==="
    bash "${SCRIPT_DIR}/teardown_frrk8s.sh" || {
      echo "ERROR: teardown-frrk8s failed" >&2
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
echo "  OPENPE_E2E_PROVIDER=${OPENPE_E2E_PROVIDER}"
echo "  CLAB_RUNTIME=${CLAB_RUNTIME} CONTAINER_RUNTIME=${CONTAINER_RUNTIME}"
echo "  OPENPE_E2E_SKIP_TEARDOWN=${SKIP_TEARDOWN}"

bash "${SCRIPT_DIR}/deploy-bastion.sh"

echo "=== configure worker underlay IPs ==="
bash "${SCRIPT_DIR}/configure-bastion-worker-net.sh"

set +e
bash "${SCRIPT_DIR}/run_tests.sh"
TEST_RC=$?
set -e

if [[ "${TEST_RC}" -ne 0 ]]; then
  echo "ERROR: run_tests.sh exited ${TEST_RC}" >&2
fi

# trap runs teardown; propagate test status
exit "${TEST_RC}"
