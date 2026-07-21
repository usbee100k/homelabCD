#!/usr/bin/env bash


decrypt_bootstrap_secrets() {


    log_info "Decrypting bootstrap secrets"


    mkdir -p "${ROOT_DIR}/generated/secrets"



    sops \
    -d \
    /tmp/homelab-bootstrap/secrets/worker_join.enc \
    > "${ROOT_DIR}/generated/secrets/worker_join.sh"



    sops \
    -d \
    /tmp/homelab-bootstrap/secrets/controlplane_join.enc \
    > "${ROOT_DIR}/generated/secrets/controlplane_join.sh"



    chmod 700 \
    "${ROOT_DIR}/generated/secrets/"*



    log_ok "Bootstrap secrets decrypted."

}