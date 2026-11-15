#!/usr/bin/env bash
# Provision the Skopos Prometheus/Tempo datasources and dashboards in the
# host's Grafana instance.
set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/.local/bin:$PATH"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/k0s-lab.conf}"

GATEWAY_IP="$(kubectl -n observability get svc skopos-gateway -o jsonpath='{.spec.clusterIP}')"
GATEWAY_URL="http://${GATEWAY_IP}:8080"

for cmd in kubectl curl sed jq; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "missing required command: $cmd" >&2
    exit 1
  }
done

sudo -n true || {
  echo "passwordless sudo is required" >&2
  exit 1
}

echo "==> Checking Skopos gateway at $GATEWAY_URL"
curl -fsS --max-time 5 "$GATEWAY_URL/healthz" >/dev/null

echo "==> Installing Grafana datasources"
sed "s|__SKOPOS_GATEWAY_URL__|$GATEWAY_URL|g" \
  "$LAB_DIR/grafana/skopos-datasource.yaml" \
  | sudo tee /etc/grafana/provisioning/datasources/skopos.yaml >/dev/null
sudo chown root:grafana /etc/grafana/provisioning/datasources/skopos.yaml
sudo chmod 0640 /etc/grafana/provisioning/datasources/skopos.yaml

echo "==> Installing Grafana dashboard provider"
sudo install -m 0640 -o root -g grafana \
  "$LAB_DIR/grafana/skopos-dashboards.yaml" \
  /etc/grafana/provisioning/dashboards/skopos.yaml

echo "==> Installing Skopos dashboards"
sudo install -d -o root -g grafana -m 0755 /var/lib/grafana/dashboards/skopos
sudo install -m 0640 -o root -g grafana -t /var/lib/grafana/dashboards/skopos \
  "$LAB_DIR"/grafana/dashboards/*.json

if [ -f /etc/alloy/config.alloy ] && command -v alloy >/dev/null 2>&1; then
  if ! sudo grep -q 'prometheus.scrape "skopos_gateway"' /etc/alloy/config.alloy; then
    echo "==> Adding Skopos gateway scrape to Alloy"
    backup="/etc/alloy/config.alloy.bak-skopos-$(date +%Y%m%d-%H%M%S)"
    sudo cp /etc/alloy/config.alloy "$backup"
    sed "s|__ADDRESS__|${GATEWAY_IP}:8080|" \
      "$LAB_DIR/grafana/alloy-skopos-scrape.alloy" \
      | sudo tee -a /etc/alloy/config.alloy >/dev/null
    if ! sudo alloy fmt /etc/alloy/config.alloy >/dev/null; then
      sudo cp "$backup" /etc/alloy/config.alloy
      echo "Alloy config is invalid; restored $backup" >&2
      exit 1
    fi
    if ! sudo systemctl reload alloy; then
      sudo cp "$backup" /etc/alloy/config.alloy
      sudo systemctl reload alloy || sudo systemctl restart alloy
      echo "Alloy reload failed; restored $backup" >&2
      exit 1
    fi
  fi
fi

echo "==> Restarting Grafana"
sudo systemctl restart grafana-server

for _ in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:3001/api/health >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
curl -fsS http://127.0.0.1:3001/api/health

if command -v sqlite3 >/dev/null 2>&1; then
  echo
  echo "==> Grafana datasources"
  sudo sqlite3 /var/lib/grafana/grafana.db \
    "select name, type, url from data_source where uid like 'skopos-%';"
  echo "==> Grafana dashboards"
  sudo sqlite3 /var/lib/grafana/grafana.db \
    "select name from resource where \"group\"='dashboard.grafana.app' and name in ('skopos-overview','obi-red','skopos-tempo-dashboard');"
  echo "==> Gateway metrics in Mimir"
  curl -sS 'http://127.0.0.1:9009/prometheus/api/v1/query?query=skopos_build_info' \
    | jq -r '.data.result[]? | "\(.metric.__name__){job=\(.metric.job)}"' 2>/dev/null || true
fi

echo
echo "Grafana:"
echo "  URL:        https://monitoring.jawara.cloud (or http://127.0.0.1:3001)"
echo "  Datasource: Skopos Prometheus"
echo "  Traces:     Explore -> Skopos Tempo"
echo "  Dashboards: Dashboards -> Skopos"
