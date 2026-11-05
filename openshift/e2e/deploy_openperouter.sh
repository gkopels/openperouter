set -euo pipefail

echo "=== Patching OpenPerouter CSV to set GROUT_TEST_MODE, GROUT_MAX_MTU and GROUT_TAP_UNDERLAY  ==="
echo "Needed until https://github.com/openperouter/openperouter/issues/866 is fixed"

CSV_NAME=$(oc get csv -n openshift-openperouter -o jsonpath='{.items[0].metadata.name}')
echo "Found CSV: $CSV_NAME"

mkdir -p /tmp/kind_logs/clusterserviceversions
CSV_FILE=/tmp/kind_logs/clusterserviceversions/csv.yaml
oc get csv "$CSV_NAME" -n openshift-openperouter -o yaml > "$CSV_FILE"
cp "$CSV_FILE" /tmp/kind_logs/clusterserviceversions/original.yaml

sed -i '/name: GROUT_TEST_MODE/{n;s|value: "false"|value: "true"|}' "$CSV_FILE"
sed -i '/name: GROUT_TAP_UNDERLAY/{n;s|value: "false"|value: "true"|}' "$CSV_FILE"
sed -i '/name: GROUT_MAX_MTU/{n;s|value: "0"|value: "9500"|}' "$CSV_FILE"

oc replace -f "$CSV_FILE"

# Create OpenPERouter CR
cat <<EOF | oc apply -f -
apiVersion: network.openperouter.io/v1alpha1
kind: OpenPERouter
metadata:
  name: openperouter
  namespace: openshift-openperouter
spec:
  logLevel: debug
  datapath: ${OPENPEROUTER_DATAPATH:-kernel}
EOF

# Wait for controller and router daemonsets to be created and rolled out
for ds in controller router; do
  echo "Waiting for daemonset $ds to be created..."
  oc wait --for=create daemonset/"$ds" -n openshift-openperouter --timeout=300s
  oc rollout status daemonset/"$ds" -n openshift-openperouter --timeout=300s
done

echo "=== Deploy verification ==="
oc get pods -n openshift-openperouter -o wide
oc get daemonset -n openshift-openperouter

# Verify all pods are Running and Ready
NOT_READY=$(oc get pods -n openshift-openperouter --no-headers | grep -v "Completed" | grep -v "1/1\|2/2\|3/3\|4/4\|5/5" || true)
if [ -n "$NOT_READY" ]; then
  echo "ERROR: Some pods are not fully ready:"
  echo "$NOT_READY"
  exit 1
fi

echo "All openperouter pods are running and ready"
