# OpenShift / cluster e2e environments

This directory wires the OpenPE **containerlab fabric** to a real OpenShift
cluster (not KIND). Upstream KIND e2e remains under `clab/` + `e2etests/` and
must keep working.

## Compatibility contract (do not break)

Any bastion / lab changes on this branch must preserve:

| Provider | How it runs today | Entry points |
| --- | --- | --- |
| **KIND** | Full in-clab KIND (`pe-kind*`) | Repo `make deploy` / `clab/singlecluster/kind.clab.yml` + `e2etests` |
| **Virtual OCP** | OCP VMs via **dev-scripts** + libvirt nets `toswitch1`/`toswitch2` | `openshift/e2e/deploy.sh` → `setup-clab.sh` (default) |
| **Bastion lab** (new) | Clab on a bastion; cluster workers reached over lab NIC (`eth1`/`eth2`) / VLAN bridges | `make e2e-bastion` / `OPENPE_E2E_PROVIDER=bastion` |

Rules:

1. **Default** `OPENPE_E2E_PROVIDER` is `dev-scripts` — same behavior as before this branch.
2. Do **not** remove or rename `toswitch1` / `toswitch2` in `ocp.clab.yml` without updating virtual-OCP scripts.
3. Prefer env flags / thin wrappers over forking the topology YAML.
4. Bastion mode must not set a default gateway on the lab NIC (breaks SSH / mgmt). See bastion notes below.

## Virtual OCP (dev-scripts) — default

```bash
export KUBECONFIG=/root/dev-scripts/ocp/ostest/auth/kubeconfig
./openshift/e2e/deploy.sh
# or only fabric:
./openshift/e2e/setup-clab.sh
```

Prerequisites: `EXTRA_NETWORK_NAMES` / post-install `toswitch1` `toswitch2`, Docker, OpenPE + frr-k8s on cluster.

## Bastion lab (opt-in)

Target: QE bastions with:

- `eth0` = mgmt / SSH / **default route only**
- `eth1` = lab VLAN → `toswitch1` (no gateway; `ipv4.never-default yes`)
- `eth2` = lab VLAN → `toswitch2` (same rules)
- Clab fabric on the bastion; same `ocp.clab.yml` bridges named `toswitch1`/`toswitch2`

### CI / full lifecycle (setup → test → teardown)

This is the bastion/OCP counterpart to KIND `make deploy` + e2e + clean.  
**Do not** use KIND `make deploy` on the bastion. OpenPE must already be installed. Telco QE clusters already enable CNO **FRR** (frr-k8s) as shared lab infra — `deploy-bastion.sh` defaults to waiting for existing pods (`OPENPE_E2E_DEPLOY_FRRK8S=false`) and does not tear FRR down (`OPENPE_E2E_TEARDOWN_FRRK8S=false`). Set both to `true` only when this job must enable/restore CNO FRR itself.

```bash
set -a && source openshift/e2e/bastion.env.example && set +a

# make e2e-bastion requires OPENPE_KUBECONFIG (Make would otherwise export KIND's
# bin/kubeconfig as KUBECONFIG). Sourcing bastion.env alone is not enough for Make.
export OPENPE_KUBECONFIG=/path/to/ocp/kubeconfig
make e2e-bastion

# Or bypass Make and set KUBECONFIG for the script directly:
# export KUBECONFIG=/path/to/ocp/kubeconfig
# ./openshift/e2e/e2e-bastion.sh
```

Flow:

1. `deploy-bastion.sh` → wait for existing frr-k8s (default) + bridges + `setup-clab.sh` (fabric + nodelink). With `OPENPE_E2E_DEPLOY_FRRK8S=true`, enables CNO FRR via `deploy_frrk8s.sh` first.
2. `configure-bastion-worker-net.sh` → apply worker underlay IPs (`OPENPE_UNDERLAY_IFACE`)
3. `run_tests.sh` → Ginkgo suite (same as KIND by default; optional `OPENPE_E2E_FOCUS` / `OPENPE_E2E_SKIP`)
4. EXIT trap (always unless `OPENPE_E2E_SKIP_TEARDOWN=true`):
   1. `teardown-bastion-worker-net.sh` → remove planned worker underlay IPs (while cluster API still usable)
   2. `teardown-clab.sh` → destroy fabric; keeps `toswitch*` / mgmt NICs; asserts default route stays on `eth0`
   3. `teardown_frrk8s.sh` → **skipped by default** (shared CNO FRR). With `OPENPE_E2E_TEARDOWN_FRRK8S=true`, reverts CNO only if this run patched it (marker + `providersBefore`). `force` drops FRR from the current list; does not delete the frr-k8s namespace / ConfigMap.

Debug (skip **all** EXIT cleanup — worker-net IPs, clab, and CNO FRR): `OPENPE_E2E_SKIP_TEARDOWN=true OPENPE_KUBECONFIG=… make e2e-bastion`.  
For selective cleanup, leave that unset and use `OPENPE_E2E_TEARDOWN_WORKER_NET` / `OPENPE_E2E_TEARDOWN_FRRK8S` (see `bastion.env.example`).

### Shared `CLAB_*` variables (OpenPE + MetalLB)

Same bastion will later host MetalLB **external FRR** containers. Use one var set:

| Variable | Purpose | Example |
| --- | --- | --- |
| `CLAB_EXECUTOR` | `local` (CI/bastion) or `ssh` (laptop later) | `local` |
| `CLAB_BASTION_HOST` / `SSH` / `WORKDIR` | Future / MetalLB laptop→bastion; **unused** by OpenPE when `CLAB_EXECUTOR=local` | (optional) |
| `CLAB_RUNTIME` | `podman` or `docker` | `podman` |
| `CLAB_BASTION_LAB_IFACE_TOSWITCH1` | Lab NIC → `toswitch1` (never default route) | `eth1` |
| `CLAB_BASTION_LAB_IFACE_TOSWITCH2` | Lab NIC → `toswitch2` | `eth2` |
| `CLAB_BASTION_ATTACH_LAB_IFACE` | Enslave lab NICs: eth1→toswitch1, eth2→toswitch2 | `true` |
| `OPENPE_E2E_PROVIDER` | OpenPE only: `dev-scripts` \| `bastion` | `bastion` |
| `OPENPE_KUBECONFIG` | Required for `make e2e-bastion` | path to OCP kubeconfig |
| `KUBECONFIG` | Required by scripts when not using Make | same path |

See `bastion.env.example`. Phase 1: **`CLAB_EXECUTOR=local` only** (run tests + clab on the bastion). Remote `ssh` / `CLAB_BASTION_HOST` is future (e.g. MetalLB); CI stays `local`.

```bash
set -a && source openshift/e2e/bastion.env.example && set +a
export KUBECONFIG=/path/to/ocp/kubeconfig
# bastion.env sets OPENPE_UNDERLAY_IFACE (required; e.g. eth1.100 or ens1f0)

# Bring-up only (no tests / no teardown):
./openshift/e2e/deploy-bastion.sh

# Or step by step:
# ./openshift/e2e/setup-bastion-bridges.sh
# ./openshift/e2e/setup-clab.sh
# ./openshift/e2e/configure-bastion-worker-net.sh   # needs OPENPE_UNDERLAY_IFACE
# ./openshift/e2e/run_tests.sh
# ./openshift/e2e/teardown-bastion-worker-net.sh
# ./openshift/e2e/teardown-clab.sh
# ./openshift/e2e/teardown_frrk8s.sh   # no-op unless this run enabled CNO FRR
```

`setup-clab.sh` with `OPENPE_E2E_PROVIDER=bastion`:

- Uses `CLAB_RUNTIME` (default **podman**)
- Skips libvirt/virsh DHCP and `ostest_*` NIC rename
- Writes planned `nodelink.json` only (worker IPs applied later by `configure-bastion-worker-net.sh`)
- Refuses to continue if default route is on `eth1`/`eth2`

**Worker underlay IPs:** `e2e-bastion` runs `configure-bastion-worker-net.sh` after clab (applies addresses from `nodelink.json` onto `OPENPE_UNDERLAY_IFACE`) and removes them in EXIT via `teardown-bastion-worker-net.sh`. `run_tests.sh` exports `OPENPE_UNDERLAY_IFACE*` into `make e2etests` / Ginkgo (hydrates from configure state if unset). Underlay must be tagged `parent.VID` (e.g. `eth1.100` / `eth2.200`). Configure creates missing vlan subifs; teardown deletes them.

## KIND

Unaffected by this directory. Use the existing Kind-based developer and CI flows.

## Files

| File | Role |
| --- | --- |
| `ocp.clab.yml` | Fabric topo; bridges `toswitch1`/`toswitch2` (shared by virtual OCP + bastion) |
| `bastion.env.example` | Bastion env template (replace placeholders for your site) |
| `setup-clab.sh` | Deploy fabric, IPs, setups, nodelink (provider-aware) |
| `teardown-clab.sh` | Destroy fabric only (podman-safe); keep bridges/mgmt; assert eth0 default |
| `setup_extra_networks.sh` | **Virtual OCP only** — libvirt extra nets |
| `setup-bastion-bridges.sh` | **Bastion only** — create `toswitch*` + attach eth1/eth2 (no SSH theft) |
| `deploy_frrk8s.sh` | Enable CNO FRR / wait for frr-k8s (marker when this run patches CNO) |
| `teardown_frrk8s.sh` | Restore CNO FRR if marker present; no-op by default on telco |
| `deploy-bastion.sh` | **Bastion only** — frr wait/enable + bridges + `setup-clab.sh` (not KIND `make deploy`) |
| `configure-bastion-worker-net.sh` | Apply worker underlay IPs from nodelink (`OPENPE_UNDERLAY_IFACE`) |
| `teardown-bastion-worker-net.sh` | Remove planned worker underlay IPs; keep state on failure |
| `podman-root.sh` | Rootful `sudo -n podman` wrapper for Ginkgo `CONTAINER_RUNTIME` |
| `e2e-bastion.sh` | **Bastion only** — deploy → configure → `run_tests.sh` → teardown (`make e2e-bastion`) |
| `run_tests.sh` | Focused e2e against `nodelink.json` (bastion preflight + podman-root) |
| `ip_map_ocp.txt` | Static IPs inside clab nodes |
| `deploy.sh` | Full virtual-OCP bring-up |
