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
    # Join Worker
    #########################################


    next_step "Joining Kubernetes Cluster"



    if [[ ! -f "${ROOT_DIR}/generated/worker_join.sh" ]]; then


        log_error "Missing worker join command."


        echo

        echo "Copy generated/worker_join.sh from the control plane."


        exit 1

    fi



    bash "${ROOT_DIR}/generated/worker_join.sh"



    finish_step



    #########################################
    # Verify
    #########################################


    next_step "Node Validation"


    log_info "Worker joined."

    finish_step



    log_ok "Worker Node Joined Successfully."

}


join_worker