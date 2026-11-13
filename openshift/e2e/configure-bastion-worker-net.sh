#!/usr/bin/env bash
# Apply underlay IPs on selected worker nodes for bastion e2e.
# Addresses and iface names come from nodelink.json (setup-clab-bastion.sh).
# OPENPE_UNDERLAY_IFACE / OPENPE_UNDERLAY_IFACE2 override nodelink ifaces when set.
#
# Both underlay NICs are required (OPENPE_UNDERLAY_IFACE and OPENPE_UNDERLAY_IFACE2).
#
# IPv4-only. Records ownership in .e2e-bastion-state/worker-net.json from the
# remote operation's actual outcome (CREATED_LINK / ADDED_ADDRESS markers) — never
# from intent. already_present races are not claimed. Each successful add is
# recorded before the next fallible command (link set up / addr confirm), so a
# later failure still leaves teardown able to remove what this run created.
#
# Does not mutate parent iface state (no nmcli / ip link set on parent): the lab
# must provision the parent UP with no IPv4. Conflicting VLAN IPv4 or node labels
# fail before modify.
#
# Underlay must be tagged (parent.VID), e.g. eth1.100 / eth2.200.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODELINK="${SCRIPT_DIR}/nodelink.json"
STATE_DIR="${SCRIPT_DIR}/.e2e-bastion-state"
STATE_FILE="${STATE_DIR}/worker-net.json"
LABEL_KEY="e2e.openperouter.io/underlay"

OPENPE_NS="${OPENPE_E2E_NAMESPACE:-openshift-openperouter}"

if [[ ! -f "${NODELINK}" ]]; then
  echo "ERROR: ${NODELINK} missing — run setup-clab-bastion.sh / deploy-bastion first" >&2
  exit 1
fi

if ! oc get ns "${OPENPE_NS}" >/dev/null 2>&1; then
  echo "ERROR: OpenPE namespace ${OPENPE_NS} not found" >&2
  exit 1
fi

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

# Read-only and mutating helpers. Mutating calls do not fall back after a failed
# oc debug (avoids re-running a partial mutation via nsenter).
node_exec_ro() {
  local node=$1; shift
  if oc debug "node/${node}" --quiet -- chroot /host "$@" ; then
    return 0
  fi
  echo "WARNING: oc debug failed on ${node}; trying controller nsenter (read-only)" >&2
  local pod
  pod=$(oc get pods -n "${OPENPE_NS}" -l app=controller \
    --field-selector "spec.nodeName=${node}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -z "${pod}" ]]; then
    echo "ERROR: no controller on ${node} in ${OPENPE_NS}; cannot probe" >&2
    return 1
  fi
  oc exec -n "${OPENPE_NS}" "${pod}" -- nsenter -t 1 -m -u -i -n "$@"
}

node_exec_rw() {
  local node=$1; shift
  if oc debug "node/${node}" --quiet -- chroot /host "$@" ; then
    return 0
  fi
  echo "ERROR: oc debug failed on ${node} during mutation; not retrying via nsenter (avoids duplicate mutate)" >&2
  return 1
}

write_state() {
  ENTRIES_JSON="${ENTRIES_JSON}" LABELS_JSON="${LABELS_JSON}" \
  UNDERLAY1="${OPENPE_UNDERLAY_IFACE}" UNDERLAY2="${OPENPE_UNDERLAY_IFACE2}" \
  LABEL_KEY="${LABEL_KEY}" STATE_FILE="${STATE_FILE}" python3 - <<'PY'
import json, os
state = {
  "underlayIface": os.environ["UNDERLAY1"],
  "underlayIface2": os.environ["UNDERLAY2"],
  "labelKey": os.environ["LABEL_KEY"],
  "entries": json.loads(os.environ["ENTRIES_JSON"]),
  "labels": json.loads(os.environ["LABELS_JSON"]),
}
with open(os.environ["STATE_FILE"], "w", encoding="utf-8") as f:
    json.dump(state, f, indent=2)
    f.write("\n")
PY
}

append_entry() {
  local node="$1" iface="$2" ip="$3" plen="$4" created="$5" added="$6"
  ENTRIES_JSON="$(
    NODE="${node}" IFACE="${iface}" IP="${ip}" PLEN="${plen}" \
    CREATED="${created}" ADDED="${added}" ENTRIES_JSON="${ENTRIES_JSON}" \
    python3 - <<'PY'
import json, os
entries = json.loads(os.environ["ENTRIES_JSON"])
# Update in place if same node/iface/ip already recorded (partial retry).
key = (os.environ["NODE"], os.environ["IFACE"], os.environ["IP"])
updated = False
for e in entries:
    if (e["node"], e["iface"], e["ip"]) == key:
        e["createdLink"] = e["createdLink"] or (os.environ["CREATED"] == "1")
        e["addedAddress"] = e["addedAddress"] or (os.environ["ADDED"] == "1")
        e["prefix"] = int(os.environ["PLEN"])
        updated = True
        break
if not updated:
    entries.append({
        "node": os.environ["NODE"],
        "iface": os.environ["IFACE"],
        "ip": os.environ["IP"],
        "prefix": int(os.environ["PLEN"]),
        "createdLink": os.environ["CREATED"] == "1",
        "addedAddress": os.environ["ADDED"] == "1",
    })
print(json.dumps(entries))
PY
  )"
  write_state
}

mkdir -p "${STATE_DIR}"
export OPENPE_UNDERLAY_IFACE OPENPE_UNDERLAY_IFACE2

mapfile -t APPLY_LINES < <(python3 - <<PY
import json, os
with open("${NODELINK}") as f:
    cfg = json.load(f)
env1 = os.environ.get("OPENPE_UNDERLAY_IFACE", "").strip()
env2 = os.environ.get("OPENPE_UNDERLAY_IFACE2", "").strip()
for name, nc in cfg.get("nodes", {}).items():
    ip1 = nc.get("ipForKindLeaf", "")
    ip2 = nc.get("ipForKindLeaf2", "")
    if not ip1 or not ip2:
        raise SystemExit(f"nodelink node {name}: requires ipForKindLeaf and ipForKindLeaf2")
    iface1 = env1 or nc.get("ifaceForKindLeaf") or "toswitch1"
    iface2 = env2 or nc.get("ifaceForKindLeaf2") or "toswitch2"
    print(f"{name}|{iface1}|{ip1}|24")
    print(f"{name}|{iface2}|{ip2}|24")
PY
)

if [[ ${#APPLY_LINES[@]} -eq 0 ]]; then
  echo "ERROR: no underlay addresses derived from nodelink.json" >&2
  exit 1
fi

ENTRIES_JSON='[]'
LABELS_JSON='[]'
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

  # --- Probe parent + iface (read-only; fallback allowed) ---
  PROBE_OUT="$(node_exec_ro "${node}" bash -c "
    set -euo pipefail
    parent='${parent}'
    iface='${iface}'
    planned='${planned}'
    if ! ip link show \"\${parent}\" >/dev/null 2>&1; then
      echo \"ERROR: parent iface \${parent} missing on host (for \${iface})\" >&2
      ip -br link >&2 || true
      exit 1
    fi
    # Parent must already be UP — lab provisions this; we do not ip link set parent.
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

  # --- Create VLAN if missing (mutate; no nsenter fallback) ---
  # Split: record after successful ip link add, then bring the link up separately
  # so a failed "ip link set ... up" still leaves createdLink for teardown.
  if [[ "${iface_exists}" -eq 0 ]]; then
    echo "  creating vlan ${iface} on ${parent} id ${vid}"
    VLAN_OUT="$(node_exec_rw "${node}" bash -c "
      set -euo pipefail
      parent='${parent}'
      iface='${iface}'
      vid='${vid}'
      if ip link show \"\${iface}\" >/dev/null 2>&1; then
        # Appeared since probe — pre-existing relative to this run; do not claim ownership.
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
      node_exec_rw "${node}" bash -c "
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

  # --- Add address if missing (mutate; no nsenter fallback) ---
  # Split: record after successful ip addr add, then confirm separately so a
  # failed follow-up query still leaves addedAddress for teardown.
  if [[ "${has_planned}" -eq 0 ]]; then
    echo "  adding ${planned} on ${iface}"
    ADDR_OUT="$(node_exec_rw "${node}" bash -c "
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
        # Present since probe — do not claim we added it.
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
      node_exec_rw "${node}" bash -c "
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

  # --- Node label (once per node): reject conflicting values (incl. empty) ---
  if [[ -z "${LABEL_DONE[${node}]:-}" ]]; then
    NODE_JSON="$(oc get node "${node}" -o json)" || {
      echo "ERROR: failed to get node ${node} for label ${LABEL_KEY}" >&2
      exit 1
    }
    LABEL_META="$(NODE_JSON="${NODE_JSON}" LABEL_KEY="${LABEL_KEY}" python3 - <<'PY'
import json, os, sys
try:
    doc = json.loads(os.environ["NODE_JSON"])
except json.JSONDecodeError as e:
    print(f"ERROR: invalid node json: {e}", file=sys.stderr)
    sys.exit(2)
labels = (doc.get("metadata") or {}).get("labels") or {}
key = os.environ["LABEL_KEY"]
if key not in labels:
    print("PRESENT=0")
    print("VALUE=")
else:
    # Distinguish missing key from present-but-empty value.
    print("PRESENT=1")
    print(f"VALUE={labels[key]}")
PY
)" || {
      echo "ERROR: failed to read label ${LABEL_KEY} from node ${node}" >&2
      exit 1
    }
    label_present="$(printf '%s\n' "${LABEL_META}" | awk -F= '/^PRESENT=/ {print $2; exit}')"
    prior_label="$(printf '%s\n' "${LABEL_META}" | awk -F= '/^VALUE=/ {sub(/^VALUE=/,""); print; exit}')"
    label_present="${label_present:-0}"

    if [[ "${label_present}" -eq 0 ]]; then
      oc label node "${node}" "${LABEL_KEY}=true"
      LABELS_JSON="$(LABELS_JSON="${LABELS_JSON}" NODE="${node}" python3 - <<'PY'
import json, os
labels = json.loads(os.environ["LABELS_JSON"])
labels.append({"node": os.environ["NODE"], "labeledByUs": True, "priorValue": None})
print(json.dumps(labels))
PY
)"
      write_state
    elif [[ "${prior_label}" == "true" ]]; then
      echo "  node ${node}: label ${LABEL_KEY}=true already present"
      LABELS_JSON="$(LABELS_JSON="${LABELS_JSON}" NODE="${node}" python3 - <<'PY'
import json, os
labels = json.loads(os.environ["LABELS_JSON"])
labels.append({"node": os.environ["NODE"], "labeledByUs": False, "priorValue": "true"})
print(json.dumps(labels))
PY
)"
      write_state
    else
      echo "ERROR: node ${node} has conflicting label ${LABEL_KEY}='${prior_label}' (want true); refusing to overwrite" >&2
      exit 1
    fi
    LABEL_DONE["${node}"]=1
  fi
done

echo "=== configure-bastion-worker-net complete ==="
