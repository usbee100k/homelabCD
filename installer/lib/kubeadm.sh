#!/usr/bin/env bash

set -Eeuo pipefail


#############################################
# Install Kubernetes Packages
#############################################

install_kubernetes() {

    log_info "Installing Kubernetes packages"


    apt-get update


    apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gpg


    install -d -m 0755 /etc/apt/keyrings


    curl -fsSL \
        "https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION}/deb/Release.key" \
        | gpg --dearmor \
        -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg


    echo \
"deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION}/deb/ /" \
        > /etc/apt/sources.list.d/kubernetes.list


    apt-get update


    apt-get install -y \
        kubelet \
        kubeadm \
        kubectl


    apt-mark hold \
        kubelet \
        kubeadm \
        kubectl


    systemctl enable kubelet


    log_ok "Kubernetes packages installed."

}



#############################################
# Initialize Kubernetes Control Plane
#############################################

kubeadm_init() {


    log_info "Running kubeadm init"


    kubeadm init \
        --config "${ROOT_DIR}/generated/kubeadm-config.yaml" \
        --upload-certs


    log_ok "Kubernetes control plane initialized."

}