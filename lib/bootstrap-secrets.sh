#!/usr/bin/env bash


#############################################
# ENCRYPT BOOTSTRAP FILES
#############################################

command -v sops >/dev/null || {
    log_error "sops is not installed"
    exit 1
}

command -v age-keygen >/dev/null || {
    log_error "age is not installed"
    exit 1
}


create_bootstrap_package() {


    BOOTSTRAP_DIR="${ROOT_DIR}/generated/bootstrap"


    mkdir -p "${BOOTSTRAP_DIR}/secrets"



    log_info "Creating encrypted bootstrap package"



    encrypt_bootstrap_file \
    "${ROOT_DIR}/generated/worker_join.sh" \
    "${BOOTSTRAP_DIR}/secrets/worker_join.enc"



    encrypt_bootstrap_file \
    "${ROOT_DIR}/generated/controlplane_join.sh" \
    "${BOOTSTRAP_DIR}/secrets/controlplane_join.enc"



    CLUSTER_INFO="${ROOT_DIR}/generated/cluster-info.yaml"

    if [[ ! -f "${CLUSTER_INFO}" ]]; then
        log_error "Missing cluster info file: ${CLUSTER_INFO}"
        exit 1
    fi

    cp \
        "${CLUSTER_INFO}" \
        "${BOOTSTRAP_DIR}/"



    log_ok "Bootstrap package created."

}

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