#!/usr/bin/env bash
# Bastion host helper: validate parent NIC, then clean+create underlay VLAN + IPv4.
# Intended to run in the worker host netns via:
#   oc debug node/<node> --quiet -i --tty=false -- chroot /host bash -s -- <args>
# Does not mutate the parent (must be UP, unmanaged, no IPv4).
#
# Usage:
#   ./openshift/e2e/apply-underlay-vlan-on-host.sh <parent> <iface> <vid> <ip/plen>
#
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "Usage: $0 <parent> <iface> <vid> <ip/plen>" >&2
  exit 2
fi

parent=$1
iface=$2
vid=$3
planned=$4

if ! ip link show "${parent}" >/dev/null 2>&1; then
  echo "ERROR: parent iface ${parent} missing on host (for ${iface})" >&2
  ip -br link >&2 || true
  exit 1
fi

if ! ip -o link show "${parent}" | grep -Eq 'state UP|<[^>]*[,<]UP[,>]'; then
  echo "ERROR: parent ${parent} is not UP; provision parent state before bastion e2e" >&2
  ip -br link show "${parent}" >&2 || true
  exit 1
fi

parent_addrs=$(ip -4 -o addr show dev "${parent}" 2>/dev/null | awk '{print $4}' | paste -sd, - || true)
if [[ -n "${parent_addrs}" ]]; then
  echo "ERROR: parent ${parent} has IPv4 [${parent_addrs}]; refusing to modify" >&2
  exit 1
fi

if command -v nmcli >/dev/null 2>&1; then
  nm_state=$(nmcli -t -f DEVICE,STATE device status 2>/dev/null | awk -F: -v d="${parent}" '$1==d {print $2; exit}')
  if [[ -n "${nm_state}" && "${nm_state}" != "unmanaged" ]]; then
    echo "ERROR: parent ${parent} NM state is '${nm_state}' (want unmanaged); fix in the lab before bastion e2e" >&2
    exit 1
  fi
fi

if ip link show "${iface}" >/dev/null 2>&1; then
  echo "  removing existing ${iface}"
  ip link del "${iface}"
fi

ip link add link "${parent}" name "${iface}" type vlan id "${vid}"
ip link set "${iface}" up
ip -4 addr add "${planned}" dev "${iface}"

if ! ip -4 -o addr show dev "${iface}" | awk '{print $4}' | grep -qxF "${planned}"; then
  echo "ERROR: ${planned} missing on ${iface} after addr add" >&2
  exit 1
fi

ip -br addr show "${iface}" 2>/dev/null || true
