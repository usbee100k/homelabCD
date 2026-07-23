#!/usr/bin/env bash

generate_join_commands() {

    mkdir -p "${ROOT_DIR}/generated"


    log_info "Generating Kubernetes join commands"


    #############################################
    # FIND KUBERNETES ADMIN CONFIG
    #############################################

    local KCFG

    if [[ -f "/etc/kubernetes/admin.conf" ]]; then

        KCFG="/etc/kubernetes/admin.conf"

    elif [[ -n "${KUBECONFIG}" && -f "${KUBECONFIG}" ]]; then

        KCFG="${KUBECONFIG}"

    else

        log_error "Kubernetes admin kubeconfig not found."
        return 1

    fi


    export KUBECONFIG="${KCFG}"


    log_info "Using kubeconfig: ${KUBECONFIG}"



    #############################################
    # GENERATE WORKER JOIN COMMAND
    #############################################

    log_info "Creating worker join command"


    local WORKER_JOIN


    WORKER_JOIN=$(
        kubeadm token create \
            --print-join-command
    )


    if [[ -z "${WORKER_JOIN}" ]]; then

        log_error "Failed to generate worker join command."
        return 1

    fi



    cat > "${ROOT_DIR}/generated/worker_join.sh" <<EOF
#!/usr/bin/env bash

set -e

${WORKER_JOIN}

EOF


    chmod +x "${ROOT_DIR}/generated/worker_join.sh"



    #############################################
    # UPLOAD CONTROL PLANE CERTIFICATES
    #############################################

    log_info "Uploading control-plane certificates"


    local CERT_KEY


    CERT_KEY=$(
        kubeadm init phase upload-certs \
            --upload-certs 2>&1 \
        | grep -E '^[a-f0-9]{64}$' \
        | tail -1
    )


    if [[ -z "${CERT_KEY}" ]]; then

        log_error "Failed to generate certificate key."
        return 1

    fi



    #############################################
    # GENERATE CONTROL PLANE JOIN COMMAND
    #############################################

    log_info "Creating control-plane join command"


    local CONTROL_JOIN


    CONTROL_JOIN=$(
        kubeadm token create \
            --print-join-command
    )


    if [[ -z "${CONTROL_JOIN}" ]]; then

        log_error "Failed to generate control-plane join command."
        return 1

    fi



    cat > "${ROOT_DIR}/generated/controlplane_join.sh" <<EOF
#!/usr/bin/env bash

set -e

${CONTROL_JOIN} \\
    --control-plane \\
    --certificate-key ${CERT_KEY}

EOF


    chmod +x "${ROOT_DIR}/generated/controlplane_join.sh"



    #############################################
    # VERIFY FILES
    #############################################

    if [[ ! -f "${ROOT_DIR}/generated/worker_join.sh" ]]; then

        log_error "Worker join script was not created."
        return 1

    fi


    if [[ ! -f "${ROOT_DIR}/generated/controlplane_join.sh" ]]; then

        log_error "Control-plane join script was not created."
        return 1

    fi



    log_ok "Join commands generated."

}