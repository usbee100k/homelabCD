#!/usr/bin/env bash


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


kubernetesVersion: ${KUBERNETES_VERSION}


controlPlaneEndpoint: "${VIP_ADDRESS}:6443"


networking:

  podSubnet: ${POD_SUBNET}

  serviceSubnet: ${SERVICE_SUBNET}


EOF


log_ok "Generated kubeadm configuration."

}