#!/usr/bin/env bash

set -Eeuo pipefail

#############################################
# DOCKER COMPOSE IMPORT
#############################################
#
# Turns a docker-compose.yml into an Argo CD app in the GitOps repo
# (apps/applications/<name>/). The conversion and questions live in
# KubesTUI (`kubestui compose-import`); this wraps it:
#
#   1. bring the GitOps checkout up to date (gitops_prepare)
#   2. run the importer against it
#   3. commit and push, then watch Argo CD until the app is healthy
#
# Imported apps live only in the GitOps repo; sync_gitops_repo
# leaves apps/applications/ alone.
#
# COMPOSE_FILE (optional): path to the compose file; asked otherwise.
#############################################

kubestui_bin() {
    local bin="${ROOT_DIR}/bin/kubestui"
    [[ -x "${bin}" ]] || die "KubesTUI is not built (${bin}). Run install.sh once."
    echo "${bin}"
}

# Runs the importer subcommand against the GitOps checkout. Prints the
# app name it worked on (empty if cancelled).
run_compose_tool() {

    local sub="$1" result

    result="$(mktemp)"

    # Interactive: the tool reads answers from this terminal.
    if ! env \
        GITOPS_DIR="${GITOPS_DIR}" \
        GITHUB_REPO="${GITHUB_REPO}" \
        GIT_BRANCH="${GIT_BRANCH:-main}" \
        BASE_DOMAIN="${BASE_DOMAIN:-}" \
        METALLB_RANGE="${METALLB_RANGE:-}" \
        VPN_LB_IP="${VPN_LB_IP:-}" \
        COMPOSE_FILE="${COMPOSE_FILE:-}" \
        KUBESTUI_RESULT_FILE="${result}" \
        "$(kubestui_bin)" "${sub}" </dev/tty >/dev/tty 2>&1; then
        rm -f "${result}"
        return 1
    fi

    cat "${result}"
    rm -f "${result}"
}

# Shows the Argo CD app's sync/health until it is Healthy (or 5 minutes).
watch_argocd_app() {

    local app="$1" last="" state sync health i

    # Ask Argo CD to look at the repo now instead of in a few minutes.
    kubectl -n argocd annotate application applications \
        argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true

    echo
    log_info "Waiting for Argo CD to deploy ${app} (Ctrl+C stops watching; it keeps deploying)..."

    for i in $(seq 1 60); do
        sync="$(kubectl -n argocd get application "${app}" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
        health="$(kubectl -n argocd get application "${app}" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
        state="${sync:-Pending} / ${health:-Pending}"

        if [[ "${state}" != "${last}" ]]; then
            printf '  %s  %s\n' "$(date +%H:%M:%S)" "${state}"
            last="${state}"
        fi

        if [[ "${sync}" == "Synced" && "${health}" == "Healthy" ]]; then
            log_ok "${app} is running."
            return 0
        fi
        if [[ "${health}" == "Degraded" ]]; then
            log_warn "${app} is Degraded. Check: kubectl -n ${app} get pods; kubectl -n ${app} describe pods"
            return 1
        fi
        sleep 5
    done

    log_warn "${app} isn't healthy after 5 minutes (images may still be downloading)."
    echo "  Check: kubectl -n ${app} get pods"
    return 1
}

# gitops_prepare without the per-file rsync listing; shows it on failure.
quiet_gitops_prepare() {
    local log
    log="$(mktemp)"
    log_info "Updating the GitOps repository..."
    if ! gitops_prepare >"${log}" 2>&1; then
        cat "${log}"
        rm -f "${log}"
        die "Could not update the GitOps repository."
    fi
    rm -f "${log}"
    log_ok "GitOps repository up to date (${GITOPS_DIR})"
}

compose_import() {

    header 2>/dev/null || true

    quiet_gitops_prepare

    local app
    app="$(run_compose_tool compose-import)" || return 1
    [[ -n "${app}" ]] || return 1

    gitops_commit_push "Import ${app} from Docker Compose"

    watch_argocd_app "${app}" || true

    echo
    echo "  Files: ${GITOPS_DIR}/apps/applications/${app}/ (see README.md there)"
    echo
}

compose_remove() {

    header 2>/dev/null || true

    quiet_gitops_prepare

    local app
    app="$(run_compose_tool compose-remove)" || return 1
    [[ -n "${app}" ]] || return 1

    gitops_commit_push "Remove ${app}"

    kubectl -n argocd annotate application applications \
        argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true

    # Argo CD deletes what the app deployed; the namespace (and its Secret)
    # was created outside the app, so remove it too.
    log_info "Removing namespace ${app} (volumes and secrets)..."
    kubectl delete namespace "${app}" --wait=false >/dev/null 2>&1 || true

    log_ok "${app} removed."
}
