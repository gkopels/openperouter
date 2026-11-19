#!/usr/bin/env bash
# Remove underlay changes applied by configure-bastion-worker-net.sh.
#
# Env:
#   OPENPE_E2E_TEARDOWN_WORKER_NET — only the literal string "false" skips
#     (default: tear down). Any other value runs teardown.
#   OPENPE_E2E_WORKER_NET_IFACE_WAIT_SECS — seconds to wait for the NIC to
#     return to the host netns after Underlay CR cleanup (default: 60).
#   OPENPE_E2E_WORKER_NET_DEBUG_TIMEOUT — timeout(1) for oc debug (default: 120s).
#   KUBECONFIG — required for oc (normally set by e2e-bastion / caller).
#
# Ownership-aware: removes only addresses / vlan links / labels this run added
# (see worker-net.state createdLink / addedAddress / labeledByUs). No blanket
# IPv4 flush. Pre-existing VLANs and unrelated addresses are left alone.
#
# State: .e2e-bastion-state/worker-net.state (line-oriented). Kept on failure.
# Also accepts legacy worker-net.json only to print a clear migrate error.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${SCRIPT_DIR}/.e2e-bastion-state"
STATE_FILE="${STATE_DIR}/worker-net.state"
LEGACY_JSON="${STATE_DIR}/worker-net.json"
HOST_REMOVE="${SCRIPT_DIR}/remove-underlay-vlan-on-host.sh"

TEARDOWN="${OPENPE_E2E_TEARDOWN_WORKER_NET:-true}"
IFACE_WAIT_SECS="${OPENPE_E2E_WORKER_NET_IFACE_WAIT_SECS:-60}"

echo "=== teardown-bastion-worker-net ==="
echo "  OPENPE_E2E_TEARDOWN_WORKER_NET=${TEARDOWN}"

if [[ "${TEARDOWN}" == "false" ]]; then
  echo "Skipping worker underlay IP teardown"
  exit 0
fi

if [[ ! -f "${STATE_FILE}" ]]; then
  if [[ -f "${LEGACY_JSON}" ]]; then
    echo "ERROR: found legacy ${LEGACY_JSON}; re-run configure-bastion-worker-net.sh to refresh state as worker-net.state" >&2
    exit 1
  fi
  echo "No state at ${STATE_FILE}; nothing to remove"
  exit 0
fi

if [[ ! -f "${HOST_REMOVE}" ]]; then
  echo "ERROR: missing host script ${HOST_REMOVE}" >&2
  exit 1
fi

# shellcheck source=./bastion-run-host-script.sh
source "${SCRIPT_DIR}/bastion-run-host-script.sh"

mapfile -t FLUSH_LINES < "${STATE_FILE}"
if [[ ${#FLUSH_LINES[@]} -eq 0 ]]; then
  echo "ERROR: ${STATE_FILE} is empty — keeping file" >&2
  exit 1
fi

FAILED=0
HAVE_WORK=0
for line in "${FLUSH_LINES[@]}"; do
  [[ -z "${line}" || "${line}" == \#* ]] && continue
  IFS='|' read -r kind rest <<<"${line}"
  case "${kind}" in
    meta)
      continue
      ;;
    addr)
      IFS='|' read -r node iface ip plen created_link added_address <<<"${rest}"
      HAVE_WORK=1
      echo "  addr ${node}: ${iface} ${ip}/${plen} (createdLink=${created_link} addedAddress=${added_address})"
      if [[ "${added_address}" != "1" && "${created_link}" != "1" ]]; then
        echo "  skip ${node}/${iface}: nothing owned by this run"
        continue
      fi
      if ! run_host_script "${node}" "${HOST_REMOVE}" \
        "${iface}" "${ip}" "${plen}" "${created_link}" "${added_address}" "${IFACE_WAIT_SECS}"; then
        echo "ERROR: teardown failed on ${node}/${iface}" >&2
        FAILED=1
      fi
      ;;
    label)
      IFS='|' read -r node label_key owned prior <<<"${rest}"
      HAVE_WORK=1
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

if [[ "${HAVE_WORK}" -eq 0 ]]; then
  echo "ERROR: ${STATE_FILE} has no addr/label entries — keeping file" >&2
  exit 1
fi

if [[ "${FAILED}" -eq 0 ]]; then
  rm -f "${STATE_FILE}"
  echo "=== teardown-bastion-worker-net complete ==="
else
  echo "ERROR: worker underlay teardown incomplete; state kept at ${STATE_FILE}" >&2
  exit 1
fi
