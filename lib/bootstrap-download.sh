#!/usr/bin/env bash


download_bootstrap_secrets() {

    log_info "Downloading bootstrap secrets"

    #############################################
    # Determine local encrypted package
    #############################################

    local BOOTSTRAP_PACKAGE_DIR
    BOOTSTRAP_PACKAGE_DIR="${BOOTSTRAP_PACKAGE_DIR:-${ROOT_DIR}/generated/bootstrap}"

    local TEMP_DIR=""
    local ENCRYPTED_FILE=""
    local OUTPUT_FILE=""
    local JOIN_NAME=""

    #############################################
    # Determine node join type
    #############################################

    case "${NODE_ROLE}" in

        worker)

            ENCRYPTED_FILE="${BOOTSTRAP_PACKAGE_DIR}/secrets/worker_join.enc"
            OUTPUT_FILE="${ROOT_DIR}/generated/secrets/worker_join.sh"
            JOIN_NAME="worker"

            ;;

        control-plane|controlplane)

            ENCRYPTED_FILE="${BOOTSTRAP_PACKAGE_DIR}/secrets/controlplane_join.enc"
            OUTPUT_FILE="${ROOT_DIR}/generated/secrets/controlplane_join.sh"
            JOIN_NAME="control-plane"

            ;;

        *)

            log_error "Unknown NODE_ROLE: ${NODE_ROLE}"
            return 1

            ;;

    esac

    #############################################
    # Prefer local encrypted bootstrap package
    #############################################

    if [[ -f "${ENCRYPTED_FILE}" ]]; then

        log_info "Using local encrypted bootstrap package:"
        log_info "${ENCRYPTED_FILE}"

    else

        #############################################
        # Fall back to GitHub bootstrap repository
        #############################################

        if [[ -z "${BOOTSTRAP_REPO:-}" ]]; then

            echo
            echo "Bootstrap repository is not configured."
            echo

            read -rp "Enter bootstrap repository URL: " BOOTSTRAP_REPO

            if [[ -z "${BOOTSTRAP_REPO}" ]]; then
                log_error "Bootstrap repository URL is required."
                return 1
            fi

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
            return 1

        fi

        ENCRYPTED_FILE="${TEMP_DIR}/secrets/${JOIN_NAME//-/_}_join.enc"

        if [[ "${JOIN_NAME}" == "control-plane" ]]; then
            ENCRYPTED_FILE="${TEMP_DIR}/secrets/controlplane_join.enc"
        fi

    fi

    #############################################
    # AGE KEY
    #############################################

    local AGE_DIR
    local AGE_KEY_FILE

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

        local AGE_PRIVATE_KEY

        read -rsp "> " AGE_PRIVATE_KEY
        echo

        printf '%s\n' "${AGE_PRIVATE_KEY}" > "${AGE_KEY_FILE}"

        chmod 600 "${AGE_KEY_FILE}"

        log_ok "AGE key saved."
    fi

    #############################################
    # Validate encrypted file
    #############################################

    if [[ ! -f "${ENCRYPTED_FILE}" ]]; then

        log_error "Encrypted ${JOIN_NAME} join command not found:"
        log_error "${ENCRYPTED_FILE}"

        [[ -n "${TEMP_DIR}" ]] && rm -rf "${TEMP_DIR}"

        return 1
    fi

    #############################################
    # Prepare output directory
    #############################################

    mkdir -p "${ROOT_DIR}/generated/secrets"

    #############################################
    # Decrypt join command
    #############################################

    log_info "Found encrypted ${JOIN_NAME} join command."

    if SOPS_AGE_KEY_FILE="${AGE_KEY_FILE}" \
        sops --decrypt "${ENCRYPTED_FILE}" > "${OUTPUT_FILE}"
    then

        chmod +x "${OUTPUT_FILE}"

        log_ok "${JOIN_NAME} join command decrypted."

    else

        log_error "Failed to decrypt ${JOIN_NAME} join command."

        rm -f "${OUTPUT_FILE}"

        [[ -n "${TEMP_DIR}" ]] && rm -rf "${TEMP_DIR}"

        return 1
    fi

    #############################################
    # Validate decrypted join script
    #############################################

    if [[ -f "${OUTPUT_FILE}" ]] && \
       grep -q "kubeadm join" "${OUTPUT_FILE}"; then

        log_ok "${JOIN_NAME} join command ready."
        log_ok "Bootstrap secrets ready."

        [[ -n "${TEMP_DIR}" ]] && rm -rf "${TEMP_DIR}"

        return 0
    fi

    log_error "Decrypted ${JOIN_NAME} join script is invalid."

    rm -f "${OUTPUT_FILE}"

    [[ -n "${TEMP_DIR}" ]] && rm -rf "${TEMP_DIR}"

    return 1
}