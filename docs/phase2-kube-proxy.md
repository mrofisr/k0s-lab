# Phase 2a: replace kube-proxy with Cilium

This is the runbook used to move the lab from Cilium + kube-proxy to Cilium's
eBPF kube-proxy replacement (KPR). Cilium now owns ClusterIP, NodePort,
LoadBalancer, and HostPort service handling. k0s kube-proxy is disabled and
removed.

## Why these settings

| Setting | Reason |
| --- | --- |
| `kubeProxyReplacement: "true"` | Cilium's eBPF datapath handles services |
| `k8sServiceHost` / `k8sServicePort` | The agent reaches the API directly once kube-proxy is gone |
| `socketLB.hostNamespaceOnly: true` | Keeps socket load balancing out of pod namespaces; required for Istio redirection |
| `cni.exclusive: false` | Allows the Istio CNI plugin to chain with Cilium later |
| `bpf.masquerade: false` | Istio ambient does not support Cilium BPF masquerading; iptables masquerading remains |
| `routingMode: tunnel` | The existing VXLAN mode is supported by KPR |

## Before you start

Snapshot the state so you can roll back:

```sh
cd "$HOME/k0s-lab"
mkdir -p backups
helm get values cilium -n kube-system -o yaml > backups/cilium-values-before-kpr.yaml
kubectl -n kube-system get ds kube-proxy -o yaml > backups/kube-proxy-ds.yaml
kubectl -n kube-system get cm kube-proxy -o yaml > backups/kube-proxy-cm.yaml
kubectl get svc -A -o yaml > backups/services-before-kpr.yaml
kubectl -n kube-system exec ds/cilium -- cilium-dbg status > backups/cilium-status-before-kpr.txt
sudo iptables-save > backups/iptables-before-kpr.txt
```

Expect existing connections to break during the switch: Cilium and kube-proxy
maintain independent NAT state. This is a lab, so the demo traffic can be
recreated. The API server stays reachable at `10.0.0.81:6443`; Cilium uses that
direct endpoint, not the Kubernetes service IP.

## Steps

### 1. Enable Cilium KPR while kube-proxy is still running

`cilium/values.yaml` already contains the settings. Apply them:

```sh
helm upgrade --install cilium cilium/cilium --version 1.20.4 \
  --namespace kube-system -f cilium/values.yaml --wait --timeout 10m
```

### 2. Restart the Cilium agent

The agent reads `kubeProxyReplacement` at startup. A Helm value change does not
always roll the DaemonSet:

```sh
kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system rollout status ds/cilium --timeout=300s
```

### 3. Verify KPR before removing kube-proxy

```sh
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep KubeProxyReplacement
```

Expected:

```text
KubeProxyReplacement:    True   [enp0s6 ... (Direct Routing)]
```

Also check the ConfigMap:

```sh
kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.kube-proxy-replacement}'
kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.bpf-lb-sock-hostns-only}'
kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.cni-exclusive}'
```

All three should be `true`, `true`, and `false`, respectively.

Test at least:

- pod to `kubernetes.default.svc:443`;
- pod DNS resolution;
- a ClusterIP HTTP service;
- NodePort `30080` and `30443`;
- `kubectl top nodes` and `kubectl logs`.

Do not remove kube-proxy until those pass.

### 4. Disable kube-proxy in k0s

In `config/k0sctl.yaml`:

```yaml
network:
  kubeProxy:
    disabled: true
```

Apply:

```sh
k0sctl apply --config config/k0sctl.yaml \
  --kubeconfig-out "$HOME/.kube/k0s-lab.conf"
```

k0s restarts the controller. The API is briefly unavailable, then returns.

### 5. Remove the leftover kube-proxy DaemonSet

k0s does not delete an already-running kube-proxy DaemonSet when the config
switches to disabled:

```sh
kubectl -n kube-system delete ds kube-proxy
kubectl -n kube-system delete cm kube-proxy --ignore-not-found
kubectl -n kube-system wait --for=delete pod -l k8s-app=kube-proxy --timeout=120s
```

### 6. Remove kube-proxy iptables chains

Back up first, then remove every line containing `KUBE`:

```sh
sudo iptables-save > backups/iptables-before-kube-proxy-cleanup.txt
sudo sh -c 'iptables-save | grep -v KUBE | iptables-restore'
```

This removes `KUBE-SERVICES`, `KUBE-SVC-*`, `KUBE-SEP-*`, and
`KUBE-NODEPORTS`. Kubelet may recreate the harmless `KUBE-FIREWALL` and
`KUBE-KUBELET-CANARY` chains.

### 7. Verify the final state

```sh
kubectl -n kube-system get ds kube-proxy        # NotFound
sudo iptables-save | grep -E 'KUBE-SVC|KUBE-SERVICES|KUBE-NODEPORTS'  # empty
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep KubeProxyReplacement
kubectl -n kube-system exec ds/cilium -- cilium-dbg service list | grep -E '10.96.0.1|30080|30443'
kubectl top nodes
curl -I http://demo.local:30080
curl --cacert cert-manager/lab-ca.crt https://demo.local:30443/
```

## Rollback

If service routing is broken, restore kube-proxy first:

1. Set `spec.network.kubeProxy.disabled: false` in `config/k0sctl.yaml`.
2. `k0sctl apply --config config/k0sctl.yaml --kubeconfig-out "$HOME/.kube/k0s-lab.conf"`.
3. Wait for the kube-proxy DaemonSet and its iptables chains to return.
4. Set `kubeProxyReplacement: "false"` in `cilium/values.yaml`, run
   `helm upgrade --install cilium ...`, and restart the Cilium DaemonSet.
5. Verify `KubeProxyReplacement: False` and service traffic.

Keep `cni.exclusive: false` and `bpf.masquerade: false` if you plan to continue
to Istio ambient later; they do not hurt the kube-proxy path.

## Notes

- `kubeProxyReplacement: "true"` requires the kernel features Cilium checks at
  startup. Kernel 7.0 on this host is sufficient.
- Cilium KPR supports the existing VXLAN tunnel mode; native routing is not
  required for this lab.
- The k0s `kubeProxy.disabled` setting prevents k0s from installing
  kube-proxy, but it does not clean up an existing installation.
- Never delete kube-proxy before `KubeProxyReplacement: True`; that creates a
  service-routing gap.
