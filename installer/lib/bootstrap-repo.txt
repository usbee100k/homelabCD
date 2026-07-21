#!/usr/bin/env bash


clone_bootstrap_repo() {


    if [[ -z "${BOOTSTRAP_REPO}" ]]; then

        read -rp \
        "Private bootstrap repository URL: " \
        BOOTSTRAP_REPO

    fi



    mkdir -p /tmp/homelab-bootstrap



    git clone \
        --branch "${BOOTSTRAP_BRANCH}" \
        "${BOOTSTRAP_REPO}" \
        /tmp/homelab-bootstrap



    log_ok "Bootstrap repository downloaded."

}