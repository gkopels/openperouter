#!/usr/bin/env bash
# Shared oc-debug helper for bastion worker-net (configure + teardown).
# Usage: run_host_script <node> <script> [args...]
# OPENPE_E2E_WORKER_NET_DEBUG_TIMEOUT defaults to 120s.
#
# Older oc builds reject "oc debug -i"; we base64 the script and decode on the
# node so stdin flags are not required.
run_host_script() {
  local node=$1 script=$2
  local debug_timeout="${OPENPE_E2E_WORKER_NET_DEBUG_TIMEOUT:-120s}"
  shift 2

  local b64 q args_q=""
  if base64 -w0 /dev/null >/dev/null 2>&1; then
    b64="$(base64 -w0 <"${script}")"
  else
    b64="$(base64 <"${script}" | tr -d '\n')"
  fi

  local a
  for a in "$@"; do
    printf -v q '%q' "${a}"
    args_q+=" ${q}"
  done

  timeout "${debug_timeout}" oc debug "node/${node}" --quiet -- chroot /host \
    bash -c "echo '${b64}' | base64 -d | bash -s --${args_q}"
}
