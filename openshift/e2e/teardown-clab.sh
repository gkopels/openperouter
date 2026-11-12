#!/usr/bin/env bash
# Tear down the OpenPE ocp.clab fabric on this host.
# Keeps toswitch* bridges and mgmt; removes .setup-*.log leftovers.
# Default runtime: docker (override with CLAB_RUNTIME / OPENPE_CLAB_RUNTIME).
#
# Usage:
#   ./openshift/e2e/teardown-clab.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOPO="${SCRIPT_DIR}/ocp.clab.yml"
RUNTIME="${CLAB_RUNTIME:-${OPENPE_CLAB_RUNTIME:-docker}}"
MGMT_IFACE="${CLAB_BASTION_MGMT_IFACE:-eth0}"

CLAB_BIN=""
if command -v clab >/dev/null 2>&1; then
  CLAB_BIN=clab
elif command -v containerlab >/dev/null 2>&1; then
  CLAB_BIN=containerlab
fi

assert_mgmt_default() {
  local def
  def="$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}')"
  if [[ -z "${def}" ]]; then
    echo "ERROR: no default route (expected via ${MGMT_IFACE})" >&2
    return 1
  fi
  if [[ "${def}" != "${MGMT_IFACE}" ]]; then
    echo "ERROR: default route on ${def}, expected ${MGMT_IFACE}" >&2
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
echo "  runtime=${RUNTIME} topo=${TOPO}"

if ! sudo -n true 2>/dev/null; then
  echo "ERROR: passwordless sudo required (sudo -n true failed)" >&2
  exit 1
fi

assert_mgmt_default

if [[ -n "${CLAB_BIN}" ]]; then
  set +e
  sudo "${CLAB_BIN}" destroy --runtime "${RUNTIME}" --topo "${TOPO}" --cleanup
  destroy_rc=$?
  set -e
  if [[ "${destroy_rc}" -ne 0 ]]; then
    echo "WARN: clab destroy exited ${destroy_rc}; removing leftovers" >&2
  fi
else
  echo "WARN: clab/containerlab not found; runtime-only leftover cleanup via ${RUNTIME}" >&2
fi

rm_clab_kind_leftovers
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
