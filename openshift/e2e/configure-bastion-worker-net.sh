#!/usr/bin/env bash
# Apply underlay IPs on selected worker nodes for bastion e2e.
# Addresses and iface names come from nodelink.json (setup-clab.sh).
# OPENPE_UNDERLAY_IFACE / OPENPE_UNDERLAY_IFACE2 override nodelink ifaces when set.
#
# Both underlay NICs are required (OPENPE_UNDERLAY_IFACE and OPENPE_UNDERLAY_IFACE2).
#
# IPv4-only: nodelink may list ipv6ForKindLeaf*; this script applies IPv4 only.
# Bastion focused e2e is IPv4 underlay today. Records state for
# teardown-bastion-worker-net.sh (and run_tests iface hydration).
#
# Idempotent: each apply flushes IPv4 on the iface then adds the planned address
# (test owns IPv4 on that NIC for the run).
#
# Underlay must be tagged (parent.VID), e.g.:
#   OPENPE_UNDERLAY_IFACE=eth1.100
#   OPENPE_UNDERLAY_IFACE2=eth2.200
# If iface is parent.VID and missing, create `ip link add … type vlan id VID`.
# Also flushes IPv4 on the parent so leftovers on the bare parent cannot steal routes.
# Teardown deletes the planned address and removes vlan subifs we recorded.
#
# Re-run after a partial apply is safe. Planned state is rewritten in full before
# the apply loop so EXIT teardown can remove addresses even if a later node fails.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODELINK="${SCRIPT_DIR}/nodelink.json"
STATE_DIR="${SCRIPT_DIR}/.e2e-bastion-state"
STATE_FILE="${STATE_DIR}/worker-net.json"

OPENPE_NS="${OPENPE_E2E_NAMESPACE:-openshift-openperouter}"

if [[ ! -f "${NODELINK}" ]]; then
  echo "ERROR: ${NODELINK} missing — run setup-clab.sh / deploy-bastion first" >&2
  exit 1
fi

if ! oc get ns "${OPENPE_NS}" >/dev/null 2>&1; then
  echo "ERROR: OpenPE namespace ${OPENPE_NS} not found" >&2
  exit 1
fi

# Bastion does not virsh-rename NICs to toswitch*; require both real worker ifaces.
if [[ -z "${OPENPE_UNDERLAY_IFACE:-}" || -z "${OPENPE_UNDERLAY_IFACE2:-}" ]]; then
  echo "ERROR: bastion requires OPENPE_UNDERLAY_IFACE and OPENPE_UNDERLAY_IFACE2" >&2
  echo "  e.g. ens1f0.177 and ens1f1.178 — setup-clab does not rename worker NICs" >&2
  exit 1
fi

echo "=== configure-bastion-worker-net ==="
echo "  namespace=${OPENPE_NS}"
echo "  nodelink=${NODELINK}"
echo "  OPENPE_UNDERLAY_IFACE=${OPENPE_UNDERLAY_IFACE}"
echo "  OPENPE_UNDERLAY_IFACE2=${OPENPE_UNDERLAY_IFACE2}"

# Same path as teardown: prefer oc debug/chroot, fall back to controller nsenter.
node_exec() {
  local node=$1; shift
  if oc debug "node/${node}" --quiet -- chroot /host "$@" ; then
    return 0
  fi
  echo "WARNING: oc debug failed on ${node}; trying controller nsenter" >&2
  local pod
  pod=$(oc get pods -n "${OPENPE_NS}" -l app=controller \
    --field-selector "spec.nodeName=${node}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -z "${pod}" ]]; then
    echo "ERROR: no controller on ${node} in ${OPENPE_NS}; cannot configure" >&2
    return 1
  fi
  oc exec -n "${OPENPE_NS}" "${pod}" -- nsenter -t 1 -m -u -i -n "$@"
}

# Build apply list from nodelink; env overrides iface names when set.
# Write worker-net.json via json.dump (iface names + entries for teardown).
export OPENPE_UNDERLAY_IFACE="${OPENPE_UNDERLAY_IFACE:-}"
export OPENPE_UNDERLAY_IFACE2="${OPENPE_UNDERLAY_IFACE2:-}"
mkdir -p "${STATE_DIR}"
mapfile -t APPLY_LINES < <(python3 - <<PY
import json, os
with open("${NODELINK}") as f:
    cfg = json.load(f)
env1 = os.environ.get("OPENPE_UNDERLAY_IFACE", "").strip()
env2 = os.environ.get("OPENPE_UNDERLAY_IFACE2", "").strip()
entries = []
for name, nc in cfg.get("nodes", {}).items():
    ip1 = nc.get("ipForKindLeaf", "")
    ip2 = nc.get("ipForKindLeaf2", "")
    if not ip1 or not ip2:
        raise SystemExit(f"nodelink node {name}: requires ipForKindLeaf and ipForKindLeaf2")
    iface1 = env1 or nc.get("ifaceForKindLeaf") or "toswitch1"
    iface2 = env2 or nc.get("ifaceForKindLeaf2") or "toswitch2"
    entries.append({"node": name, "iface": iface1, "ip": ip1, "prefix": 24})
    print(f"{name}|{iface1}|{ip1}|24")
    entries.append({"node": name, "iface": iface2, "ip": ip2, "prefix": 24})
    print(f"{name}|{iface2}|{ip2}|24")
def is_vlan_iface(name: str) -> bool:
    # parent.VID — VID is numeric (eth1.100). Avoid matching e.g. br-ex.
    if "." not in name:
        return False
    parent, _, vid = name.rpartition(".")
    return bool(parent) and vid.isdigit()

for e in entries:
    e["deleteLink"] = is_vlan_iface(e["iface"])

state = {
    "underlayIface": env1,
    "underlayIface2": env2,
    "entries": entries,
}
with open("${STATE_FILE}", "w", encoding="utf-8") as f:
    json.dump(state, f, indent=2)
    f.write("\n")
PY
)

if [[ ${#APPLY_LINES[@]} -eq 0 ]]; then
  echo "ERROR: no underlay addresses derived from nodelink.json" >&2
  rm -f "${STATE_FILE}"
  exit 1
fi
echo "Recorded planned ${STATE_FILE} (${#APPLY_LINES[@]} entries)"

LABELED_NODES=()
for line in "${APPLY_LINES[@]}"; do
  IFS='|' read -r node iface ip plen <<<"${line}"
  echo "  ${node}: ${iface}=${ip}/${plen}"
  node_exec "${node}" bash -c "
    set -e
    iface='${iface}'
    ip='${ip}'
    plen='${plen}'
    # Tagged underlay: parent.VID → create vlan subiface; flush parent IPv4 leftovers.
    case \"\${iface}\" in
      *.[0-9]*)
        parent=\"\${iface%.*}\"
        vid=\"\${iface##*.}\"
        if ! ip link show \"\${parent}\" >/dev/null 2>&1; then
          echo \"ERROR: parent iface \${parent} missing on ${node} (for \${iface})\" >&2
          ip -br link >&2 || true
          exit 1
        fi
        nmcli device set \"\${parent}\" managed no 2>/dev/null || true
        ip link set \"\${parent}\" up
        # Leftover underlay on bare parent steals routes from the vlan subiface.
        ip -4 addr flush dev \"\${parent}\" 2>/dev/null || true
        if ! ip link show \"\${iface}\" >/dev/null 2>&1; then
          echo \"  creating vlan \${iface} on \${parent} id \${vid}\"
          # Idempotent: race with a prior run, or kernel still holds the name
          # after OpenPE moved the iface into a netns (\"VLAN device already exists\").
          if ! add_out=\$(ip link add link \"\${parent}\" name \"\${iface}\" type vlan id \"\${vid}\" 2>&1); then
            if echo \"\${add_out}\" | grep -qiE 'already exists|File exists'; then
              echo \"  vlan \${iface} already exists; continuing\"
            else
              echo \"\${add_out}\" >&2
              exit 1
            fi
          fi
        fi
        ;;
    esac
    # If OpenPE still owns the iface in a netns, it won't show in the host netns.
    deadline=\$((SECONDS + 60))
    while (( SECONDS < deadline )); do
      if ip link show \"\${iface}\" >/dev/null 2>&1; then
        break
      fi
      sleep 2
    done
    if ! ip link show \"\${iface}\" >/dev/null 2>&1; then
      echo \"ERROR: iface \${iface} missing on ${node} host netns (still in OpenPE netns?). Delete Underlay/L2VNI/L3VNI CRs and retry.\" >&2
      ip -br link >&2 || true
      exit 1
    fi
    nmcli device set \"\${iface}\" managed no 2>/dev/null || true
    ip link set \"\${iface}\" up
    # replace any existing IPv4 on this iface (test-owned underlay)
    ip -4 addr flush dev \"\${iface}\" 2>/dev/null || true
    ip -4 addr add \"\${ip}/\${plen}\" dev \"\${iface}\"
    ip -br addr show \"\${iface}\"
  "
  # Mark underlay-capable workers for e2e (sessions / frr_restart scheduling).
  if [[ ! " ${LABELED_NODES[*]} " =~ " ${node} " ]]; then
    oc label node "${node}" e2e.openperouter.io/underlay=true --overwrite
    LABELED_NODES+=("${node}")
  fi
done

echo "=== configure-bastion-worker-net complete ==="
