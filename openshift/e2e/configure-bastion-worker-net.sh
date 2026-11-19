#!/usr/bin/env bash
# Apply underlay IPs on selected worker nodes for bastion e2e.
# Addresses come from nodelink.json; ifaces from OPENPE_UNDERLAY_IFACE{,2}.
#
# Both underlay NICs are required (tagged parent.VID, e.g. ens1f0.173).
#
# IPv4-only. Records ownership in .e2e-bastion-state/worker-net.state (line-oriented,
# bash-native — no embedded Python). Markers createdLink / addedAddress come from
# the remote operation's outcome, never from intent.
#
# Does not mutate parent iface state: lab must provision parent UP with no IPv4.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODELINK="${SCRIPT_DIR}/nodelink.json"
STATE_DIR="${SCRIPT_DIR}/.e2e-bastion-state"
STATE_FILE="${STATE_DIR}/worker-net.state"
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

echo "=== configure-bastion-worker-net ==="
echo "  namespace=openshift-openperouter"
echo "  nodelink=${NODELINK}"
echo "  OPENPE_UNDERLAY_IFACE=${OPENPE_UNDERLAY_IFACE}"
echo "  OPENPE_UNDERLAY_IFACE2=${OPENPE_UNDERLAY_IFACE2}"

# Host access via oc debug only.
node_exec() {
  local node=$1; shift
  oc debug "node/${node}" --quiet -- chroot /host "$@"
}

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
  echo "  ${node}: ${iface}=${ip}/${plen}"
  planned="${ip}/${plen}"
  created_link=0
  added_address=0

  parent=""
  vid=""
  case "${iface}" in
    *.[0-9]*)
      parent="${iface%.*}"
      vid="${iface##*.}"
      ;;
    *)
      echo "ERROR: underlay iface ${iface} must be parent.VID (vlan)" >&2
      exit 1
      ;;
  esac

  PROBE_OUT="$(node_exec "${node}" bash -c "
    set -euo pipefail
    parent='${parent}'
    iface='${iface}'
    planned='${planned}'
    if ! ip link show \"\${parent}\" >/dev/null 2>&1; then
      echo \"ERROR: parent iface \${parent} missing on host (for \${iface})\" >&2
      ip -br link >&2 || true
      exit 1
    fi
    if ! ip -o link show \"\${parent}\" | grep -Eq 'state UP|<[^>]*[,<]UP[,>]'; then
      echo \"ERROR: parent \${parent} is not UP; provision parent state before bastion e2e\" >&2
      ip -br link show \"\${parent}\" >&2 || true
      exit 1
    fi
    parent_addrs=\$(ip -4 -o addr show dev \"\${parent}\" 2>/dev/null | awk '{print \$4}' | paste -sd, - || true)
    if [[ -n \"\${parent_addrs}\" ]]; then
      echo \"ERROR: parent \${parent} has IPv4 [\${parent_addrs}]; refusing to modify\" >&2
      exit 1
    fi
    if command -v nmcli >/dev/null 2>&1; then
      nm_state=\$(nmcli -t -f DEVICE,STATE device status 2>/dev/null | awk -F: -v d=\"\${parent}\" '\$1==d {print \$2; exit}')
      if [[ -n \"\${nm_state}\" && \"\${nm_state}\" != \"unmanaged\" ]]; then
        echo \"ERROR: parent \${parent} NM state is '\${nm_state}' (want unmanaged); fix in the lab before bastion e2e\" >&2
        exit 1
      fi
    fi
    iface_exists=0
    if ip link show \"\${iface}\" >/dev/null 2>&1; then
      iface_exists=1
    fi
    extras=\"\"
    has_planned=0
    if [[ \"\${iface_exists}\" -eq 1 ]]; then
      while read -r a; do
        [[ -z \"\${a}\" ]] && continue
        if [[ \"\${a}\" == \"\${planned}\" ]]; then
          has_planned=1
        else
          extras=\"\${extras},\${a}\"
        fi
      done < <(ip -4 -o addr show dev \"\${iface}\" 2>/dev/null | awk '{print \$4}')
      extras=\"\${extras#,}\"
      if [[ -n \"\${extras}\" ]]; then
        echo \"ERROR: \${iface} has conflicting IPv4 [\${extras}]; planned \${planned}. Refusing to modify.\" >&2
        exit 1
      fi
    fi
    echo \"IFACE_EXISTS=\${iface_exists}\"
    echo \"HAS_PLANNED=\${has_planned}\"
  ")"

  iface_exists="$(printf '%s\n' "${PROBE_OUT}" | awk -F= '/^IFACE_EXISTS=/ {print $2; exit}')"
  has_planned="$(printf '%s\n' "${PROBE_OUT}" | awk -F= '/^HAS_PLANNED=/ {print $2; exit}')"
  iface_exists="${iface_exists:-0}"
  has_planned="${has_planned:-0}"
  printf '%s\n' "${PROBE_OUT}" | grep -vE '^(IFACE_EXISTS|HAS_PLANNED)=' || true

  if [[ "${iface_exists}" -eq 0 ]]; then
    echo "  creating vlan ${iface} on ${parent} id ${vid}"
    VLAN_OUT="$(node_exec "${node}" bash -c "
      set -euo pipefail
      parent='${parent}'
      iface='${iface}'
      vid='${vid}'
      if ip link show \"\${iface}\" >/dev/null 2>&1; then
        echo \"CREATED_LINK=0\"
        echo \"OUTCOME=already_present\"
        exit 0
      fi
      ip link add link \"\${parent}\" name \"\${iface}\" type vlan id \"\${vid}\"
      echo \"CREATED_LINK=1\"
      echo \"OUTCOME=created\"
    ")"
    created_link="$(printf '%s\n' "${VLAN_OUT}" | awk -F= '/^CREATED_LINK=/ {print $2; exit}')"
    created_link="${created_link:-0}"
    printf '%s\n' "${VLAN_OUT}" | grep -vE '^(CREATED_LINK|OUTCOME)=' || true
    append_entry "${node}" "${iface}" "${ip}" "${plen}" "${created_link}" 0
    if [[ "${created_link}" -eq 1 ]]; then
      echo "  bringing up vlan ${iface}"
      node_exec "${node}" bash -c "
        set -euo pipefail
        iface='${iface}'
        ip link set \"\${iface}\" up
        if ! ip link show \"\${iface}\" >/dev/null 2>&1; then
          echo \"ERROR: vlan \${iface} missing after create\" >&2
          exit 1
        fi
      "
    fi
  else
    append_entry "${node}" "${iface}" "${ip}" "${plen}" 0 0
  fi

  if [[ "${has_planned}" -eq 0 ]]; then
    echo "  adding ${planned} on ${iface}"
    ADDR_OUT="$(node_exec "${node}" bash -c "
      set -euo pipefail
      iface='${iface}'
      planned='${planned}'
      deadline=\$((SECONDS + 60))
      while (( SECONDS < deadline )); do
        if ip link show \"\${iface}\" >/dev/null 2>&1; then
          break
        fi
        sleep 2
      done
      if ! ip link show \"\${iface}\" >/dev/null 2>&1; then
        echo \"ERROR: iface \${iface} missing on host netns\" >&2
        exit 1
      fi
      if ip -4 -o addr show dev \"\${iface}\" | awk '{print \$4}' | grep -qxF \"\${planned}\"; then
        echo \"ADDED_ADDRESS=0\"
        echo \"OUTCOME=already_present\"
        exit 0
      fi
      extras=\$(ip -4 -o addr show dev \"\${iface}\" | awk '{print \$4}' | grep -vxF \"\${planned}\" | paste -sd, - || true)
      if [[ -n \"\${extras}\" ]]; then
        echo \"ERROR: \${iface} has conflicting IPv4 [\${extras}]\" >&2
        exit 1
      fi
      ip link set \"\${iface}\" up
      ip -4 addr add \"\${planned}\" dev \"\${iface}\"
      echo \"ADDED_ADDRESS=1\"
      echo \"OUTCOME=added\"
    ")"
    added_address="$(printf '%s\n' "${ADDR_OUT}" | awk -F= '/^ADDED_ADDRESS=/ {print $2; exit}')"
    added_address="${added_address:-0}"
    printf '%s\n' "${ADDR_OUT}" | grep -vE '^(ADDED_ADDRESS|OUTCOME)=' || true
    append_entry "${node}" "${iface}" "${ip}" "${plen}" "${created_link}" "${added_address}"
    if [[ "${added_address}" -eq 1 ]]; then
      echo "  confirming ${planned} on ${iface}"
      node_exec "${node}" bash -c "
        set -euo pipefail
        iface='${iface}'
        planned='${planned}'
        if ! ip -4 -o addr show dev \"\${iface}\" | awk '{print \$4}' | grep -qxF \"\${planned}\"; then
          echo \"ERROR: \${planned} missing on \${iface} after addr add\" >&2
          exit 1
        fi
        ip -br addr show \"\${iface}\" 2>/dev/null || true
      "
    fi
  else
    echo "  ${planned} already present on ${iface}; leaving in place"
    append_entry "${node}" "${iface}" "${ip}" "${plen}" "${created_link}" 0
  fi

  if [[ -z "${LABEL_DONE[${node}]:-}" ]]; then
    label_present="$(oc get node "${node}" -o go-template='{{if index .metadata.labels "'"${LABEL_KEY}"'"}}1{{else}}0{{end}}')"
    prior_label="$(oc get node "${node}" -o go-template='{{index .metadata.labels "'"${LABEL_KEY}"'"}}')"
    label_present="${label_present:-0}"

    if [[ "${label_present}" -eq 0 ]]; then
      oc label node "${node}" "${LABEL_KEY}=true"
      STATE_LABELS+=("${node}|${LABEL_KEY}|1|-")
      write_state
    elif [[ "${prior_label}" == "true" ]]; then
      echo "  node ${node}: label ${LABEL_KEY}=true already present"
      STATE_LABELS+=("${node}|${LABEL_KEY}|0|true")
      write_state
    else
      echo "ERROR: node ${node} has conflicting label ${LABEL_KEY}='${prior_label}' (want true); refusing to overwrite" >&2
      exit 1
    fi
    LABEL_DONE["${node}"]=1
  fi
done

echo "=== configure-bastion-worker-net complete ==="
