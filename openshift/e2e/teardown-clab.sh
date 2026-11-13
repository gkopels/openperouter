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

# Print: present | absent | unknown
#
# Verified absence only on inspect rc=0 plus a known empty-lab payload.
# Non-zero rc (runtime/socket/exec errors) → unknown. Never treat generic
# "not found" / "does not exist" substrings as absence.
topo_inspect_status() {
  local out rc kind
  if [[ -z "${CLAB_BIN}" ]]; then
    echo "unknown"
    return 0
  fi
  set +e
  out="$(sudo "${CLAB_BIN}" inspect --runtime "${RUNTIME}" --topo "${TOPO}" --format json 2>&1)"
  rc=$?
  set -e
  if [[ "${rc}" -ne 0 ]]; then
    echo "ERROR: clab inspect failed (rc=${rc}); cannot confirm topology absence:" >&2
    printf '%s\n' "${out}" >&2
    echo "unknown"
    return 0
  fi
  # Heredoc (not python -c '...') so regex quotes cannot break Bash parsing.
  kind="$(
    INSPECT_OUT="${out}" python3 - <<'PY'
import json, os, re, sys

raw = os.environ.get("INSPECT_OUT", "")
# Newer containerlab: empty lab → "{}" / "[]" on stdout (possibly among log lines).
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
# Older containerlab: exit 0 and exact empty-lab line "no containers found"
# (log.Println / log.Info). Do not substring-match bare "not found".
for line in raw.splitlines():
    s = line.strip()
    if s == "no containers found":
        print("absent")
        sys.exit(0)
    # logrus / similar: ... msg="no containers found"  OR  INFO[...] no containers found
    if re.search(r"(?:msg=)?[\"']?no containers found[\"']?\s*$", s):
        print("absent")
        sys.exit(0)
print("unknown")
PY
  )"
  case "${kind}" in
    absent|present)
      echo "${kind}"
      ;;
    *)
      echo "ERROR: clab inspect succeeded but did not return a verified empty/non-empty lab response:" >&2
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

if [[ -z "${CLAB_BIN}" ]]; then
  echo "ERROR: clab/containerlab not found; cannot destroy ${TOPO}" >&2
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
