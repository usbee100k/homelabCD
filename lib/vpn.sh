#!/usr/bin/env bash

set -Eeuo pipefail

#############################################
# WIREGUARD VPN (wg-easy)
#############################################
#
# Optional remote access. wg-easy runs in the cluster
# (apps/infrastructure/wg-easy) behind a fixed MetalLB IP; your
# router forwards UDP VPN_PORT to that IP. Clients get their
# own 10.8.0.x address and are routed (NAT) into the node
# subnet(s) in VPN_ALLOWED_IPS, so they can reach every node,
# the VIP and LoadBalancer services as if they were home.
#
# The public endpoint is a DuckDNS name kept at your PUBLIC
# IP by the DuckDNS updater (your base domain stays LAN-only).
#
# The wg-easy admin password is stored only in the cluster
# (Secret wg-easy/wg-easy-init), never in git.
#############################################

# Prints the IPv4 CIDR of the node's own subnet, e.g. 192.168.50.0/24.
node_subnet() {

    local iface cidr ip prefix ipnum mask

    iface="$(ip route | awk '/^default/ {print $5; exit}')"
    cidr="$(ip -o -4 addr show dev "${iface}" 2>/dev/null | awk '{print $4; exit}')"

    [[ -n "${cidr}" ]] || return 1

    ip="${cidr%/*}"
    prefix="${cidr#*/}"

    ipnum="$(ip_to_int "${ip}")"
    mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    ipnum=$(( ipnum & mask ))

    printf '%d.%d.%d.%d/%d\n' \
        $(( (ipnum >> 24) & 255 )) $(( (ipnum >> 16) & 255 )) \
        $(( (ipnum >> 8) & 255 )) $(( ipnum & 255 )) "${prefix}"
}

int_to_ip() {
    local n="$1"
    printf '%d.%d.%d.%d' $(( (n >> 24) & 255 )) $(( (n >> 16) & 255 )) $(( (n >> 8) & 255 )) $(( n & 255 ))
}

# Last usable address of the MetalLB range (START-END or CIDR).
metallb_last_ip() {

    local range="${METALLB_RANGE:-}" base prefix n

    if [[ "${range}" == */* ]]; then
        base="${range%/*}"
        prefix="${range#*/}"
        n=$(( $(ip_to_int "${base}") | ((1 << (32 - prefix)) - 1) ))
        int_to_ip $(( n - 1 ))
    elif [[ "${range}" == *-* ]]; then
        echo "${range#*-}"
    fi
}

ip_in_metallb_range() {

    local ip range="${METALLB_RANGE:-}" start end base prefix n

    ip="$(ip_to_int "$1")"

    if [[ "${range}" == */* ]]; then
        base="${range%/*}"
        prefix="${range#*/}"
        start=$(( $(ip_to_int "${base}") & ((0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF) ))
        end=$(( start | ((1 << (32 - prefix)) - 1) ))
    elif [[ "${range}" == *-* ]]; then
        start="$(ip_to_int "${range%-*}")"
        end="$(ip_to_int "${range#*-}")"
    else
        return 1
    fi

    (( ip >= start && ip <= end ))
}

#############################################
# Prompts (bootstrap, or "Set Up VPN" later)
#############################################

configure_vpn() {

    local force="${1:-}"

    if [[ "${force}" != "--force" && "${VPN_ENABLED:-false}" == "true" ]]; then
        log_ok "VPN: wg-easy at ${VPN_ENDPOINT}:${VPN_PORT} (${VPN_LB_IP})"
        return 0
    fi

    echo
    echo "============================================="
    echo " WireGuard VPN (optional)"
    echo "============================================="
    echo
    echo "Reach the cluster from anywhere: wg-easy runs in the cluster and"
    echo "VPN clients (laptops, KubesTUI on a workstation) get routed into"
    echo "your node subnet. Needs one port forward on your router (UDP)."
    echo

    local answer
    read -rp "Set up a WireGuard VPN? [y/N]: " answer

    if [[ ! "${answer}" =~ ^[Yy]([Ee][Ss])?$ ]]; then
        VPN_ENABLED=false
        export VPN_ENABLED
        save_config
        log_info "VPN skipped. Add it later from KubesTUI: Set Up VPN."
        return 0
    fi

    local octet='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
    local ip="${octet}\\.${octet}\\.${octet}\\.${octet}"
    local suggestion value

    # Node subnet clients may reach.
    suggestion="${VPN_ALLOWED_IPS:-$(node_subnet || true)}"
    echo
    echo "Subnet(s) VPN clients can reach (comma-separated CIDRs)."
    while true; do
        read -rp "Node subnet [${suggestion}]: " value
        value="${value:-${suggestion}}"
        value="${value//[[:space:]]/}"
        if [[ "${value}" =~ ^(${ip}/([0-9]|[12][0-9]|3[0-2]))(,${ip}/([0-9]|[12][0-9]|3[0-2]))*$ ]]; then
            VPN_ALLOWED_IPS="${value}"
            break
        fi
        echo "[ERROR] Use CIDR notation, e.g. 192.168.50.0/24"
    done

    # Public endpoint.
    suggestion="${VPN_ENDPOINT:-}"
    if [[ -z "${suggestion}" && -n "${DUCKDNS_DOMAIN:-}" ]]; then
        suggestion="${DUCKDNS_DOMAIN}-vpn.duckdns.org"
    fi
    echo
    echo "Public name or IP that clients connect to from outside."
    if [[ -n "${DUCKDNS_DOMAIN:-}" ]]; then
        echo "Your base domain points at your LAN, so use a SECOND DuckDNS"
        echo "name for the VPN (create it at duckdns.org first). The cluster"
        echo "keeps it pointed at your public IP with the same token."
    fi
    while true; do
        read -rp "VPN endpoint [${suggestion}]: " value
        value="${value:-${suggestion}}"
        value="${value//[[:space:]]/}"
        if [[ "${value}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
            if [[ -n "${DUCKDNS_DOMAIN:-}" && "${value}" == "${DUCKDNS_DOMAIN}.duckdns.org" ]]; then
                echo "[ERROR] That is your LAN-only base domain; use a separate name."
                continue
            fi
            VPN_ENDPOINT="${value}"
            break
        fi
        echo "[ERROR] Invalid name: ${value}"
    done

    # UDP port.
    while true; do
        read -rp "UDP port [${VPN_PORT:-51820}]: " value
        value="${value:-${VPN_PORT:-51820}}"
        if [[ "${value}" =~ ^[0-9]+$ ]] && (( value >= 1 && value <= 65535 )); then
            VPN_PORT="${value}"
            break
        fi
        echo "[ERROR] Port must be 1-65535."
    done

    # Fixed MetalLB IP, so the router port forward never changes.
    suggestion="${VPN_LB_IP:-$(metallb_last_ip)}"
    echo
    echo "LoadBalancer IP for the VPN (from your MetalLB pool ${METALLB_RANGE:-})."
    while true; do
        read -rp "VPN IP [${suggestion}]: " value
        value="${value:-${suggestion}}"
        if [[ "${value}" =~ ^${ip}$ ]] && ip_in_metallb_range "${value}"; then
            VPN_LB_IP="${value}"
            break
        fi
        echo "[ERROR] Must be an address inside ${METALLB_RANGE:-the MetalLB pool}."
    done

    # wg-easy web UI admin login (cluster Secret only).
    echo
    echo "Password for the wg-easy web UI (user: admin), at least 12 characters."
    while true; do
        read -rsp "wg-easy password: " VPN_ADMIN_PASSWORD
        echo
        if (( ${#VPN_ADMIN_PASSWORD} < 12 )); then
            echo "[ERROR] Use at least 12 characters."
            continue
        fi
        read -rsp "Repeat password: " value
        echo
        [[ "${value}" == "${VPN_ADMIN_PASSWORD}" ]] && break
        echo "[ERROR] Passwords did not match."
    done

    VPN_ENABLED=true
    export VPN_ENABLED VPN_ENDPOINT VPN_PORT VPN_LB_IP VPN_ALLOWED_IPS VPN_ADMIN_PASSWORD

    save_config

    log_ok "VPN configured: ${VPN_ENDPOINT}:${VPN_PORT} -> ${VPN_LB_IP}, clients reach ${VPN_ALLOWED_IPS}"
    echo
    echo "  On your router: forward UDP ${VPN_PORT} to ${VPN_LB_IP}"
    echo
}

#############################################
# Cluster secret and DuckDNS name
#############################################

install_vpn_secret() {

    [[ "${VPN_ENABLED:-false}" == "true" ]] || return 0

    if [[ -z "${VPN_ADMIN_PASSWORD:-}" ]]; then
        log_info "wg-easy admin password unchanged."
    else
        kubectl create namespace wg-easy --dry-run=client -o yaml | kubectl apply -f -

        kubectl -n wg-easy create secret generic wg-easy-init \
            --from-literal=INIT_USERNAME=admin \
            --from-literal=INIT_PASSWORD="${VPN_ADMIN_PASSWORD}" \
            --dry-run=client -o yaml |
            kubectl apply -f -

        log_ok "wg-easy admin login stored in the cluster."
    fi

    # Keep the VPN DuckDNS name at the public IP (see duckdns.yaml).
    if [[ "${VPN_ENDPOINT}" == *.duckdns.org ]] &&
        kubectl -n duckdns get secret duckdns >/dev/null 2>&1; then

        local sub="${VPN_ENDPOINT%.duckdns.org}"
        sub="${sub##*.}"

        kubectl -n duckdns patch secret duckdns --type merge \
            -p "{\"stringData\":{\"vpn_domain\":\"${sub}\"}}" >/dev/null

        log_ok "DuckDNS will keep ${VPN_ENDPOINT} at your public IP."
    fi
}

#############################################
# "Set Up VPN" from the node menu (after bootstrap)
#############################################

setup_vpn() {

    header 2>/dev/null || true

    local was_enabled="${VPN_ENABLED:-false}"

    if [[ "${was_enabled}" == "true" ]]; then
        log_info "VPN is already set up: ${VPN_ENDPOINT}:${VPN_PORT} (${VPN_LB_IP})."
        echo "  Answer n at the next question to turn it off and remove wg-easy."
        local again
        read -rp "Change its settings? [y/N]: " again
        [[ "${again}" =~ ^[Yy] ]] || return 0
    fi

    if [[ -n "${BASE_DOMAIN:-}" && "${BASE_DOMAIN}" == *.duckdns.org ]]; then
        DUCKDNS_DOMAIN="${BASE_DOMAIN%.duckdns.org}"
        DUCKDNS_DOMAIN="${DUCKDNS_DOMAIN##*.}"
        export DUCKDNS_DOMAIN
    fi

    # Bring the GitOps checkout up to date first, while the saved
    # settings are still the old ones (see lib/gitops.sh).
    gitops_prepare

    configure_vpn --force

    if [[ "${VPN_ENABLED}" != "true" && "${was_enabled}" != "true" ]]; then
        return 0 # stayed off: nothing to push
    fi

    [[ "${VPN_ENABLED}" == "true" ]] && install_vpn_secret

    # Push through GitOps: adds wg-easy, or (when turned off) leaves it
    # out so Argo CD removes it. Only the VPN's own files are updated;
    # the rest of the repository is left as it is.
    gitops_apply_templates "Configure the VPN" \
        apps/infrastructure/wg-easy \
        apps/infrastructure/kustomization.yaml

    if [[ "${VPN_ENABLED}" != "true" ]]; then
        log_ok "VPN turned off; Argo CD removes wg-easy within a few minutes."
        echo
        echo "  You can delete the router's UDP ${VPN_PORT} port forward now."
        echo "  The wg-easy data volume is deleted with it (clients and keys)."
        echo
        return 0
    fi

    log_ok "VPN manifests pushed; Argo CD deploys wg-easy within a few minutes."
    echo
    echo "  Next:"
    echo "   1. Forward UDP ${VPN_PORT} on your router to ${VPN_LB_IP}"
    echo "   2. Open https://wg.${BASE_DOMAIN} (on the LAN), log in as admin"
    echo "   3. Create a client and download its .conf for each device"
    echo "   4. Check with: VPN Status"
    echo
}

#############################################
# VPN health
#############################################

vpn_status() {

    local pass=0 warn=0 fail=0
    _ok()   { pass=$((pass + 1)); echo -e "  ${GREEN}PASS${NC}  $1"; }
    _warn() { warn=$((warn + 1)); echo -e "  ${YELLOW}WARN${NC}  $1"; }
    _fail() { fail=$((fail + 1)); echo -e "  ${RED}FAIL${NC}  $1"; }

    echo
    echo "============================================="
    echo " VPN Status (wg-easy)"
    echo "============================================="

    if [[ "${VPN_ENABLED:-false}" != "true" ]]; then
        echo
        echo "  The VPN is not set up. Choose \"Set Up VPN\" in KubesTUI to add it."
        echo
        return 0
    fi

    echo
    echo "  Endpoint   ${VPN_ENDPOINT}:${VPN_PORT}/udp"
    echo "  Server IP  ${VPN_LB_IP}   (router: forward UDP ${VPN_PORT} here)"
    echo "  Clients    reach ${VPN_ALLOWED_IPS}"
    echo "  Web UI     https://wg.${BASE_DOMAIN:-<base domain>}  (LAN)"
    echo

    local ready
    ready="$(kubectl -n wg-easy get deployment wg-easy -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
    if [[ "${ready:-0}" == "1" ]]; then
        _ok "wg-easy is running"
    else
        _fail "wg-easy is not running (kubectl -n wg-easy get pods)"
    fi

    local lb
    lb="$(kubectl -n wg-easy get svc wg-easy-vpn -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    if [[ "${lb}" == "${VPN_LB_IP}" ]]; then
        _ok "VPN listening on ${lb}:${VPN_PORT}/udp"
    elif [[ -n "${lb}" ]]; then
        _warn "VPN got ${lb}, expected ${VPN_LB_IP}: update your router's port forward"
    else
        _fail "VPN service has no LoadBalancer IP yet (MetalLB)"
    fi

    local resolved public
    resolved="$(getent ahostsv4 "${VPN_ENDPOINT}" 2>/dev/null | awk 'NR==1 {print $1}' || true)"
    public="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    if [[ -z "${resolved}" ]]; then
        _fail "${VPN_ENDPOINT} does not resolve"
    elif [[ -n "${public}" && "${resolved}" != "${public}" ]]; then
        _warn "${VPN_ENDPOINT} -> ${resolved}, but your public IP is ${public} (DuckDNS updates every 5 min)"
    else
        _ok "${VPN_ENDPOINT} -> ${resolved}${public:+ (your public IP)}"
    fi

    # Peers from the live WireGuard interface.
    local dump
    if dump="$(kubectl -n wg-easy exec deploy/wg-easy -- wg show wg0 dump 2>/dev/null)"; then
        local now total=0 active=0 line name hs rx tx
        now="$(date +%s)"
        echo
        echo -e "  ${BLUE}Clients${NC}"
        while IFS=$'\t' read -r name _ _ _ hs rx tx _; do
            total=$((total + 1))
            if (( hs > 0 && now - hs < 180 )); then
                active=$((active + 1))
                printf '    %-14s  connected  handshake %3ss ago  rx %s  tx %s\n' "${name:0:12}…" $((now - hs)) \
                    "$(numfmt --to=iec "${rx}")" "$(numfmt --to=iec "${tx}")"
            elif (( hs > 0 )); then
                printf '    %-14s  idle       last seen %s\n' "${name:0:12}…" "$(date -d "@${hs}" '+%Y-%m-%d %H:%M')"
            else
                printf '    %-14s  never connected\n' "${name:0:12}…"
            fi
        done < <(tail -n +2 <<< "${dump}")
        (( total == 0 )) && echo "    none yet: create one in the web UI"
        echo
        _ok "${total} client(s), ${active} connected now"
    else
        _warn "Could not read WireGuard peers (pod not ready?)"
    fi

    echo
    echo "  Note: from inside your LAN this can't prove the router forward"
    echo "  works. Test once from outside (e.g. phone on mobile data)."
    echo
    echo "============================================="
    echo -e " Summary: ${GREEN}${pass} passed${NC}, ${YELLOW}${warn} warnings${NC}, ${RED}${fail} failed${NC}"
    echo "============================================="

    (( fail == 0 ))
}
