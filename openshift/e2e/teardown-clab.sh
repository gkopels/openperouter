#!/usr/bin/env bash
# Tear down the OpenPE ocp.clab fabric on this host.
#
# Safe for bastion:
#   - Does NOT remove toswitch* bridges or touch eth0/mgmt (bridges stay for reuse)
#   - Removes .setup-*.log from setup-clab.sh (bastion quiet path)
# Works around containerlab+podman destroy SEGV by falling back to runtime rm.
# If clab/containerlab is missing, still attempts runtime-only leftover cleanup.
#
# Requires: passwordless sudo (sudo -n).
#
# Usage:
#   export OPENPE_E2E_PROVIDER=bastion CLAB_RUNTIME=podman   # optional; defaults apply
#   ./openshift/e2e/teardown-clab.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOPO="${SCRIPT_DIR}/ocp.clab.yml"
PROVIDER="${OPENPE_E2E_PROVIDER:-dev-scripts}"
MGMT_IFACE="${CLAB_BASTION_MGMT_IFACE:-eth0}"

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

CLAB_BIN=""
if command -v clab >/dev/null 2>&1; then
  CLAB_BIN=clab
elif command -v containerlab >/dev/null 2>&1; then
  CLAB_BIN=containerlab
fi

assert_mgmt_default() {
  if [[ "${PROVIDER}" != "bastion" ]]; then
    return 0
  fi
  local def
  def="$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}')"
  if [[ -z "${def}" ]]; then
    echo "ERROR: no default route (expected via ${MGMT_IFACE})" >&2
    return 1
  fi
  if [[ "${def}" != "${MGMT_IFACE}" ]]; then
    echo "ERROR: default route on ${def}, expected ${MGMT_IFACE} (SSH/mgmt broken risk)" >&2
    return 1
  fi
  echo "OK: default route still on ${MGMT_IFACE}"
}

list_clab_kind() {
  if [[ "${RUNTIME}" == "podman" ]]; then
    sudo podman ps -a --filter name=clab-kind --format '{{.Names}}' 2>/dev/null || true
  else
    sudo docker ps -a --filter name=clab-kind --format '{{.Names}}' 2>/dev/null || true
  fi
}

rm_clab_kind_leftovers() {
  local name any=0
  while IFS= read -r name; do
    [[ -z "${name}" ]] && continue
    any=1
    echo "  rm -f ${name}"
    if [[ "${RUNTIME}" == "podman" ]]; then
      sudo podman rm -f "${name}" 2>/dev/null || true
    else
      sudo docker rm -f "${name}" 2>/dev/null || true
    fi
  done < <(list_clab_kind)
  if [[ "${any}" -eq 1 ]]; then
    echo "Removed leftover clab-kind containers via ${RUNTIME}"
  fi
}

echo "=== teardown-clab ==="
echo "  provider=${PROVIDER} runtime=${RUNTIME} topo=${TOPO}"

if ! sudo -n true 2>/dev/null; then
  echo "ERROR: passwordless sudo required (sudo -n true failed)" >&2
  exit 1
fi

# Abort before destroy if mgmt is already wrong — continuing is riskier on bastion.
if [[ "${PROVIDER}" == "bastion" ]]; then
  assert_mgmt_default
fi

if [[ -n "${CLAB_BIN}" ]]; then
  # Prefer explicit destroy; ignore non-zero / SEGV (podman path is known flaky).
  set +e
  sudo "${CLAB_BIN}" destroy --runtime "${RUNTIME}" --topo "${TOPO}" --cleanup
  destroy_rc=$?
  set -e
  if [[ "${destroy_rc}" -ne 0 ]]; then
    echo "WARN: clab destroy exited ${destroy_rc} (often SEGV with podman); removing leftovers" >&2
  fi
else
  echo "WARN: clab/containerlab not found; runtime-only leftover cleanup via ${RUNTIME}" >&2
fi

rm_clab_kind_leftovers

# Drop per-container setup logs written by setup-clab.sh (bastion quiet path).
rm -f "${SCRIPT_DIR}"/.setup-*.log

left="$(list_clab_kind)"
if [[ -n "${left}" ]]; then
  echo "ERROR: clab-kind containers still present after teardown:" >&2
  echo "${left}" >&2
  exit 1
fi
echo "OK: no clab-kind containers remain"

assert_mgmt_default
echo "=== teardown-clab complete ==="
echo "  (toswitch* bridges and mgmt left up intentionally)"
