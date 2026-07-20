#!/usr/bin/env bash



download_bootstrap_secrets() {


    mkdir -p "${ROOT_DIR}/generated/secrets"



    git clone \
    "${BOOTSTRAP_REPO}" \
    /tmp/bootstrap-download



    sops \
    --decrypt \
    /tmp/bootstrap-download/secrets/worker_join.enc \
    > "${ROOT_DIR}/generated/secrets/worker_join.sh"



    sops \
    --decrypt \
    /tmp/bootstrap-download/secrets/controlplane_join.enc \
    > "${ROOT_DIR}/generated/secrets/controlplane_join.sh"



    chmod 700 \
    "${ROOT_DIR}/generated/secrets/"*



    log_ok "Bootstrap secrets downloaded."

}