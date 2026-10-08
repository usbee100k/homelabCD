#!/usr/bin/env bash


repair_node() {


    header


    log_info "Starting node repair..."


    local svc

    for svc in containerd kubelet; do

        echo
        log_info "Restarting ${svc}..."

        systemctl restart "${svc}" || true

        sleep 3

        if systemctl is-active --quiet "${svc}"; then
            log_ok "${svc} is running."
        else
            log_error "${svc} failed to start. Recent log:"
            journalctl -u "${svc}" -n 20 --no-pager || true
        fi

    done


    echo

    log_info "Recent kubelet errors:"

    journalctl -u kubelet --since "-5 min" --no-pager 2>/dev/null |
        grep -iE 'error|fail' | tail -n 10 || echo "  none"


    echo

    if [[ -f /etc/kubernetes/admin.conf ]]; then
        kubectl get nodes -o wide || true
    else
        log_info "Worker node: check its status from a control plane with: kubectl get nodes"
    fi


    log_ok "Repair completed."

}


reset_worker_node() {
    if [[ -f /etc/kubernetes/kubelet.conf ]]; then

    log_info "Existing cluster detected."

    reset_worker_node

    fi

}