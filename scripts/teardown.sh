#!/usr/bin/env bash
# Remove the k0s lab. Repository files and CLI binaries are kept.
set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/.local/bin:$PATH"
export KUBECONFIG="$HOME/.kube/k0s-lab.conf"

if [[ "${1:-}" != "--yes" ]]; then
  read -r -p "Remove the k0s lab (demo, Istio, cert-manager, Cilium, k0s)? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || {
    echo "aborted"
    exit 1
  }
fi

if timeout 10 kubectl cluster-info >/dev/null 2>&1; then
  echo "==> Demo"
  kubectl delete -f "$LAB_DIR/istio/virtualservice.yaml" --ignore-not-found || true
  kubectl delete -f "$LAB_DIR/istio/gateway.yaml" --ignore-not-found || true
  kubectl delete -f "$LAB_DIR/istio/peer-authentication.yaml" --ignore-not-found || true
  kubectl delete -f "$LAB_DIR/cert-manager/demo-certificate.yaml" --ignore-not-found || true
  kubectl delete -f "$LAB_DIR/apps/whoami.yaml" --ignore-not-found || true
  kubectl delete -f "$LAB_DIR/istio/demo-namespace.yaml" --ignore-not-found || true

  echo "==> Istio"
  istioctl uninstall --purge -y || true

  echo "==> cert-manager"
  helm uninstall cert-manager -n cert-manager || true
  kubectl delete namespace cert-manager --ignore-not-found || true

  echo "==> Cilium"
  helm uninstall cilium -n kube-system || true
else
  echo "==> Cluster is not reachable; skipping in-cluster cleanup"
fi

echo "==> k0s"
k0sctl reset --config "$LAB_DIR/config/k0sctl.yaml" --force || true

echo "==> Host cleanup"
sudo systemctl disable --now k0s-lab-firewall.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/k0s-lab-firewall.service
sudo systemctl daemon-reload

sudo sed -i -E '/^[[:space:]]*10\.0\.0\.81[[:space:]]+demo\.local([[:space:]]|$)/d' /etc/hosts
while sudo iptables -C INPUT -s 10.244.0.0/16 -j ACCEPT 2>/dev/null; do
  sudo iptables -D INPUT -s 10.244.0.0/16 -j ACCEPT
done
sudo rm -f /etc/cni/net.d/05-cilium.conflist

if [ -f "$KUBECONFIG" ] && [ -f "$HOME/.kube/config" ] && \
   cmp -s "$KUBECONFIG" "$HOME/.kube/config"; then
  rm -f "$HOME/.kube/config"
  echo "Removed ~/.kube/config (it was a copy of the lab kubeconfig)."
fi
rm -f "$KUBECONFIG"
rm -f "$LAB_DIR/cert-manager/lab-ca.crt"

echo "Teardown complete. Repository files and ~/.local/bin CLIs were kept."
