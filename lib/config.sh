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

    local saved_repo="${GITHUB_REPO:-}" # from config/defaults.env, if any
    GITHUB_REPO=$(yq '.github.repo' "${CONFIG_FILE}")

    BASE_DOMAIN=$(yq '.domains.base' "${CONFIG_FILE}")

    ACME_EMAIL=$(yq '.domains.acmeEmail' "${CONFIG_FILE}")

    METALLB_RANGE=$(yq '.network.metallbRange' "${CONFIG_FILE}")

    VPN_ENABLED=$(yq '.vpn.enabled // false' "${CONFIG_FILE}")
    VPN_ENDPOINT=$(yq '.vpn.endpoint // ""' "${CONFIG_FILE}")
    VPN_PORT=$(yq '.vpn.port // 51820' "${CONFIG_FILE}")
    VPN_LB_IP=$(yq '.vpn.ip // ""' "${CONFIG_FILE}")
    VPN_ALLOWED_IPS=$(yq '.vpn.allowedIPs // ""' "${CONFIG_FILE}")


    if [[ "${GITHUB_REPO}" == "null" || -z "${GITHUB_REPO}" ]]; then
        GITHUB_REPO="${saved_repo}"
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


#############################################
# RENAME THE CLUSTER
#############################################
#
# The cluster name lives only in config/cluster.yaml (cluster.name).
# KubesTUI, the text menu and the cluster report all read it from there,
# so renaming is this one edit. Kubernetes itself keeps the name kubeadm
# was given when the cluster was created; nothing in the cluster depends
# on it.
#############################################

rename_cluster() {

    local current new

    current="$(yq '.cluster.name // ""' "${CONFIG_FILE}")"

    echo "Current cluster name: ${current:-<none>}"
    echo "Lowercase letters, digits and dashes (e.g. homelab, teslab, lab-2)."
    echo

    read -r -p "New cluster name (blank = keep): " new

    new="${new,,}"
    new="${new//[[:space:]]/}"

    if [[ -z "${new}" || "${new}" == "${current}" ]]; then
        log_ok "Cluster name unchanged: ${current}"
        return 0
    fi

    if [[ ! "${new}" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
        log_error "\"${new}\" isn't a valid name: use lowercase letters, digits and dashes,"
        log_error "starting and ending with a letter or digit (at most 63 characters)."
        return 1
    fi

    NEW_NAME="${new}" yq -i '.cluster.name = strenv(NEW_NAME)' "${CONFIG_FILE}"

    CLUSTER_NAME="${new}"
    export CLUSTER_NAME

    log_ok "Cluster renamed: ${current} -> ${new}"
    echo "  Saved in ${CONFIG_FILE}. KubesTUI shows the new name within a few seconds."
}
