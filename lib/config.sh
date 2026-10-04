#!/usr/bin/env bash

CONFIG_FILE="${ROOT_DIR}/config/cluster.yaml"

BASE_DOMAIN= ""

load_config() {

    CLUSTER_NAME=$(yq '.cluster.name' "${CONFIG_FILE}")

    KUBERNETES_VERSION=$(yq '.kubernetes.version' "${CONFIG_FILE}")

    VIP_ADDRESS=$(yq '.network.vip' "${CONFIG_FILE}")

    POD_SUBNET=$(yq '.network.podSubnet' "${CONFIG_FILE}")

    SERVICE_SUBNET=$(yq '.network.serviceSubnet' "${CONFIG_FILE}")

    GITHUB_REPO=$(yq '.github.repo' "${CONFIG_FILE}")

    BASE_DOMAIN=$(yq '.base.domain' "${CONFIG_FILE}")


    if [[ "${GITHUB_REPO}" == "null" ]]; then
        GITHUB_REPO=""
    fi

    if [[ "${ARGOCD_DOMAIN}" == "null" ]]; then
        ARGOCD_DOMAIN=""
    fi
}


save_config() {

    yq -i \
        ".github.repo = \"${GITHUB_REPO}\"" \
        "${CONFIG_FILE}"

    yq -i \
        ".argocd.domain = \"${ARGOCD_DOMAIN}\"" \
        "${CONFIG_FILE}"
}