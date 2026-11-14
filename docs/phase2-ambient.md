# Phase 2b: Istio ambient mode

The `demo` namespace now runs in Istio ambient mode. The whoami pod has no
sidecar; ztunnel handles HBONE and mTLS. The ingress gateway remains a classic
Envoy proxy so the existing NodePort and `demo.local` certificate keep working.

## Why this shape

- **No per-pod sidecar.** Ambient moves L4 mTLS and redirection to the node-level
  ztunnel, so the application pod is 1/1.
- **Ingress stays explicit.** The ambient profile does not include
  `istio-ingressgateway`; it must be enabled in the install overlay.
- **Cilium remains the CNI.** Cilium owns pod networking and kube-proxy
  replacement. Istio CNI chains after `cilium-cni` to install ambient
  redirection.
- **Sidecars are still available.** Ambient and sidecar workloads can coexist;
  only namespaces or pods labeled for ambient use ztunnel.

## Preconditions

- Phase 2a complete: Cilium KPR active, k0s kube-proxy removed.
- Cilium values already contain:
  - `cni.exclusive: false`
  - `bpf.masquerade: false`
- `istioctl` 1.32.0.
- Snapshot the sidecar state first:

```sh
cd "$HOME/Documents/projects/k0s-lab"
mkdir -p backups/istio-before-ambient
kubectl -n istio-system get all,cm,sa -o yaml > backups/istio-before-ambient/istio-system-resources.yaml
kubectl get gateway,virtualservice,peerauthentication -A -o yaml > backups/istio-before-ambient/istio-cr.yaml
kubectl -n istio-system get svc istio-ingressgateway -o yaml > backups/istio-before-ambient/ingress-svc.yaml
sudo cat /etc/cni/net.d/05-cilium.conflist > backups/istio-before-ambient/cilium-cni.json
kubectl get ns demo -o yaml > backups/istio-before-ambient/demo-ns.yaml
```

## Install the ambient profile with the ingress gateway

The ambient profile installs Istiod, the CNI node agent, and ztunnel, but **not**
the ingress gateway. Enable it explicitly:

```sh
istioctl install -y --set profile=ambient \
  --set 'components.ingressGateways[0].enabled=true' \
  --set 'components.ingressGateways[0].name=istio-ingressgateway' \
  --set values.gateways.istio-ingressgateway.type=NodePort

kubectl -n istio-system patch svc istio-ingressgateway --type=strategic \
  -p '{"spec":{"type":"NodePort","ports":[{"port":80,"nodePort":30080},{"port":443,"nodePort":30443}]}}'
```

Verify the components:

```sh
kubectl -n istio-system get pods
kubectl -n istio-system get ds istio-cni-node ztunnel
istioctl proxy-status
istioctl ztunnel-config workloads
```

Expected pods: `istiod`, `istio-cni-node`, `ztunnel`, and
`istio-ingressgateway`.

### Verify CNI chaining

```sh
sudo cat /etc/cni/net.d/05-cilium.conflist
```

The `plugins` list must contain both:

```json
{ "type": "cilium-cni" },
{ "type": "istio-cni" }
```

If `istio-cni` is missing, check the CNI agent:

```sh
kubectl -n istio-system logs ds/istio-cni-node
```

Cilium must keep `cni-exclusive: "false"` in its ConfigMap; otherwise it removes
other CNI configuration.

## Switch the demo namespace

Keep the sidecar demo working first. Then switch only this namespace:

```sh
kubectl label namespace demo istio-injection- \
  istio.io/dataplane-mode=ambient --overwrite
kubectl -n demo rollout restart deploy/whoami
kubectl -n demo rollout status deploy/whoami --timeout=180s
```

Verify the pod has no sidecar:

```sh
kubectl -n demo get pod -o wide
kubectl -n demo get pod -o jsonpath='{.items[0].spec.containers[*].name}'
```

Expected: `1/1` and only `whoami`.

Verify ztunnel picked it up:

```sh
istioctl ztunnel-config workloads | grep whoami
```

Expected protocol: `HBONE`.

### Verify traffic and mTLS

```sh
curl -I http://demo.local:30080
curl --cacert cert-manager/lab-ca.crt https://demo.local:30443/
istioctl ztunnel-config connections
```

The HTTPS request returns `200`. The ztunnel connection table shows an inbound
HBONE connection from the ingress gateway to the whoami workload. Ambient does
not add the sidecar's `X-Forwarded-Client-Cert` header; use the ztunnel
connection table as the mTLS evidence.

STRICT mTLS still applies from `istio/peer-authentication.yaml`. A non-mesh pod
calling whoami directly is reset:

```sh
kubectl -n default run ambient-nettest --image=curlimages/curl:8.11.0 \
  --restart=Never --command -- \
  curl -sS --max-time 5 http://whoami.demo.svc.cluster.local/
kubectl -n default logs ambient-nettest
kubectl -n default delete pod ambient-nettest
```

## Rollback

Return only the demo namespace to sidecars:

```sh
kubectl label namespace demo istio.io/dataplane-mode- \
  istio-injection=enabled --overwrite
kubectl -n demo rollout restart deploy/whoami
kubectl -n demo rollout status deploy/whoami
```

The whoami pod returns to 2/2 with `istio-proxy`. The ambient components can
stay installed while sidecar workloads run.

For a full rollback to the default profile:

```sh
istioctl install -y --set profile=default \
  --set values.gateways.istio-ingressgateway.type=NodePort
kubectl -n istio-system patch svc istio-ingressgateway --type=strategic \
  -p '{"spec":{"type":"NodePort","ports":[{"port":80,"nodePort":30080},{"port":443,"nodePort":30443}]}}'
```

This prunes the ambient CNI and ztunnel. Check that the Cilium CNI config no
longer lists `istio-cni`; if it does, restart Cilium so it rewrites the primary
config, then recreate ambient pods only if you re-enable ambient.

## Notes and caveats

- The ambient profile deliberately omits the ingress gateway. Enabling it in
  the same overlay avoids pruning the existing NodePort service.
- `istio-cni` excludes `kube-system`; system pods are not ambient workloads.
- Cilium's BPF masquerading is disabled. Enabling it breaks Istio ambient
  kubelet health checks because Istio uses a link-local SNAT address.
- If you later add a default-deny NetworkPolicy, add the Istio-documented
  `CiliumClusterwideNetworkPolicy` that allows `169.254.7.127/32` host probes.
- Sidecar injection and ambient can coexist. Do not label a namespace with both
  `istio-injection=enabled` and `istio.io/dataplane-mode=ambient`.
- The whoami response no longer includes `X-Forwarded-Client-Cert`; that header
  was added by the sidecar path. The ztunnel HBONE connection is the mTLS
  evidence in ambient mode.
