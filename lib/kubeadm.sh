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


    # Convert Kubernetes version to minor version
    K8S_MINOR_VERSION=$(echo "${KUBERNETES_VERSION}" | awk -F. '{print $1"."$2}')


    rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg


    curl -fsSL \
        "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR_VERSION}/deb/Release.key" \
        | gpg --dearmor \
        -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg



    cat > /etc/apt/sources.list.d/kubernetes.list <<EOF
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR_VERSION}/deb/ /
EOF



   apt-get update

# Skip if the desired version is already installed
if dpkg-query -W -f='${Status}' kubelet kubeadm kubectl 2>/dev/null | \
   grep -q "install ok installed"; then
    log_info "Kubernetes packages already installed. Skipping package installation."
else
    apt-get install -y --allow-downgrades \
        kubelet="${KUBERNETES_VERSION}-*" \
        kubeadm="${KUBERNETES_VERSION}-*" \
        kubectl="${KUBERNETES_VERSION}-*"

    apt-mark hold kubelet kubeadm kubectl
fi


    systemctl enable kubelet


    log_ok "Kubernetes packages installed."

}


#############################################
# Initialize Kubernetes Control Plane
#############################################

kubeadm_init() {

    log_info "Running kubeadm init"


    #############################################
    # Check if Kubernetes is already initialized
    #############################################

    if [[ -f /etc/kubernetes/admin.conf ]] && \
       [[ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]]; then

        log_ok "Kubernetes control plane already exists. Skipping kubeadm init."
        return 0

    fi



    #############################################
    # Initialize new cluster
    #############################################

    kubeadm init \
        --config "${ROOT_DIR}/generated/kubeadm-config.yaml" \
        --upload-certs



    log_ok "Kubernetes control plane initialized."

}