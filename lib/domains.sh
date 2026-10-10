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
# LET'S ENCRYPT ACME EMAIL
#############################################

configure_acme_email() {

    if [[ -n "${ACME_EMAIL:-}" ]]; then
        log_ok "Let's Encrypt email: ${ACME_EMAIL}"
        return 0
    fi

    echo
    echo "============================================="
    echo " Let's Encrypt Email"
    echo "============================================="
    echo
    echo "cert-manager uses this address for ACME"
    echo "account registration and expiry notices."
    echo

    while true; do

        read -rp "Let's Encrypt email: " ACME_EMAIL

        ACME_EMAIL="${ACME_EMAIL//[[:space:]]/}"

        if [[ -z "${ACME_EMAIL}" ]]; then
            echo "[ERROR] Email cannot be empty."
            continue
        fi

        if [[ "${ACME_EMAIL}" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
            break
        fi

        echo "[ERROR] Invalid email: ${ACME_EMAIL}"

    done

    export ACME_EMAIL

    save_config

    log_ok "Let's Encrypt email saved: ${ACME_EMAIL}"
}


#############################################
# DUCKDNS
#############################################
#
# The token is held in memory only and written to the
# cluster as a Secret; it is never saved to config/ or
# pushed to the GitOps repository.
#############################################

configure_duckdns() {

    if [[ "${BASE_DOMAIN}" != *.duckdns.org ]]; then
        log_info "Base domain is not a DuckDNS domain; skipping DuckDNS."
        return 0
    fi

    DUCKDNS_DOMAIN="${BASE_DOMAIN%.duckdns.org}"
    DUCKDNS_DOMAIN="${DUCKDNS_DOMAIN##*.}"

    export DUCKDNS_DOMAIN

    if [[ -n "${DUCKDNS_TOKEN:-}" ]]; then
        log_ok "DuckDNS token provided for ${DUCKDNS_DOMAIN}.duckdns.org"
        return 0
    fi

    echo
    echo "============================================="
    echo " DuckDNS"
    echo "============================================="
    echo
    echo "The cluster keeps ${DUCKDNS_DOMAIN}.duckdns.org pointed at"
    echo "the ingress-nginx LoadBalancer IP on your LAN. Every"
    echo "*.${DUCKDNS_DOMAIN}.duckdns.org hostname resolves to it,"
    echo "so services are reachable on your LAN only."
    echo
    echo "Find your token at https://www.duckdns.org"
    echo

    local result

    while true; do

        read -rsp "DuckDNS token: " DUCKDNS_TOKEN
        echo

        DUCKDNS_TOKEN="${DUCKDNS_TOKEN//[[:space:]]/}"

        if [[ ! "${DUCKDNS_TOKEN}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
            echo "[ERROR] Token should look like xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
            continue
        fi

        # Verify with the LAN VIP so the public IP is never published;
        # the in-cluster updater replaces it with the ingress IP.
        result=$(
            curl -fsS --max-time 30 \
                "https://www.duckdns.org/update?domains=${DUCKDNS_DOMAIN}&token=${DUCKDNS_TOKEN}&ip=${VIP_ADDRESS}" \
                2>/dev/null
        ) || result=""

        if [[ "${result}" == "OK" ]]; then
            break
        fi

        echo "[ERROR] DuckDNS rejected the token for ${DUCKDNS_DOMAIN}.duckdns.org"

    done

    export DUCKDNS_TOKEN

    log_ok "DuckDNS verified: ${DUCKDNS_DOMAIN}.duckdns.org"
}


install_duckdns_secret() {

    if [[ -z "${DUCKDNS_DOMAIN:-}" || -z "${DUCKDNS_TOKEN:-}" ]]; then
        log_info "DuckDNS not configured; skipping secret."
        return 0
    fi

    log_info "Creating DuckDNS secret..."

    kubectl create namespace duckdns \
        --dry-run=client -o yaml |
        kubectl apply -f -

    kubectl -n duckdns create secret generic duckdns \
        --from-literal=domain="${DUCKDNS_DOMAIN}" \
        --from-literal=token="${DUCKDNS_TOKEN}" \
        --dry-run=client -o yaml |
        kubectl apply -f -

    log_ok "DuckDNS secret created."
}


#############################################
# METALLB IP POOL
#############################################

ip_to_int() {

    local a b c d

    IFS=. read -r a b c d <<< "$1"

    echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}


configure_metallb_range() {

    if [[ -n "${METALLB_RANGE:-}" ]]; then
        log_ok "MetalLB IP pool: ${METALLB_RANGE}"
        return 0
    fi

    local octet='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
    local ip="${octet}\\.${octet}\\.${octet}\\.${octet}"
    local start end vip

    echo
    echo "============================================="
    echo " MetalLB LoadBalancer IP Pool"
    echo "============================================="
    echo
    echo "LoadBalancer services get IPs from this range."
    echo "Use free addresses on your LAN, outside your"
    echo "router's DHCP range, and not including the VIP"
    echo "(${VIP_ADDRESS:-unset})."
    echo
    echo "Examples:"
    echo "  192.168.50.200-192.168.50.220"
    echo "  192.168.50.192/27"
    echo

    while true; do

        read -rp "MetalLB IP range: " METALLB_RANGE

        METALLB_RANGE="${METALLB_RANGE//[[:space:]]/}"

        if [[ -z "${METALLB_RANGE}" ]]; then
            echo "[ERROR] IP range cannot be empty."
            continue
        fi

        if [[ "${METALLB_RANGE}" =~ ^${ip}/([0-9]|[12][0-9]|3[0-2])$ ]]; then
            break
        fi

        if [[ "${METALLB_RANGE}" =~ ^(${ip})-(${ip})$ ]]; then

            start=$(ip_to_int "${METALLB_RANGE%-*}")
            end=$(ip_to_int "${METALLB_RANGE#*-}")

            if (( start > end )); then
                echo "[ERROR] Range start must be before range end."
                continue
            fi

            if [[ -n "${VIP_ADDRESS:-}" && "${VIP_ADDRESS}" =~ ^${ip}$ ]]; then

                vip=$(ip_to_int "${VIP_ADDRESS}")

                if (( vip >= start && vip <= end )); then
                    echo "[ERROR] Range contains the control plane VIP (${VIP_ADDRESS})."
                    continue
                fi
            fi

            break
        fi

        echo "[ERROR] Invalid range: ${METALLB_RANGE}"
        echo "        Use START-END or CIDR notation."

    done

    export METALLB_RANGE

    save_config

    log_ok "MetalLB IP pool saved: ${METALLB_RANGE}"
}


#############################################
# RENDER GITOPS INGRESSES
#############################################

# render_gitops_ingresses [dir]: fills in the hostnames in dir
# (default: the GitOps checkout).
render_gitops_ingresses() {

    local dir="${1:-${GITOPS_DIR:-}}"

    log_info "Rendering GitOps ingress hostnames..."

    [[ -n "${BASE_DOMAIN:-}" ]] || \
        die "BASE_DOMAIN missing"

    [[ -n "${dir}" ]] || \
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

    while IFS=$'\t' read -r name path subdomain; do

        [[ -n "${path}" ]] || continue
        [[ -n "${subdomain}" ]] || continue

        hostname="${subdomain}.${BASE_DOMAIN}"
        target="${dir}/${path}"

        if [[ ! -f "${target}" ]]; then
            log_warn "Ingress file not found: ${target}"
            continue
        fi

        log_info "Rendering ${hostname}  (${name}: ${path})"

        sed -i \
            "s|__HOSTNAME__|${hostname}|g" \
            "${target}"

        count=$((count + 1))

    done < <(
        yq -r '.ingresses[] | [.name, .path, .subdomain] | @tsv' \
            "${INGRESS_CONFIG}"
    )

    log_ok "Rendered ${count} GitOps ingress(s)."
}