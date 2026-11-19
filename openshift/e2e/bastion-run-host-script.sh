#!/usr/bin/env bash
# Shared oc-debug helper for bastion worker-net (configure + teardown).
# Usage: run_host_script <node> <script> [args...]
# OPENPE_E2E_WORKER_NET_DEBUG_TIMEOUT defaults to 120s.
run_host_script() {
  local node=$1 script=$2
  local debug_timeout="${OPENPE_E2E_WORKER_NET_DEBUG_TIMEOUT:-120s}"
  shift 2
  timeout "${debug_timeout}" oc debug "node/${node}" --quiet -i --tty=false -- \
    chroot /host bash -s -- "$@" <"${script}"
}
