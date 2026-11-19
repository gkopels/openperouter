#!/usr/bin/env bash
# Tear down the OpenPE ocp.clab fabric on this host.
# Keeps toswitch* bridges and mgmt; removes .setup-*.log leftovers.
# Default runtime: docker (override with CLAB_RUNTIME / OPENPE_CLAB_RUNTIME).
#
# Only path: containerlab/clab destroy --topo ocp.clab.yml.
# Absence is confirmed only by a successful inspect (rc=0) with a verified
# empty-lab response from containerlab:
#   - newer: --format json prints {} or []
#   - older (get.containerlab.dev lineage): exact "no containers found"
# Inspect failures (missing runtime/socket/exec, etc.) are "unknown" — never
# matched via generic "not found" / "does not exist" text — so setup will not
# deploy after a failed destroy.
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

# Print: present | absent | unknown
#
# Verified absence (containerlab):
#   - rc=0 and empty JSON "{}" / "[]", or exact "no containers found"
#   - rc!=0 and topology-list empty-lab error (v0.79+ after destroy):
#       "Failed to list containers based on topology" + "containers not found"
# Runtime/socket/exec failures stay unknown. Never match bare "not found".
topo_inspect_status() {
  local out rc kind
  if [[ ! -x "${CLAB_BIN}" ]]; then
    echo "unknown"
    return 0
  fi
  set +e
  out="$(sudo "${CLAB_BIN}" inspect --runtime "${RUNTIME}" --topo "${TOPO}" --format json 2>&1)"
  rc=$?
  set -e
  # Heredoc (not python -c '...') so regex quotes cannot break Bash parsing.
  kind="$(
    INSPECT_RC="${rc}" INSPECT_OUT="${out}" python3 - <<'PY'
import json, os, re, sys

rc = int(os.environ.get("INSPECT_RC", "1"))
raw = os.environ.get("INSPECT_OUT", "")

# Prefer JSON when present (success or mixed with log lines).
candidates = []
for line in raw.splitlines():
    s = line.strip()
    if s[:1] in "{[":
        candidates.append(s)
if not candidates:
    s = raw.strip()
    if s[:1] in "{[":
        candidates.append(s)
for cand in reversed(candidates):
    try:
        data = json.loads(cand)
    except json.JSONDecodeError:
        continue
    if data in ({}, []):
        print("absent")
        sys.exit(0)
    print("present")
    sys.exit(0)

# Older containerlab: exit 0 and exact empty-lab line "no containers found".
for line in raw.splitlines():
    s = line.strip()
    if s == "no containers found":
        print("absent")
        sys.exit(0)
    if re.search(r"(?:msg=)?[\"']?no containers found[\"']?\s*$", s):
        print("absent")
        sys.exit(0)

# containerlab v0.79+ after destroy: inspect often exits non-zero with a
# topology-scoped empty-lab error (not a runtime/socket failure).
low = raw.lower()
if (
    "failed to list containers based on topology" in low
    and "containers not found" in low
):
    print("absent")
    sys.exit(0)

if rc != 0:
    print("unknown")
    sys.exit(0)
print("unknown")
PY
  )"
  case "${kind}" in
    absent|present)
      echo "${kind}"
      ;;
    *)
      echo "ERROR: clab inspect (rc=${rc}) did not return a verified empty/non-empty lab response:" >&2
      printf '%s\n' "${out}" >&2
      echo "unknown"
      ;;
  esac
  return 0
}

echo "=== teardown-clab ==="
echo "  runtime=${RUNTIME} topo=${TOPO}"

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

set +e
sudo "${CLAB_BIN}" destroy --runtime "${RUNTIME}" --topo "${TOPO}" --cleanup
DESTROY_RC=$?
set -e

if [[ "${DESTROY_RC}" -eq 0 ]]; then
  echo "OK: clab destroy succeeded for ${TOPO}"
else
  status="$(topo_inspect_status)"
  case "${status}" in
    absent)
      echo "OK: clab destroy exited ${DESTROY_RC} and inspect JSON positively reports empty lab"
      ;;
    present)
      echo "ERROR: clab destroy exited ${DESTROY_RC} and topology is still present" >&2
      exit "${DESTROY_RC}"
      ;;
    *)
      echo "ERROR: clab destroy exited ${DESTROY_RC} and inspect could not confirm absence (status=${status})" >&2
      echo "ERROR: refusing to treat failed destroy as success" >&2
      exit 1
      ;;
  esac
fi

rm -f "${SCRIPT_DIR}"/.setup-*.log

status="$(topo_inspect_status)"
case "${status}" in
  absent)
    echo "OK: topology ${TOPO} is absent (inspect --format json empty)"
    ;;
  present)
    echo "ERROR: topology still present after teardown (clab inspect)" >&2
    exit 1
    ;;
  *)
    echo "ERROR: cannot confirm topology absence (inspect status=${status})" >&2
    exit 1
    ;;
esac

assert_mgmt_default
echo "=== teardown-clab complete ==="
echo "  (toswitch* bridges and mgmt left up intentionally)"
