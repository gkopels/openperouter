#!/usr/bin/env bash
# Tear down the OpenPE ocp.clab fabric on this host.
# Keeps toswitch* bridges and mgmt; removes .setup-*.log leftovers.
# Same idea as make clean / clab/clean.sh: containerlab destroy --cleanup
# (no inspect/Python presence checks).
#
# Usage:
#   ./openshift/e2e/teardown-clab.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOPO="${SCRIPT_DIR}/ocp.clab.yml"
RUNTIME="${CLAB_RUNTIME:-${OPENPE_CLAB_RUNTIME:-docker}}"
MGMT_IFACE="${CLAB_BASTION_MGMT_IFACE:-eth0}"
# get.containerlab.dev installs here (BIN_INSTALL_DIR=/usr/bin, BINARY_NAME=containerlab).
CLAB_BIN="${CLAB_BIN:-/usr/bin/containerlab}"

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

echo "=== teardown-clab ==="
echo "  runtime=${RUNTIME} topo=${TOPO} clab=${CLAB_BIN}"

if [[ ! -f "${TOPO}" ]]; then
  echo "ERROR: topology file missing: ${TOPO}" >&2
  exit 1
fi

if ! sudo -n true 2>/dev/null; then
  echo "ERROR: passwordless sudo required (sudo -n true failed)" >&2
  exit 1
fi

assert_mgmt_default

if [[ ! -x "${CLAB_BIN}" ]]; then
  echo "ERROR: ${CLAB_BIN} not found or not executable; cannot destroy ${TOPO}" >&2
  exit 1
fi

echo "=== Destroying containerlab topology ==="
# Match make clean / clab/clean.sh: destroy --cleanup; ignore destroy errors.
sudo "${CLAB_BIN}" destroy --runtime "${RUNTIME}" --topo "${TOPO}" --cleanup || true

rm -f "${SCRIPT_DIR}"/.setup-*.log

assert_mgmt_default
echo "=== teardown-clab complete ==="
echo "  (toswitch* bridges and mgmt left up intentionally)"
