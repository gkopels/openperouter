#!/bin/bash
# Sets up the containerlab fabric and wires it to an OpenShift cluster.
#
# Providers (OPENPE_E2E_PROVIDER):
#   dev-scripts (default) — virtual OCP via libvirt nets toswitch1/toswitch2 + docker
#   bastion               — clab on bastion host bridges; podman by default; skip virsh
#
# Prerequisites (both):
#   - OpenPERouter + frr-k8s on the cluster
#   - KUBECONFIG set
#   - toswitch1 / toswitch2 bridges already present
#       * dev-scripts: setup_extra_networks.sh / EXTRA_NETWORK_NAMES
#       * bastion:     setup-bastion-bridges.sh
#   - containerlab installed (or curl available to install)
#
# Bastion extras:
#   CLAB_RUNTIME=podman|docker (default podman for bastion, docker for dev-scripts)
#   Bastion always writes nodelink.json with planned addresses only (no virsh /
#   in-script IP apply). Worker underlay IPs are applied by
#   configure-bastion-worker-net.sh (e2e-bastion lifecycle).
#
# Usage:
#   export KUBECONFIG=...
#   # virtual OCP:
#   ./openshift/e2e/setup-clab.sh
#   # bastion:
#   set -a && source openshift/e2e/bastion.env.example && set +a
#   ./openshift/e2e/setup-bastion-bridges.sh
#   ./openshift/e2e/setup-clab.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
NODELINK_OUT="${SCRIPT_DIR}/nodelink.json"

PROVIDER="${OPENPE_E2E_PROVIDER:-dev-scripts}"
case "${PROVIDER}" in
  bastion|dev-scripts) ;;
  *)
    echo "ERROR: unknown OPENPE_E2E_PROVIDER=${PROVIDER} (want bastion or dev-scripts)" >&2
    exit 1
    ;;
esac
if [[ "${PROVIDER}" == "bastion" ]]; then
    RUNTIME="${CLAB_RUNTIME:-${OPENPE_CLAB_RUNTIME:-podman}}"
else
    RUNTIME="${CLAB_RUNTIME:-${OPENPE_CLAB_RUNTIME:-docker}}"
fi
# First nodelink node gets 192.168.11.${BASE} (use 103 if workers already use .103/.104)
NODE_IP_BASE="${OPENPE_BASTION_NODE_IP_BASE:-100}"

CLI="sudo ${RUNTIME}"

echo "=== OpenPE setup-clab ==="
echo "  provider=${PROVIDER} runtime=${RUNTIME}"

if ! command -v containerlab >/dev/null 2>&1 && ! command -v clab >/dev/null 2>&1; then
    echo "containerlab not found; installing it"
    command -v curl >/dev/null 2>&1 || {
        echo "curl is required to install containerlab" >&2
        exit 1
    }
    bash -c "$(curl -fsSL https://get.containerlab.dev)"
fi
CLAB_BIN="$(command -v containerlab || command -v clab)"

if [[ "${PROVIDER}" == "dev-scripts" ]]; then
    echo "=== Step 1: Disable DHCP on extra networks (libvirt) ==="
    # dev-scripts enables DHCP by default. DHCP IPs compete with our static IPs
    # and expire after 60 minutes, breaking VXLAN routing.
    for net in toswitch1 toswitch2; do
        DHCP_RANGE=$(virsh net-dumpxml "${net}" 2>/dev/null | grep '<range' | sed 's/^ *//' ) || true
        if [ -n "${DHCP_RANGE}" ]; then
            virsh net-update "${net}" delete ip-dhcp-range "${DHCP_RANGE}" --live --config 2>/dev/null && \
                echo "  ${net}: removed DHCP range" || echo "  ${net}: failed to remove DHCP range"
        else
            echo "  ${net}: no DHCP range configured"
        fi
    done
elif [[ "${PROVIDER}" == "bastion" ]]; then
    echo "=== Step 1: Skip libvirt DHCP (bastion host bridges) ==="
    for br in toswitch1 toswitch2; do
        if ! ip link show "${br}" >/dev/null 2>&1; then
            echo "ERROR: bridge ${br} missing. Run setup-bastion-bridges.sh first." >&2
            exit 1
        fi
        echo "  ${br}: present"
    done
    # Refuse if lab NICs stole the default route (exact device match; not eth1⊂eth10).
    MGMT_IFACE="${CLAB_BASTION_MGMT_IFACE:-eth0}"
    def_dev="$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}')"
    for iface in "${CLAB_BASTION_LAB_IFACE_TOSWITCH1:-eth1}" "${CLAB_BASTION_LAB_IFACE_TOSWITCH2:-eth2}"; do
        if [[ -n "${def_dev}" && "${def_dev}" == "${iface}" ]]; then
            echo "ERROR: default route is on ${iface}; fix mgmt (${MGMT_IFACE}) before continuing" >&2
            ip route show default >&2 || true
            exit 1
        fi
    done
fi

echo "=== Step 2: Generate peerLeaf FRR configs ==="
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

echo "=== Step 3: Ensure container runtime (${RUNTIME}) ==="
if [[ "${RUNTIME}" == "docker" ]]; then
    sudo systemctl enable --now docker
elif [[ "${RUNTIME}" == "podman" ]]; then
    sudo systemctl enable --now podman.socket 2>/dev/null || true
else
    echo "ERROR: unsupported CLAB_RUNTIME=${RUNTIME}" >&2
    exit 1
fi

echo "=== Step 4: Deploy clab topology ==="
cd "${REPO_ROOT}"
# containerlab 0.79 + podman: --reconfigure can SEGV in destroy/ListContainers.
# Destroy explicitly first, then deploy clean.
sudo "${CLAB_BIN}" destroy --runtime "${RUNTIME}" \
  --topo "${SCRIPT_DIR}/ocp.clab.yml" --cleanup 2>/dev/null || true
# Remove leftover lab containers that confuse the next deploy (both runtimes;
# same pattern as teardown-clab.sh).
if [[ "${RUNTIME}" == "podman" ]]; then
    sudo podman ps -a --filter name=clab-kind --format '{{.Names}}' \
      | xargs -r sudo podman rm -f 2>/dev/null || true
elif [[ "${RUNTIME}" == "docker" ]]; then
    sudo docker ps -a --filter name=clab-kind --format '{{.Names}}' \
      | xargs -r sudo docker rm -f 2>/dev/null || true
fi
sudo "${CLAB_BIN}" deploy --runtime "${RUNTIME}" \
    --topo "${SCRIPT_DIR}/ocp.clab.yml"

echo "=== Step 5: Assign IPs to clab containers ==="
cd "${REPO_ROOT}/clab"
go run tools/assign_ips/assign_ips.go \
    -file "${SCRIPT_DIR}/ip_map_ocp.txt" -engine "${CLI}"

${CLI} exec clab-kind-leafkind1 ip link set dev toswitch1 mtu 1500
${CLI} exec clab-kind-leafkind2 ip link set dev toswitch2 mtu 1500

echo "=== Step 6: Run container setup scripts ==="
# leafSRV6 / hostSRV6_* enable SRv6 sysctls that hang this bastion kernel under podman
# (guest soft-lock / SSH loss). Skip on bastion until that is root-caused.
# Bastion default: skip SRv6 setups (sysctls hang under podman). Opt in with =false.
if [[ "${PROVIDER}" == "bastion" ]]; then
    SKIP_SRV6_SETUP="${OPENPE_BASTION_SKIP_SRV6_SETUP:-true}"
else
    SKIP_SRV6_SETUP="${OPENPE_BASTION_SKIP_SRV6_SETUP:-false}"
fi
if [[ "${PROVIDER}" == "bastion" && "${SKIP_SRV6_SETUP}" == "true" ]]; then
    echo "  skipping leafSRV6/hostSRV6_* setups (OPENPE_BASTION_SKIP_SRV6_SETUP=true)"
fi
for c in leafA leafB leafSRV6 hostA_red hostA_blue hostA_default hostB_red hostB_blue hostSRV6_red hostSRV6_blue; do
    container="clab-kind-${c}"
    if [[ "${PROVIDER}" == "bastion" && "${SKIP_SRV6_SETUP}" == "true" && "${c}" == *SRV6* ]]; then
        echo "  skip ${c}"
        continue
    fi
    echo "Setting up container: ${c}"

    if timeout 10s ${CLI} exec "${container}" test -f /setup.sh 2>/dev/null; then
        # Avoid bash -x on the SSH tty (large output can stall/drop interactive sessions).
        # Log to a file on the bastion instead.
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

# Bastion/CNF labs often only cable underlay on workers (e.g. MCP workercnf).
# Override with OPENPE_E2E_NODE_SELECTOR (label selector), e.g.:
#   node-role.kubernetes.io/workercnf
#   node-role.kubernetes.io/worker
if [[ "${PROVIDER}" == "bastion" ]]; then
    NODE_SELECTOR="${OPENPE_E2E_NODE_SELECTOR:-node-role.kubernetes.io/worker}"
    echo "  node selector (bastion): ${NODE_SELECTOR}"
    NODES=$(oc get nodes -l "${NODE_SELECTOR}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
else
    NODES=$(oc get nodes -l kubernetes.io/os=linux -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
fi
if [[ -z "${NODES//[[:space:]]/}" ]]; then
    echo "ERROR: no nodes matched selector for nodelink generation" >&2
    exit 1
fi

OPENPE_NS="${OPENPE_E2E_NAMESPACE:-openshift-openperouter}"
# Bastion: require both worker underlay NIC names (no virsh rename to toswitch*).
if [[ "${PROVIDER}" == "bastion" ]]; then
    if [[ -z "${OPENPE_UNDERLAY_IFACE:-}" || -z "${OPENPE_UNDERLAY_IFACE2:-}" ]]; then
        echo "ERROR: bastion requires OPENPE_UNDERLAY_IFACE and OPENPE_UNDERLAY_IFACE2" >&2
        echo "  e.g. ens1f0.177 and ens1f1.178 — workers keep vendor NIC names; toswitch* is not safe" >&2
        exit 1
    fi
fi
BASTION_IFACE1="${OPENPE_UNDERLAY_IFACE:-toswitch1}"
BASTION_IFACE2="${OPENPE_UNDERLAY_IFACE2:-toswitch2}"

node_exec() {
    local node=$1; shift
    local pod
    pod=$(oc get pods -n "${OPENPE_NS}" -l app=controller \
        --field-selector spec.nodeName="${node}" -o jsonpath='{.items[0].metadata.name}')
    if [[ -z "${pod}" ]]; then
        echo "ERROR: no controller pod on ${node} in ${OPENPE_NS}" >&2
        return 1
    fi
    oc exec -n "${OPENPE_NS}" "${pod}" -- nsenter -t 1 -m -u -i -n "$@"
}
if [[ "${PROVIDER}" == "dev-scripts" ]]; then
    echo "=== Step 7: Rename NICs + install udev rules (virsh / ostest_*) ==="
    for node in ${NODES}; do
        short_name="${node%%.*}"
        vm_name="ostest_${short_name//-/_}"
        for i in 1 2; do
            BRIDGE_MAC=$(sudo virsh domiflist "${vm_name}" 2>/dev/null | awk -v network="toswitch${i}" '$3 == network && !found { print $5; found=1 }')
            if [ -n "${BRIDGE_MAC}" ]; then
                node_exec "${node}" bash -c "
                    echo 'SUBSYSTEM==\"net\", ATTR{address}==\"${BRIDGE_MAC}\", NAME=\"toswitch${i}\"' \
                        > /etc/udev/rules.d/70-toswitch${i}.rules
                    udevadm control --reload-rules
                    IFACE=\$(ip -br link show | grep '${BRIDGE_MAC}' | awk '{print \$1}')
                    if [ -n \"\$IFACE\" ] && [ \"\$IFACE\" != \"toswitch${i}\" ]; then
                        nmcli device set \$IFACE managed no 2>/dev/null || true
                        ip link set \$IFACE down
                        ip link set \$IFACE name toswitch${i}
                        ip link set toswitch${i} up
                        echo \"  ${node}: \$IFACE -> toswitch${i}\"
                    elif [ \"\$IFACE\" = \"toswitch${i}\" ]; then
                        nmcli device set toswitch${i} managed no 2>/dev/null || true
                        echo \"  ${node}: toswitch${i} already named\"
                    else
                        echo \"  ${node}: toswitch${i} not found (MAC ${BRIDGE_MAC})\"
                    fi
                " 2>&1
            fi
        done
    done

    echo "=== Step 8: Assign static IPs on workers (IPv4 + IPv6) ==="
    NODE_INDEX=0
    NODES_JSON=""
    for node in ${NODES}; do
        TS1_V4="192.168.11.$((NODE_IP_BASE + NODE_INDEX))"
        TS2_V4="192.168.12.$((NODE_IP_BASE + NODE_INDEX))"
        TS1_V6="2001:db8:11::$((NODE_IP_BASE + NODE_INDEX))"
        TS2_V6="2001:db8:12::$((NODE_IP_BASE + NODE_INDEX))"
        NODE_INDEX=$((NODE_INDEX + 1))

        node_exec "${node}" bash -c "
            ip -4 addr flush dev toswitch1 2>/dev/null || true
            ip -4 addr add ${TS1_V4}/24 dev toswitch1
            ip -6 addr add ${TS1_V6}/64 dev toswitch1 2>/dev/null || true
            ip link set toswitch1 up

            ip -4 addr flush dev toswitch2 2>/dev/null || true
            ip -4 addr add ${TS2_V4}/24 dev toswitch2
            ip -6 addr add ${TS2_V6}/64 dev toswitch2 2>/dev/null || true
            ip link set toswitch2 up
        " 2>&1
        echo "  ${node}: ts1=${TS1_V4}+${TS1_V6}  ts2=${TS2_V4}+${TS2_V6}"

        if [ -n "${NODES_JSON}" ]; then
            NODES_JSON="${NODES_JSON},"
        fi
        NODES_JSON="${NODES_JSON}
    \"${node}\": {
      \"ipForKindLeaf\": \"${TS1_V4}\",
      \"ipForKindLeaf2\": \"${TS2_V4}\",
      \"ipv6ForKindLeaf\": \"${TS1_V6}\",
      \"ipv6ForKindLeaf2\": \"${TS2_V6}\",
      \"ifaceForKindLeaf\": \"toswitch1\",
      \"ifaceForKindLeaf2\": \"toswitch2\",
      \"leafIfaceForKindLeaf\": \"toswitch1\",
      \"leafIfaceForKindLeaf2\": \"toswitch2\"
    }"
    done
elif [[ "${PROVIDER}" == "bastion" ]]; then
    echo "=== Step 7/8: Bastion — nodelink only (worker IPs via configure-bastion-worker-net.sh) ==="
    echo "  iface1=${BASTION_IFACE1} iface2=${BASTION_IFACE2}"
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
fi

# underlayHostIfaces: KIND uses toswitch1/2; bastion uses OPENPE_UNDERLAY_IFACE*.
if [[ "${PROVIDER}" == "bastion" ]]; then
    UNDERLAY_HOST_IFACES_JSON="[\"${BASTION_IFACE1}\", \"${BASTION_IFACE2}\"]"
else
    UNDERLAY_HOST_IFACES_JSON='["toswitch1", "toswitch2"]'
fi

cat > "${NODELINK_OUT}" << TOPOEOF
{
  "provider": "${PROVIDER}",
  "underlayHostIfaces": ${UNDERLAY_HOST_IFACES_JSON},
  "nodes": {${NODES_JSON}
  }
}
TOPOEOF

echo ""
echo "=== Setup complete ==="
echo "Node links config: ${NODELINK_OUT}"
echo ""
cat "${NODELINK_OUT}"

if [[ "${PROVIDER}" == "bastion" ]]; then
    echo ""
    echo "Bastion notes:"
    echo "  - Fabric is up on host bridges toswitch1/toswitch2"
    echo "  - Default route must stay on ${CLAB_BASTION_MGMT_IFACE:-eth0} (mgmt)"
    echo "  - Lab NICs: ${CLAB_BASTION_LAB_IFACE_TOSWITCH1:-eth1}->toswitch1, ${CLAB_BASTION_LAB_IFACE_TOSWITCH2:-eth2}->toswitch2"
    echo "  - Worker underlay IPs: configure-bastion-worker-net.sh (OPENPE_UNDERLAY_IFACE, e.g. eth1.100)"
fi
