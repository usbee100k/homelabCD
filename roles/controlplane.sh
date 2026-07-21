#!/usr/bin/env bash

set -Eeuo pipefail


#############################################
# ROLE BOOTSTRAP
#############################################

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT_DIR
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
    inventory
    node-labels
    hardware-labels
    validation
    system
    networking
    containerd
    kubeadm
    kubeadm-config
    bootstrap-download
    health
)


for lib in "${LIBRARIES[@]}"; do

    source "${ROOT_DIR}/lib/${lib}.sh"

done


#############################################
# ADDITIONAL CONTROL PLANE JOIN
#############################################

join_controlplane()
{

    next_step "Additional Control Plane Join"


    log_info "Joining additional control plane node"



    #########################################
    # Host Preparation
    #########################################

    next_step "Preparing Operating System"


    validate_system

    update_system

    disable_swap

    configure_kernel_modules

    configure_sysctl

    mount_bpf


    finish_step



    #########################################
    # Container Runtime
    #########################################

    next_step "Installing Container Runtime"


    install_containerd


    finish_step



    #########################################
    # Kubernetes Packages
    #########################################

    next_step "Installing Kubernetes Packages"


    install_kubernetes


    finish_step



    #########################################
    # Download Bootstrap Secrets
    #########################################

    next_step "Retrieving Cluster Join Credentials"


    download_bootstrap_secrets


    finish_step



    #########################################
    # Join Control Plane
    #########################################

    next_step "Joining Kubernetes Control Plane"


    if [[ ! -f "${ROOT_DIR}/generated/secrets/controlplane_join.sh" ]]; then

        log_error "Missing control plane join command."

        echo
        echo "Bootstrap repository did not contain controlplane_join.sh"

        exit 1

    fi


    bash "${ROOT_DIR}/generated/secrets/controlplane_join.sh"


    finish_step



    #########################################
    # Configure kubectl
    #########################################

    next_step "Configuring kubectl"


    configure_kubectl


    finish_step



    #########################################
    # Node Registration
    #########################################

    next_step "Registering Node"


    register_node


    finish_step



    #########################################
    # Apply Labels
    #########################################

    next_step "Applying Node Labels"


    apply_node_labels

    detect_special_hardware


    finish_step



    #########################################
    # Verify Cluster
    #########################################

    next_step "Validating Control Plane"


    kubectl get nodes

    kubectl get pods -A


    finish_step


    log_ok "Control Plane Joined Successfully."

}



join_controlplane