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

    # Native routing must cover every pod IP. A smaller range makes Cilium
    # masquerade pod-to-pod traffic across nodes, which then times out.
    local pod_subnet
    pod_subnet="$(cluster_pod_subnet)"

    if [[ -z "${pod_subnet}" ]]; then
        log_error "network.podSubnet is not set in config/cluster.yaml"
        return 1
    fi



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
            --set-string "ipv4NativeRoutingCIDR=${pod_subnet}" \
            --set bpf.masquerade=true \
            --set bpf.hostLegacyRouting=true \
            --set rollOutCiliumPods=true \
            --set "operator.replicas=${OPERATOR_REPLICAS}"

    else

        log_info "Cilium release not found. Installing..."

        cilium install --version "${version}" \
            --values "${ROOT_DIR}/templates/cilium-values.yaml" \
            --set-string "k8sServiceHost=${VIP_ADDRESS}" \
            --set-string "k8sServicePort=6443" \
            --set kubeProxyReplacement=true \
            --set routingMode=native \
            --set autoDirectNodeRoutes=true \
            --set-string "ipv4NativeRoutingCIDR=${pod_subnet}" \
            --set bpf.masquerade=true \
            --set bpf.hostLegacyRouting=true \
            --set rollOutCiliumPods=true \
            --set "operator.replicas=${OPERATOR_REPLICAS}" 
    fi
    
}


#############################################
# Cilium routing CIDR = pod subnet
#############################################
#
# With native routing, Cilium masquerades any pod traffic to an address
# outside ipv4NativeRoutingCIDR. If that range is smaller than the pod
# subnet, pods on different nodes can't talk to each other: e.g. Argo CD
# on a worker can't reach Redis and logs everyone out. Clusters installed
# before the range came from the pod subnet kept a wrong one, and nothing
# re-ran the install, so update and health check it on existing clusters.
#############################################

# The pod subnet kubeadm really uses; config/cluster.yaml when there is no
# cluster yet (or this isn't a control plane).
cluster_pod_subnet() {

    local subnet

    subnet="$(kubectl -n kube-system get cm kubeadm-config \
        -o jsonpath='{.data.ClusterConfiguration}' 2>/dev/null |
        yq '.networking.podSubnet // ""' 2>/dev/null || true)"

    if [[ -z "${subnet}" || "${subnet}" == null ]]; then
        subnet="${POD_SUBNET:-}"
    fi

    [[ "${subnet}" == null ]] && subnet=""

    echo "${subnet}"
}

# Prints "<routing mode> <native routing CIDR>"; empty without Cilium.
cilium_routing_config() {

    kubectl -n kube-system get cm cilium-config \
        -o jsonpath='{.data.routing-mode} {.data.ipv4-native-routing-cidr}' 2>/dev/null || true
}

# Returns 1 only when the CIDR is wrong (prints why); 0 when it's right or
# can't be checked from here.
cilium_routing_ok() {

    local config mode cidr want

    config="$(cilium_routing_config)"
    [[ -n "${config}" ]] || return 0

    read -r mode cidr <<< "${config}"
    [[ "${mode}" == native ]] || return 0 # tunnel mode doesn't use the range

    want="$(cluster_pod_subnet)"
    [[ -n "${want}" ]] || return 0

    if [[ "${cidr:-}" != "${want}" ]]; then
        echo "Cilium's native routing CIDR is ${cidr:-unset}, but pods use ${want}"
        return 1
    fi
}

# Fixes the CIDR on an existing cluster, keeping the running Cilium version.
ensure_cilium_routing_cidr() {

    local problem want version generation

    if problem="$(cilium_routing_ok)"; then
        return 0
    fi

    want="$(cluster_pod_subnet)"

    log_warn "${problem}: pod traffic between nodes is broken."
    log_info "Setting Cilium's native routing CIDR to ${want}..."

    version="$(kubectl -n kube-system get ds cilium \
        -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null |
        sed -n 's/.*:v\([0-9][0-9.]*\).*/\1/p')"
    version="${version:-${CILIUM_VERSION:-1.18.1}}"

    generation="$(kubectl -n kube-system get ds cilium -o jsonpath='{.metadata.generation}' 2>/dev/null || true)"

    if command -v cilium >/dev/null 2>&1 && helm status cilium -n kube-system >/dev/null 2>&1; then
        if ! cilium upgrade --version "${version}" --reuse-values \
            --set-string "ipv4NativeRoutingCIDR=${want}"; then
            log_error "cilium upgrade failed."
            return 1
        fi
    else
        if ! kubectl -n kube-system patch cm cilium-config --type merge \
            -p "{\"data\":{\"ipv4-native-routing-cidr\":\"${want}\"}}"; then
            log_error "Could not update cilium-config."
            return 1
        fi
    fi

    # The agents read the setting at start. rollOutCiliumPods restarts
    # them on a config change; restart them here if it didn't.
    if [[ "$(kubectl -n kube-system get ds cilium -o jsonpath='{.metadata.generation}' 2>/dev/null || true)" == "${generation}" ]]; then
        kubectl -n kube-system rollout restart ds/cilium || return 1
    fi

    if ! kubectl -n kube-system rollout status ds/cilium --timeout=10m; then
        log_error "Cilium agents did not come back."
        return 1
    fi

    if ! problem="$(cilium_routing_ok)"; then
        log_error "${problem} (still)."
        return 1
    fi

    log_ok "Cilium routes the whole pod subnet (${want})."
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
