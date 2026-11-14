#!/usr/bin/env bash
# Install the published Skopos alpha on the k0s lab.
set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/.local/bin:$PATH"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/k0s-lab.conf}"

SKOPOS_VERSION="0.0.1-alpha"
CHART="oci://ghcr.io/mrofisr/charts/skopos"
LOCAL_PATH_VERSION="v0.0.37"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

for cmd in kubectl helm curl; do
  need "$cmd"
done

# k0s has no default StorageClass. Skopos needs a 50Gi ClickHouse volume and a
# 5Gi collector queue, so install the same local-path provisioner k3s uses.
if ! kubectl get storageclass local-path >/dev/null 2>&1; then
  echo "==> Installing local-path provisioner $LOCAL_PATH_VERSION"
  curl -sSfL "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_VERSION}/deploy/local-path-storage.yaml" \
    | kubectl apply -f -
  kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=180s
fi

if ! kubectl get storageclass 2>/dev/null | grep -q '(default)'; then
  kubectl patch storageclass local-path \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
fi

if [ ! -f "$LAB_DIR/skopos/values.release.yaml" ]; then
  echo "==> Fetching release values"
  curl -sSfL "https://github.com/mrofisr/skopos/releases/download/v${SKOPOS_VERSION}/values.release.yaml" \
    -o "$LAB_DIR/skopos/values.release.yaml"
fi

# Do not add --wait or --wait-for-jobs here. The ClickHouse schema/user init is
# a post-install hook, but the gateway readiness probe depends on the user that
# hook creates. --wait deadlocks: it waits for the gateway before running the
# hook. Helm waits for hooks by default, which is the required behavior.
echo "==> Installing Skopos $SKOPOS_VERSION"
helm upgrade --install skopos "$CHART" --version "$SKOPOS_VERSION" \
  --namespace observability --create-namespace \
  -f "$LAB_DIR/skopos/values.release.yaml" \
  -f "$LAB_DIR/skopos/values.k0s.yaml" \
  --timeout 15m

echo "==> Waiting for the data plane"
kubectl -n observability rollout status statefulset/skopos-clickhouse --timeout=300s
kubectl -n observability rollout status statefulset/skopos-collector --timeout=300s
kubectl -n observability rollout status deploy/skopos-gateway --timeout=300s
kubectl -n observability rollout status ds/skopos-obi --timeout=300s

echo "==> Skopos resources"
kubectl -n observability get pods,pvc,jobs

echo
echo "Skopos is installed in namespace observability."
echo "Port-forward and check:"
echo "  kubectl -n observability port-forward svc/skopos-gateway 8080:8080"
echo "  curl -s http://127.0.0.1:8080/readyz"
echo "  curl -s 'http://127.0.0.1:8080/api/v1/query?query=vector(42)'"
