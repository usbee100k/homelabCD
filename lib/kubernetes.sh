#!/usr/bin/env bash

install_kubernetes() {

    log_info "Installing Kubernetes ${KUBERNETES_VERSION}..."

    mkdir -p /etc/apt/keyrings

    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key \
        | gpg --dearmor \
        -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

    chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

    cat >/etc/apt/sources.list.d/kubernetes.list <<EOF
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /
EOF

    apt-get update

    apt-get install -y \
        kubelet \
        kubeadm \
        kubectl

    apt-mark hold kubelet kubeadm kubectl

    systemctl enable kubelet

    log_ok "Kubernetes installed."

}
