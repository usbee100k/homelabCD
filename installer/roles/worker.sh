#!/usr/bin/env bash

set -Eeuo pipefail


#############################################
# WORKER NODE JOIN
#############################################


join_worker() {


    header


    log_info "Joining worker node"



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
    # Join Worker
    #########################################


    next_step "Joining Kubernetes Cluster"



    if [[ ! -f "${ROOT_DIR}/generated/secrets/worker_join.sh" ]]; then


        log_error "Missing worker join command."


        echo

        echo "Bootstrap repository did not contain worker_join.sh"


        exit 1

    fi



    bash "${ROOT_DIR}/generated/secrets/worker_join.sh"



    finish_step



    #########################################
    # Node Registration
    #########################################


    next_step "Registering Node"



    register_node


    finish_step



    #########################################
    # Apply Kubernetes Labels
    #########################################


    next_step "Applying Node Labels"



    apply_node_labels


    detect_special_hardware



    finish_step



    #########################################
    # Verify
    #########################################


    next_step "Node Validation"



    kubectl get nodes



    finish_step



    log_ok "Worker Node Joined Successfully."

}


join_worker