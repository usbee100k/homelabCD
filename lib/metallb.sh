#!/usr/bin/env bash

set -Eeuo pipefail

#############################################
# METALLB NODE SELECTOR
#############################################
#
# Keeps up to METALLB_MAX_NODES Ready nodes labelled
# homelab.io/metallb-announce=true. The L2Advertisement
# only announces from labelled nodes.
#
# Runs every 60s, so nodes that join later are picked
# up automatically, and NotReady nodes hand their slot
# to a healthy node.
#############################################

install_metallb_node_selector() {

    log_info "Installing MetalLB node selector..."

    cat >/usr/local/sbin/metallb-node-selector.sh <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

export KUBECONFIG=/etc/kubernetes/admin.conf

LABEL="homelab.io/metallb-announce"
EXCLUDE_LABEL="node.kubernetes.io/exclude-from-external-load-balancers"
METALLB_MAX_NODES=3

NODES=$(
    kubectl get nodes \
        --sort-by=.metadata.creationTimestamp \
        -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.conditions[?(@.type=="Ready")].status}{"|"}{.spec.unschedulable}{"|"}{.metadata.labels.homelab\.io/metallb-announce}{"\n"}{end}'
)

SELECTED=0

#############################################
# Release labelled nodes that are no longer Ready
#############################################

while IFS='|' read -r name ready unschedulable labelled; do

    [[ -n "${name}" && "${labelled}" == "true" ]] || continue

    if [[ "${ready}" == "True" && "${unschedulable}" != "true" ]]; then
        SELECTED=$((SELECTED + 1))
    else
        logger -t metallb-node-selector "Releasing ${name} (not Ready)"
        kubectl label node "${name}" "${LABEL}-" >/dev/null
    fi

done <<< "${NODES}"

#############################################
# Fill free slots with Ready nodes, oldest first
#############################################

while IFS='|' read -r name ready unschedulable labelled; do

    (( SELECTED < METALLB_MAX_NODES )) || break

    [[ -n "${name}" && "${labelled}" != "true" ]] || continue
    [[ "${ready}" == "True" && "${unschedulable}" != "true" ]] || continue

    logger -t metallb-node-selector "Selecting ${name} (${SELECTED}/${METALLB_MAX_NODES} before)"

    kubectl label node "${name}" "${LABEL}=true" --overwrite >/dev/null

    # MetalLB speakers ignore nodes carrying the exclusion label.
    kubectl label node "${name}" "${EXCLUDE_LABEL}-" >/dev/null 2>&1 || true

    SELECTED=$((SELECTED + 1))

done <<< "${NODES}"
EOF

    chmod +x /usr/local/sbin/metallb-node-selector.sh

    cat >/etc/systemd/system/metallb-node-selector.service <<'EOF'
[Unit]
Description=MetalLB Node Selector
After=network-online.target kubelet.service
Wants=network-online.target
Requires=kubelet.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/metallb-node-selector.sh
EOF

    cat >/etc/systemd/system/metallb-node-selector.timer <<'EOF'
[Unit]
Description=Keep up to 3 Ready nodes selected for MetalLB L2 announcements

[Timer]
OnBootSec=60s
OnUnitActiveSec=60s
Unit=metallb-node-selector.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now metallb-node-selector.timer

    log_ok "MetalLB node selector enabled."
}
