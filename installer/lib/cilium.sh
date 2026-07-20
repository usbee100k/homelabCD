#!/usr/bin/env bash

install_cilium_cli() {

    log_info "Installing Cilium CLI..."

    if command -v cilium >/dev/null 2>&1; then
        log_ok "Cilium CLI already installed."
        return
    fi

    CLI_ARCH=amd64

    if [[ $(uname -m) == "aarch64" ]]; then
        CLI_ARCH=arm64
    fi

    CILIUM_VERSION=$(curl -s https://api.github.com/repos/cilium/cilium-cli/releases/latest \
        | jq -r .tag_name)

    curl -L \
        --fail \
        -o cilium.tar.gz \
        "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz"

    tar -xzf cilium.tar.gz

    mv cilium /usr/local/bin/

    rm -f cilium.tar.gz

    log_ok "Cilium CLI installed."

}

install_cilium() {

    log_info "Installing Cilium..."

    cilium install \
        --version "${CILIUM_VERSION}" \
        --set kubeProxyReplacement=true \
        --set k8sServiceHost="${VIP_ADDRESS}" \
        --set k8sServicePort=6443

    log_ok "Cilium deployed."

}

wait_for_cilium() {

    log_info "Waiting for Cilium..."

    cilium status --wait

    log_ok "Cilium Ready."

}
