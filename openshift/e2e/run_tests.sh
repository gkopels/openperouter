#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODELINK="${SCRIPT_DIR}/nodelink.json"
STATE_FILE="${SCRIPT_DIR}/.e2e-bastion-state/worker-net.json"
PROVIDER="${OPENPE_E2E_PROVIDER:-}"

# How the lab was deployed (setup-clab writes "provider" into nodelink.json).
# Also treat worker-net state / non-toswitch underlay iface as bastion signals.
deployed_provider() {
	local p=""
	if [[ -f "${NODELINK}" ]]; then
		p="$(python3 -c "import json; print(json.load(open('${NODELINK}')).get('provider') or '')" 2>/dev/null || true)"
	fi
	if [[ -n "${p}" ]]; then
		echo "${p}"
		return
	fi
	if [[ -f "${STATE_FILE}" ]]; then
		echo "bastion"
		return
	fi
	if [[ -n "${OPENPE_UNDERLAY_IFACE:-}" && "${OPENPE_UNDERLAY_IFACE}" != toswitch* ]]; then
		echo "bastion"
		return
	fi
	echo ""
}

DEPLOYED="$(deployed_provider)"
if [[ -n "${DEPLOYED}" ]]; then
	if [[ -z "${PROVIDER}" ]]; then
		# Inherit from nodelink so metal CI (and local runs after setup-clab)
		# do not need an explicit OPENPE_E2E_PROVIDER export.
		PROVIDER="${DEPLOYED}"
	elif [[ "${PROVIDER}" != "${DEPLOYED}" ]]; then
		echo "ERROR: OPENPE_E2E_PROVIDER=${PROVIDER} but nodelink/lab was deployed as ${DEPLOYED}" >&2
		echo "  export OPENPE_E2E_PROVIDER=${DEPLOYED}" >&2
		exit 1
	fi
elif [[ -z "${PROVIDER}" ]]; then
	# No deploy signal — default virtual-OCP path, same as before.
	PROVIDER="dev-scripts"
fi

# Bastion: clab is deployed with sudo podman (rootful). Ginkgo uses
# CONTAINER_RUNTIME as a single binary — default to podman-root.sh so tests
# see the same containers. KIND / virtual OCP keep docker unless overridden.
if [[ "${PROVIDER}" == "bastion" ]]; then
	RUNTIME="${CONTAINER_RUNTIME:-${SCRIPT_DIR}/podman-root.sh}"
	if [[ "${RUNTIME}" == "${SCRIPT_DIR}/podman-root.sh" && ! -x "${RUNTIME}" ]]; then
		echo "ERROR: bastion default runtime missing or not executable: ${RUNTIME}" >&2
		exit 1
	fi
else
	RUNTIME="${CONTAINER_RUNTIME:-${CLAB_RUNTIME:-${OPENPE_CLAB_RUNTIME:-docker}}}"
fi

# Namespace where OpenPERouter runs (OCP CI: openshift-openperouter; some labs: openperouter-system)
OPENPE_NS="${OPENPE_E2E_NAMESPACE:-openshift-openperouter}"
FRRK8S_NAMESPACE="${FRRK8S_NAMESPACE:-openshift-frr-k8s}"

# Optional Ginkgo --focus / --skip via OPENPE_E2E_FOCUS / OPENPE_E2E_SKIP.
# Unset = run the suite like KIND (label-filter only; no hardcoded focus wave).
# Values may be pipe-separated (legacy) or whitespace-separated; we expand to
# repeated --focus/--skip flags. Do NOT pass a raw "A|B" string through `make
# GINKGO_ARGS=...` — Makefile uses `SHELL=bash -o pipefail`, so unquoted `|`
# turns the ginkgo recipe into a pipeline (suite can pass, make still exits 1).
FOCUS="${OPENPE_E2E_FOCUS:-}"
SKIP="${OPENPE_E2E_SKIP:-}"

# Split "a|b|c" or "a b c" into repeated ginkgo flags (multiple flags are ORed).
ginkgo_regex_flags() {
	local flag="$1"
	local value="$2"
	local part
	local out=()
	if [[ -z "${value}" ]]; then
		return 0
	fi
	value="${value//|/ }"
	# shellcheck disable=SC2206
	local parts=( ${value} )
	for part in "${parts[@]}"; do
		[[ -n "${part}" ]] || continue
		out+=( "${flag}=${part}" )
	done
	printf '%s\n' "${out[@]}"
}
FOCUS_FLAGS="$(ginkgo_regex_flags --focus "${FOCUS}" | paste -sd' ' -)"
SKIP_FLAGS="$(ginkgo_regex_flags --skip "${SKIP}" | paste -sd' ' -)"

# Bastion preflight: same contract as configure-bastion-worker-net.sh so Ginkgo
# sees the real underlay NIC (not default toswitch1). Export for make e2etests.
if [[ "${PROVIDER}" == "bastion" ]]; then
	if [[ -z "${KUBECONFIG:-}" ]]; then
		echo "ERROR: KUBECONFIG must be set for bastion e2e" >&2
		exit 1
	fi
	if [[ ! -f "${KUBECONFIG}" ]]; then
		echo "ERROR: KUBECONFIG file not found: ${KUBECONFIG}" >&2
		exit 1
	fi
	if [[ ! -f "${NODELINK}" ]]; then
		echo "ERROR: ${NODELINK} missing — run setup-clab.sh / deploy-bastion first" >&2
		exit 1
	fi
	if [[ -z "${OPENPE_UNDERLAY_IFACE:-}" && -f "${STATE_FILE}" ]]; then
		OPENPE_UNDERLAY_IFACE="$(python3 -c "import json; print(json.load(open('${STATE_FILE}')).get('underlayIface') or '')")"
	fi
	if [[ -z "${OPENPE_UNDERLAY_IFACE2:-}" && -f "${STATE_FILE}" ]]; then
		OPENPE_UNDERLAY_IFACE2="$(python3 -c "import json; print(json.load(open('${STATE_FILE}')).get('underlayIface2') or '')")"
	fi
	if [[ -z "${OPENPE_UNDERLAY_IFACE:-}" || -z "${OPENPE_UNDERLAY_IFACE2:-}" ]]; then
		echo "ERROR: bastion requires OPENPE_UNDERLAY_IFACE and OPENPE_UNDERLAY_IFACE2" >&2
		echo "  e.g. ens1f0.177 and ens1f1.178 — setup-clab does not rename worker NICs" >&2
		exit 1
	fi
	export OPENPE_UNDERLAY_IFACE
	export OPENPE_UNDERLAY_IFACE2
fi

# Ginkgo --instrumented-nodes-label (k8s label selector). On bastion, default to the
# same selector used for nodelink (OPENPE_E2E_NODE_SELECTOR) so masters are excluded.
# Override with OPENPE_E2E_INSTRUMENTED_NODES_LABEL; set empty to select all nodes.
if [[ "${PROVIDER}" == "bastion" ]]; then
	INSTRUMENTED_NODES_LABEL="${OPENPE_E2E_INSTRUMENTED_NODES_LABEL:-${OPENPE_E2E_NODE_SELECTOR:-node-role.kubernetes.io/worker}}"
else
	INSTRUMENTED_NODES_LABEL="${OPENPE_E2E_INSTRUMENTED_NODES_LABEL:-}"
fi

TEST_ARGS="--nodelink-config=${NODELINK} \
	--frrk8s-namespace=${FRRK8S_NAMESPACE} \
	--openperouter-namespace=${OPENPE_NS}"
if [[ -n "${INSTRUMENTED_NODES_LABEL}" ]]; then
	TEST_ARGS="${TEST_ARGS} --instrumented-nodes-label=${INSTRUMENTED_NODES_LABEL}"
fi

echo "=== Run e2e tests ==="
echo "  OPENPE_E2E_PROVIDER=${PROVIDER}"
echo "  CONTAINER_RUNTIME=${RUNTIME} KUBECONFIG=${KUBECONFIG:-}"
echo "  openperouter-namespace=${OPENPE_NS}"
echo "  frrk8s-namespace=${FRRK8S_NAMESPACE}"
echo "  nodelink=${NODELINK}"
if [[ -n "${INSTRUMENTED_NODES_LABEL}" ]]; then
	echo "  instrumented-nodes-label=${INSTRUMENTED_NODES_LABEL}"
else
	echo "  instrumented-nodes-label=<unset> (all nodes)"
fi
if [[ "${PROVIDER}" == "bastion" ]]; then
	echo "  OPENPE_UNDERLAY_IFACE=${OPENPE_UNDERLAY_IFACE}"
	echo "  OPENPE_UNDERLAY_IFACE2=${OPENPE_UNDERLAY_IFACE2}"
fi
echo "  focus=${FOCUS}"
echo "  skip=${SKIP}"
echo "  ginkgo focus flags: ${FOCUS_FLAGS}"
echo "  ginkgo skip flags:  ${SKIP_FLAGS}"

pushd "$SCRIPT_DIR"/../..

# label-filter uses '!'; keep it as one make word with no `|`.
CONTAINER_RUNTIME="${RUNTIME}" make e2etests \
	TEST_ARGS="${TEST_ARGS}" \
	KUBECONFIG_PATH=$KUBECONFIG \
	GINKGO_ARGS="--label-filter=!systemd-mode ${FOCUS_FLAGS} ${SKIP_FLAGS}"

popd
