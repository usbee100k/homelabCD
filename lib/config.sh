#!/usr/bin/env bash

CONFIG_FILE="${ROOT_DIR}/config/cluster.yaml"

load_config() {

    CLUSTER_NAME=$(yq '.cluster.name' "${CONFIG_FILE}")

    KUBERNETES_VERSION=$(yq '.kubernetes.version' "${CONFIG_FILE}")

    VIP_ADDRESS=$(yq '.network.vip' "${CONFIG_FILE}")

    # Detect the IP address of the interface used for the default route.
    LOCAL_IP=$(ip -4 route get 1.1.1.1 2>/dev/null |
        awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')

    if [[ -z "${LOCAL_IP}" ]]; then
        echo "ERROR: Unable to automatically determine local IPv4 address."
        exit 1
    fi

    POD_SUBNET=$(yq '.network.podSubnet' "${CONFIG_FILE}")

    SERVICE_SUBNET=$(yq '.network.serviceSubnet' "${CONFIG_FILE}")

    GITHUB_REPO=$(yq '.github.repo' "${CONFIG_FILE}")

    BASE_DOMAIN=$(yq '.domains.base' "${CONFIG_FILE}")


    if [[ "${GITHUB_REPO}" == "null" ]]; then
        GITHUB_REPO=""
    fi


    if [[ "${BASE_DOMAIN}" == "null" ]]; then
        BASE_DOMAIN=""
    fi

    export LOCAL_IP
    export VIP_ADDRESS
    export BASE_DOMAIN
}


save_config() {

    yq -i \
        ".github.repo = \"${GITHUB_REPO}\"" \
        "${CONFIG_FILE}"

    yq -i \
        ".domains.base = \"${BASE_DOMAIN}\"" \
        "${CONFIG_FILE}"
}