#!/usr/bin/env bash


CONFIG_FILE="${ROOT_DIR}/config/cluster.yaml"



load_config() {


    CLUSTER_NAME=$(yq '.cluster.name' "${CONFIG_FILE}")


    KUBERNETES_VERSION=$(yq '.kubernetes.version' "${CONFIG_FILE}")


    VIP_ADDRESS=$(yq '.network.vip' "${CONFIG_FILE}")


    POD_SUBNET=$(yq '.network.podSubnet' "${CONFIG_FILE}")


    SERVICE_SUBNET=$(yq '.network.serviceSubnet' "${CONFIG_FILE}")


    GITHUB_REPO=$(yq '.github.repo' "${CONFIG_FILE}")



    if [[ "${GITHUB_REPO}" == "null" ]]; then

        GITHUB_REPO=""

    fi

}



save_config() {


    yq -i \
    ".github.repo = \"${GITHUB_REPO}\"" \
    "${CONFIG_FILE}"

}