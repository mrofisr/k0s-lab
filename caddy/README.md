# Caddy templates for `*.cluster.jawara.cloud`

These are templates. The live Caddy configuration was deliberately **not**
changed. Install exactly one of them after choosing the Cloudflare path.

Both templates proxy to the k0s Istio ingress NodePort
`10.0.0.81:30080` and preserve the original `Host` header. The matching Istio
Gateway/VirtualService is `istio/cluster-wildcard.yaml`.

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
   sudo systemctl reload caddy
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
   sudo systemctl reload caddy
   ```

The template allows only Cloudflare edge IP ranges to use the site; direct
requests to the origin receive `403`.

## Notes

- The installed Caddy binary is the standard build and does **not** include the
  `dns.providers.cloudflare` plugin, so `tls { dns cloudflare ... }` will not
  load. Use a tunnel or an Origin CA certificate instead.
- The global `on_demand_tls` ask endpoint at `http://127.0.0.1:8090` is
  currently down. These templates avoid on-demand TLS entirely.
- The wildcard DNS record matches one label only:
  `whoami.cluster.jawara.cloud` matches, `a.b.cluster.jawara.cloud` does not.
- Local pre-DNS test:

  ```sh
  curl -sS -H 'Host: whoami.cluster.jawara.cloud' http://10.0.0.81:30080/
  ```
