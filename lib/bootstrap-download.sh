#!/usr/bin/env bash


download_bootstrap_secrets() {

    log_info "Downloading bootstrap secrets"


    #############################################
    # Bootstrap Repository
    #############################################

    if [[ -z "${BOOTSTRAP_REPO:-}" ]]; then

        echo
        echo "Bootstrap repository is not configured."
        echo

        read -rp "Enter bootstrap repository URL: " BOOTSTRAP_REPO

        export BOOTSTRAP_REPO

    fi


    TEMP_DIR="/tmp/bootstrap-download"

    rm -rf "${TEMP_DIR}"


    log_info "Cloning bootstrap repository"


    if ! git clone \
        "${BOOTSTRAP_REPO}" \
        "${TEMP_DIR}"
    then

        log_error "Failed to clone bootstrap repository."

        exit 1

    fi



    #############################################
    # AGE KEY
    #############################################

    AGE_DIR="${HOME}/.config/sops/age"
    AGE_KEY_FILE="${AGE_DIR}/keys.txt"


    mkdir -p "${AGE_DIR}"


    if [[ ! -f "${AGE_KEY_FILE}" ]]; then


        echo
        echo "================================================="
        echo " AGE PRIVATE KEY REQUIRED"
        echo "================================================="
        echo
        echo "Paste your AGE private key:"
        echo


        read -rsp "> " AGE_PRIVATE_KEY
        echo


        echo "${AGE_PRIVATE_KEY}" > "${AGE_KEY_FILE}"

        chmod 600 "${AGE_KEY_FILE}"


        log_ok "AGE key saved."

    fi



    #############################################
    # Determine Node Join Type
    #############################################

    mkdir -p "${ROOT_DIR}/generated/secrets"


    case "${NODE_ROLE}" in


        worker)

            ENCRYPTED_FILE="${TEMP_DIR}/secrets/worker_join.enc"
            OUTPUT_FILE="${ROOT_DIR}/generated/secrets/worker_join.sh"
            JOIN_NAME="worker"

            ;;


        control-plane|controlplane)

            ENCRYPTED_FILE="${TEMP_DIR}/secrets/controlplane_join.enc"
            OUTPUT_FILE="${ROOT_DIR}/generated/secrets/controlplane_join.sh"
            JOIN_NAME="control-plane"

            ;;


        *)

            log_error "Unknown NODE_ROLE: ${NODE_ROLE}"

            exit 1

            ;;

    esac



    #############################################
    # Decrypt Join Command
    #############################################

    if [[ -f "${ENCRYPTED_FILE}" ]]; then


        log_info "Found encrypted ${JOIN_NAME} join command."


        if SOPS_AGE_KEY_FILE="${AGE_KEY_FILE}" \
            sops --decrypt "${ENCRYPTED_FILE}" > "${OUTPUT_FILE}"
        then


            chmod +x "${OUTPUT_FILE}"


            log_ok "${JOIN_NAME} join command decrypted."


        else


            log_error "Failed to decrypt ${JOIN_NAME} join command."


            rm -f "${OUTPUT_FILE}"


        fi


    else


        log_error "Encrypted ${JOIN_NAME} join command not found."



    fi



    #############################################
    # Validate Decrypted Join Script
    #############################################

    if [[ -f "${OUTPUT_FILE}" ]] && \
       grep -q "kubeadm join" "${OUTPUT_FILE}"; then


        log_ok "${JOIN_NAME} join command ready."


        log_ok "Bootstrap secrets ready."

        return 0


    fi



    #############################################
    # Manual Fallback
    #############################################

    echo
    echo "================================================="
    echo " MANUAL ${JOIN_NAME^^} JOIN"
    echo "================================================="
    echo
    echo "Paste the FULL kubeadm join command."
    echo
    echo "Example:"
    echo
    echo "kubeadm join 192.168.1.10:6443 --token TOKEN --discovery-token-ca-cert-hash sha256:HASH"
    echo


    read -rp "> " JOIN_COMMAND



    cat > "${OUTPUT_FILE}" <<EOF
#!/usr/bin/env bash

${JOIN_COMMAND}
EOF


    chmod +x "${OUTPUT_FILE}"


    log_ok "${JOIN_NAME} join command saved."


    log_ok "Bootstrap secrets ready."

}