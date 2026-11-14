# Caddy templates for `*.cluster.jawara.cloud`

The live configuration uses the **DNS-only + Let's Encrypt wildcard** template
(`cluster-wildcard-dns-only.caddy`). The other templates are alternatives.

Cloudflare's Universal SSL certificate covers `jawara.cloud` and
`*.jawara.cloud` only. A proxied `*.cluster.jawara.cloud` hostname needs an edge
certificate from Advanced Certificate Manager/Total TLS (or a custom
certificate). The selected DNS-only path avoids that requirement. See
`docs/cloudflare-wildcard.md`.

All templates proxy to the k0s Istio ingress NodePort `10.0.0.81:30080` and
preserve the original `Host` header. The matching Istio Gateway/VirtualService
is `istio/cluster-wildcard.yaml`.

On this host `systemctl reload caddy` fails with a systemd `PrivateTmp`
namespace error. Use the admin API instead:

```sh
sudo caddy validate --config /etc/caddy/Caddyfile
sudo caddy reload --config /etc/caddy/Caddyfile --force
```

## Path A: Cloudflare Tunnel (recommended)

Cloudflare terminates TLS and `cloudflared` connects to Caddy on localhost:80.
No Origin CA certificate and no public NodePort are required for this hostname.

1. Install and authenticate `cloudflared`:

   ```sh
   cloudflared tunnel login
   cloudflared tunnel create k0s-lab
   cloudflared tunnel route dns k0s-lab '*.cluster.jawara.cloud'
   ```

2. Use a tunnel config like:

   ```yaml
   tunnel: <tunnel-id>
   credentials-file: /home/ubuntu/.cloudflared/<tunnel-id>.json
   ingress:
     - hostname: "*.cluster.jawara.cloud"
       service: http://localhost:80
     - service: http_status:404
   ```

3. Install this template:

   ```sh
   sudo cp cluster-wildcard-tunnel.caddy /etc/caddy/sites/cluster-wildcard.caddy
   sudo caddy validate --config /etc/caddy/Caddyfile
   sudo caddy reload --config /etc/caddy/Caddyfile --force
   ```

The template only accepts requests from `127.0.0.1`/`::1`, so direct requests to
the origin's public port 80 receive `403`.

## Path B: Proxied DNS + Cloudflare Origin CA

Cloudflare proxies `*.cluster.jawara.cloud` to the origin's public 80/443 and
validates Caddy's Origin CA certificate in Full (strict) mode.

1. Create the DNS record in Cloudflare:

   ```text
   A  *.cluster  158.178.238.132  Proxied
   ```

2. Create an Origin CA certificate in Cloudflare:
   **SSL/TLS → Origin Server → Create Certificate**, with hostnames:

   ```text
   *.cluster.jawara.cloud
   cluster.jawara.cloud
   ```

3. Install the certificate and key:

   ```sh
   sudo install -d -o root -g caddy -m 0750 /etc/caddy/certs
   sudo install -o root -g caddy -m 0640 cluster-origin.pem /etc/caddy/certs/
   sudo install -o root -g caddy -m 0640 cluster-origin.key /etc/caddy/certs/
   ```

4. Install this template and set Cloudflare SSL/TLS to **Full (strict)**:

   ```sh
   sudo cp cluster-wildcard-origin-ca.caddy /etc/caddy/sites/cluster-wildcard.caddy
   sudo caddy validate --config /etc/caddy/Caddyfile
   sudo caddy reload --config /etc/caddy/Caddyfile --force
   ```

The template allows only Cloudflare edge IP ranges to use the site; direct
requests to the origin receive `403`.

## Selected: DNS-only + Let's Encrypt wildcard

The Cloudflare record is a DNS-only CNAME:

```text
*.cluster.jawara.cloud -> ns2.jawara.cloud
ns2.jawara.cloud       -> 158.178.238.132
```

Run:

```sh
cd "$HOME/Documents/projects/k0s-lab"
./scripts/install-cluster-cert.sh
```

The script:

1. reads the scoped Cloudflare token from
   `/etc/letsencrypt/cloudflare.ini` (or prompts for it);
2. switches `*.cluster` to DNS-only;
3. issues the wildcard certificate with certbot DNS-01;
4. copies it to `/etc/caddy/certs/cluster-le.pem` and `.key`;
5. installs `cluster-wildcard-dns-only.caddy` and reloads Caddy.

Renewal is handled by `certbot.timer` and
`/usr/local/sbin/cluster-cert-deploy.sh`.

Test from a public resolver or with `--resolve`:

```sh
curl -I --resolve whoami.cluster.jawara.cloud:443:158.178.238.132 \
  https://whoami.cluster.jawara.cloud/
```

Tradeoff: Cloudflare proxy/WAF is bypassed for this wildcard; clients reach the
origin IP directly. The k0s API and NodePorts remain closed.

## Notes

- The installed Caddy binary is the standard build and does **not** include the
  `dns.providers.cloudflare` plugin, so `tls { dns cloudflare ... }` will not
  load. Use certbot DNS-01 (the selected path), a tunnel, or an Origin CA
  certificate.
- In the selected path, certbot owns the certificate and renews it; Caddy only
  loads the files at `/etc/caddy/certs/cluster-le.{pem,key}`.
- The global `on_demand_tls` ask endpoint at `http://127.0.0.1:8090` is
  currently down. These templates avoid on-demand TLS entirely.
- The wildcard DNS record matches one label only:
  `whoami.cluster.jawara.cloud` matches, `a.b.cluster.jawara.cloud` does not.
- Local pre-DNS test:

  ```sh
  curl -sS -H 'Host: whoami.cluster.jawara.cloud' http://10.0.0.81:30080/
  ```
