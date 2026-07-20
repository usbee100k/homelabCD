#!/usr/bin/env bash

set -Eeuo pipefail


#############################################
# FIRST CONTROL PLANE BOOTSTRAP
#############################################


bootstrap_cluster() {


    header


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


    install_cilium


    wait_for_cilium


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

    next_step "Starting GitOps"


    bootstrap_gitops


    finish_step



    #########################################
    # STEP 11
    #########################################

    next_step "Generating Cluster Recovery Files"


    generate_join_commands


    generate_report
    
    register_node

    apply_node_labels


    finish_step



    #########################################
    # COMPLETE
    #########################################


    header


    log_ok "Cluster Bootstrap Complete"


    echo

    echo "Generated Files:"

    echo

    echo "generated/"
    echo " ├── cluster-info.yaml"
    echo " ├── worker_join.sh"
    echo " └── controlplane_join.sh"

    echo


}



bootstrap_cluster