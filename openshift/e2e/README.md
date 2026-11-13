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
Default container runtime: **docker**.

**Prerequisites (must already be installed and Ready):** OpenPERouter in `openshift-openperouter` (namespace, underlay CRD, `controller` / `router` DaemonSets), and FRR-K8s in `openshift-frr-k8s` (CNO `additionalRoutingCapabilities`). Bastion e2e does not install either; it only waits for Ready.

Supply lab settings from the shell, a local wrapper, or CI. `bastion.env.example` is a reference template only — sourcing it is not required.

### What you must provide

```bash
make e2e-bastion \
  OPENPE_KUBECONFIG=/path/to/ocp/kubeconfig \
  OPENPE_UNDERLAY_IFACE=ens1f0.173 \
  OPENPE_UNDERLAY_IFACE2=ens1f1.174
```

| Variable | Purpose |
| --- | --- |
| `OPENPE_KUBECONFIG` | OCP kubeconfig path (`make` passes it as `KUBECONFIG` into the scripts). |
| `OPENPE_UNDERLAY_IFACE` | Worker underlay NIC for leaf 1 (tagged `parent.VID`). |
| `OPENPE_UNDERLAY_IFACE2` | Worker underlay NIC for leaf 2 (tagged `parent.VID`). |

Direct `./openshift/e2e/e2e-bastion.sh` uses **`KUBECONFIG`** in place of `OPENPE_KUBECONFIG`; the two underlay variables are unchanged:

```bash
export KUBECONFIG=/path/to/ocp/kubeconfig
export OPENPE_UNDERLAY_IFACE=ens1f0.173
export OPENPE_UNDERLAY_IFACE2=ens1f1.174
./openshift/e2e/e2e-bastion.sh
```

### Optional overrides (defaults)

CI or a wrapper only needs to pass the three values above unless it changes a default. Defaults match the current bastion scripts; see `bastion.env.example` for a commented template.

| Variable | Default | Purpose |
| --- | --- | --- |
| `OPENPE_E2E_NODE_SELECTOR` | `node-role.kubernetes.io/worker` | Nodes for `nodelink.json` and Ginkgo `--instrumented-nodes-label`. The default `worker` label **includes master/control-plane nodes that also carry that label** (common on compact or lab clusters). Use a narrower role such as `node-role.kubernetes.io/workercnf` when only CNF workers are wired to the test underlay. |
| `OPENPE_BASTION_NODE_IP_BASE` | `100` (script) | Third octet base for planned worker underlay IPs in `nodelink.json`. The example template sets `103` as a lab-specific illustration — unset uses `100`. |
| `CLAB_BASTION_MGMT_IFACE` | `eth0` | Bastion management NIC (default route must stay here). |
| `CLAB_BASTION_LAB_IFACE_TOSWITCH1` | `eth1` | Bastion NIC enslaved to `toswitch1`. |
| `CLAB_BASTION_LAB_IFACE_TOSWITCH2` | `eth2` | Bastion NIC enslaved to `toswitch2`. |
| `CLAB_BASTION_LAB_IFACE` / `OPENPE_BASTION_LAB_IFACE` | `eth1` | Legacy single-NIC fallback for toswitch1 when `CLAB_BASTION_LAB_IFACE_TOSWITCH1` is unset. |
| `CLAB_BASTION_ATTACH_LAB_IFACE` / `OPENPE_BASTION_ATTACH_LAB_IFACE` | `true` | Enslave lab NICs onto the `toswitch*` bridges. |
| `CLAB_RUNTIME` / `OPENPE_CLAB_RUNTIME` | `docker` | containerlab runtime for deploy/teardown. |
| `CONTAINER_RUNTIME` | follows `OPENPE_CLAB_RUNTIME` / `CLAB_RUNTIME` / `docker` | Runtime binary (or wrapper) passed to Ginkgo e2etests. |
| `CLAB_EXECUTOR` | `local` | `local` runs clab on this host; remote bastion SSH vars are unused when `local`. |
| `OPENPE_BASTION_SKIP_SRV6_SETUP` | `true` | Skip leafSRV6 / hostSRV6_* setup on bastion. |
| `OPENPE_E2E_NAMESPACE` | `openshift-openperouter` | OpenPE namespace for prereqs and tests. |
| `FRRK8S_NAMESPACE` | `openshift-frr-k8s` | FRR-K8s namespace (prerequisite wait). |
| `FRRK8S_SELECTOR` | `app=frr-k8s` | Pod label selector for readiness. |
| `FRRK8S_TIMEOUT` | `5m` | Wait timeout for FRR-K8s create/Ready. |
| `OPENPE_E2E_BASTION_PHASE` | `all` | `all` \| `prereqs` \| `fabric` for `deploy-bastion.sh`. |
| `OPENPE_E2E_FOCUS` | unset (full suite) | Ginkgo `--focus` (e.g. `Single.Session.Baseline`). |
| `OPENPE_E2E_SKIP` | unset (+ built-in excludes) | Extra Ginkgo `--skip` patterns. |
| `OPENPEROUTER_DATAPATH` | unset (`kernel`) | Set to `grout` to pass `--groutmode` and grout label filters. |
| `OPENPE_E2E_TEARDOWN_WORKER_NET` | `true` | Tear down worker underlay ownership on EXIT (`false` skips). |
| `OPENPE_E2E_SKIP_TEARDOWN` | `false` | Skip all EXIT cleanup (worker-net + clab). |
| `OPENPE_E2E_WORKER_NET_IFACE_WAIT_SECS` | `60` | Wait for underlay NIC back in host netns during teardown. |
| `OPENPE_E2E_WORKER_NET_DEBUG_TIMEOUT` | `120s` | `timeout(1)` for `oc debug` during worker-net teardown. |

### Local `registry` (Podman) override

Docker remains the default. On a RHEL bastion that already runs Podman (e.g. disconnected registry), pass the three required values plus:

```bash
make e2e-bastion \
  OPENPE_KUBECONFIG=/path/to/ocp/kubeconfig \
  OPENPE_UNDERLAY_IFACE=ens1f0.173 \
  OPENPE_UNDERLAY_IFACE2=ens1f1.174 \
  CLAB_RUNTIME=podman \
  OPENPE_CLAB_RUNTIME=podman \
  CONTAINER_RUNTIME=/absolute/path/to/openperouter/openshift/e2e/podman-root.sh
```

`CLAB_RUNTIME` / `OPENPE_CLAB_RUNTIME` select Podman for containerlab. `CONTAINER_RUNTIME` must be the **absolute** path to `openshift/e2e/podman-root.sh` so Ginkgo sees the same rootful peers that `sudo podman` created. A local wrapper outside the repo can export these and call `make e2e-bastion`.

### Lifecycle

1. `deploy-bastion.sh` → verify OpenPE + wait for FRR-K8s readiness, then set up bridges and containerlab
2. `configure-bastion-worker-net.sh` → worker underlay IPs (`OPENPE_UNDERLAY_IFACE*`)
3. `run_tests-bastion.sh` → Ginkgo (optional `OPENPE_E2E_FOCUS` / `OPENPE_E2E_SKIP`)
4. EXIT (unless `OPENPE_E2E_SKIP_TEARDOWN=true`): worker-net → `teardown-clab.sh`

Step by step (same three required values):

```bash
export KUBECONFIG=/path/to/ocp/kubeconfig
export OPENPE_UNDERLAY_IFACE=ens1f0.173
export OPENPE_UNDERLAY_IFACE2=ens1f1.174

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
| `bastion.env.example` | Optional reference template (not required to source) |
| `podman-root.sh` | Optional rootful podman wrapper for Ginkgo |
