#!/usr/bin/env bash

set -Eeuo pipefail


#############################################
# BOOTSTRAP REPOSITORY AUTH
#############################################


_bootstrap_ssh_url()
{
    local url="${BOOTSTRAP_REPO:-}"

    [[ -n "$url" ]] || {
        die "BOOTSTRAP_REPO is empty."
    }

    # Already SSH
    if [[ "$url" == git@* ]]; then
        echo "$url"
        return
    fi

    # Convert HTTPS to SSH
    sed -E 's#https?://([^/@]+@)?([^/]+)/#git@\2:#' <<< "$url"
}


validate_bootstrap_config()
{
    log_info "Validating bootstrap repository configuration"


    [[ -n "${BOOTSTRAP_REPO:-}" ]] || \
        die "BOOTSTRAP_REPO is missing."


    [[ -n "${SSH_KEY_PATH:-}" ]] || \
        die "SSH_KEY_PATH is missing."


    [[ -f "${SSH_KEY_PATH}" ]] || \
        die "SSH key not found: ${SSH_KEY_PATH}"


    export BOOTSTRAP_REPO="$(_bootstrap_ssh_url)"


    log_ok "Bootstrap repository configuration valid"
}