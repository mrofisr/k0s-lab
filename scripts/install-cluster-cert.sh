#!/usr/bin/env bash
# Issue the free Let's Encrypt wildcard certificate for
# *.cluster.jawara.cloud and install the DNS-only Caddy site.
#
# Requires a Cloudflare API token with:
#   Zone -> DNS -> Edit
#   Zone -> Zone -> Read
# scoped to the jawara.cloud zone.
set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERT_NAME="cluster-jawara-cloud"
CF_INI="/etc/letsencrypt/cloudflare.ini"
ORIGIN_IP="158.178.238.132"
DOMAIN="jawara.cloud"
WILDCARD="*.cluster.jawara.cloud"
DEPLOY_HOOK="/usr/local/sbin/cluster-cert-deploy.sh"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

for cmd in certbot curl dig jq; do
  need "$cmd"
done

sudo -n true || {
  echo "passwordless sudo is required" >&2
  exit 1
}

if ! certbot plugins 2>/dev/null | grep -q 'dns-cloudflare'; then
  echo "==> Installing certbot Cloudflare DNS plugin"
  sudo apt-get update -qq
  sudo apt-get install -y python3-certbot-dns-cloudflare
fi

if ! sudo test -s "$CF_INI"; then
  cat <<'EOF'
Create a Cloudflare API token:
  Dashboard -> My Profile -> API Tokens -> Create Token -> Custom token
  Permissions:
    Zone -> DNS -> Edit
    Zone -> Zone -> Read
  Zone Resources:
    Include -> Specific zone -> jawara.cloud

The token is stored only in /etc/letsencrypt/cloudflare.ini (root, 0600).
EOF
  read -rsp "Cloudflare API token: " token
  echo
  sudo install -d -o root -g root -m 0700 /etc/letsencrypt
  printf 'dns_cloudflare_api_token = %s\n' "$token" | sudo tee "$CF_INI" >/dev/null
  sudo chmod 600 "$CF_INI"
  unset token
fi

token="$(sudo sed -n 's/^dns_cloudflare_api_token[[:space:]]*=[[:space:]]*//p' "$CF_INI" | head -n1)"
if [ -z "$token" ]; then
  echo "could not read dns_cloudflare_api_token from $CF_INI" >&2
  exit 1
fi

echo "==> Looking up the Cloudflare zone"
zone_id="$(curl -sS -H "Authorization: Bearer $token" \
  "https://api.cloudflare.com/client/v4/zones?name=$DOMAIN" \
  | jq -r '.result[0].id // empty')"
if [ -z "$zone_id" ]; then
  echo "could not find zone $DOMAIN; check Zone:Zone:Read on the token" >&2
  exit 1
fi

echo "==> Finding $WILDCARD"
# The record may be an A record or a CNAME; match by name only.
record_id="$(curl -sS -G -H "Authorization: Bearer $token" \
  --data-urlencode "name=$WILDCARD" \
  "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" \
  | jq -r '.result[0].id // empty')"
if [ -z "$record_id" ]; then
  echo "DNS record $WILDCARD was not found in $DOMAIN" >&2
  exit 1
fi

echo "==> Setting $WILDCARD to DNS-only"
curl -sS -X PATCH \
  -H "Authorization: Bearer $token" \
  -H "Content-Type: application/json" \
  --data '{"proxied":false}' \
  "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id" \
  | jq -e '.success' >/dev/null

for _ in $(seq 1 30); do
  ip="$(dig @1.1.1.1 +short A whoami.cluster.jawara.cloud | tail -n1)"
  [ "$ip" = "$ORIGIN_IP" ] && break
  sleep 2
done
echo "whoami.cluster.jawara.cloud -> ${ip:-no answer}"

echo "==> Installing the certbot deploy hook"
sudo install -m 0755 "$LAB_DIR/scripts/cluster-cert-deploy.sh" "$DEPLOY_HOOK"

echo "==> Issuing the wildcard certificate"
sudo certbot certonly --dns-cloudflare \
  --dns-cloudflare-credentials "$CF_INI" \
  --dns-cloudflare-propagation-seconds 30 \
  --cert-name "$CERT_NAME" \
  -d "$WILDCARD" -d "cluster.$DOMAIN" \
  --non-interactive --agree-tos --email "admin@$DOMAIN" \
  --deploy-hook "$DEPLOY_HOOK"

# certbot exits successfully without running the deploy hook when the
# certificate is not yet due for renewal. Copy the current cert explicitly.
if [ -f "/etc/letsencrypt/live/$CERT_NAME/fullchain.pem" ]; then
  sudo "$DEPLOY_HOOK"
fi

echo "==> Installing the DNS-only Caddy site"
if [ -f /etc/caddy/sites/cluster-wildcard.caddy ]; then
  sudo cp /etc/caddy/sites/cluster-wildcard.caddy \
    "/etc/caddy/sites/cluster-wildcard.caddy.bak-$(date +%Y%m%d-%H%M%S)"
fi
sudo install -m 0644 "$LAB_DIR/caddy/cluster-wildcard-dns-only.caddy" \
  /etc/caddy/sites/cluster-wildcard.caddy
sudo caddy validate --config /etc/caddy/Caddyfile
sudo caddy reload --config /etc/caddy/Caddyfile --force

echo "==> Testing"
curl -sS -I --resolve "whoami.cluster.jawara.cloud:443:$ORIGIN_IP" \
  "https://whoami.cluster.jawara.cloud/" | head -5

echo
echo "Wildcard certificate installed; Cloudflare record is DNS-only."
echo "Test:"
echo "  curl -sS --resolve whoami.cluster.jawara.cloud:443:$ORIGIN_IP https://whoami.cluster.jawara.cloud/"
