#!/usr/bin/env bash

wait_for_nodes() {

    log_info "Waiting for Kubernetes Nodes..."

    until kubectl get nodes 2>/dev/null | grep -q Ready
    do
        sleep 5
    done

    log_ok "Nodes Ready."

}

wait_for_coredns() {

    log_info "Waiting for CoreDNS..."

    kubectl rollout status \
        deployment/coredns \
        -n kube-system

    log_ok "CoreDNS Ready."

}

#############################################
# CLUSTER HEALTH REPORT
#############################################
#
# Read-only. Every check prints PASS / WARN / FAIL and the
# report ends with a summary; exits 1 if anything failed.
# install.sh runs with an ERR trap, so every command that
# may fail is guarded with `|| true` or an `if`.
#############################################

HEALTH_PASS=0
HEALTH_WARN=0
HEALTH_FAIL=0

health_pass() { HEALTH_PASS=$((HEALTH_PASS + 1)); echo -e "  ${GREEN}PASS${NC}  $1"; }
health_warn() { HEALTH_WARN=$((HEALTH_WARN + 1)); echo -e "  ${YELLOW}WARN${NC}  $1"; }
health_fail() { HEALTH_FAIL=$((HEALTH_FAIL + 1)); echo -e "  ${RED}FAIL${NC}  $1"; }
health_detail() { sed 's/^/          /'; }

health_section() {
    echo
    echo -e "${BLUE}== $1 ==${NC}"
}

# Prints "<ready>/<desired>" for a deployment or daemonset, or nothing.
health_rollout() {

    local kind="$1" ns="$2" name="$3"
    local fields

    if [[ "${kind}" == "daemonset" ]]; then
        fields='{.status.numberReady}/{.status.desiredNumberScheduled}'
    else
        fields='{.status.readyReplicas}/{.spec.replicas}'
    fi

    kubectl -n "${ns}" get "${kind}" "${name}" -o jsonpath="${fields}" 2>/dev/null || true
}

health_check_rollout() {

    local label="$1" kind="$2" ns="$3" name="$4"
    local status ready desired

    status="$(health_rollout "${kind}" "${ns}" "${name}")"

    if [[ -z "${status}" ]]; then
        health_warn "${label}: not installed (${ns}/${name})"
        return 0
    fi

    ready="${status%/*}"; ready="${ready:-0}"
    desired="${status#*/}"; desired="${desired:-0}"

    if (( desired > 0 && ready == desired )); then
        health_pass "${label}: ${ready}/${desired} ready"
    elif (( ready > 0 )); then
        health_warn "${label}: ${ready}/${desired} ready"
    else
        health_fail "${label}: ${ready}/${desired} ready"
    fi
}

cluster_health() {

    HEALTH_PASS=0
    HEALTH_WARN=0
    HEALTH_FAIL=0

    local out count total bad

    echo
    echo "============================================="
    echo " Cluster Health Report  ($(date '+%Y-%m-%d %H:%M:%S'))"
    echo " Run from: $(hostname)"
    echo "============================================="

    #############################################
    # API server
    #############################################

    health_section "API Server"

    if ! kubectl get --raw='/readyz' >/dev/null 2>&1; then
        health_fail "Kubernetes API is not reachable with KUBECONFIG=${KUBECONFIG:-<unset>}"
        echo "          Run this from a control plane node (workers have no admin credentials)."
        health_summary
        return 1
    fi

    health_pass "API server ready ($(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true))"

    if [[ -n "${VIP_ADDRESS:-}" && "${VIP_ADDRESS}" != "unknown" ]]; then
        if curl -fsk --max-time 5 "https://${VIP_ADDRESS}:6443/livez" >/dev/null 2>&1; then
            health_pass "Control plane VIP ${VIP_ADDRESS} answering (kube-vip)"
        else
            health_fail "Control plane VIP ${VIP_ADDRESS} not answering on :6443 (check kube-vip)"
        fi
    fi

    #############################################
    # Nodes
    #############################################

    health_section "Nodes"

    out="$(kubectl get nodes --no-headers 2>/dev/null || true)"
    total="$(grep -c . <<< "${out}" || true)"
    count="$(awk '$2 == "Ready"' <<< "${out}" | grep -c . || true)"
    bad="$(awk '$2 != "Ready"' <<< "${out}")"

    if [[ -z "${bad}" ]]; then
        health_pass "All ${total} node(s) Ready"
    else
        health_fail "${count}/${total} node(s) Ready"
        health_detail <<< "${bad}"
    fi

    kubectl get nodes \
        -L homelab.io/metallb-announce,homelab.io/gpu,homelab.io/igpu,homelab.io/storage,homelab.io/longhorn-disk \
        -o wide 2>/dev/null | health_detail || true

    count="$(kubectl get nodes -l homelab.io/metallb-announce=true --no-headers 2>/dev/null | grep -c . || true)"

    if (( count > 0 )); then
        health_pass "${count} node(s) selected for MetalLB announcements"
    else
        health_fail "No node has homelab.io/metallb-announce=true; LoadBalancer IPs and ingress are down"
    fi

    out="$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.status=="True")].type}{"\n"}{end}' 2>/dev/null |
        grep -E 'MemoryPressure|DiskPressure|PIDPressure' || true)"

    if [[ -z "${out}" ]]; then
        health_pass "No memory, disk or PID pressure"
    else
        health_warn "Nodes under resource pressure:"
        health_detail <<< "${out}"
    fi

    if out="$(kubectl top nodes 2>/dev/null)"; then
        health_detail <<< "${out}"
    else
        health_warn "kubectl top unavailable (metrics-server not ready)"
    fi

    #############################################
    # Control plane
    #############################################

    health_section "Control Plane"

    local component
    for component in etcd kube-apiserver kube-controller-manager kube-scheduler; do

        out="$(kubectl -n kube-system get pods -l "component=${component}" --no-headers 2>/dev/null || true)"
        total="$(grep -c . <<< "${out}" || true)"
        count="$(awk '$3 == "Running"' <<< "${out}" | grep -c . || true)"

        if (( total == 0 )); then
            health_fail "${component}: no pods found"
        elif (( count == total )); then
            health_pass "${component}: ${count}/${total} running"
        else
            health_fail "${component}: ${count}/${total} running"
        fi
    done

    total="$(kubectl -n kube-system get pods -l component=etcd --no-headers 2>/dev/null | grep -c . || true)"
    if (( total == 2 )); then
        health_warn "etcd has 2 members: losing either one stops the cluster. Use 1 or 3 control planes."
    fi

    if command -v kubeadm >/dev/null 2>&1 && [[ -f /etc/kubernetes/pki/ca.crt ]]; then

        out="$(kubeadm certs check-expiration 2>/dev/null | awk '/^(admin|apiserver|controller|etcd|front|scheduler|super)/ {print $1, $(NF-2)}' || true)"

        if [[ -z "${out}" ]]; then
            health_warn "Could not read certificate expiry (kubeadm certs check-expiration)"
        elif awk '{ d = $2 + 0; if ($2 ~ /y$/) d *= 365; else if ($2 !~ /d$/) d = 0; if (d < 30) exit 1 }' <<< "${out}"; then
            health_pass "Control plane certificates valid for 30+ days"
        else
            health_warn "Control plane certificates expire within 30 days: sudo kubeadm certs renew all"
            health_detail <<< "${out}"
        fi
    fi

    #############################################
    # Networking
    #############################################

    health_section "Networking"

    health_check_rollout "Cilium agents" daemonset kube-system cilium
    health_check_rollout "Cilium operator" deployment kube-system cilium-operator
    health_check_rollout "CoreDNS" deployment kube-system coredns

    if command -v cilium >/dev/null 2>&1; then
        if out="$(cilium status --wait-duration 10s 2>&1 | grep -E 'Cilium:|Operator:|Hubble|Errors|Warnings' )"; then
            health_detail <<< "${out}"
        fi
    fi

    health_check_rollout "MetalLB controller" deployment metallb-system metallb-controller
    health_check_rollout "MetalLB speakers" daemonset metallb-system metallb-speaker

    out="$(kubectl -n metallb-system get ipaddresspools -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.spec.addresses[*]}{"\n"}{end}' 2>/dev/null || true)"
    if [[ -z "${out}" ]]; then
        health_fail "No MetalLB IPAddressPool"
    elif grep -q REPLACE_ <<< "${out}"; then
        health_fail "MetalLB pool still has a placeholder: ${out}"
    else
        health_pass "MetalLB pool ${out}"
    fi

    health_check_rollout "ingress-nginx" deployment ingress-nginx ingress-nginx-controller
    health_check_rollout "Node Feature Discovery workers" daemonset node-feature-discovery node-feature-discovery-worker

    local ingress_ip
    ingress_ip="$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"

    if [[ -n "${ingress_ip}" ]]; then
        health_pass "Ingress LoadBalancer IP: ${ingress_ip}"
    else
        health_fail "ingress-nginx has no LoadBalancer IP (check MetalLB pool and node labels)"
    fi

    out="$(kubectl get svc -A --no-headers 2>/dev/null | awk '$3 == "LoadBalancer" && $5 == "<pending>" {print $1 "/" $2}' || true)"
    if [[ -n "${out}" ]]; then
        health_fail "LoadBalancer services waiting for an IP:"
        health_detail <<< "${out}"
    fi

    #############################################
    # DNS (DuckDNS)
    #############################################

    if [[ -n "${BASE_DOMAIN:-}" && "${BASE_DOMAIN}" == *.duckdns.org ]]; then

        health_section "DNS (${BASE_DOMAIN})"

        local resolved
        resolved="$(getent ahostsv4 "${BASE_DOMAIN}" 2>/dev/null | awk 'NR==1 {print $1}' || true)"

        if [[ -z "${resolved}" ]]; then
            health_fail "${BASE_DOMAIN} does not resolve"
        elif [[ -n "${ingress_ip}" && "${resolved}" != "${ingress_ip}" ]]; then
            health_warn "${BASE_DOMAIN} -> ${resolved}, expected ingress IP ${ingress_ip} (updater runs every 5 min)"
        else
            health_pass "${BASE_DOMAIN} -> ${resolved}"
        fi

        if ! kubectl -n duckdns get secret duckdns >/dev/null 2>&1; then
            health_fail "DuckDNS secret missing in namespace duckdns"
        fi

        out="$(kubectl -n duckdns get jobs --sort-by=.metadata.creationTimestamp --no-headers 2>/dev/null | tail -n1 || true)"
        if [[ -z "${out}" ]]; then
            health_warn "DuckDNS updater has not run yet"
        elif awk '{ if ($2 ~ /^1\/1$/ || $2 == "Complete") exit 0; exit 1 }' <<< "${out}"; then
            health_pass "Last DuckDNS update succeeded ($(awk '{print $1}' <<< "${out}"))"
        else
            health_fail "Last DuckDNS update did not succeed: kubectl -n duckdns logs job/$(awk '{print $1}' <<< "${out}")"
        fi
    fi

    #############################################
    # VPN (optional)
    #############################################

    if [[ "${VPN_ENABLED:-false}" == "true" ]]; then

        health_section "VPN (${VPN_ENDPOINT}:${VPN_PORT})"

        health_check_rollout "wg-easy" deployment wg-easy wg-easy

        out="$(kubectl -n wg-easy get svc wg-easy-vpn -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
        if [[ "${out}" == "${VPN_LB_IP}" ]]; then
            health_pass "VPN on ${out}:${VPN_PORT}/udp (router forwards here)"
        else
            health_fail "VPN LoadBalancer IP is '${out:-none}', expected ${VPN_LB_IP}"
        fi
        echo "          Peers and details: KubesTUI > VPN Status"
    fi

    #############################################
    # GitOps
    #############################################

    health_section "Argo CD Applications"

    out="$(kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.sync.status}{" "}{.status.health.status}{"\n"}{end}' 2>/dev/null || true)"

    if [[ -z "${out}" ]]; then
        health_fail "No Argo CD applications found"
    else
        local name sync health
        while read -r name sync health; do
            [[ -n "${name}" ]] || continue
            if [[ "${sync}" == "Synced" && "${health}" == "Healthy" ]]; then
                health_pass "${name}: ${sync} / ${health}"
            elif [[ "${health}" == "Degraded" || "${health}" == "Missing" || "${sync}" == "Unknown" ]]; then
                health_fail "${name}: ${sync:-?} / ${health:-?}"
            else
                health_warn "${name}: ${sync:-?} / ${health:-?}"
            fi
        done <<< "${out}"
    fi

    #############################################
    # Workloads
    #############################################

    health_section "Workloads"

    out="$(kubectl get pods -A --no-headers 2>/dev/null |
        awk '$4 != "Running" && $4 != "Completed" && $4 != "Succeeded" {print $1 "/" $2 "  " $4}' || true)"

    if [[ -z "${out}" ]]; then
        health_pass "All pods Running or Completed"
    else
        health_fail "$(grep -c . <<< "${out}") pod(s) not running:"
        health_detail <<< "${out}"
    fi

    out="$(kubectl get pods -A --no-headers 2>/dev/null |
        awk '$4 == "Running" { split($3, r, "/"); if (r[1] != r[2]) print $1 "/" $2 "  " $3 " containers ready" }' || true)"

    if [[ -n "${out}" ]]; then
        health_warn "Running pods with containers not ready:"
        health_detail <<< "${out}"
    fi

    out="$(kubectl get pods -A --no-headers 2>/dev/null | awk '$5+0 >= 10 {print $1 "/" $2 "  " $5 " restarts"}' || true)"

    if [[ -n "${out}" ]]; then
        health_warn "Pods restarting often (10+ restarts):"
        health_detail <<< "${out}"
    fi

    #############################################
    # Storage and certificates
    #############################################

    health_section "Storage & Certificates"

    if ! out="$(kubectl get pvc -A --no-headers 2>/dev/null | awk '$3 != "Bound" {print $1 "/" $2 "  " $3}')"; then
        health_warn "Could not list PersistentVolumeClaims"
    elif [[ -z "${out}" ]]; then
        health_pass "All PersistentVolumeClaims Bound"
    else
        health_fail "Unbound PersistentVolumeClaims:"
        health_detail <<< "${out}"
    fi

    out="$(kubectl -n longhorn-system get volumes.longhorn.io -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.robustness}{"\n"}{end}' 2>/dev/null |
        awk '$2 != "healthy" && $2 != "" {print}' || true)"
    if [[ -n "${out}" ]]; then
        health_warn "Longhorn volumes not healthy:"
        health_detail <<< "${out}"
    fi

    if ! out="$(kubectl get certificates -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null |
        awk '$2 != "True" {print}')"; then
        health_warn "cert-manager not installed (no Certificate resource type)"
    elif [[ -z "${out}" ]]; then
        health_pass "All cert-manager certificates Ready"
    else
        health_fail "cert-manager certificates not Ready:"
        health_detail <<< "${out}"
    fi

    #############################################
    # Host automation (this node)
    #############################################

    health_section "Host Timers ($(hostname))"

    local timer
    for timer in metallb-node-selector worker-role-labeler argocd-replica-scaler cilium-operator-scaler; do
        if systemctl is-active --quiet "${timer}.timer" 2>/dev/null; then
            if systemctl is-failed --quiet "${timer}.service" 2>/dev/null; then
                health_fail "${timer}: last run failed (journalctl -u ${timer}.service)"
            else
                health_pass "${timer}: active"
            fi
        else
            health_warn "${timer}: not installed on this node"
        fi
    done

    health_summary

    (( HEALTH_FAIL == 0 ))
}

health_summary() {
    echo
    echo "============================================="
    echo -e " Summary: ${GREEN}${HEALTH_PASS} passed${NC}, ${YELLOW}${HEALTH_WARN} warnings${NC}, ${RED}${HEALTH_FAIL} failed${NC}"
    echo "============================================="
}
