#!/usr/bin/env bash
# Bootstrap the single-node k0s lab from this directory.
set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/.local/bin:$PATH"
export KUBECONFIG="$HOME/.kube/k0s-lab.conf"

K0S_VERSION="v1.36.6+k0s.0"
CILIUM_VERSION="1.20.4"
CERT_MANAGER_VERSION="v1.21.3"
ISTIO_VERSION="1.32.0"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

for cmd in k0sctl kubectl helm istioctl base64 curl; do
  need "$cmd"
done

sudo -n true || {
  echo "passwordless sudo is required for k0sctl, the firewall unit, and /etc/hosts" >&2
  exit 1
}

mkdir -p "$(dirname "$KUBECONFIG")"

echo "==> Host firewall exception"
sudo install -m 0644 "$LAB_DIR/systemd/k0s-lab-firewall.service" \
  /etc/systemd/system/k0s-lab-firewall.service
sudo systemctl daemon-reload
sudo systemctl enable --now k0s-lab-firewall.service

echo "==> k0s $K0S_VERSION"
k0sctl apply --config "$LAB_DIR/config/k0sctl.yaml" --kubeconfig-out "$KUBECONFIG"

# Seed the default kubeconfig when it is missing or has no contexts. This
# makes a plain `kubectl get nodes` work after a fresh install. If the user
# already has contexts there, leave the file alone.
if [ ! -f "$HOME/.kube/config" ] || \
   [ -z "$(KUBECONFIG="$HOME/.kube/config" kubectl config get-contexts -o name 2>/dev/null)" ]; then
  install -m 0600 "$KUBECONFIG" "$HOME/.kube/config"
else
  echo "Existing ~/.kube/config left unchanged; use scripts/env.sh for the lab context."
fi

echo "==> Cilium $CILIUM_VERSION"
helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
helm repo update cilium >/dev/null

had_kube_proxy=false
if kubectl -n kube-system get ds kube-proxy >/dev/null 2>&1; then
  had_kube_proxy=true
fi

helm upgrade --install cilium cilium/cilium --version "$CILIUM_VERSION" \
  --namespace kube-system -f "$LAB_DIR/cilium/values.yaml" \
  --wait --timeout 10m

kubectl wait --for=condition=Ready node --all --timeout=300s
kubectl -n kube-system rollout status ds/cilium --timeout=300s

# The agent reads kubeProxyReplacement at startup. On an upgrade from
# kube-proxy mode the ConfigMap changes but the DaemonSet does not roll
# automatically, so restart it once and wait for KPR to become active.
if ! kubectl -n kube-system exec ds/cilium -- cilium-dbg status 2>/dev/null \
    | grep -q 'KubeProxyReplacement:.*True'; then
  kubectl -n kube-system rollout restart ds/cilium
  kubectl -n kube-system rollout status ds/cilium --timeout=300s
fi

kpr_ready=false
for _ in $(seq 1 60); do
  if kubectl -n kube-system exec ds/cilium -- cilium-dbg status 2>/dev/null \
      | grep -q 'KubeProxyReplacement:.*True'; then
    kpr_ready=true
    break
  fi
  sleep 2
done
if [ "$kpr_ready" != true ]; then
  echo "Cilium kube-proxy replacement did not become active" >&2
  exit 1
fi

# k0s leaves an existing kube-proxy DaemonSet in place when the config is
# switched to disabled. Remove it and its iptables chains only after KPR is
# verified, so service routing never has a gap.
if [ "$had_kube_proxy" = true ] || sudo iptables-save | grep -q 'KUBE-SVC'; then
  kubectl -n kube-system delete ds kube-proxy --ignore-not-found
  kubectl -n kube-system delete cm kube-proxy --ignore-not-found
  kubectl -n kube-system wait --for=delete pod -l k8s-app=kube-proxy --timeout=120s || true

  mkdir -p "$LAB_DIR/backups"
  sudo iptables-save > "$LAB_DIR/backups/iptables-before-kube-proxy-cleanup-$(date +%Y%m%d-%H%M%S).txt"
  sudo sh -c 'iptables-save | grep -v KUBE | iptables-restore'
fi

kubectl -n kube-system rollout status deploy/coredns --timeout=300s
kubectl -n kube-system rollout status deploy/metrics-server --timeout=300s

echo "==> cert-manager $CERT_MANAGER_VERSION"
helm repo add jetstack https://charts.jetstack.io/ >/dev/null 2>&1 || true
helm repo update jetstack >/dev/null
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace --version "$CERT_MANAGER_VERSION" \
  --set crds.enabled=true \
  --set replicaCount=1 \
  --set webhook.replicaCount=1 \
  --set cainjector.replicaCount=1 \
  --wait --timeout 10m

kubectl apply -f "$LAB_DIR/cert-manager/selfsigned-issuer.yaml"
kubectl apply -f "$LAB_DIR/cert-manager/ca-certificate.yaml"
kubectl -n cert-manager wait --for=condition=Ready certificate/lab-ca --timeout=300s
kubectl apply -f "$LAB_DIR/cert-manager/ca-clusterissuer.yaml"
kubectl wait --for=condition=Ready clusterissuer/lab-ca --timeout=300s

echo "==> Istio $ISTIO_VERSION"
istioctl install -y --set profile=default \
  --set values.gateways.istio-ingressgateway.type=NodePort

kubectl -n istio-system patch svc istio-ingressgateway --type=strategic \
  -p '{"spec":{"type":"NodePort","ports":[{"port":80,"nodePort":30080},{"port":443,"nodePort":30443}]}}'
kubectl -n istio-system rollout status deploy/istiod --timeout=300s
kubectl -n istio-system rollout status deploy/istio-ingressgateway --timeout=300s

echo "==> Demo workload and certificate"
kubectl apply -f "$LAB_DIR/istio/demo-namespace.yaml"
kubectl apply -f "$LAB_DIR/apps/whoami.yaml"
kubectl apply -f "$LAB_DIR/cert-manager/demo-certificate.yaml"
kubectl -n istio-system wait --for=condition=Ready certificate/demo-local --timeout=300s

kubectl apply -f "$LAB_DIR/istio/gateway.yaml"
kubectl apply -f "$LAB_DIR/istio/virtualservice.yaml"
kubectl apply -f "$LAB_DIR/istio/peer-authentication.yaml"
kubectl -n demo rollout status deploy/whoami --timeout=300s

echo "==> Host name and public CA certificate"
if ! grep -qE '^[[:space:]]*10\.0\.0\.81[[:space:]]+demo\.local([[:space:]]|$)' /etc/hosts; then
  echo '10.0.0.81 demo.local' | sudo tee -a /etc/hosts >/dev/null
fi
kubectl -n cert-manager get secret lab-ca-key-pair \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > "$LAB_DIR/cert-manager/lab-ca.crt"

echo "==> Smoke test"
kubectl get nodes
for _ in $(seq 1 30); do
  if kubectl top nodes >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
kubectl top nodes

code=""
for _ in $(seq 1 30); do
  code="$(curl --noproxy '*' -sS --cacert "$LAB_DIR/cert-manager/lab-ca.crt" \
    -o /dev/null -w '%{http_code}' https://demo.local:30443/ 2>/dev/null || true)"
  [ "$code" = "200" ] && break
  sleep 2
done
echo "https://demo.local:30443 -> ${code:-no response}"

echo
echo "Lab ready."
echo "  KUBECONFIG=$KUBECONFIG"
echo "  http://demo.local:30080  -> https://demo.local:30443"
echo "  CA certificate: $LAB_DIR/cert-manager/lab-ca.crt"
