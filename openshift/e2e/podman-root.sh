#!/usr/bin/env bash
# Rootful podman wrapper for bastion e2e.
# setup-clab.sh deploys with "sudo podman"; Ginkgo uses CONTAINER_RUNTIME as a
# single binary, so point CONTAINER_RUNTIME at this script.
# Requires passwordless sudo (sudo -n) — same as setup-bastion-bridges.sh.
set -euo pipefail
PODMAN="$(command -v podman || true)"
if [[ -z "${PODMAN}" ]]; then
  echo "ERROR: podman not found in PATH" >&2
  exit 127
fi
if ! sudo -n true 2>/dev/null; then
  echo "ERROR: passwordless sudo required for rootful podman (sudo -n true failed)" >&2
  exit 1
fi
exec sudo -n "${PODMAN}" "$@"
