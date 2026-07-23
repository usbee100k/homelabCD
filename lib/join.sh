#!/usr/bin/env bash


#############################################
# GENERATE JOIN COMMANDS
#############################################

generate_join_commands() {

    mkdir -p "${ROOT_DIR}/generated"

    log_info "Generating Kubernetes join commands"

    kubeadm token create \
        --kubeconfig="${KUBECONFIG}" \
        --print-join-command \
        > "${ROOT_DIR}/generated/worker_join.sh" || {
        log_fail "Failed to generate worker join command."
        return 1
    }

    chmod +x "${ROOT_DIR}/generated/worker_join.sh"

    CERT_KEY=$(
        kubeadm init phase upload-certs \
            --kubeconfig="${KUBECONFIG}" \
            --upload-certs \
        | tail -1
    ) || {
        log_fail "Failed to upload control-plane certificates."
        return 1
    }

    JOIN_COMMAND=$(
        kubeadm token create \
            --kubeconfig="${KUBECONFIG}" \
            --print-join-command
    ) || {
        log_fail "Failed to generate control-plane join command."
        return 1
    }

    cat > "${ROOT_DIR}/generated/controlplane_join.sh" <<EOF
#!/usr/bin/env bash

${JOIN_COMMAND} \\
    --control-plane \\
    --certificate-key ${CERT_KEY}
EOF

    chmod +x "${ROOT_DIR}/generated/controlplane_join.sh"

    log_ok "Join commands generated."
}