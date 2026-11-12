#!/bin/bash
# Bastion-only e2e runner against nodelink.json + real worker underlay NICs.
#
# Requires: KUBECONFIG, nodelink.json (underlay NICs validated in setup/configure).
# Default container runtime: docker (OPENPE_CLAB_RUNTIME / CLAB_RUNTIME / CONTAINER_RUNTIME).
# OPENPE_E2E_NODE_SELECTOR drives nodelink generation and --instrumented-nodes-label.
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
OPENPE_NS="${OPENPE_E2E_NAMESPACE:-openshift-openperouter}"
FRRK8S_NAMESPACE="${FRRK8S_NAMESPACE:-openshift-frr-k8s}"
INSTRUMENTED_NODES_LABEL="${OPENPE_E2E_NODE_SELECTOR:-node-role.kubernetes.io/worker}"

if [[ -z "${KUBECONFIG:-}" ]]; then
  echo "ERROR: KUBECONFIG must be set for bastion e2e" >&2
  exit 1
fi
if [[ ! -f "${KUBECONFIG}" ]]; then
  echo "ERROR: KUBECONFIG file not found: ${KUBECONFIG}" >&2
  exit 1
fi
if [[ ! -f "${NODELINK}" ]]; then
  echo "ERROR: ${NODELINK} missing — run setup-clab-bastion.sh / deploy-bastion first" >&2
  exit 1
fi

# Same excludes as openshift/e2e/run_tests.sh (main / virtual OCP).
EXCLUDE_ARRAY=(
  'Routes.between.bgp.and.the.fabric.underlay.address.family.Unnumbered'
  'DHCP.underlay.lifecycle.removes.the.DHCP.interfaces.when.the.underlay.is.deleted'
  'reflects.type-2.routes.between.client.nodes.via.the.route.reflector'
  'assigns.each.underlay.port.a.unique.IPv6.link-local'
)
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

# Split "a|b|c" or "a b c" into repeated --focus flags (ORed by Ginkgo).
FOCUS_FLAGS=""
if [[ -n "${OPENPE_E2E_FOCUS:-}" ]]; then
  focus_value="${OPENPE_E2E_FOCUS//|/ }"
  # shellcheck disable=SC2206
  focus_parts=( ${focus_value} )
  for part in "${focus_parts[@]}"; do
    [[ -n "${part}" ]] || continue
    FOCUS_FLAGS="${FOCUS_FLAGS} --focus=${part}"
  done
fi

GROUT_TEST_ARGS=""
GROUT_GINKGO_ARGS=""
if [ "${OPENPEROUTER_DATAPATH:-}" == "grout" ]; then
  GROUT_TEST_ARGS="--groutmode"
  GROUT_GINKGO_ARGS="--label-filter='grout-support || grout-only'"
fi

TEST_ARGS="--nodelink-config=${NODELINK} \
  --frrk8s-namespace=${FRRK8S_NAMESPACE} \
  --openperouter-namespace=${OPENPE_NS} \
  --instrumented-nodes-label=${INSTRUMENTED_NODES_LABEL} \
  ${GROUT_TEST_ARGS}"

echo "=== Run bastion e2e tests ==="
echo "  CONTAINER_RUNTIME=${RUNTIME} KUBECONFIG=${KUBECONFIG}"
echo "  openperouter-namespace=${OPENPE_NS}"
echo "  frrk8s-namespace=${FRRK8S_NAMESPACE}"
echo "  nodelink=${NODELINK}"
echo "  instrumented-nodes-label=${INSTRUMENTED_NODES_LABEL}"
echo "  focus=${OPENPE_E2E_FOCUS:-}"
echo "  skip=${SKIP}"

pushd "$SCRIPT_DIR"/../..

CONTAINER_RUNTIME="${RUNTIME}" make e2etests \
  TEST_ARGS="${TEST_ARGS}" \
  KUBECONFIG_PATH="${KUBECONFIG}" \
  GINKGO_ARGS="--junit-report=junit_e2e.xml \
    --label-filter=\!'systemdmode' \
    --skip='${SKIP}' \
    ${FOCUS_FLAGS} \
    ${GROUT_GINKGO_ARGS}"

popd
