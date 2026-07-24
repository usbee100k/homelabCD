#!/usr/bin/env bash

set -Eeuo pipefail


#############################################
# Install Cilium CLI
#############################################

detect_primary_interface() {

    if [[ -n "${NETWORK_INTERFACE:-}" ]]; then
        echo "${NETWORK_INTERFACE}"
        return
    fi

    ip route get 1.1.1.1 \
        | awk '/dev/ {for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}



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

    log_info "Installing Cilium"


    #############################################
    # Validate Cilium version
    #############################################

    local version="${CILIUM_VERSION:-1.18.1}"


    if [[ "${version}" == "latest" ]] || [[ "${version}" == *"latest"* ]]; then
        log_warn "Invalid Cilium version '${version}', using 1.18.1"
        version="1.18.1"
    fi


    if ! [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_warn "Invalid Cilium version '${version}', using 1.18.1"
        version="1.18.1"
    fi


    log_info "Using Cilium version: ${version}"



    #############################################
    # Cleanup stuck Cilium namespace
    #############################################

    if kubectl get namespace cilium-secrets >/dev/null 2>&1; then

        STATUS=$(kubectl get namespace cilium-secrets \
            -o jsonpath='{.status.phase}')


        if [[ "${STATUS}" == "Terminating" ]]; then

            log_warn "Removing stuck cilium-secrets namespace"


            kubectl get namespace cilium-secrets \
                -o json \
                | jq '.spec.finalizers=[]' \
                | kubectl replace --raw \
                    "/api/v1/namespaces/cilium-secrets/finalize" \
                    -f -

        fi

    fi



    #############################################
    # Skip existing installation
    #############################################

    if kubectl get daemonset cilium -n kube-system >/dev/null 2>&1; then

        log_ok "Cilium already installed. Skipping."
        return 0

    fi



    #############################################
    # Install Cilium
    #############################################




    cilium install \
        --version "${version}" \
        --set kubeProxyReplacement=true \
        --set k8sServiceHost="${VIP_ADDRESS}" \
        --set k8sServicePort=6443 \
        --set devices="^(en|eth).*" \
        --set ipam.mode=kubernetes \
        --set routingMode=tunnel \
        --set tunnelProtocol=vxlan \
        --set autoDirectNodeRoutes=false \
        --set rollOutCiliumPods=true

}


#############################################
# Wait for Cilium
#############################################

wait_for_cilium() {

    log_info "Waiting for Cilium..."


    cilium status --wait


    log_ok "Cilium Ready."

}
