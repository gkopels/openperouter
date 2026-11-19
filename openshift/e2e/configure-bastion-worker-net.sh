#!/usr/bin/env bash
# Apply underlay IPs on selected worker nodes for bastion e2e.
# Addresses come from nodelink.json; ifaces from OPENPE_UNDERLAY_IFACE{,2}.
#
# Both underlay NICs are required (tagged parent.VID, e.g. ens1f0.173).
#
# Idempotency is clean + create: delete the VLAN if present, recreate it, add
# the planned IPv4. Parent NICs are never mutated (must be UP, unmanaged, no IPv4).
#
# Ownership is recorded in .e2e-bastion-state/worker-net.state (line-oriented).
# After a successful apply we always own the VLAN + address (createdLink=1,
# addedAddress=1) so teardown can remove them.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODELINK="${SCRIPT_DIR}/nodelink.json"
STATE_DIR="${SCRIPT_DIR}/.e2e-bastion-state"
STATE_FILE="${STATE_DIR}/worker-net.state"
HOST_APPLY="${SCRIPT_DIR}/apply-underlay-vlan-on-host.sh"
LABEL_KEY="e2e.openperouter.io/underlay"

if [[ ! -f "${NODELINK}" ]]; then
  echo "ERROR: ${NODELINK} missing — run setup-clab-bastion.sh / deploy-bastion first" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required to read nodelink.json" >&2
  exit 1
fi

if ! oc get ns openshift-openperouter >/dev/null 2>&1; then
  echo "ERROR: OpenPE namespace openshift-openperouter not found" >&2
  exit 1
fi

if [[ -z "${OPENPE_UNDERLAY_IFACE:-}" || -z "${OPENPE_UNDERLAY_IFACE2:-}" ]]; then
  echo "ERROR: bastion requires OPENPE_UNDERLAY_IFACE and OPENPE_UNDERLAY_IFACE2" >&2
  echo "  e.g. ens1f0.177 and ens1f1.178 — setup-clab does not rename worker NICs" >&2
  exit 1
fi

if [[ ! -f "${HOST_APPLY}" ]]; then
  echo "ERROR: missing host script ${HOST_APPLY}" >&2
  exit 1
fi

echo "=== configure-bastion-worker-net ==="
echo "  namespace=openshift-openperouter"
echo "  nodelink=${NODELINK}"
echo "  OPENPE_UNDERLAY_IFACE=${OPENPE_UNDERLAY_IFACE}"
echo "  OPENPE_UNDERLAY_IFACE2=${OPENPE_UNDERLAY_IFACE2}"

# shellcheck source=./bastion-run-host-script.sh
source "${SCRIPT_DIR}/bastion-run-host-script.sh"

# Line-oriented state (no JSON / no Python):
#   meta|<labelKey>|<iface1>|<iface2>
#   addr|<node>|<iface>|<ip>|<plen>|<createdLink 0|1>|<addedAddress 0|1>
#   label|<node>|<labelKey>|<labeledByUs 0|1>|<priorValue or ->
STATE_ADDRS=()
STATE_LABELS=()

write_state() {
  {
    echo "meta|${LABEL_KEY}|${OPENPE_UNDERLAY_IFACE}|${OPENPE_UNDERLAY_IFACE2}"
    local line
    for line in "${STATE_ADDRS[@]+"${STATE_ADDRS[@]}"}"; do
      echo "addr|${line}"
    done
    for line in "${STATE_LABELS[@]+"${STATE_LABELS[@]}"}"; do
      echo "label|${line}"
    done
  } >"${STATE_FILE}"
}

# Update or append one addr ownership line, then rewrite state.
append_entry() {
  local node="$1" iface="$2" ip="$3" plen="$4" created="$5" added="$6"
  local i e_node e_iface e_ip e_plen e_created e_added updated=0
  if ((${#STATE_ADDRS[@]})); then
    for i in "${!STATE_ADDRS[@]}"; do
      IFS='|' read -r e_node e_iface e_ip e_plen e_created e_added <<<"${STATE_ADDRS[$i]}"
      if [[ "${e_node}" == "${node}" && "${e_iface}" == "${iface}" && "${e_ip}" == "${ip}" ]]; then
        [[ "${e_created}" == "1" || "${created}" == "1" ]] && e_created=1 || e_created=0
        [[ "${e_added}" == "1" || "${added}" == "1" ]] && e_added=1 || e_added=0
        STATE_ADDRS[$i]="${e_node}|${e_iface}|${e_ip}|${plen}|${e_created}|${e_added}"
        updated=1
        break
      fi
    done
  fi
  if [[ "${updated}" -eq 0 ]]; then
    STATE_ADDRS+=("${node}|${iface}|${ip}|${plen}|${created}|${added}")
  fi
  write_state
}

# iface must be parent.VID (e.g. ens1f0.177). Prints "parent vid" on stdout.
parse_vlan_iface() {
  local iface="$1"
  case "${iface}" in
    *.[0-9]*)
      printf '%s %s\n' "${iface%.*}" "${iface##*.}"
      ;;
    *)
      echo "ERROR: underlay iface ${iface} must be parent.VID (vlan)" >&2
      return 1
      ;;
  esac
}

# Clean + create via apply-underlay-vlan-on-host.sh on the node.
# Always owns the result (createdLink=1, addedAddress=1).
apply_underlay_clean_create() {
  local node="$1" iface="$2" ip="$3" plen="$4"
  local parent="" vid="" planned="${ip}/${plen}"

  read -r parent vid < <(parse_vlan_iface "${iface}")

  echo "  ${node}: clean+create ${iface}=${planned} (parent ${parent} vid ${vid})"
  run_host_script "${node}" "${HOST_APPLY}" "${parent}" "${iface}" "${vid}" "${planned}"
  append_entry "${node}" "${iface}" "${ip}" "${plen}" 1 1
}

# Always set (overwrite) the underlay label; we own removal on teardown.
ensure_underlay_label() {
  local node="$1"
  echo "  ${node}: label ${LABEL_KEY}=true"
  oc label node "${node}" "${LABEL_KEY}=true" --overwrite
  STATE_LABELS+=("${node}|${LABEL_KEY}|1|-")
  write_state
}

mkdir -p "${STATE_DIR}"

mapfile -t APPLY_LINES < <(
  jq -r \
    --arg i1 "${OPENPE_UNDERLAY_IFACE}" \
    --arg i2 "${OPENPE_UNDERLAY_IFACE2}" \
    '
    .nodes | to_entries[] |
    .key as $name |
    .value as $nc |
    ($nc.ipForKindLeaf // "") as $ip1 |
    ($nc.ipForKindLeaf2 // "") as $ip2 |
    if ($ip1 == "" or $ip2 == "") then
      error("nodelink node \($name): requires ipForKindLeaf and ipForKindLeaf2")
    else
      "\($name)|\($i1)|\($ip1)|24",
      "\($name)|\($i2)|\($ip2)|24"
    end
    ' "${NODELINK}"
)

if [[ ${#APPLY_LINES[@]} -eq 0 ]]; then
  echo "ERROR: no underlay addresses derived from nodelink.json" >&2
  exit 1
fi

write_state
echo "Initialized ${STATE_FILE}"

declare -A LABEL_DONE=()

for line in "${APPLY_LINES[@]}"; do
  IFS='|' read -r node iface ip plen <<<"${line}"
  apply_underlay_clean_create "${node}" "${iface}" "${ip}" "${plen}"
  if [[ -z "${LABEL_DONE[${node}]:-}" ]]; then
    ensure_underlay_label "${node}"
    LABEL_DONE["${node}"]=1
  fi
done

echo "=== configure-bastion-worker-net complete ==="
