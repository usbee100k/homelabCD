#!/usr/bin/env bash

set -Eeuo pipefail

generate_kubeadm_config() {

    mkdir -p "${ROOT_DIR}/generated"

    cat > "${ROOT_DIR}/generated/kubeadm-config.yaml" <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration

localAPIEndpoint:
  advertiseAddress: ${LOCAL_IP}
  bindPort: 6443

nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock

---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration

clusterName: ${CLUSTER_NAME}

kubernetesVersion: v${KUBERNETES_VERSION}

controlPlaneEndpoint: "${VIP_ADDRESS}:6443"

networking:
  podSubnet: ${POD_SUBNET}
  serviceSubnet: ${SERVICE_SUBNET}
  dnsDomain: ${DNS_DOMAIN}

proxy:
  disabled: true

EOF

    log_ok "Generated kubeadm configuration."

}