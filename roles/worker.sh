#!/usr/bin/env bash

set -Eeuo pipefail


#############################################
# ROLE BOOTSTRAP
#############################################

if [[ -z "${ROOT_DIR:-}" ]]; then
    ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
    export ROOT_DIR
fi


export NODE_ROLE="worker"


#############################################
# Load Configuration
#############################################

if [[ -f "${ROOT_DIR}/config/defaults.env" ]]; then
    source "${ROOT_DIR}/config/defaults.env"
fi


if [[ -f "${ROOT_DIR}/config/versions.env" ]]; then
    source "${ROOT_DIR}/config/versions.env"
fi


if [[ -f "${ROOT_DIR}/config/bootstrap.env" ]]; then
    source "${ROOT_DIR}/config/bootstrap.env"
fi


export KUBERNETES_VERSION="${KUBERNETES_VERSION:-unknown}"



#############################################
# Load Required Libraries
#############################################

LIBRARIES=(

    logging
    common
    progress

    config

    github

    validation
    system
    networking

    containerd

    kubeadm

    bootstrap-dependencies
    bootstrap-secrets
    bootstrap-download

    secrets

    inventory
    node-labels
    hardware-labels

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
# Load Configuration Values
#############################################

if declare -F load_config >/dev/null; then
    load_config
fi



#############################################
# WORKER NODE JOIN
#############################################

join_worker() {


    header


    log_info "Joining worker node"



    #########################################
    # Validate Host
    #########################################

    next_step "Validating Host"


    validate_system


    finish_step



    #########################################
    # Prepare OS
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
    # Kubernetes
    #########################################

    next_step "Installing Kubernetes Packages"


    install_kubernetes


    finish_step



    #########################################
    # Bootstrap Secrets
    #########################################

    next_step "Retrieving Cluster Join Credentials"


    #########################################
    # Bootstrap Repository
    #########################################

    if [[ -z "${BOOTSTRAP_REPO:-}" ]]; then


        echo
        echo "================================================="
        echo " Bootstrap Repository Required"
        echo "================================================="
        echo
        echo "Example:"
        echo "git@github.com:user/bootstrap-repo.git"
        echo


        read -rp "Enter Bootstrap Git Repository URL: " BOOTSTRAP_REPO


        if [[ -z "${BOOTSTRAP_REPO}" ]]; then

            log_error "Bootstrap repository cannot be empty."

            exit 1

        fi


        export BOOTSTRAP_REPO



        if [[ -f "${ROOT_DIR}/config/defaults.env" ]]; then


            sed -i \
                '/^BOOTSTRAP_REPO=/d' \
                "${ROOT_DIR}/config/defaults.env"


            echo "BOOTSTRAP_REPO=\"${BOOTSTRAP_REPO}\"" \
                >> "${ROOT_DIR}/config/defaults.env"


            log_ok "Bootstrap repository saved."

        fi


    fi



    #########################################
    # GitHub SSH Access
    #########################################

    next_step "Verifying GitHub SSH Access"


    ensure_github_ssh_access


    finish_step



    #########################################
    # Download Bootstrap Secrets
    #########################################

    download_bootstrap_secrets




    if [[ ! -f "${ROOT_DIR}/generated/secrets/worker_join.sh" ]]; then

        log_error "Worker join command missing."

        exit 1

    fi



    chmod +x \
        "${ROOT_DIR}/generated/secrets/worker_join.sh"


    finish_step



    #########################################
    # Join Cluster
    #########################################

    next_step "Joining Kubernetes Cluster"


    if ! bash "${ROOT_DIR}/generated/secrets/worker_join.sh"; then

        log_error "kubeadm join failed."

        echo
        echo "Debug commands:"
        echo "  systemctl status kubelet"
        echo "  journalctl -u kubelet -xe"
        echo

        exit 1

    fi


    finish_step



    #########################################
    # Wait For Kubelet
    #########################################

    next_step "Waiting For Kubelet"


    log_info "Waiting for kubelet service..."


    for i in {1..30}; do

        if systemctl is-active --quiet kubelet; then

            break

        fi

        sleep 2

    done


    finish_step



    #########################################
    # Validation
    #########################################

    next_step "Validating Worker Node"


    if systemctl is-active --quiet kubelet; then

        log_ok "Kubelet is running."

    else

        log_error "Kubelet failed to start."

        echo
        echo "Debug commands:"
        echo "  systemctl status kubelet"
        echo "  journalctl -u kubelet -xe"
        echo

        exit 1

    fi


    echo
    log_ok "Worker node successfully joined the cluster."
    echo
    echo "Verify the node from a control plane:"
    echo
    echo "  kubectl get nodes -o wide"
    echo


    finish_step



    log_ok "Worker Node Joined Successfully."

}



join_worker