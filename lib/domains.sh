#!/usr/bin/env bash

set -Eeuo pipefail

#############################################
# BASE DOMAIN
#############################################

configure_base_domain() {

    if [[ -n "${BASE_DOMAIN:-}" ]]; then
        log_ok "Base domain: ${BASE_DOMAIN}"
        return 0
    fi

    echo
    echo "============================================="
    echo " Domain Configuration"
    echo "============================================="
    echo
    echo "Enter the base domain for your homelab."
    echo
    echo "Example:"
    echo "  user.duckdns.org"
    echo

    while true; do

        read -rp "Base domain: " BASE_DOMAIN

        BASE_DOMAIN="${BASE_DOMAIN#https://}"
        BASE_DOMAIN="${BASE_DOMAIN#http://}"
        BASE_DOMAIN="${BASE_DOMAIN%/}"

        if [[ -z "${BASE_DOMAIN}" ]]; then
            echo "[ERROR] Base domain cannot be empty."
            continue
        fi

        if [[ "${BASE_DOMAIN}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
            break
        fi

        echo "[ERROR] Invalid domain: ${BASE_DOMAIN}"

    done

    export BASE_DOMAIN

    save_config

    log_ok "Base domain saved: ${BASE_DOMAIN}"
}


#############################################
# RENDER GITOPS INGRESSES
#############################################

render_gitops_ingresses() {

    log_info "Rendering GitOps ingress hostnames..."

    [[ -n "${BASE_DOMAIN:-}" ]] || \
        die "BASE_DOMAIN missing"

    [[ -n "${GITOPS_DIR:-}" ]] || \
        die "GITOPS_DIR missing"

    local INGRESS_CONFIG
    INGRESS_CONFIG="${ROOT_DIR}/config/ingress.yaml"

    [[ -f "${INGRESS_CONFIG}" ]] || {
        log_warn "No ingress configuration found."
        return 0
    }

    local count=0
    local path
    local subdomain
    local hostname
    local target

    while IFS=$'\t' read -r path subdomain; do

        [[ -n "${path}" ]] || continue
        [[ -n "${subdomain}" ]] || continue

        hostname="${subdomain}.${BASE_DOMAIN}"
        target="${GITOPS_DIR}/${path}"

        if [[ ! -f "${target}" ]]; then
            log_warn "Ingress file not found: ${target}"
            continue
        fi

        log_info "Rendering ${hostname}"

        sed -i \
            "s|__HOSTNAME__|${hostname}|g" \
            "${target}"

        count=$((count + 1))

    done < <(
        yq -r '.ingresses[] | [.path, .subdomain] | @tsv' \
            "${INGRESS_CONFIG}"
    )

    log_ok "Rendered ${count} GitOps ingress(s)."
}