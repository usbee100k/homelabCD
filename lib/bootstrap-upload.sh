#!/usr/bin/env bash


upload_bootstrap_package() {


    if [[ -z "${BOOTSTRAP_REPO}" ]]; then

        log_error "Bootstrap repository missing."

        exit 1

    fi



    TEMP_DIR="/tmp/bootstrap-upload"



    rm -rf "${TEMP_DIR}"



    git clone \
    "${BOOTSTRAP_REPO}" \
    "${TEMP_DIR}"



    cp -r \
    "${ROOT_DIR}/generated/bootstrap/"* \
    "${TEMP_DIR}/"



    cd "${TEMP_DIR}"



    git add .

    git commit \
    -m "Update encrypted cluster bootstrap"



    git push



    cd "${ROOT_DIR}"



    log_ok "Encrypted bootstrap uploaded."

}