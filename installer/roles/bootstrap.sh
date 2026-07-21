#!/usr/bin/env bash

set -Eeuo pipefail


#############################################
# ROLE BOOTSTRAP
#############################################

if [[ -z "${ROOT_DIR:-}" ]]; then
    readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
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
        # shellcheck disable=SC1090
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



    #########################################
    # STEP 1
    #########################################

    next_step "Validating Host"


    validate_system


    finish_step



    #########################################
    # STEP 2
    #########################################

    next_step "Preparing Operating System"


    update_system

    disable_swap

    configure_kernel_modules

    configure_sysctl

    mount_bpf


    finish_step



    #########################################
    # STEP 3
    #########################################

    next_step "Installing Container Runtime"


    install_containerd


    finish_step



    #########################################
    # STEP 4
    #########################################

    next_step "Installing Kubernetes Packages"


    install_kubernetes


    finish_step



    #########################################
    # STEP 5
    #########################################

    next_step "Configuring kube-vip"


    install_kubevip


    finish_step



    #########################################
    # STEP 6
    #########################################

    next_step "Initializing Kubernetes Cluster"


    generate_kubeadm_config


    kubeadm_init


    configure_kubectl


    finish_step



    #########################################
    # STEP 7
    #########################################

    next_step "Installing Helm"


    install_helm


    finish_step



    #########################################
    # STEP 8
    #########################################

    next_step "Installing Cilium"


    install_cilium_cli
    
    
    install_cilium


    wait_for_cilium

    untaint_controlplane


    finish_step



    #########################################
    # STEP 9
    #########################################

    next_step "Installing Argo CD"


    install_argocd


    finish_step



    #########################################
    # STEP 10
    #########################################

    next_step "Connecting GitOps Repository"


    bootstrap_gitops


    finish_step



    #########################################
    # STEP 11
    #########################################

    next_step "Generating Cluster Join Credentials"


    generate_join_commands


    finish_step



    #########################################
    # STEP 12
    #########################################

    next_step "Creating Encrypted Bootstrap Package"


    create_bootstrap_package


    upload_bootstrap_package


    finish_step



    #########################################
    # STEP 13
    #########################################

    next_step "Registering Primary Node"


    register_node


    apply_node_labels


    detect_special_hardware


    finish_step



    #########################################
    # STEP 14
    #########################################

    next_step "Cluster Validation"

    kubectl cluster-info
    
    kubectl get nodes


    kubectl get pods -A


    finish_step



    #########################################
    # COMPLETE
    #########################################

    log_ok "Kubernetes Cluster Bootstrap Complete"


    echo
    echo "Bootstrap Complete"
    echo
    echo "Private repository updated with:"
    echo
    echo " ├── encrypted worker join"
    echo " ├── encrypted control plane join"
    echo " └── cluster inventory"
    echo

}



bootstrap_cluster