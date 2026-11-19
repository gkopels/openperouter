#!/usr/bin/env bash
# Run on the worker host netns (via oc debug … chroot /host bash -s).
# Usage: remove-underlay-vlan-on-host.sh <iface> <ip> <plen> <createdLink 0|1> <addedAddress 0|1> <wait_secs>
#
# Ownership-aware: deletes the planned IPv4 and/or VLAN link only when this run
# created them. Waits up to wait_secs for the iface to reappear in the host netns
# after Underlay CR cleanup.
#
set -euo pipefail

if [[ $# -ne 6 ]]; then
  echo "Usage: $0 <iface> <ip> <plen> <createdLink> <addedAddress> <wait_secs>" >&2
  exit 2
fi

iface=$1
ip=$2
plen=$3
created_link=$4
added_address=$5
wait_secs=$6
planned="${ip}/${plen}"

deadline=$((SECONDS + wait_secs))
while (( SECONDS < deadline )); do
  if ip link show "${iface}" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

if ! ip link show "${iface}" >/dev/null 2>&1; then
  echo "  ${iface} already absent on host; skipping"
  exit 0
fi

if [[ "${added_address}" == "1" ]]; then
  if ip -4 -o addr show dev "${iface}" | awk '{print $4}' | grep -qxF "${planned}"; then
    ip -4 addr del "${planned}" dev "${iface}"
  fi
  if ip -4 -o addr show dev "${iface}" | awk '{print $4}' | grep -qxF "${planned}"; then
    echo "ERROR: ${planned} still present on ${iface}" >&2
    exit 1
  fi
fi

if [[ "${created_link}" == "1" ]]; then
  echo "  removing vlan link ${iface} (created by this run)"
  ip link del "${iface}"
  if ip link show "${iface}" >/dev/null 2>&1; then
    echo "ERROR: ${iface} still present after ip link del" >&2
    exit 1
  fi
else
  ip -br addr show "${iface}" 2>/dev/null || true
fi
