#!/usr/bin/env bash

set -Eeuo pipefail


#############################################
# ROLE BOOTSTRAP
#############################################

if [[ -z "${ROOT_DIR:-}" ]]; then
    ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
    export ROOT_DIR
fi


#############################################
# Load Configuration
#############################################

source "${ROOT_DIR}/config/defaults.env" 2>/dev/null || true

export NODE_ROLE="${NODE_ROLE:-controlplane}"
export KUBERNETES_VERSION="${KUBERNETES_VERSION:-unknown}"


#############################################
# Load Required Libraries
#############################################

LIBRARIES=(
    logging
    common
    progress
    validation
    system
    networking
    containerd
    kubevip
    kubeadm
    kubeadm-config
    helm
    cilium
    argocd
    inventory
    node-labels
    hardware-labels
    bootstrap-secrets
    bootstrap-upload
    bootstrap-download
    secrets
    health
)


for lib in "${LIBRARIES[@]}"; do

    if [[ -f "${ROOT_DIR}/lib/${lib}.sh" ]]; then
        source "${ROOT_DIR}/lib/${lib}.sh"
    else
        echo "[ERROR] Missing library: ${lib}.sh"
        exit 1
    fi

done



#############################################
# FIRST CONTROL PLANE BOOTSTRAP
#############################################

bootstrap_cluster() {


    log_info "Starting Kubernetes cluster bootstrap"



    next_step "Validating Host"

    validate_system

    finish_step



    next_step "Preparing Operating System"

    update_system

    disable_swap

    configure_kernel_modules

    configure_sysctl

    mount_bpf

    finish_step



    next_step "Installing Container Runtime"

    install_containerd

    finish_step



    next_step "Installing Kubernetes Packages"

    install_kubernetes

    finish_step



    next_step "Configuring kube-vip"

    install_kubevip

    finish_step



    next_step "Initializing Kubernetes Cluster"

    generate_kubeadm_config

    kubeadm_init

    configure_kubectl

    finish_step



    next_step "Installing Helm"

    install_helm

    finish_step



    next_step "Installing Cilium"

    install_cilium_cli

    install_cilium

    wait_for_cilium

    untaint_controlplane

    finish_step



    next_step "Installing Argo CD"

    install_argocd

    finish_step



    next_step "Connecting GitHub GitOps Repository"

    configure_argocd_repository

    bootstrap_gitops

    finish_step



    next_step "Generating Cluster Join Credentials"

    generate_join_commands

    finish_step



    next_step "Creating Encrypted Bootstrap Package"

    create_bootstrap_package

    upload_bootstrap_package

    finish_step



    next_step "Registering Primary Node"

    register_node

    apply_node_labels

    detect_special_hardware

    finish_step



    next_step "Cluster Validation"

    kubectl cluster-info

    kubectl get nodes

    kubectl get pods -A

    finish_step



    log_ok "Kubernetes Cluster Bootstrap Complete"


    echo
    echo "Bootstrap Complete"
    echo
    echo "GitOps repository contains:"
    echo
    echo " ├── encrypted worker join"
    echo " ├── encrypted control plane join"
    echo " ├── cluster inventory"
    echo " └── Argo CD application definitions"
    echo

}



bootstrap_cluster