#!/usr/bin/env bash

set -Eeuo pipefail

#############################################
# NODE LABELS
#############################################

apply_node_labels() {

    log_info "Configuring node labels..."

    #############################################
    # Get node name
    #############################################

    local NODE_NAME
    NODE_NAME="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"

    if [[ -z "${NODE_NAME}" ]]; then
        log_error "Unable to determine Kubernetes node name."
        return 1
    fi

    #############################################
    # Update node inventory
    #############################################

    log_info "Updating node inventory..."

    if kubectl get node "${NODE_NAME}" >/dev/null 2>&1; then
        log_ok "Node inventory updated."
    else
        log_error "Node ${NODE_NAME} does not exist."
        return 1
    fi

    #############################################
    # Remove external load balancer exclusion
    #############################################

    if kubectl get node "${NODE_NAME}" \
        -o jsonpath='{.metadata.labels.node\.kubernetes\.io/exclude-from-external-load-balancers}' \
        2>/dev/null |
        grep -q .; then

        kubectl label node "${NODE_NAME}" \
            node.kubernetes.io/exclude-from-external-load-balancers-

        log_ok "Removed external load balancer exclusion label."

    else

        log_info "External load balancer exclusion label is not present."

    fi

    #############################################
    # Add any additional node labels here
    #############################################

    log_ok "Node labels configured."
}