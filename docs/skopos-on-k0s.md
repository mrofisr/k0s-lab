# Skopos on k0s

The published Skopos `v0.0.1-alpha` chart is installed in the `observability`
namespace on this k0s cluster.

```text
chart:        oci://ghcr.io/mrofisr/charts/skopos:0.0.1-alpha
chart digest: sha256:c7fa544002b22c84908af53a6927b21937025f47e17d73348ca6630632e97cc1
gateway:      sha256:d516587cb9f2b97d4599f6c8f9da1ae97be2575fbd76b9bfde710ae9aec5c709
release:      skopos, revision 2, deployed
```

## Prerequisites

- The k0s lab from this repository is running.
- Cilium is the CNI with kube-proxy replacement active.
- metrics-server works (`kubectl top`).
- A default StorageClass exists, or the install script creates one.

The chart needs a 50 GiB ClickHouse volume and a 5 GiB collector queue. k0s has
no built-in StorageClass, so the lab uses Rancher's local-path provisioner
`v0.0.37`, the same provisioner k3s/k3d uses.

## Install

```sh
cd "$HOME/k0s-lab"
source scripts/env.sh
./scripts/install-skopos.sh
```

Or manually:

```sh
helm upgrade --install skopos oci://ghcr.io/mrofisr/charts/skopos \
  --version 0.0.1-alpha \
  --namespace observability --create-namespace \
  -f skopos/values.release.yaml \
  -f skopos/values.k0s.yaml \
  --timeout 15m
```

### Why there is no `--wait`

The ClickHouse schema and `skopos_gateway` user are created by a
**post-install/post-upgrade Helm hook** (`skopos-clickhouse-init`). The gateway
readiness probe connects to ClickHouse as that user. With `--wait`, Helm waits
for the gateway to become ready before it runs the post-install hook, so the
install deadlocks and fails after the timeout.

Helm waits for hook Jobs by default. Do not add `--wait` or `--wait-for-jobs`
to this chart. After Helm returns, the wrapper script waits for the data plane
explicitly.

## Verify

```sh
kubectl -n observability get pods,pvc,jobs
```

Expected: ClickHouse, collector, gateway, and OBI running; both PVCs Bound; the
init Job Complete.

Gateway:

```sh
kubectl -n observability port-forward svc/skopos-gateway 8080:8080
curl -sS http://127.0.0.1:8080/healthz
curl -sS http://127.0.0.1:8080/readyz
curl -sS http://127.0.0.1:8080/version
curl -sS 'http://127.0.0.1:8080/api/v1/query?query=vector(42)'
```

The alpha NOTES still claim the query APIs are not implemented. That text is
stale: this release serves a working Prometheus query API.

Real OBI telemetry through the gateway:

```sh
curl -sS 'http://127.0.0.1:8080/api/v1/query?query=target_info'
curl -sS 'http://127.0.0.1:8080/api/v1/query?query=http_server_request_duration_count'
curl -sS 'http://127.0.0.1:8080/api/v1/label/__name__/values'
```

At install time the gateway returned `target_info` for both
`istio-ingressgateway` and `whoami`, and
`http_server_request_duration_count{service_name="whoami"}` was populated.

ClickHouse:

```sh
kubectl -n observability exec skopos-clickhouse-0 -- \
  clickhouse-client --query 'SELECT ServiceName, count() FROM otel.otel_traces GROUP BY ServiceName'
```

The first run produced thousands of traces for `istio` and `whoami`, plus HTTP
histograms for request duration and body size.

## OBI findings on k0s

OBI is running and producing traces and metrics, but its log shows several
capability warnings:

```text
error running iterator in netns ... join target netns: operation not permitted
Go context propagation ... missing capability CAP_SYS_ADMIN
tracefs fallback failed ... /sys/kernel/tracing/uprobe_events: permission denied
creating or accessing OTEL namespace in bpffs failed ... /sys/fs/bpf/otel
```

The published chart grants `BPF`, `PERFMON`, `SYS_PTRACE`, `SYS_RESOURCE`,
`NET_RAW`, `DAC_READ_SEARCH`, and `CHECKPOINT_RESTORE`, but not `SYS_ADMIN` or
`DAC_OVERRIDE`. `setns` into target network namespaces and tracefs writes need
the missing capabilities.

This did not stop application traces: OBI instrumented the whoami process and
produced HTTP metrics and spans. A lab-only workaround is to add `SYS_ADMIN` and
`DAC_OVERRIDE` to `obi.securityContext.capabilities.add`; that weakens the
container boundary and should be reviewed before using it outside a lab.

OBI `v1.0.0` also does not understand Go 1.27 binaries (`pilot-discovery`,
`ztunnel`, and other Istio components). It logs `runtime ABI is not generated
for go1.27.3` and falls back to generic instrumentation. That is an OBI version
issue, not a Skopos install failure.

The bpffs warning is a fallback: OBI uses process-internal maps when
`/sys/fs/bpf/otel` is unavailable.

## Compare with the k3d run

| | k3d demo | k0s lab |
| --- | --- | --- |
| CNI / service path | Flannel + kube-proxy | Cilium KPR |
| Storage | k3s local-path | Rancher local-path v0.0.37 |
| Chart / gateway digest | same | same |
| Gateway PromQL | worked | worked |
| ClickHouse schema | created by hook | created by hook |
| OBI netns warnings | yes (nested Docker) | yes (missing `SYS_ADMIN`) |
| OBI traces/metrics | limited by nesting | whoami + istio telemetry present |

The k0s run is a better OBI environment than nested k3d, but the chart's
security context still limits network-namespace capture.

## Uninstall

```sh
helm uninstall skopos -n observability
kubectl -n observability delete pvc data-skopos-clickhouse-0 queue-skopos-collector-0
kubectl delete namespace observability
```

The local-path provisioner can stay for other workloads. Its data lives under
`/opt/local-path-provisioner` on the node; deleting the PVCs removes the
corresponding PVs and data.
