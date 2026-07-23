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
    # Kubernetes Packages
    #########################################

    next_step "Installing Kubernetes Packages"


    install_kubernetes


    finish_step



    #########################################
    # Bootstrap Credentials
    #########################################

    next_step "Retrieving Cluster Join Credentials"


    download_bootstrap_secrets


    if [[ ! -f "${ROOT_DIR}/generated/secrets/worker_join.sh" ]]; then

        log_error "Worker join command missing after decryption."

        echo
        echo "Expected:"
        echo "${ROOT_DIR}/generated/secrets/worker_join.sh"

        exit 1

    fi


    chmod +x "${ROOT_DIR}/generated/secrets/worker_join.sh"


    finish_step



    #########################################
    # Join Cluster
    #########################################

    next_step "Joining Kubernetes Cluster"


    if ! bash "${ROOT_DIR}/generated/secrets/worker_join.sh"; then

        log_error "kubeadm join failed."

        echo
        echo "Check:"
        echo "  systemctl status kubelet"
        echo "  journalctl -u kubelet -xe"
        echo

        exit 1

    fi


    finish_step



    #########################################
    # Wait For Node Registration
    #########################################

    next_step "Waiting For Node Registration"


    log_info "Worker joined. Waiting for kubelet..."


    sleep 15


    finish_step



    #########################################
    # Node Configuration
    #########################################

    next_step "Configuring Node"


    register_node


    apply_node_labels


    detect_special_hardware


    finish_step



    #########################################
    # Validation
    #########################################

    next_step "Node Validation"


    if systemctl is-active --quiet kubelet; then

        log_ok "Kubelet is running."

    else

        log_error "Kubelet is not running."

        systemctl status kubelet --no-pager

        exit 1

    fi


    finish_step



    log_ok "Worker Node Joined Successfully."

}


join_worker