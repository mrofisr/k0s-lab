#!/usr/bin/env bash
# Certbot deploy hook: copy the cluster wildcard certificate into Caddy's
# certificate directory and reload Caddy.
set -euo pipefail

CERT_NAME="cluster-jawara-cloud"
SRC="/etc/letsencrypt/live/${CERT_NAME}"
DST="/etc/caddy/certs"

install -d -o root -g caddy -m 0750 "$DST"
install -o root -g caddy -m 0640 "$SRC/fullchain.pem" "$DST/cluster-le.pem"
install -o root -g caddy -m 0640 "$SRC/privkey.pem" "$DST/cluster-le.key"

# systemctl reload caddy currently fails on this host with a PrivateTmp
# namespace error. Reload through Caddy's admin API instead.
caddy reload --config /etc/caddy/Caddyfile --force
