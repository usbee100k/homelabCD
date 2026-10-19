#!/usr/bin/env bash

#############################################
# STUCK PODS
#############################################
#
# A node that goes down leaves its pods stuck Terminating (only its kubelet
# can confirm they stopped), which blocks Jobs and their CronJobs, and its
# DaemonSet pods keep Argo CD syncs waiting. The pod-cleanup CronJob
# (apps/infrastructure/pod-cleanup) handles the pods every 2 minutes; the
# Argo CD DaemonSet health check (bootstrap/argocd/daemonset-health.lua)
# stops syncs from waiting on a node that is down.
#############################################

POD_CLEANUP_SCRIPT="${ROOT_DIR}/apps/infrastructure/pod-cleanup/resources/cleanup"

# Sets the DaemonSet health check in argocd-cm. New clusters get it from
# lib/argocd.sh; this brings existing ones up to date. Argo CD picks up the
# change by itself.
apply_argocd_health_checks() {

    local lua="${ROOT_DIR}/bootstrap/argocd/daemonset-health.lua"

    [[ -f "${lua}" ]] || return 0
    kubectl -n argocd get configmap argocd-cm >/dev/null 2>&1 || return 0

    if kubectl -n argocd patch configmap argocd-cm --type merge --patch-file <(
        echo "data:"
        echo "  resource.customizations.health.apps_DaemonSet: |"
        sed 's/^/    /' "${lua}"
    ) >/dev/null; then
        log_ok "Argo CD no longer waits for DaemonSet pods on nodes that are down."
    else
        log_warn "Could not update the Argo CD DaemonSet health check."
    fi
}

# "Clean Up Stuck Pods" (install.sh --run pod-cleanup): shows what the
# cleanup would do, asks, then does it now.
pod_cleanup() {

    local plan answer

    command -v kubectl >/dev/null 2>&1 && kubectl get nodes >/dev/null 2>&1 || {
        log_error "Run this on a control plane (kubectl must reach the cluster)."
        return 1
    }

    apply_argocd_health_checks

    log_info "Looking for stuck and left-behind pods..."
    plan="$(DRY_RUN=1 sh "${POD_CLEANUP_SCRIPT}")" || {
        echo "${plan}"
        return 1
    }

    echo
    echo "${plan}"
    echo

    if [[ "${plan}" != would* ]]; then
        log_ok "Nothing to clean up."
    else
        read -rp "Clean these up now? [Y/n] " answer || answer=n
        if [[ "${answer:-Y}" =~ ^[Yy] ]]; then
            sh "${POD_CLEANUP_SCRIPT}"
            log_ok "Cleaned up."
        else
            log_info "Nothing was changed."
        fi
    fi

    if kubectl -n kubestui get cronjob pod-cleanup >/dev/null 2>&1; then
        log_info "The pod-cleanup CronJob also does this every 2 minutes."
    else
        log_info "To do this every 2 minutes by itself, run Update GitOps Templates"
        echo "       (it adds the pod-cleanup app)."
    fi
}
