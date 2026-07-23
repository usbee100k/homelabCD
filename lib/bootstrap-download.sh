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
        echo "Paste the AGE private key from the control plane:"
        echo
        echo "Example:"
        echo "AGE-SECRET-KEY-1..."
        echo


        read -rs AGE_PRIVATE_KEY


        echo "${AGE_PRIVATE_KEY}" > "${AGE_KEY_FILE}"


        chmod 600 "${AGE_KEY_FILE}"


        echo

        log_ok "AGE key saved."

    fi



    #############################################
    # Prepare Output
    #############################################

    mkdir -p \
        "${ROOT_DIR}/generated/secrets"



    ENCRYPTED_FILE="${TEMP_DIR}/secrets/worker_join.enc"

    OUTPUT_FILE="${ROOT_DIR}/generated/secrets/worker_join.sh"



    if [[ ! -f "${ENCRYPTED_FILE}" ]]; then

        log_error "Encrypted worker join file missing."

        echo
        echo "Expected:"
        echo "${ENCRYPTED_FILE}"
        echo

        exit 1

    fi



    #############################################
    # Decrypt
    #############################################

    log_info "Decrypting worker join command"



    if ! SOPS_AGE_KEY_FILE="${AGE_KEY_FILE}" \
        sops \
        --decrypt \
        "${ENCRYPTED_FILE}" \
        > "${OUTPUT_FILE}"
    then

        log_error "Failed to decrypt worker join command."

        exit 1

    fi



    chmod +x "${OUTPUT_FILE}"



    log_ok "Worker join command ready."

}