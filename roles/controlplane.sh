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
    kubeadm
    kubeadm-config
    inventory
    node-labels
    hardware-labels
    bootstrap-download
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
# ADDITIONAL CONTROL PLANE JOIN
#############################################

join_controlplane() {

    log_info "Joining additional control plane node"

    #########################################
    # Validate Host
    #########################################

    next_step "Validating Host"

    validate_system

    finish_step

    #########################################
    # Host Preparation
    #########################################

    next_step "Preparing Operating System"

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
        echo

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
    # Register Node
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
    # Validate Cluster
    #########################################

    next_step "Validating Control Plane"

    kubectl cluster-info

    kubectl get nodes

    kubectl get pods -A

    finish_step

    #########################################
    # Complete
    #########################################

    log_ok "Control Plane Joined Successfully."

    echo
    echo "Control Plane Join Complete"
    echo
    echo "Node has been:"
    echo " ├── Joined to the Kubernetes control plane"
    echo " ├── Registered in cluster inventory"
    echo " ├── Kubernetes labels applied"
    echo " └── Hardware labels detected"
    echo
}

join_controlplane