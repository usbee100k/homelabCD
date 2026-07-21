#!/usr/bin/env bash

set -Eeuo pipefail


#############################################
# Install Cilium CLI
#############################################

install_cilium_cli() {

    log_info "Installing Cilium CLI..."


    if command -v cilium >/dev/null 2>&1; then
        log_ok "Cilium CLI already installed."
        return
    fi


    local CLI_ARCH="amd64"


    if [[ "$(uname -m)" == "aarch64" ]]; then
        CLI_ARCH="arm64"
    fi


    local CLI_VERSION

    CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)


    curl -L --fail \
        -o /tmp/cilium.tar.gz \
        "https://github.com/cilium/cilium-cli/releases/download/${CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz"


    tar -xzf /tmp/cilium.tar.gz -C /tmp


    mv /tmp/cilium /usr/local/bin/cilium


    rm -f /tmp/cilium.tar.gz


    chmod +x /usr/local/bin/cilium


    log_ok "Cilium CLI installed."

}



#############################################
# Install Cilium CNI
#############################################

install_cilium() {

    log_info "Installing Cilium..."


    # Default Cilium Helm version
    if [[ -z "${CILIUM_VERSION:-}" ]]; then
        CILIUM_VERSION="1.18.1"
    fi


    # Remove bad values
    if [[ "${CILIUM_VERSION}" == "latest" || "${CILIUM_VERSION}" == *"latest"* ]]; then
        CILIUM_VERSION="1.18.1"
    fi


    log_info "Using Cilium version: ${CILIUM_VERSION}"


    cilium install \
        --version "${CILIUM_VERSION}" \
        --set kubeProxyReplacement=true \
        --set k8sServiceHost="${VIP_ADDRESS}" \
        --set k8sServicePort=6443


    log_ok "Cilium deployed."

}



#############################################
# Wait for Cilium
#############################################

wait_for_cilium() {

    log_info "Waiting for Cilium..."


    cilium status --wait


    log_ok "Cilium Ready."

}
