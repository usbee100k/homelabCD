#!/usr/bin/env bash

set -Eeuo pipefail


#############################################
# BOOTSTRAP SSH AUTHENTICATION
#############################################


setup_bootstrap_ssh()
{
    log_info "Setting up Argo CD SSH authentication"


    local ssh_dir

    ssh_dir="$(dirname "${SSH_KEY_PATH}")"


    mkdir -p "${ssh_dir}"

    chmod 700 "${ssh_dir}"



    if [[ ! -f "${SSH_KEY_PATH}" ]]; then

        log_info "Generating Argo CD SSH key"


        ssh-keygen \
            -t ed25519 \
            -f "${SSH_KEY_PATH}" \
            -C "argocd-bootstrap" \
            -N ""


        chmod 600 "${SSH_KEY_PATH}"

    else

        log_info "Existing Argo CD SSH key found"

    fi



    log_ok "SSH key ready"



    echo
    echo "================================================"
    echo " ADD THIS DEPLOY KEY TO GITHUB"
    echo "================================================"
    echo

    cat "${SSH_KEY_PATH}.pub"

    echo
    echo "================================================"
    echo

}



_bootstrap_ssh_url()
{
    local url="${BOOTSTRAP_REPO:-}"


    [[ -n "$url" ]] || \
        die "BOOTSTRAP_REPO missing"



    if [[ "$url" == git@* ]]; then
        echo "$url"
        return
    fi


    sed \
    -E \
    's#https?://([^/@]+@)?([^/]+)/#git@\2:#' \
    <<<"$url"
}



validate_bootstrap_config()
{

    log_info "Validating bootstrap configuration"


    [[ -n "${BOOTSTRAP_REPO:-}" ]] || \
        die "BOOTSTRAP_REPO missing"



    [[ -f "${SSH_KEY_PATH}" ]] || \
        die "SSH key missing"



    export BOOTSTRAP_REPO="$(_bootstrap_ssh_url)"



    log_ok "Bootstrap configuration valid"

}