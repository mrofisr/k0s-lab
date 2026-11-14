# Cloudflare → Caddy → Istio wildcard

Goal: route `*.cluster.jawara.cloud` through Cloudflare and Caddy into the k0s
Istio ingress, without exposing the cluster API or NodePorts to the internet.

## Current facts

| Item | Value |
| --- | --- |
| k0s node | `10.0.0.81` (RFC1918) |
| Public origin | `158.178.238.132` |
| `jawara.cloud` DNS | Cloudflare nameservers |
| `*.cluster.jawara.cloud` | DNS-only CNAME → `ns2.jawara.cloud` → `158.178.238.132` |
| Cloudflare proxy for this wildcard | disabled (DNS-only) |
| Caddy certificate | Let's Encrypt wildcard, active |
| Cert renewal | `certbot.timer` + `/usr/local/sbin/cluster-cert-deploy.sh` |
| Cloudflare edge certificate | not used for this wildcard |
| Local Oracle VCN resolver | `169.254.169.254`; caches negative answers |
| Caddy | active on `*:80` and `*:443` |
| k0s API `6443` from public IP | closed |
| NodePorts `30080`/`30443` from public IP | closed |
| Caddy DNS plugin | none (`dns.providers.cloudflare` not built in) |
| On-demand TLS ask endpoint | `127.0.0.1:8090` is down |

The public-origin checks above used the host's public IP. Only Caddy `80`/`443`
answered. The k0s API is additionally rejected by the host INPUT chain, and the
Cilium NodePorts are reachable on the LAN but not from the public IP.

## Selected $0 path: DNS-only + Let's Encrypt

The chosen path is live:

- Cloudflare record: `CNAME *.cluster → ns2.jawara.cloud`, proxy **off**.
- `ns2.jawara.cloud` is an A record to `158.178.238.132`.
- Caddy serves a Let's Encrypt ECDSA certificate:
  ```text
  CN=*.cluster.jawara.cloud
  SAN: *.cluster.jawara.cloud, cluster.jawara.cloud
  expires: 2027-02-12
  ```
- `caddy/cluster-wildcard-dns-only.caddy` proxies to `10.0.0.81:30080`.
- `certbot.timer` renews the certificate; the deploy hook copies it to
  `/etc/caddy/certs/cluster-le.{pem,key}` and reloads Caddy.

Install/renew with:

```sh
cd "$HOME/Documents/projects/k0s-lab"
./scripts/install-cluster-cert.sh
```

The Cloudflare API token is stored only at
`/etc/letsencrypt/cloudflare.ini` (root, 0600). It needs:

```text
Zone -> DNS -> Edit
Zone -> Zone -> Read
```

Tradeoff: Cloudflare proxy/WAF is bypassed for this wildcard; clients resolve
the origin IP directly. The k0s API `6443` and NodePorts `30080`/`30443` remain
closed to the internet; only Caddy `443` is exposed.

On this host `systemctl reload caddy` fails with a systemd `PrivateTmp`
namespace error. The deploy hook and install script use:

```sh
caddy reload --config /etc/caddy/Caddyfile --force
```

which reloads through Caddy's admin API and works.

## Critical Cloudflare edge certificate limit

Cloudflare's current Universal SSL certificate for this zone contains:

```text
DNS:jawara.cloud
DNS:*.jawara.cloud
```

`*.jawara.cloud` matches one label. It does **not** match
`whoami.cluster.jawara.cloud`. A forced TLS handshake to the Cloudflare edge
with that SNI fails:

```text
sslv3 alert handshake failure
SSL alert number 40
```

This means a proxied `*.cluster.jawara.cloud` record cannot serve HTTPS clients
until Cloudflare has an edge certificate for the second-level wildcard. An
Origin CA certificate at Caddy does not fix the client-facing handshake.

The selected DNS-only path above avoids this limit entirely: Cloudflare is used
only for DNS, and Caddy terminates a publicly trusted wildcard certificate.

The wildcard record is now live at Cloudflare and resolves to the proxy IPs
from the authoritative nameservers. The remaining blocker is the edge
certificate. The record shape in the `jawara.cloud` zone is:

```text
Type: A
Name: *.cluster          # dashboard shows *.cluster.jawara.cloud
Content: 158.178.238.132
Proxy: Proxied
```

Entering the full `*.cluster.jawara.cloud` as the record name in the
`jawara.cloud` zone creates the wrong name. A separate `cluster.jawara.cloud`
zone would need NS delegation from `jawara.cloud`.

The host's `systemd-resolved` uses the Oracle VCN resolver
`169.254.169.254`, which can keep the old NXDOMAIN answer for a while. Verify
DNS with `dig @1.1.1.1 whoami.cluster.jawara.cloud`; a "could not resolve"
error on the host is a cache issue, not a Cloudflare failure.

### Options

1. **Advanced Certificate Manager / Total TLS.** Enable an edge certificate
   for `*.cluster.jawara.cloud` and `cluster.jawara.cloud`. This is the cleanest
   way to keep Cloudflare proxied. Availability depends on the Cloudflare plan.
2. **Single-level hostname.** Use a name Universal SSL already covers, such as
   `cluster.jawara.cloud` with path-based routing, or
   `whoami-cluster.jawara.cloud`. No ACM needed.
3. **DNS-only + origin wildcard certificate.** Set `*.cluster` to DNS-only and
   terminate TLS at Caddy with a publicly trusted wildcard certificate for
   `*.cluster.jawara.cloud` (ACME DNS-01 with a Cloudflare API token, or a
   custom Caddy build with the Cloudflare DNS plugin). This bypasses the edge
   certificate but exposes the origin IP and loses Cloudflare proxy protection.
4. **Cloudflare for SaaS / custom hostname certificate.** Use a custom hostname
   and certificate for `*.cluster.jawara.cloud`; typically a paid feature.

A Cloudflare Tunnel does **not** bypass this limit: the public hostname still
needs a Cloudflare edge certificate.

## Traffic shape

```text
client
  │ HTTPS
  ▼
Cloudflare edge (TLS)
  │ tunnel or proxied origin
  ▼
Caddy on the host
  │ HTTP to 10.0.0.81:30080, Host preserved
  ▼
Istio ingress gateway
  │ Gateway/VirtualService host *.cluster.jawara.cloud
  ▼
whoami.demo.svc.cluster.local (ambient, HBONE)
```

Caddy terminates or receives TLS; the hop from Caddy to Istio is plain HTTP on
the private host network. The Istio Gateway `cluster-wildcard` listens on HTTP
port 80; the ingress service maps it to NodePort `30080`.

## DNS wildcard and sub-subdomains

`*.cluster.jawara.cloud` matches **one** label:

```text
whoami.cluster.jawara.cloud      yes
a.b.cluster.jawara.cloud         no
```

DNS wildcards are single-label. Cloudflare does not give you an automatic
`*.*.cluster.jawara.cloud`. Caddy and Istio can route any Host header that
reaches them, but DNS must resolve that name first.

Options for nested names:

- Add a wildcard per level, e.g. `*.apps.cluster.jawara.cloud`.
- Add explicit records for each nested host.
- Keep one label per tenant: `<tenant>.cluster.jawara.cloud`.
- Put the tenant in the path instead of the hostname.

## Path A: Cloudflare Tunnel

Cloudflare terminates TLS and `cloudflared` connects to Caddy on localhost. The
origin needs no Origin CA certificate and no public NodePort.

This still requires a Cloudflare edge certificate for
`*.cluster.jawara.cloud`; the tunnel avoids origin exposure but not the edge
certificate limit. Enable Total TLS/ACM first if you use this path.

1. Install and authenticate `cloudflared`.
2. Create a tunnel and route the wildcard DNS name:

   ```sh
   cloudflared tunnel login
   cloudflared tunnel create k0s-lab
   cloudflared tunnel route dns k0s-lab '*.cluster.jawara.cloud'
   ```

3. Point the tunnel ingress at Caddy:

   ```yaml
   tunnel: <tunnel-id>
   credentials-file: /home/ubuntu/.cloudflared/<tunnel-id>.json
   ingress:
     - hostname: "*.cluster.jawara.cloud"
       service: http://localhost:80
     - service: http_status:404
   ```

4. Install `caddy/cluster-wildcard-tunnel.caddy` as
   `/etc/caddy/sites/cluster-wildcard.caddy`, validate, and reload Caddy.

This is the most private option: the hostname is reachable only through the
tunnel, and the Caddy site accepts only `127.0.0.1`/`::1`.

## Path B: Proxied DNS + Origin CA

Cloudflare proxies the wildcard to the origin and validates a Cloudflare Origin
CA certificate. This requires an edge certificate for
`*.cluster.jawara.cloud`; without ACM/Total TLS the client-facing handshake
fails before Caddy is reached.

1. Add the proxied record:

   ```text
   A  *.cluster  158.178.238.132  Proxied
   ```

2. Create an Origin CA certificate for:

   ```text
   *.cluster.jawara.cloud
   cluster.jawara.cloud
   ```

3. Install the certificate and key under `/etc/caddy/certs/`.

4. Install `caddy/cluster-wildcard-origin-ca.caddy`, validate, and reload.

5. Set Cloudflare SSL/TLS to **Full (strict)**.

The template allows only Cloudflare edge IP ranges to use the site. Direct
requests to the origin's `80`/`443` receive `403`. For defense in depth, also
restrict the cloud security list to Cloudflare ranges, or only allow `80`/`443`
from Cloudflare.

## Path C: Single-level hostname fallback

If you do not have ACM/Total TLS, use a name Universal SSL already covers:

```text
cluster.jawara.cloud
whoami-cluster.jawara.cloud
```

`cluster.jawara.cloud` is matched by `*.jawara.cloud`. Use it as one entry point
and route by path in Istio, or use one single-label hostname per app. This
avoids the second-level wildcard certificate problem entirely.

## Why not on-demand TLS?

The global Caddy config has:

```caddyfile
on_demand_tls {
    ask http://127.0.0.1:8090/api/v1/tls-ask
}
```

That endpoint is currently down, so a new on-demand site would fail certificate
issuance. The standard Caddy binary also lacks the Cloudflare DNS provider, so a
DNS-01 wildcard certificate cannot be issued by Caddy itself. Use a tunnel or an
Origin CA certificate.

## Is the cluster fully private?

From the internet, currently yes:

- The node and all pod/service networks are RFC1918.
- The API on `6443` is not reachable from the public IP and is rejected by the
  host INPUT chain.
- NodePorts `30080`/`30443` are not reachable from the public IP.
- Caddy on `80`/`443` is the only public listener.

Caveats:

- Cilium kube-proxy replacement handles NodePorts in BPF, which may bypass host
  iptables. The cloud security list/firewall is the real guard for `30080` and
  `30443`; keep them closed to the internet.
- Caddy's `trusted_proxies` list is for client-IP trust, not access control. It
  does not stop direct requests to the origin.
- If you use Path B, restrict the origin to Cloudflare IPs at the cloud firewall
  and in the Caddy site template.
- A tunnel avoids inbound origin access entirely and is the better choice for a
  private cluster.

## Verification

Before DNS or Caddy changes, the k0s side is already live:

```sh
curl -sS -H 'Host: whoami.cluster.jawara.cloud' http://10.0.0.81:30080/
```

After DNS and TLS:

```sh
curl -I https://whoami.cluster.jawara.cloud
istioctl analyze -n demo
```

The wildcard host should return the whoami headers and the ambient HBONE path
should still be visible in `istioctl ztunnel-config connections`.

## Files

- `istio/cluster-wildcard.yaml` — live Istio Gateway and VirtualService.
- `caddy/cluster-wildcard-tunnel.caddy` — tunnel template.
- `caddy/cluster-wildcard-origin-ca.caddy` — proxied Origin CA template.
- `caddy/README.md` — install steps for both.
