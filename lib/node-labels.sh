#!/usr/bin/env bash

set -Eeuo pipefail

#############################################
# CURRENT NODE NAME
#############################################
#
# kubeadm registers the node under the lowercased hostname,
# which may be the FQDN or the short name depending on how
# the host is configured. Prints whichever one exists.
#############################################

current_node_name() {

    local name

    for name in \
        "$(hostname | tr '[:upper:]' '[:lower:]')" \
        "$(hostname -s | tr '[:upper:]' '[:lower:]')"
    do
        if kubectl get node "${name}" >/dev/null 2>&1; then
            echo "${name}"
            return 0
        fi
    done

    return 1
}


#############################################
# NODE LABELS
#############################################

apply_node_labels() {

    log_info "Configuring node labels..."

    #############################################
    # Get node name
    #############################################

    local NODE_NAME
    NODE_NAME="$(current_node_name)" || NODE_NAME=""

    if [[ -z "${NODE_NAME}" ]]; then
        log_error "Unable to determine Kubernetes node name."
        return 1
    fi

    #############################################
    # Update node inventory
    #############################################

    log_info "Updating node inventory..."

    if kubectl get node "${NODE_NAME}" >/dev/null 2>&1; then
        log_ok "Node inventory updated."
    else
        log_error "Node ${NODE_NAME} does not exist."
        return 1
    fi

    #############################################
    # Remove external load balancer exclusion
    #############################################

    if kubectl get node "${NODE_NAME}" \
        -o jsonpath='{.metadata.labels.node\.kubernetes\.io/exclude-from-external-load-balancers}' \
        2>/dev/null |
        grep -q .; then

        kubectl label node "${NODE_NAME}" \
            node.kubernetes.io/exclude-from-external-load-balancers-

        log_ok "Removed external load balancer exclusion label."

    else

        log_info "External load balancer exclusion label is not present."

    fi

    #############################################
    # Add any additional node labels here
    #############################################

    log_ok "Node labels configured."
}

#############################################
# WORKER ROLE LABELER
#############################################
#
# Nodes cannot set node-role.kubernetes.io/* on themselves
# (NodeRestriction), and workers have no admin credentials,
# so a control plane labels every non-control-plane node as
# a worker. This fills the ROLES column of `kubectl get nodes`.
#############################################

install_worker_role_labeler() {

    log_info "Installing worker role labeler..."

    cat >/usr/local/sbin/worker-role-labeler.sh <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

export KUBECONFIG=/etc/kubernetes/admin.conf

kubectl get nodes \
    -l '!node-role.kubernetes.io/control-plane,!node-role.kubernetes.io/worker' \
    -o name |
while read -r node; do

    logger -t worker-role-labeler "Labelling ${node} as worker"

    kubectl label "${node}" node-role.kubernetes.io/worker= --overwrite >/dev/null

done
EOF

    chmod +x /usr/local/sbin/worker-role-labeler.sh

    cat >/etc/systemd/system/worker-role-labeler.service <<'EOF'
[Unit]
Description=Worker Role Labeler
After=network-online.target kubelet.service
Wants=network-online.target
Requires=kubelet.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/worker-role-labeler.sh
EOF

    cat >/etc/systemd/system/worker-role-labeler.timer <<'EOF'
[Unit]
Description=Label joined worker nodes with the worker role

[Timer]
OnBootSec=60s
OnUnitActiveSec=60s
Unit=worker-role-labeler.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now worker-role-labeler.timer

    log_ok "Worker role labeler enabled."
}
