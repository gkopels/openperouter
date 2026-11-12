# OpenShift / cluster e2e environments

Wires the OpenPE containerlab fabric to a real OpenShift cluster (not KIND).
Upstream KIND e2e stays under `clab/` + `e2etests/`.

## Compatibility

| Environment | Entry points |
| --- | --- |
| **KIND** | `make deploy` / `clab/singlecluster/kind.clab.yml` + `e2etests` |
| **Virtual OCP / metal** | `deploy.sh` → `setup-clab.sh` + `run_tests.sh` (same as `kni/main`) |
| **Bastion lab** | `make e2e-bastion` → `setup-clab-bastion.sh` + `run_tests-bastion.sh` |

Shared `setup-clab.sh` / `run_tests.sh` / `deploy_frrk8s.sh` stay on the main (virtual OCP) path and are unchanged from main behavior. Bastion uses dedicated wrappers.

## Virtual OCP (dev-scripts)

```bash
export KUBECONFIG=/root/dev-scripts/ocp/ostest/auth/kubeconfig
./openshift/e2e/deploy.sh
# or fabric only:
./openshift/e2e/setup-clab.sh
```

## Bastion lab

Layout: `eth0` = mgmt/SSH; `eth1`→`toswitch1`, `eth2`→`toswitch2` (no gateway on lab NICs).
Default container runtime: **docker** (`CLAB_RUNTIME` / `OPENPE_CLAB_RUNTIME`).

**Prerequisite:** CI or the lab must provision FRR-K8s (CNO `additionalRoutingCapabilities` / `openshift-frr-k8s`) before the bastion run. Bastion e2e only waits for Ready pods; it does not enable or tear down CNO FRR.

### Full lifecycle

```bash
set -a && source openshift/e2e/bastion.env.example && set +a
export OPENPE_KUBECONFIG=/path/to/ocp/kubeconfig
make e2e-bastion
# or: export KUBECONFIG=... && ./openshift/e2e/e2e-bastion.sh
```

Flow:

1. `deploy-bastion.sh` → wait for FRR-K8s readiness, then set up bridges and containerlab
2. `configure-bastion-worker-net.sh` → worker underlay IPs (`OPENPE_UNDERLAY_IFACE*`)
3. `run_tests-bastion.sh` → Ginkgo (optional `OPENPE_E2E_FOCUS` / `OPENPE_E2E_SKIP`)
4. EXIT (unless `OPENPE_E2E_SKIP_TEARDOWN=true`): worker-net → `teardown-clab.sh`

### Step by step

```bash
set -a && source openshift/e2e/bastion.env.example && set +a
export KUBECONFIG=/path/to/ocp/kubeconfig

./openshift/e2e/deploy-bastion.sh
# or:
# ./openshift/e2e/setup-bastion-bridges.sh
# ./openshift/e2e/setup-clab-bastion.sh
./openshift/e2e/configure-bastion-worker-net.sh
./openshift/e2e/run_tests-bastion.sh
./openshift/e2e/teardown-bastion-worker-net.sh
./openshift/e2e/teardown-clab.sh
```

`setup-clab-bastion.sh` writes planned `nodelink.json` (real worker ifaces); IPs are applied by `configure-bastion-worker-net.sh`.

### Env highlights

| Variable | Purpose | Default / example |
| --- | --- | --- |
| `CLAB_RUNTIME` | clab runtime | `docker` |
| `OPENPE_UNDERLAY_IFACE{,2}` | worker underlay NICs | `eth1.100` / `eth2.200` |
| `OPENPE_E2E_NODE_SELECTOR` | nodelink + instrumented nodes | `node-role.kubernetes.io/worker` |
| `OPENPE_KUBECONFIG` | required for `make e2e-bastion` | path to OCP kubeconfig |

See `bastion.env.example`. `podman-root.sh` remains available for optional podman overrides; defaults use docker.

## Files

| File | Role |
| --- | --- |
| `ocp.clab.yml` | Shared fabric topo (`toswitch1`/`toswitch2`) |
| `setup-clab.sh` / `run_tests.sh` | Virtual OCP / metal (main behavior) |
| `setup-clab-bastion.sh` / `run_tests-bastion.sh` | Bastion-only fabric + tests |
| `setup-bastion-bridges.sh` | Bastion `toswitch*` bridges |
| `deploy-bastion.sh` / `e2e-bastion.sh` | Bastion bring-up / lifecycle |
| `configure-bastion-worker-net.sh` / `teardown-bastion-worker-net.sh` | Worker underlay IPs |
| `teardown-clab.sh` | Destroy fabric; keep bridges/mgmt |
| `deploy_frrk8s.sh` | FRR-K8s setup helper for the metal / virtual OCP path (`deploy.sh`) |
| `bastion.env.example` | Bastion env template |
| `podman-root.sh` | Optional rootful podman wrapper |
