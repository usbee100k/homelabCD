#!/usr/bin/env bash

install_helm() {

    log_info "Installing Helm..."

    if command -v helm >/dev/null 2>&1; then
        log_ok "Helm already installed."
        return
    fi

    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

    log_ok "Helm installed."

}
