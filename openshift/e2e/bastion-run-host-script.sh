#!/usr/bin/env bash
# Shared helper: pipe a host script into a worker host netns via oc debug.
# Sourced by configure-bastion-worker-net.sh and teardown-bastion-worker-net.sh.
#
# Usage:
#   # shellcheck source=./bastion-run-host-script.sh
#   source "${SCRIPT_DIR}/bastion-run-host-script.sh"
#   run_host_script <node> <script> [args...]
#
# Env:
#   OPENPE_E2E_WORKER_NET_DEBUG_TIMEOUT — timeout(1) for oc debug (default: 120s).
#
run_host_script() {
  local node=$1 script=$2
  local debug_timeout="${OPENPE_E2E_WORKER_NET_DEBUG_TIMEOUT:-120s}"
  shift 2
  timeout "${debug_timeout}" oc debug "node/${node}" --quiet -i --tty=false -- \
    chroot /host bash -s -- "$@" <"${script}"
}
