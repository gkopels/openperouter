#!/usr/bin/env bash
# Bastion-only helper: create toswitch1/toswitch2 Linux bridges for ocp.clab.yml
# and optionally attach lab NICs. Does NOT change eth0 / default route.
#
# Typical layout (tagging often on the hypervisor; guest sees untagged NICs):
#   leaf1 path → bastion eth1 → toswitch1 (leafkind1)
#   leaf2 path → bastion eth2 → toswitch2 (leafkind2)
#
# Usage:
#   set -a && source openshift/e2e/bastion.env.example && set +a
#   ./openshift/e2e/setup-bastion-bridges.sh
#
# Safety:
#   - Never adds a gateway on lab ifaces
#   - Flushes addresses on lab ifaces before enslaving
#   - Marks lab NICs NM-unmanaged (no SSH theft) without bouncing eth0
#   - Does NOT nmcli-mod the live mgmt profile (that drops SSH)
#   - Idempotent: skips work when already correct
#   - No rollback: if attach fails after ensure_bridge, bridges stay (rerun is OK)
#   - CLAB_BASTION_ATTACH_LAB_IFACE: only the literal "true" enables attach
#   - Requires working passwordless (or cached) sudo
#   - lab-* NM profiles created here are not removed by teardown-clab (intentional)
# Override guest ifaces via CLAB_BASTION_LAB_IFACE_TOSWITCH1/2 (or aliases).
set -euo pipefail

MGMT_IFACE="${CLAB_BASTION_MGMT_IFACE:-eth0}"
IFACE_TS1="${CLAB_BASTION_LAB_IFACE_TOSWITCH1:-${CLAB_BASTION_LAB_IFACE:-${OPENPE_BASTION_LAB_IFACE:-eth1}}}"
IFACE_TS2="${CLAB_BASTION_LAB_IFACE_TOSWITCH2:-eth2}"
# Only the literal string "true" enables attach (any other value = bridges only).
ATTACH_LAB="${CLAB_BASTION_ATTACH_LAB_IFACE:-${OPENPE_BASTION_ATTACH_LAB_IFACE:-true}}"

echo "=== Bastion bridges for ocp.clab.yml ==="
echo "  mgmt: ${MGMT_IFACE} (SSH / default only)"
echo "  map: ${IFACE_TS1} -> toswitch1 (leafkind1), ${IFACE_TS2} -> toswitch2 (leafkind2)"

if ! sudo -n true 2>/dev/null; then
  echo "ERROR: passwordless sudo required (sudo -n true failed)" >&2
  exit 1
fi

# Exact match on the default route's device field (avoid eth1 matching eth10).
default_route_dev() {
  ip route 2>/dev/null | awk '/^default/ {print $5; exit}'
}

refuse_if_default_on() {
  local iface="$1"
  local def
  def="$(default_route_dev)"
  if [[ -n "${def}" && "${def}" == "${iface}" ]]; then
    echo "ERROR: default route is on ${iface}. Fix mgmt (${MGMT_IFACE}) first; refusing to continue." >&2
    ip route show default >&2 || true
    exit 1
  fi
}

require_mgmt_ok() {
  if ! ip -br addr show "${MGMT_IFACE}" 2>/dev/null | grep -q 'UP'; then
    echo "ERROR: ${MGMT_IFACE} is not UP" >&2
    exit 1
  fi
  # ip -br does not print the word "inet"; match an IPv4 address instead.
  if ! ip -4 -br addr show "${MGMT_IFACE}" 2>/dev/null | grep -Eq '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
    echo "ERROR: ${MGMT_IFACE} has no IPv4 address (mgmt must stay here)" >&2
    ip -br addr >&2 || true
    exit 1
  fi
  local def
  def="$(default_route_dev)"
  if [[ -z "${def}" || "${def}" != "${MGMT_IFACE}" ]]; then
    echo "ERROR: default route is not on ${MGMT_IFACE} (got: ${def:-none})" >&2
    ip route show default >&2 || true
    exit 1
  fi
}

# Keep NM from autoconfing lab NICs. Prefer "unmanaged" — does not bounce eth0.
# Optional persistent lab-* profiles only if missing (no con up / no delete of others).
harden_lab_nm() {
  local iface="$1"
  local con_name="lab-${iface}"

  if ! command -v nmcli >/dev/null 2>&1; then
    echo "  warn: nmcli missing; cannot harden ${iface}"
    return 0
  fi

  sudo nmcli device set "${iface}" managed no 2>/dev/null || true
  echo "  nmcli: ${iface} unmanaged (NM will not assign IP/gateway)"

  # Persist a disabled profile for reboot clarity — create only if absent.
  # Do not nmcli con up / delete other profiles here (that caused SSH drops).
  if ! nmcli -t -f NAME connection show | grep -qx "${con_name}"; then
    sudo nmcli con add type ethernet ifname "${iface}" con-name "${con_name}" \
      connection.autoconnect no \
      ipv4.method disabled \
      ipv6.method disabled \
      ipv4.never-default yes \
      ipv6.never-default yes >/dev/null
    echo "  nmcli: created ${con_name} (autoconnect no, no IP)"
  else
    echo "  nmcli: ${con_name} already present"
  fi
}

bridge_of() {
  local iface="$1"
  # master <bridge> appears in `ip -o link show`
  ip -o link show "${iface}" 2>/dev/null | sed -n 's/.*master \([^ ]*\).*/\1/p' | head -1
}

ensure_bridge() {
  local br="$1"
  if ! ip link show "${br}" >/dev/null 2>&1; then
    sudo ip link add "${br}" type bridge
    echo "  created ${br}"
  else
    echo "  ${br} already exists"
  fi
  sudo ip link set "${br}" up
}

attach_to_bridge() {
  local iface="$1" br="$2"
  if ! ip link show "${iface}" >/dev/null 2>&1; then
    echo "ERROR: lab iface ${iface} not found (attach virtio NIC on HV first)" >&2
    exit 1
  fi

  harden_lab_nm "${iface}"

  local cur
  cur="$(bridge_of "${iface}")"
  if [[ "${cur}" == "${br}" ]]; then
    # Already correct — do not nomaster/remaster (avoids link flaps).
    sudo ip addr flush dev "${iface}" 2>/dev/null || true
    sudo ip link set "${iface}" up
    echo "  ${iface} already on ${br} (unchanged)"
    return 0
  fi

  sudo ip addr flush dev "${iface}" 2>/dev/null || true
  sudo ip link set "${iface}" nomaster 2>/dev/null || true
  sudo ip link set "${iface}" master "${br}"
  sudo ip link set "${iface}" up
  echo "  ${iface} -> ${br} (no address; no gateway)"
}

require_mgmt_ok

# Cheap env sanity: mgmt + both lab ifaces must be distinct names.
if [[ "${MGMT_IFACE}" == "${IFACE_TS1}" || "${MGMT_IFACE}" == "${IFACE_TS2}" || "${IFACE_TS1}" == "${IFACE_TS2}" ]]; then
  echo "ERROR: mgmt and lab iface names must be distinct" >&2
  echo "  mgmt=${MGMT_IFACE} toswitch1=${IFACE_TS1} toswitch2=${IFACE_TS2}" >&2
  exit 1
fi

refuse_if_default_on "${IFACE_TS1}"
if ip link show "${IFACE_TS2}" >/dev/null 2>&1; then
  refuse_if_default_on "${IFACE_TS2}"
fi

# Attach mode needs both lab NICs; fail before creating bridges.
if [[ "${ATTACH_LAB}" == "true" ]]; then
  for iface in "${IFACE_TS1}" "${IFACE_TS2}"; do
    if ! ip link show "${iface}" >/dev/null 2>&1; then
      echo "ERROR: CLAB_BASTION_ATTACH_LAB_IFACE=true requires both lab NICs" >&2
      echo "  missing: ${iface} (expected ${IFACE_TS1} -> toswitch1, ${IFACE_TS2} -> toswitch2)" >&2
      echo "  attach virtio NICs on the HV, or set CLAB_BASTION_ATTACH_LAB_IFACE=false" >&2
      exit 1
    fi
  done
fi

echo "  note: not modifying NM profile on ${MGMT_IFACE} (avoids SSH drop)"

ensure_bridge toswitch1
ensure_bridge toswitch2

if [[ "${ATTACH_LAB}" == "true" ]]; then
  attach_to_bridge "${IFACE_TS1}" toswitch1
  attach_to_bridge "${IFACE_TS2}" toswitch2
else
  harden_lab_nm "${IFACE_TS1}"
  if ip link show "${IFACE_TS2}" >/dev/null 2>&1; then
    harden_lab_nm "${IFACE_TS2}"
  fi
fi

echo "=== Verify default still on mgmt ==="
ip route show default
require_mgmt_ok
refuse_if_default_on "${IFACE_TS1}"
if ip link show "${IFACE_TS2}" >/dev/null 2>&1; then
  refuse_if_default_on "${IFACE_TS2}"
fi

bridge link | grep -E "toswitch|${IFACE_TS1}|${IFACE_TS2}" || true
echo "Bastion bridges ready."
