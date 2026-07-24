#!/usr/bin/env bash


repair_node() {


    header


    log_info "Starting node repair..."


    echo

    echo "Checking container runtime..."

    systemctl restart containerd


    echo

    echo "Checking kubelet..."

    systemctl restart kubelet


    echo

    kubectl get nodes || true


    log_ok "Repair completed."

}


reset_worker_node() {
    if [[ -f /etc/kubernetes/kubelet.conf ]]; then

    log_info "Existing cluster detected."

    reset_worker_node

    fi

}