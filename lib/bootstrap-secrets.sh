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




encrypt_bootstrap_file() {

    SOURCE_FILE="$1"
    OUTPUT_FILE="$2"

    if [[ ! -f "${SOURCE_FILE}" ]]; then
        log_error "Missing file: ${SOURCE_FILE}"
        exit 1
    fi

    # Load AGE public key if not already set
    if [[ -z "${AGE_PUBLIC_KEY}" ]]; then

        AGE_KEY_FILE="${HOME}/.config/sops/age/keys.txt"

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

}