#!/usr/bin/env bash

set -Eeuo pipefail


#############################################
# ADDITIONAL CONTROL PLANE NODE
#############################################


join_controlplane() {


    header


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
    # Kubernetes
    #########################################


    next_step "Installing Kubernetes"


    install_kubernetes


    finish_step



    #########################################
    # Join Cluster
    #########################################


    next_step "Joining Control Plane"



    if [[ ! -f "${ROOT_DIR}/generated/controlplane_join.sh" ]]; then

        log_error "Missing control plane join command."

        echo

        echo "Copy generated/controlplane_join.sh from the cluster leader."

        exit 1

    fi



    bash "${ROOT_DIR}/generated/controlplane_join.sh"



    finish_step



    #########################################
    # Validate
    #########################################


    next_step "Validating Node"



    kubectl get nodes


    finish_step



    log_ok "Control Plane Joined Successfully."

}


join_controlplane

register_node

apply_node_labels