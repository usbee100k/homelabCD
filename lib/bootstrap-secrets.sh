#!/usr/bin/env bash


#############################################
# ENCRYPT BOOTSTRAP FILES
#############################################


encrypt_bootstrap_file() {


    SOURCE_FILE="$1"

    OUTPUT_FILE="$2"


    if [[ ! -f "${SOURCE_FILE}" ]]; then

        log_error "Missing file: ${SOURCE_FILE}"

        exit 1

    fi



    sops \
    --encrypt \
    --age "${AGE_PUBLIC_KEY}" \
    "${SOURCE_FILE}" \
    > "${OUTPUT_FILE}"


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



    cp \
    "${ROOT_DIR}/generated/cluster-info.yaml" \
    "${BOOTSTRAP_DIR}/"



    log_ok "Bootstrap package created."

}