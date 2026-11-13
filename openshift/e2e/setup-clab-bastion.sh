#!/bin/bash
# Bastion-only: deploy ocp.clab.yml on host bridges and write nodelink.json.
#
# Prerequisites:
#   - KUBECONFIG set; OpenPE on the cluster
#   - toswitch1/toswitch2 via setup-bastion-bridges.sh
#   - OPENPE_UNDERLAY_IFACE and OPENPE_UNDERLAY_IFACE2 (real worker NICs)
#   - Docker by default (CLAB_RUNTIME / OPENPE_CLAB_RUNTIME)
#
# Usage:
#   set -a && source openshift/e2e/bastion.env.example && set +a
#   ./openshift/e2e/setup-bastion-bridges.sh
#   ./openshift/e2e/setup-clab-bastion.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
NODELINK_OUT="${SCRIPT_DIR}/nodelink.json"

RUNTIME="${CLAB_RUNTIME:-${OPENPE_CLAB_RUNTIME:-docker}}"
NODE_IP_BASE="${OPENPE_BASTION_NODE_IP_BASE:-100}"
SKIP_SRV6_SETUP="${OPENPE_BASTION_SKIP_SRV6_SETUP:-true}"
NODE_SELECTOR="${OPENPE_E2E_NODE_SELECTOR:-node-role.kubernetes.io/worker}"
CLI="sudo ${RUNTIME}"

if [[ -z "${OPENPE_UNDERLAY_IFACE:-}" || -z "${OPENPE_UNDERLAY_IFACE2:-}" ]]; then
  echo "ERROR: bastion requires OPENPE_UNDERLAY_IFACE and OPENPE_UNDERLAY_IFACE2" >&2
  exit 1
fi
BASTION_IFACE1="${OPENPE_UNDERLAY_IFACE}"
BASTION_IFACE2="${OPENPE_UNDERLAY_IFACE2}"

echo "=== setup-clab-bastion ==="
echo "  runtime=${RUNTIME} underlay=${BASTION_IFACE1},${BASTION_IFACE2}"

for br in toswitch1 toswitch2; do
  if ! ip link show "${br}" >/dev/null 2>&1; then
    echo "ERROR: bridge ${br} missing. Run setup-bastion-bridges.sh first." >&2
    exit 1
  fi
done

MGMT_IFACE="${CLAB_BASTION_MGMT_IFACE:-eth0}"
def_dev="$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}')"
for iface in "${CLAB_BASTION_LAB_IFACE_TOSWITCH1:-eth1}" "${CLAB_BASTION_LAB_IFACE_TOSWITCH2:-eth2}"; do
  if [[ -n "${def_dev}" && "${def_dev}" == "${iface}" ]]; then
    echo "ERROR: default route is on ${iface}; fix mgmt (${MGMT_IFACE}) before continuing" >&2
    exit 1
  fi
done

if ! command -v containerlab >/dev/null 2>&1 && ! command -v clab >/dev/null 2>&1; then
  echo "containerlab not found; installing it"
  command -v curl >/dev/null 2>&1 || {
    echo "curl is required to install containerlab" >&2
    exit 1
  }
  bash -c "$(curl -fsSL https://get.containerlab.dev)"
fi
CLAB_BIN="$(command -v containerlab || command -v clab)"

echo "=== Generate peerLeaf FRR configs ==="
cd "${REPO_ROOT}/clab/tools"
go build -o generate_leaf_config/generate_leaf generate_leaf_config/common.go generate_leaf_config/generate_leaf.go
go build -o generate_leaf_config/generate_leafkind generate_leaf_config/common.go generate_leaf_config/generate_leafkind.go

rm -f ../leafA/frr.conf
./generate_leaf_config/generate_leaf \
  -leaf leafA -neighbor 192.168.1.0 -network 100.64.0.1/32 \
  -template generate_leaf_config/frr_template/frr.conf.template

rm -f ../leafB/frr.conf
./generate_leaf_config/generate_leaf \
  -leaf leafB -neighbor 192.168.1.2 -network 100.64.0.2/32 \
  -template generate_leaf_config/frr_template/frr.conf.template

rm -f ../singlecluster/leafkind1/frr.conf
./generate_leaf_config/generate_leafkind \
  -leaf singlecluster/leafkind1 -asn 64512 -spine-ip 192.168.1.4 \
  -ipv4-listen-range 192.168.11.0/24 -ipv6-listen-range 2001:db8:11::/64 \
  -isis-net 49.0001.0000.0000.0004.00 \
  -toswitch-interface toswitch1 \
  -template generate_leaf_config/frr_template/leafkind.conf.template

rm -f ../singlecluster/leafkind2/frr.conf
./generate_leaf_config/generate_leafkind \
  -leaf singlecluster/leafkind2 -asn 64513 -spine-ip 192.168.1.6 \
  -ipv4-listen-range 192.168.12.0/24 -ipv6-listen-range 2001:db8:12::/64 \
  -isis-net 49.0001.0000.0000.0005.00 \
  -toswitch-interface toswitch2 \
  -template generate_leaf_config/frr_template/leafkind.conf.template

echo "=== Ensure container runtime (${RUNTIME}) ==="
if [[ "${RUNTIME}" == "docker" ]]; then
  sudo systemctl enable --now docker
elif [[ "${RUNTIME}" == "podman" ]]; then
  sudo systemctl enable --now podman.socket 2>/dev/null || true
else
  echo "ERROR: unsupported CLAB_RUNTIME=${RUNTIME}" >&2
  exit 1
fi

echo "=== Deploy clab topology ==="
cd "${REPO_ROOT}"
# Destroy any prior instance of this topo first (no --reconfigure).
# teardown-clab exits 0 when the lab is already absent; real failures must surface.
bash "${SCRIPT_DIR}/teardown-clab.sh"
sudo "${CLAB_BIN}" deploy --runtime "${RUNTIME}" \
  --topo "${SCRIPT_DIR}/ocp.clab.yml"

echo "=== Assign IPs to clab containers ==="
cd "${REPO_ROOT}/clab"
go run tools/assign_ips/assign_ips.go \
  -file "${SCRIPT_DIR}/ip_map_ocp.txt" -engine "${CLI}"

${CLI} exec clab-kind-leafkind1 ip link set dev toswitch1 mtu 1500
${CLI} exec clab-kind-leafkind2 ip link set dev toswitch2 mtu 1500

echo "=== Run container setup scripts ==="
if [[ "${SKIP_SRV6_SETUP}" == "true" ]]; then
  echo "  skipping *SRV6* setups (OPENPE_BASTION_SKIP_SRV6_SETUP=true)"
fi
for c in leafA leafB leafSRV6 hostA_red hostA_blue hostA_default hostB_red hostB_blue hostSRV6_red hostSRV6_blue; do
  container="clab-kind-${c}"
  if [[ "${SKIP_SRV6_SETUP}" == "true" && "${c}" == *SRV6* ]]; then
    echo "  skip ${c}"
    continue
  fi
  echo "Setting up container: ${c}"
  if timeout 10s ${CLI} exec "${container}" test -f /setup.sh 2>/dev/null; then
    setup_log="${SCRIPT_DIR}/.setup-${c}.log"
    if timeout 5m ${CLI} exec "${container}" bash /setup.sh >"${setup_log}" 2>&1; then
      echo "  ${c}: ok (log ${setup_log})"
    else
      rc=$?
      echo "Setup failed or timed out for ${container} (exit code ${rc}); last log lines:" >&2
      tail -40 "${setup_log}" >&2 || true
      exit "${rc}"
    fi
  else
    rc=$?
    if [ "${rc}" -ne 1 ]; then
      echo "Could not inspect ${container} for /setup.sh (exit code ${rc})" >&2
      exit "${rc}"
    fi
  fi
done

echo "=== Create ${NODELINK_OUT} ==="
echo "  node selector: ${NODE_SELECTOR}"
NODES=$(oc get nodes -l "${NODE_SELECTOR}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
if [[ -z "${NODES//[[:space:]]/}" ]]; then
  echo "ERROR: no nodes matched selector ${NODE_SELECTOR}" >&2
  exit 1
fi

NODE_INDEX=0
NODES_JSON=""
for node in ${NODES}; do
  TS1_V4="192.168.11.$((NODE_IP_BASE + NODE_INDEX))"
  TS2_V4="192.168.12.$((NODE_IP_BASE + NODE_INDEX))"
  TS1_V6="2001:db8:11::$((NODE_IP_BASE + NODE_INDEX))"
  TS2_V6="2001:db8:12::$((NODE_IP_BASE + NODE_INDEX))"
  NODE_INDEX=$((NODE_INDEX + 1))
  echo "  planned ${node}: ${BASTION_IFACE1}=${TS1_V4} ${BASTION_IFACE2}=${TS2_V4}"

  if [ -n "${NODES_JSON}" ]; then
    NODES_JSON="${NODES_JSON},"
  fi
  NODES_JSON="${NODES_JSON}
    \"${node}\": {
      \"ipForKindLeaf\": \"${TS1_V4}\",
      \"ipForKindLeaf2\": \"${TS2_V4}\",
      \"ipv6ForKindLeaf\": \"${TS1_V6}\",
      \"ipv6ForKindLeaf2\": \"${TS2_V6}\",
      \"ifaceForKindLeaf\": \"${BASTION_IFACE1}\",
      \"ifaceForKindLeaf2\": \"${BASTION_IFACE2}\",
      \"leafIfaceForKindLeaf\": \"toswitch1\",
      \"leafIfaceForKindLeaf2\": \"toswitch2\"
    }"
done

cat > "${NODELINK_OUT}" << TOPOEOF
{
  "underlayHostIfaces": ["${BASTION_IFACE1}", "${BASTION_IFACE2}"],
  "nodes": {${NODES_JSON}
  }
}
TOPOEOF

echo ""
echo "=== Setup complete ==="
echo "Node links config: ${NODELINK_OUT}"
echo ""
cat "${NODELINK_OUT}"
echo ""
echo "Worker underlay IPs: configure-bastion-worker-net.sh"
