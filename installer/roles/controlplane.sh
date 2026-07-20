#!/usr/bin/env bash

set -Eeuo pipefail


#############################################
# ADDITIONAL CONTROL PLANE JOIN
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