#!/usr/bin/env bash

wait_for_nodes() {

    log_info "Waiting for Kubernetes Nodes..."

    until kubectl get nodes 2>/dev/null | grep -q Ready
    do
        sleep 5
    done

    log_ok "Nodes Ready."

}

wait_for_coredns() {

    log_info "Waiting for CoreDNS..."

    kubectl rollout status \
        deployment/coredns \
        -n kube-system

    log_ok "CoreDNS Ready."

}

cluster_health() {

    echo

    kubectl get nodes

    echo

    kubectl get pods -A

}
