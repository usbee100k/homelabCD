generate_join_commands() {

    mkdir -p "${ROOT_DIR}/generated"

    log_info "Generating Kubernetes join commands"

    # Determine kubeconfig
    local KCFG="${KUBECONFIG:-$HOME/.kube/config}"

    if [[ ! -f "$KCFG" ]]; then
        log_error "Kubeconfig not found: $KCFG"
        return 1
    fi

    kubeadm token create \
        --kubeconfig "$KCFG" \
        --print-join-command \
        > "${ROOT_DIR}/generated/worker_join.sh" || {
            log_error "Failed to generate worker join command."
            return 1
        }

    chmod +x "${ROOT_DIR}/generated/worker_join.sh"

    local CERT_KEY
    CERT_KEY=$(
        kubeadm init phase upload-certs \
            --kubeconfig "$KCFG" \
            --upload-certs | tail -1
    ) || {
        log_error "Failed to upload certificates."
        return 1
    }

    local JOIN_COMMAND
    JOIN_COMMAND=$(
        kubeadm token create \
            --kubeconfig "$KCFG" \
            --print-join-command
    ) || {
        log_error "Failed to generate control-plane join command."
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