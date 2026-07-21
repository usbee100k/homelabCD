#!/usr/bin/env bash



apply_node_labels() {


    NODE_NAME=$(hostname)



    case "${NODE_ROLE}" in


    1)

        kubectl label node "${NODE_NAME}" \

        node-role.kubernetes.io/control-plane="" \
        --overwrite


        ;;


    2)

        kubectl label node "${NODE_NAME}" \

        node-role.kubernetes.io/control-plane="" \
        --overwrite


        ;;


    3)

        kubectl label node "${NODE_NAME}" \

        node-role.kubernetes.io/worker="" \
        --overwrite


        ;;


    esac



    log_ok "Node labels applied."

}