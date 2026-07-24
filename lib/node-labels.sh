#!/usr/bin/env bash

apply_node_labels() {

    local NODE_NAME
    NODE_NAME="$(hostname -s)"

    case "${NODE_ROLE}" in

        controlplane|control-plane|control)

            NODE_ROLE="control-plane"

            kubectl label node "${NODE_NAME}" \
                node-role.kubernetes.io/control-plane="" \
                --overwrite
            ;;

        worker|worker-node)

            NODE_ROLE="worker"

            kubectl label node "${NODE_NAME}" \
                node-role.kubernetes.io/worker="" \
                --overwrite
            ;;

        *)

            log_error "Unknown NODE_ROLE: ${NODE_ROLE}"
            return 1
            ;;

    esac

    log_ok "Node labels applied."

}