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
    # Worker Join Command
    #############################################

    mkdir -p "${ROOT_DIR}/generated/secrets"

    ENCRYPTED_FILE="${TEMP_DIR}/secrets/worker_join.enc"
    OUTPUT_FILE="${ROOT_DIR}/generated/secrets/worker_join.sh"


    if [[ -f "${ENCRYPTED_FILE}" ]]; then

        log_info "Found encrypted worker join command."

        if SOPS_AGE_KEY_FILE="${AGE_KEY_FILE}" \
            sops --decrypt "${ENCRYPTED_FILE}" > "${OUTPUT_FILE}"
        then

            chmod +x "${OUTPUT_FILE}"

            log_ok "Worker join command decrypted."

        else

            log_error "Failed to decrypt worker join command."

            rm -f "${OUTPUT_FILE}"

        fi

    else

        log_error "Encrypted worker join command not found."

    fi


    #############################################
    # Manual Fallback
    #############################################

    if [[ ! -f "${OUTPUT_FILE}" ]]; then

        echo
        echo "================================================="
        echo " MANUAL WORKER JOIN"
        echo "================================================="
        echo
        echo "Paste the FULL kubeadm join command."
        echo
        echo "Example:"
        echo "kubeadm join 192.168.1.10:6443 --token ... --discovery-token-ca-cert-hash sha256:..."
        echo

        read -rp "> " JOIN_COMMAND

        cat > "${OUTPUT_FILE}" <<EOF
#!/usr/bin/env bash
${JOIN_COMMAND}
EOF

        chmod +x "${OUTPUT_FILE}"

        log_ok "Worker join command saved."

    fi


    log_ok "Bootstrap secrets ready."

}