#!/bin/bash
# Bastion-only e2e runner. Same core as run_tests.sh (shared excludes, namespaces,
# make e2etests); assumes cluster + nodelink.json were already set up by
# e2e-bastion / deploy-bastion / setup-clab-bastion.
#
# Bastion-only knobs:
#   CONTAINER_RUNTIME / OPENPE_CLAB_RUNTIME / CLAB_RUNTIME
#   OPENPE_E2E_NODE_SELECTOR → --instrumented-nodes-label
#   OPENPE_E2E_SKIP / OPENPE_E2E_FOCUS (optional)
#
# Usage:
#   export KUBECONFIG=...
#   set -a && source openshift/e2e/bastion.env.example && set +a
#   ./openshift/e2e/run_tests-bastion.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODELINK="${SCRIPT_DIR}/nodelink.json"

join() {
  local IFS="$1"
  shift
  echo "$*"
}

RUNTIME="${CONTAINER_RUNTIME:-${OPENPE_CLAB_RUNTIME:-${CLAB_RUNTIME:-docker}}}"
INSTRUMENTED_NODES_LABEL="${OPENPE_E2E_NODE_SELECTOR:-node-role.kubernetes.io/worker}"

# shellcheck source=./e2e-test-excludes.sh
source "${SCRIPT_DIR}/e2e-test-excludes.sh"
SKIP="$(join '|' "${EXCLUDE_ARRAY[@]}")"
if [[ -n "${OPENPE_E2E_SKIP:-}" ]]; then
  extra="${OPENPE_E2E_SKIP//|/ }"
  # shellcheck disable=SC2206
  extra_parts=( ${extra} )
  for part in "${extra_parts[@]}"; do
    [[ -n "${part}" ]] || continue
    SKIP="${SKIP}|${part}"
  done
fi

# Pass OPENPE_E2E_FOCUS through as a single --focus value (Ginkgo regex; | = OR).
FOCUS_FLAGS=""
if [[ -n "${OPENPE_E2E_FOCUS:-}" ]]; then
  FOCUS_FLAGS="--focus=${OPENPE_E2E_FOCUS}"
fi

GROUT_TEST_ARGS=""
GROUT_GINKGO_ARGS=""
if [ "${OPENPEROUTER_DATAPATH:-}" == "grout" ]; then
  GROUT_TEST_ARGS="--groutmode"
  GROUT_GINKGO_ARGS="--label-filter='grout-support || grout-only'"
fi

echo "=== Run bastion e2e tests ==="
echo "  CONTAINER_RUNTIME=${RUNTIME} KUBECONFIG=${KUBECONFIG:-}"
echo "  openperouter-namespace=openshift-openperouter"
echo "  frrk8s-namespace=openshift-frr-k8s"
echo "  nodelink=${NODELINK}"
echo "  instrumented-nodes-label=${INSTRUMENTED_NODES_LABEL}"
echo "  focus=${OPENPE_E2E_FOCUS:-}"
echo "  skip=${SKIP}"

pushd "$SCRIPT_DIR"/../..

CONTAINER_RUNTIME="${RUNTIME}" make e2etests \
  TEST_ARGS="--nodelink-config=${NODELINK} \
    --frrk8s-namespace=openshift-frr-k8s \
    --openperouter-namespace=openshift-openperouter \
    --instrumented-nodes-label=${INSTRUMENTED_NODES_LABEL} \
    ${GROUT_TEST_ARGS}" \
  KUBECONFIG_PATH="${KUBECONFIG}" \
  GINKGO_ARGS="--junit-report=junit_e2e.xml \
    --label-filter=\!'systemdmode' \
    --skip='${SKIP}' \
    ${FOCUS_FLAGS} \
    ${GROUT_GINKGO_ARGS}"

popd
