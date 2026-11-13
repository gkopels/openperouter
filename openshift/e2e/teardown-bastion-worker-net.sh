#!/usr/bin/env bash
# Remove underlay changes applied by configure-bastion-worker-net.sh.
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
# Ownership-aware: removes only addresses / vlan links / labels this run added
# (see worker-net.json createdLink / addedAddress / labeledByUs). No blanket
# IPv4 flush. Pre-existing VLANs and unrelated addresses are left alone.
#
# State: .e2e-bastion-state/worker-net.json. Kept on failure for retry.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${SCRIPT_DIR}/.e2e-bastion-state"
STATE_FILE="${STATE_DIR}/worker-net.json"

OPENPE_NS="${OPENPE_E2E_NAMESPACE:-openshift-openperouter}"
TEARDOWN="${OPENPE_E2E_TEARDOWN_WORKER_NET:-true}"
IFACE_WAIT_SECS="${OPENPE_E2E_WORKER_NET_IFACE_WAIT_SECS:-60}"
DEBUG_TIMEOUT="${OPENPE_E2E_WORKER_NET_DEBUG_TIMEOUT:-120s}"
LABEL_KEY_DEFAULT="e2e.openperouter.io/underlay"

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
label_key = cfg.get("labelKey") or "${LABEL_KEY_DEFAULT}"
labels = cfg.get("labels") or []
if not entries and not labels:
    sys.exit(2)
for e in entries:
    created = "1" if e.get("createdLink") else "0"
    added = "1" if e.get("addedAddress") else "0"
    print(f"addr|{e['node']}|{e['iface']}|{e['ip']}|{e.get('prefix', 24)}|{created}|{added}")
for lab in labels:
    owned = "1" if lab.get("labeledByUs") else "0"
    prior = lab.get("priorValue")
    prior_s = "" if prior is None else str(prior)
    print(f"label|{lab['node']}|{label_key}|{owned}|{prior_s}")
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
  echo "ERROR: ${STATE_FILE} produced no teardown lines — keeping file" >&2
  exit 1
fi

FAILED=0
for line in "${FLUSH_LINES[@]}"; do
  IFS='|' read -r kind rest <<<"${line}"
  case "${kind}" in
    addr)
      IFS='|' read -r node iface ip plen created_link added_address <<<"${rest}"
      echo "  addr ${node}: ${iface} ${ip}/${plen} (createdLink=${created_link} addedAddress=${added_address})"
      if [[ "${added_address}" != "1" && "${created_link}" != "1" ]]; then
        echo "  skip ${node}/${iface}: nothing owned by this run"
        continue
      fi
      if ! node_exec "${node}" bash -c "
        set -e
        iface='${iface}'
        ip='${ip}'
        plen='${plen}'
        created_link='${created_link}'
        added_address='${added_address}'
        planned=\"\${ip}/\${plen}\"
        deadline=\$((SECONDS + ${IFACE_WAIT_SECS}))
        while (( SECONDS < deadline )); do
          if ip link show \"\${iface}\" >/dev/null 2>&1; then
            break
          fi
          sleep 2
        done
        if ! ip link show \"\${iface}\" >/dev/null 2>&1; then
          echo \"  \${iface} already absent on host; skipping\"
          exit 0
        fi
        if [[ \"\${added_address}\" == \"1\" ]]; then
          if ip -4 -o addr show dev \"\${iface}\" | awk '{print \$4}' | grep -qxF \"\${planned}\"; then
            ip -4 addr del \"\${planned}\" dev \"\${iface}\"
          fi
          if ip -4 -o addr show dev \"\${iface}\" | awk '{print \$4}' | grep -qxF \"\${planned}\"; then
            echo \"ERROR: \${planned} still present on \${iface}\" >&2
            exit 1
          fi
        fi
        if [[ \"\${created_link}\" == \"1\" ]]; then
          echo \"  removing vlan link \${iface} (created by this run)\"
          ip link del \"\${iface}\"
          if ip link show \"\${iface}\" >/dev/null 2>&1; then
            echo \"ERROR: \${iface} still present after ip link del\" >&2
            exit 1
          fi
        else
          ip -br addr show \"\${iface}\" 2>/dev/null || true
        fi
      "; then
        echo "ERROR: teardown failed on ${node}/${iface}" >&2
        FAILED=1
      fi
      ;;
    label)
      IFS='|' read -r node label_key owned prior <<<"${rest}"
      if [[ "${owned}" != "1" ]]; then
        echo "  label ${node}: ${label_key} pre-existed; leaving"
        continue
      fi
      echo "  label ${node}: remove ${label_key} (added by this run)"
      if ! oc label node "${node}" "${label_key}-" 2>/dev/null; then
        echo "ERROR: failed to remove label ${label_key} from ${node}" >&2
        FAILED=1
      fi
      ;;
    *)
      echo "ERROR: unknown state line: ${line}" >&2
      FAILED=1
      ;;
  esac
done

if [[ "${FAILED}" -eq 0 ]]; then
  rm -f "${STATE_FILE}"
  echo "=== teardown-bastion-worker-net complete ==="
else
  echo "ERROR: worker underlay teardown incomplete; state kept at ${STATE_FILE}" >&2
  exit 1
fi
