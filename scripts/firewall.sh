#!/usr/bin/env bash
# Allow the k0s pod CIDR to reach host services.
#
# The host firewall defaults to rejecting INPUT except for 22/80/443/9009.
# Kubernetes needs pods to reach the API server (6443), kubelet (10250),
# Hubble peer (4244), and the Istio control plane. Cilium forwards these
# packets to the host, where they hit INPUT rather than FORWARD.
set -euo pipefail

if ! iptables -C INPUT -s 10.244.0.0/16 -j ACCEPT 2>/dev/null; then
  iptables -I INPUT 1 -s 10.244.0.0/16 -j ACCEPT
fi
