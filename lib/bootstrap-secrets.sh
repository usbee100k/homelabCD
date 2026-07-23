#!/usr/bin/env bash


ensure_age_key() {

    if [[ -n "${SUDO_USER}" ]]; then
        REAL_HOME=$(eval echo "~${SUDO_USER}")
    else
        REAL_HOME="${HOME}"
    fi


    AGE_DIR="${REAL_HOME}/.config/sops/age"
    AGE_KEY_FILE="${AGE_DIR}/keys.txt"


    if [[ -f "${AGE_KEY_FILE}" ]]; then

        log_ok "Age key already exists: ${AGE_KEY_FILE}"

    else

        log_info "Generating new age key"

        mkdir -p "${AGE_DIR}"

        age-keygen -o "${AGE_KEY_FILE}"

        chmod 600 "${AGE_KEY_FILE}"

        log_ok "Age key created"
    fi

}


encrypt_bootstrap_file() {

    SOURCE_FILE="$1"
    OUTPUT_FILE="$2"

    if [[ ! -f "${SOURCE_FILE}" ]]; then
        log_error "Missing file: ${SOURCE_FILE}"
        exit 1
    fi


    # Load AGE public key if not already set
    if [[ -z "${AGE_PUBLIC_KEY}" ]]; then

        # Resolve real user's home directory when running with sudo
        if [[ -n "${SUDO_USER}" ]]; then
            REAL_HOME=$(eval echo "~${SUDO_USER}")
        else
            REAL_HOME="${HOME}"
        fi

        AGE_KEY_FILE="${REAL_HOME}/.config/sops/age/keys.txt"


        if [[ ! -f "${AGE_KEY_FILE}" ]]; then
            log_error "Missing age key file: ${AGE_KEY_FILE}"
            exit 1
        fi


        AGE_PUBLIC_KEY=$(age-keygen -y "${AGE_KEY_FILE}")


        if [[ -z "${AGE_PUBLIC_KEY}" ]]; then
            log_error "Failed to generate AGE_PUBLIC_KEY"
            exit 1
        fi


        export AGE_PUBLIC_KEY

        log_info "Using AGE public key: ${AGE_PUBLIC_KEY}"
    fi


    log_info "Encrypting ${SOURCE_FILE}"


    sops \
        --encrypt \
        --age "${AGE_PUBLIC_KEY}" \
        "${SOURCE_FILE}" \
        > "${OUTPUT_FILE}"


    if [[ $? -ne 0 ]]; then
        log_error "Encryption failed for ${SOURCE_FILE}"
        exit 1
    fi


    log_ok "Encrypted: ${OUTPUT_FILE}"

}