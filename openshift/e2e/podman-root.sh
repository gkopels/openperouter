#!/usr/bin/env bash
# Optional rootful podman wrapper. Bastion defaults use docker; set
# CONTAINER_RUNTIME to this script only when overriding to podman.
# Requires passwordless sudo (sudo -n).
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
