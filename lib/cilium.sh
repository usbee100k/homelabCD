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
    # Determine Cilium operator replicas
    #############################################

    READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | \
        awk '$2 == "Ready" && $0 !~ /SchedulingDisabled/ {count++} END {print count+0}')

    if (( READY_NODES >= 2 )); then
        OPERATOR_REPLICAS=2
    else
        OPERATOR_REPLICAS=1
    fi

    log_info "Detected ${READY_NODES} Ready node(s); using ${OPERATOR_REPLICAS} Cilium operator replica(s)."


    #############################################
    # Install or upgrade Cilium
    #############################################

    if helm status cilium -n kube-system >/dev/null 2>&1; then
        log_info "Cilium release already exists. Upgrading with current values..."

        cilium upgrade --version "${version}" \
            --values "${ROOT_DIR}/templates/cilium-values.yaml" \
            --set-string "k8sServiceHost=${VIP_ADDRESS}" \
            --set-string "k8sServicePort=6443" \
            --set kubeProxyReplacement=true \
            --set routingMode=native \
            --set autoDirectNodeRoutes=true \
            --set-string "ipv4NativeRoutingCIDR=10.10.0.0/24" \
            --set bpf.masquerade=true \
            --set rollOutCiliumPods=true \
            --set "operator.replicas=${OPERATOR_REPLICAS}" 

    else
        log_info "Cilium release not found. Installing..."

        cilium install --version "${version}" \
            --values "${ROOT_DIR}/templates/cilium-values.yaml" \
            --set-string "k8sServiceHost=${VIP_ADDRESS}" \
            --set-string "k8sServicePort=6443" \
            --set kubeProxyReplacement=true \
            --set rollOutPods=true \
            --set "operator.replicas=${OPERATOR_REPLICAS}" 

    fi
    
}

install_cilium_operator_scaler() {
    log_info "Installing Cilium operator replica scaler..."

    cat >/usr/local/sbin/cilium-operator-scaler.sh <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

export KUBECONFIG=/etc/kubernetes/admin.conf

READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | \
    awk '$2 == "Ready" && $0 !~ /SchedulingDisabled/ {count++} END {print count+0}')

if (( READY_NODES >= 2 )); then
    DESIRED_REPLICAS=2
else
    DESIRED_REPLICAS=1
fi

CURRENT_REPLICAS=$(kubectl -n kube-system \
    get deployment cilium-operator \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")

if [[ "${CURRENT_REPLICAS}" != "${DESIRED_REPLICAS}" ]]; then
    logger -t cilium-operator-scaler \
        "Ready nodes=${READY_NODES}; scaling Cilium operator ${CURRENT_REPLICAS} -> ${DESIRED_REPLICAS}"

    kubectl -n kube-system scale deployment cilium-operator \
        --replicas="${DESIRED_REPLICAS}"
fi
EOF

    chmod +x /usr/local/sbin/cilium-operator-scaler.sh

    cat >/etc/systemd/system/cilium-operator-scaler.service <<'EOF'
[Unit]
Description=Cilium Operator Replica Scaler
After=network-online.target kubelet.service
Wants=network-online.target
Requires=kubelet.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/cilium-operator-scaler.sh
EOF

    cat >/etc/systemd/system/cilium-operator-scaler.timer <<'EOF'
[Unit]
Description=Automatically scale Cilium Operator replicas based on Ready nodes

[Timer]
OnBootSec=60s
OnUnitActiveSec=60s
Unit=cilium-operator-scaler.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now cilium-operator-scaler.timer

    log_ok "Cilium operator replica scaler enabled."
}


#############################################
# Wait for Cilium
#############################################

wait_for_cilium() {

    log_info "Waiting for Cilium..."


    cilium status --wait --wait-duration 10m


    log_ok "Cilium Ready."

    install_cilium_operator_scaler

}
