#!/usr/bin/env bash


download_bootstrap_secrets() {


    log_info "Downloading bootstrap secrets"


    if [[ -z "${BOOTSTRAP_REPO:-}" ]]; then

        log_error "BOOTSTRAP_REPO is not configured."

        echo
        echo "Set this in:"
        echo "${ROOT_DIR}/config/defaults.env"
        echo

        exit 1

    fi



    TEMP_DIR="/tmp/bootstrap-download"


    rm -rf "${TEMP_DIR}"



    log_info "Cloning bootstrap repository"



    git clone \
        "${BOOTSTRAP_REPO}" \
        "${TEMP_DIR}"


    if [[ $? -ne 0 ]]; then

        log_error "Failed to clone bootstrap repository."

        exit 1

    fi

}