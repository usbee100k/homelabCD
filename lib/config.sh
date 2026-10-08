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

    ACME_EMAIL=$(yq '.domains.acmeEmail' "${CONFIG_FILE}")

    METALLB_RANGE=$(yq '.network.metallbRange' "${CONFIG_FILE}")

    VPN_ENABLED=$(yq '.vpn.enabled // false' "${CONFIG_FILE}")
    VPN_ENDPOINT=$(yq '.vpn.endpoint // ""' "${CONFIG_FILE}")
    VPN_PORT=$(yq '.vpn.port // 51820' "${CONFIG_FILE}")
    VPN_LB_IP=$(yq '.vpn.ip // ""' "${CONFIG_FILE}")
    VPN_ALLOWED_IPS=$(yq '.vpn.allowedIPs // ""' "${CONFIG_FILE}")


    if [[ "${GITHUB_REPO}" == "null" ]]; then
        GITHUB_REPO=""
    fi


    if [[ "${BASE_DOMAIN}" == "null" ]]; then
        BASE_DOMAIN=""
    fi

    if [[ "${ACME_EMAIL}" == "null" ]]; then
        ACME_EMAIL=""
    fi

    if [[ "${METALLB_RANGE}" == "null" ]]; then
        METALLB_RANGE=""
    fi

    export LOCAL_IP
    export VIP_ADDRESS
    export BASE_DOMAIN
    export ACME_EMAIL
    export METALLB_RANGE
    export VPN_ENABLED VPN_ENDPOINT VPN_PORT VPN_LB_IP VPN_ALLOWED_IPS
}


save_config() {

    yq -i \
        ".github.repo = \"${GITHUB_REPO}\"" \
        "${CONFIG_FILE}"

    yq -i \
        ".domains.base = \"${BASE_DOMAIN}\"" \
        "${CONFIG_FILE}"

    yq -i \
        ".domains.acmeEmail = \"${ACME_EMAIL:-}\"" \
        "${CONFIG_FILE}"

    yq -i \
        ".network.metallbRange = \"${METALLB_RANGE:-}\"" \
        "${CONFIG_FILE}"

    yq -i \
        ".vpn.enabled = ${VPN_ENABLED:-false} |
         .vpn.endpoint = \"${VPN_ENDPOINT:-}\" |
         .vpn.port = ${VPN_PORT:-51820} |
         .vpn.ip = \"${VPN_LB_IP:-}\" |
         .vpn.allowedIPs = \"${VPN_ALLOWED_IPS:-}\"" \
        "${CONFIG_FILE}"
}


#############################################
# SHOW CLUSTER CONFIGURATION
#############################################

show_cluster_config() {

    echo
    echo "============================================="
    echo " homelabCD Configuration  (${CONFIG_FILE})"
    echo "============================================="
    echo

    cat "${CONFIG_FILE}"

    echo
    echo "============================================="
    echo " Live kubeadm ClusterConfiguration"
    echo "============================================="
    echo

    kubectl -n kube-system get cm kubeadm-config \
        -o jsonpath='{.data.ClusterConfiguration}' 2>/dev/null ||
        echo "Unavailable: run this from a control plane node."

    echo
}
