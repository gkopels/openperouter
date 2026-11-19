#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

join() {
  local IFS="$1"
  shift
  echo "$*"
}

echo "=== Run e2e tests ==="

# shellcheck source=./e2e-test-excludes.sh
source "${SCRIPT_DIR}/e2e-test-excludes.sh"

pushd "$SCRIPT_DIR"/../..

SKIP="$(join '|' "${EXCLUDE_ARRAY[@]}")"

GROUT_TEST_ARGS=""
GROUT_GINKGO_ARGS=""
if [ "${OPENPEROUTER_DATAPATH:-}" == "grout" ]; then
  GROUT_TEST_ARGS="--groutmode"
  GROUT_GINKGO_ARGS="--label-filter='grout-support || grout-only'"
fi

CONTAINER_RUNTIME=docker make e2etests \
       TEST_ARGS="--nodelink-config=${SCRIPT_DIR}/nodelink.json \
               --frrk8s-namespace=openshift-frr-k8s \
               --openperouter-namespace=openshift-openperouter \
               ${GROUT_TEST_ARGS}" \
       KUBECONFIG_PATH="${KUBECONFIG}" \
       GINKGO_ARGS="--junit-report=junit_e2e.xml \
               --label-filter=\!'systemdmode' \
               --skip='${SKIP}' \
               ${GROUT_GINKGO_ARGS}"

popd
