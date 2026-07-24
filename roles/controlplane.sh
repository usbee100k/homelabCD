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

export NODE_ROLE="${NODE_ROLE:-control-plane}"
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

    log_info "Joining Kubernetes Control Plane"

    #########################################
    # Prevent Duplicate Join
    #########################################

    if [[ -f /etc/kubernetes/admin.conf ]]; then
        log_warn "This node is already a member of a Kubernetes cluster."
        exit 0
    fi

    #########################################
    # Validate Host
    #########################################

    next_step "Validating Host"

    validate_system

    finish_step

    #########################################
    # Prepare Operating System
    #########################################

    next_step "Preparing Operating System"

    update_system
    disable_swap
    configure_kernel_modules
    configure_sysctl
    mount_bpf

    finish_step

    #########################################
    # Install Container Runtime
    #########################################

    next_step "Installing Container Runtime"

    install_containerd

    finish_step

    #########################################
    # Install Kubernetes Packages
    #########################################

    next_step "Installing Kubernetes Packages"

    install_kubernetes

    finish_step


    #########################################
    # Verify Join Script
    #########################################

    next_step "Validating Join Credentials"

    JOIN_SCRIPT="${ROOT_DIR}/generated/secrets/controlplane_join.sh"

    if [[ ! -f "${JOIN_SCRIPT}" ]]; then
        log_error "Missing control plane join command."
        exit 1
    fi

    if ! grep -q "kubeadm join" "${JOIN_SCRIPT}"; then
        log_error "Invalid control plane join script."
        exit 1
    fi

    finish_step
    
    #########################################
    # Retrieve Bootstrap Package
    #########################################

    next_step "Retrieving Bootstrap Package"

    download_bootstrap_secrets

    finish_step

    #########################################
    # Join Control Plane
    #########################################

    next_step "Joining Kubernetes Control Plane"

    bash "${JOIN_SCRIPT}"

    finish_step

    #########################################
    # Wait For kubelet
    #########################################

    next_step "Waiting For kubelet"

    until systemctl is-active --quiet kubelet; do
        sleep 2
    done

    finish_step

    #########################################
    # Configure kubectl
    #########################################

    next_step "Configuring kubectl"

    configure_kubectl

    finish_step

    #########################################
    # Wait For Node Registration
    #########################################

    next_step "Waiting For Node Registration"

    HOSTNAME="$(hostname -s)"

    until kubectl get node "${HOSTNAME}" >/dev/null 2>&1; do
        sleep 5
    done

    kubectl wait \
        --for=condition=Ready \
        node/"${HOSTNAME}" \
        --timeout=5m

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
    # Cluster Validation
    #########################################

    next_step "Validating Cluster"

    kubectl get --raw='/readyz?verbose'

    kubectl get nodes -o wide

    kubectl get pods \
        -n kube-system \
        -o wide

    finish_step

    #########################################
    # Success
    #########################################

    log_ok "Control Plane Joined Successfully."

    echo
    echo "Control Plane Join Complete"
    echo
    echo "Node has been:"
    echo " ├── Joined to the Kubernetes control plane"
    echo " ├── Waited until Ready"
    echo " ├── Registered in cluster inventory"
    echo " ├── Kubernetes labels applied"
    echo " ├── Hardware labels detected"
    echo " └── Cluster health validated"
    echo
}

join_controlplane