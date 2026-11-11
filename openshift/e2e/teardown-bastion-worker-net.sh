#!/usr/bin/env bash
# Remove underlay IPs applied by configure-bastion-worker-net.sh.
#
# Env:
#   OPENPE_E2E_TEARDOWN_WORKER_NET — only the literal string "false" skips
#     (default: tear down). Any other value runs teardown.
#   OPENPE_E2E_WORKER_NET_IFACE_WAIT_SECS — seconds to wait for the NIC to
#     return to the host netns after Underlay CR cleanup (default: 60).
#   OPENPE_E2E_WORKER_NET_DEBUG_TIMEOUT — timeout(1) for oc debug (default: 120s).
#   OPENPE_E2E_NAMESPACE — OpenPE NS for controller nsenter fallback.
#   KUBECONFIG — required for oc (normally set by e2e-bastion / caller).
#
# Address removal: deletes the planned IPv4 (${ip}/${prefix}) via `ip -4 addr del`.
# For vlan underlay ifaces (parent.VID / entries.deleteLink), also `ip link del`
# the subinterface after the address is gone.
# configure still flushes IPv4 before add so the test owns that address on apply.
#
# State: .e2e-bastion-state/worker-net.json. On any flush failure the file is
# kept so EXIT / a manual re-run can retry. Removed only when every entry succeeds.
# Empty or missing entries → warn, keep file, exit 1.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${SCRIPT_DIR}/.e2e-bastion-state"
STATE_FILE="${STATE_DIR}/worker-net.json"

OPENPE_NS="${OPENPE_E2E_NAMESPACE:-openshift-openperouter}"
TEARDOWN="${OPENPE_E2E_TEARDOWN_WORKER_NET:-true}"
# Underlay CR teardown can leave the NIC in a netns briefly; wait for host.
IFACE_WAIT_SECS="${OPENPE_E2E_WORKER_NET_IFACE_WAIT_SECS:-60}"
DEBUG_TIMEOUT="${OPENPE_E2E_WORKER_NET_DEBUG_TIMEOUT:-120s}"

echo "=== teardown-bastion-worker-net ==="
echo "  OPENPE_E2E_TEARDOWN_WORKER_NET=${TEARDOWN}"

if [[ "${TEARDOWN}" == "false" ]]; then
  echo "Skipping worker underlay IP teardown"
  exit 0
fi

if [[ ! -f "${STATE_FILE}" ]]; then
  echo "No state at ${STATE_FILE}; nothing to remove"
  exit 0
fi

# Prefer oc debug/chroot: controller nsenter can fail after tests while || true
# hid the error and left underlay IPs on the workers. Verify address is gone.
# Right after Ginkgo, the NIC may still be in the OpenPE netns ("does not exist"
# on the host) — wait for it to return before deleting the planned address.
node_exec() {
  local node=$1; shift
  if timeout "${DEBUG_TIMEOUT}" oc debug "node/${node}" --quiet -- chroot /host "$@" ; then
    return 0
  fi
  echo "WARNING: oc debug failed on ${node}; trying controller nsenter" >&2
  local pod
  pod=$(oc get pods -n "${OPENPE_NS}" -l app=controller \
    --field-selector "spec.nodeName=${node}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -z "${pod}" ]]; then
    echo "ERROR: no controller on ${node} in ${OPENPE_NS}; cannot remove underlay IP" >&2
    return 1
  fi
  oc exec -n "${OPENPE_NS}" "${pod}" -- nsenter -t 1 -m -u -i -n "$@"
}

set +e
FLUSH_TXT="$(python3 - <<PY
import json, sys
with open("${STATE_FILE}") as f:
    cfg = json.load(f)
entries = cfg.get("entries") or []
if not entries:
    sys.exit(2)
def is_vlan_iface(name: str) -> bool:
    if "." not in name:
        return False
    parent, _, vid = name.rpartition(".")
    return bool(parent) and vid.isdigit()

for e in entries:
    delete_link = e.get("deleteLink")
    if delete_link is None:
        delete_link = is_vlan_iface(e["iface"])
    flag = "1" if delete_link else "0"
    print(f"{e['node']}|{e['iface']}|{e['ip']}|{e.get('prefix', 24)}|{flag}")
PY
)"
PARSE_RC=$?
set -e
if [[ "${PARSE_RC}" -eq 2 ]]; then
  echo "ERROR: ${STATE_FILE} has no entries — keeping file for inspection" >&2
  exit 1
fi
if [[ "${PARSE_RC}" -ne 0 ]]; then
  echo "ERROR: failed to parse ${STATE_FILE}" >&2
  exit 1
fi
mapfile -t FLUSH_LINES <<<"${FLUSH_TXT}"
if [[ ${#FLUSH_LINES[@]} -eq 0 || -z "${FLUSH_LINES[0]:-}" ]]; then
  echo "ERROR: ${STATE_FILE} produced no flush lines — keeping file" >&2
  exit 1
fi

FAILED=0
UNLABEL_NODES=()
for line in "${FLUSH_LINES[@]}"; do
  IFS='|' read -r node iface ip plen delete_link <<<"${line}"
  echo "  del ${node}: ${iface} ${ip}/${plen} (deleteLink=${delete_link:-0})"
  if [[ ! " ${UNLABEL_NODES[*]} " =~ " ${node} " ]]; then
    UNLABEL_NODES+=("${node}")
  fi
  if ! node_exec "${node}" bash -c "
    set -e
    iface='${iface}'
    ip='${ip}'
    plen='${plen}'
    delete_link='${delete_link:-0}'
    deadline=\$((SECONDS + ${IFACE_WAIT_SECS}))
    while (( SECONDS < deadline )); do
      if ip link show \"\${iface}\" >/dev/null 2>&1; then
        break
      fi
      sleep 2
    done
    if ! ip link show \"\${iface}\" >/dev/null 2>&1; then
      # Already gone (e.g. prior teardown deleted the vlan link) — OK.
      echo \"  \${iface} already absent on host; skipping\"
      exit 0
    fi
    # Delete only the planned address (not ip -4 addr flush on the whole iface).
    if ip -4 -o addr show dev \"\${iface}\" | awk '{print \$4}' | grep -qxF \"\${ip}/\${plen}\"; then
      ip -4 addr del \"\${ip}/\${plen}\" dev \"\${iface}\"
    fi
    if ip -4 -o addr show dev \"\${iface}\" | awk '{print \$4}' | grep -qxF \"\${ip}/\${plen}\"; then
      echo \"ERROR: \${ip}/\${plen} still present on \${iface}\" >&2
      exit 1
    fi
    if [[ \"\${delete_link}\" == \"1\" ]]; then
      echo \"  removing vlan link \${iface}\"
      ip link del \"\${iface}\"
      if ip link show \"\${iface}\" >/dev/null 2>&1; then
        echo \"ERROR: \${iface} still present after ip link del\" >&2
        exit 1
      fi
    else
      ip -br addr show \"\${iface}\"
    fi
  "; then
    echo "ERROR: teardown failed on ${node}/${iface}" >&2
    FAILED=1
  fi
done

for node in "${UNLABEL_NODES[@]}"; do
  oc label node "${node}" e2e.openperouter.io/underlay- 2>/dev/null || true
done

if [[ "${FAILED}" -eq 0 ]]; then
  rm -f "${STATE_FILE}"
  echo "=== teardown-bastion-worker-net complete ==="
else
  echo "ERROR: worker underlay teardown incomplete; state kept at ${STATE_FILE}" >&2
  exit 1
fi
