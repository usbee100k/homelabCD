#!/usr/bin/env bash

#############################################
# ROLL BACK A GITOPS CHANGE
#############################################
#
# "Roll Back GitOps Change" (install.sh --run rollback): for when
# something you tried in the GitOps repository breaks the cluster.
#
#   1. Lists the recent versions of the branch Argo CD watches; you pick
#      the last good one (default: the one before the newest change).
#   2. Commits that version's files on top and pushes. History is kept
#      (nothing is force-pushed on the branch), so rolling back is itself
#      a change you can roll back.
#   3. Makes Argo CD re-read the repository at once, stops syncs still
#      busy with the broken version, syncs what is out of date and shows
#      the apps until they settle.
#
# If the versions undone include an "Update GitOps Templates", the
# template record (branch homelabcd-templates) is moved back too, so the
# next template update brings those changes again.
#############################################

ARGOCD_NS="argocd"

gitops_rollback() {

    header 2>/dev/null || true

    gitops_prepare || return 1

    local b="${GITOPS_BRANCH}" t="${GITOPS_TEMPLATE_BRANCH}"
    local commits=() i pick target now

    if ! gitops_has_ref HEAD; then
        log_error "The GitOps repository has no commits yet."
        return 1
    fi

    # One entry per change on the branch: a template update is one entry.
    mapfile -t commits < <(gitops_git log --first-parent -n 16 --format=%H HEAD)
    now="${commits[0]}"

    if (( ${#commits[@]} < 2 )); then
        log_error "The GitOps repository has only one version; there is nothing to go back to."
        return 1
    fi

    echo
    echo "Your GitOps repository (${b}), newest first:"
    echo
    echo "  now) $(gitops_rollback_line "${now}")"
    for (( i = 1; i < ${#commits[@]}; i++ )); do
        printf "  %2d) %s\n" "${i}" "$(gitops_rollback_line "${commits[i]}")"
    done
    echo

    pick="$(read_choice "Go back to version [1 = undo the newest change]: " 1 $(( ${#commits[@]} - 1 )))"
    target="${commits[pick]}"

    if [[ "$(gitops_git rev-parse "${target}^{tree}")" == "$(gitops_git rev-parse "HEAD^{tree}")" ]]; then
        log_ok "The files are already the same as in ${target:0:7}; nothing to roll back."
        argocd_resync_all
        return 0
    fi

    echo
    echo "These changes will be undone:"
    gitops_git log --first-parent --format='  %h  %s' "${target}..HEAD"
    echo
    echo "Files that change back:"
    gitops_git --no-pager diff --stat=100 HEAD "${target}" | sed 's/^/ /'
    echo
    echo "Apps added by those changes are removed from the cluster (with their"
    echo "volumes); apps they changed go back to how they were."
    echo

    local answer
    read -rp "Roll back to ${target:0:7} and push? [y/N] " answer || answer=""
    if [[ ! "${answer}" =~ ^[Yy] ]]; then
        log_info "Nothing was changed."
        return 0
    fi

    #############################################
    # Commit the old version on top, and push
    #############################################

    local subject undone commit
    subject="$(gitops_git log -1 --format=%s "${target}")"
    undone="$(gitops_git log --first-parent --format='- %h %s' "${target}..HEAD")"

    commit="$(gitops_git commit-tree "${target}^{tree}" -p HEAD \
        -m "Roll back to ${target:0:7}: ${subject}" \
        -m "Undoes:
${undone}")" || return 1

    gitops_git reset -q --hard "${commit}"

    if ! gitops_git push -q origin "HEAD:${b}"; then
        gitops_git reset -q --hard "${now}"
        gitops_fix_ownership
        log_error "Could not push the rollback; nothing was changed."
        echo "  (Did someone push to ${b} meanwhile? Run this again to see the newest versions.)"
        return 1
    fi

    log_ok "Pushed: ${b} is back to ${target:0:7} (${subject})"

    # The template record must not be ahead of what the branch now has, or
    # the next "Update GitOps Templates" would think those changes are in.
    if gitops_has_ref "refs/heads/${t}" &&
        ! gitops_git merge-base --is-ancestor "refs/heads/${t}" "${target}"; then
        local old_t base
        old_t="$(gitops_git rev-parse "refs/heads/${t}")"
        if base="$(gitops_git merge-base "refs/heads/${t}" "${target}")"; then
            gitops_git update-ref "refs/heads/${t}" "${base}"
            if gitops_git push -q --force-with-lease="${t}:${old_t}" origin "${base}:refs/heads/${t}"; then
                log_ok "Template record moved back too: Update GitOps Templates brings those template changes again."
            else
                gitops_git update-ref "refs/heads/${t}" "${old_t}"
                log_warn "Could not move the template record (branch ${t}) back. Before the next"
                log_warn "Update GitOps Templates, run in ${GITOPS_DIR}:"
                echo "    git push --force origin ${base:0:12}:refs/heads/${t}"
            fi
        fi
    fi

    gitops_fix_ownership

    argocd_resync_all "$(gitops_git rev-parse HEAD)"

    echo
    echo "  Changed your mind? Run Roll Back GitOps Change again and pick the"
    echo "  version just before \"Roll back to ...\": that undoes this rollback."
}

# One version in the list: hash, age, author, message.
gitops_rollback_line() {
    gitops_git log -1 --format='%h  %<(14,trunc)%cr  %<(12,trunc)%an  %s' "$1"
}

#############################################
# Argo CD: re-read the repository and sync
#############################################

# "name|sync|health|operationPhase|skipReconcile" per app.
argocd_app_states() {
    kubectl -n "${ARGOCD_NS}" get applications.argoproj.io --request-timeout=20s \
        -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.sync.status}{"|"}{.status.health.status}{"|"}{.status.operationState.phase}{"|"}{.metadata.annotations.argocd\.argoproj\.io/skip-reconcile}{"\n"}{end}'
}

# Hard-refreshes every app, stops syncs stuck on an older version, syncs
# what is out of date and waits for the apps to settle. $1: the commit the
# apps should reach (optional, for the summary).
argocd_resync_all() {

    local want="${1:-}" name sync health phase skip
    local sync_body='{"operation":{"initiatedBy":{"username":"homelabcd"},"info":[{"name":"Reason","value":"Roll Back GitOps Change"}],"sync":{"syncStrategy":{"hook":{}}}}}'

    if ! command -v kubectl >/dev/null 2>&1 ||
        ! kubectl -n "${ARGOCD_NS}" get applications.argoproj.io >/dev/null 2>&1; then
        log_warn "Argo CD isn't reachable from here; it picks up the change by itself within a few minutes."
        return 0
    fi

    # 1. Syncs still running started before this change (often one waiting
    #    on whatever broke): stop them, or the new version waits behind them.
    local stopped=0
    while IFS='|' read -r name sync health phase skip; do
        [[ -n "${name}" && "${phase}" == Running && "${skip}" != true ]] || continue
        kubectl -n "${ARGOCD_NS}" patch applications.argoproj.io "${name}" --type merge \
            -p '{"status":{"operationState":{"phase":"Terminating"}}}' >/dev/null 2>&1 &&
            stopped=$(( stopped + 1 ))
    done < <(argocd_app_states)
    (( stopped == 0 )) || log_info "Stopped ${stopped} sync(s) still busy with the old version."

    # 2. Re-read the repository now instead of within 3 minutes.
    log_info "Telling Argo CD to re-read the repository..."
    kubectl -n "${ARGOCD_NS}" annotate applications.argoproj.io --all \
        argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true

    # 3. Once the stops and refreshes are through, sync what differs from
    #    git (apps paused with Turn Services On/Off are left alone).
    local i
    for (( i = 0; i < 15; i++ )); do
        sleep 2
        argocd_app_states | awk -F'|' '$4 == "Terminating" { busy = 1 } END { exit !busy }' || break
    done
    sleep 3

    local synced=0
    while IFS='|' read -r name sync health phase skip; do
        [[ -n "${name}" && "${skip}" != true && "${phase}" != Running && "${phase}" != Terminating ]] || continue
        [[ "${sync}" == OutOfSync ]] || continue
        kubectl -n "${ARGOCD_NS}" patch applications.argoproj.io "${name}" --type merge \
            -p "${sync_body}" >/dev/null 2>&1 && synced=$(( synced + 1 ))
    done < <(argocd_app_states)
    (( synced == 0 )) || log_info "Started a sync for ${synced} app(s) that differed from git."

    # 4. Progress until everything is synced and healthy, nothing is still
    #    syncing or starting, or 5 minutes have passed.
    local states total=0 ok=0 pending=0
    for (( i = 0; i < 60; i++ )); do
        states="$(argocd_app_states | grep -v '^$' || true)"
        total="$(grep -c . <<<"${states}" || true)"
        ok="$(awk -F'|' '$5 == "true" || ($2 == "Synced" && $3 == "Healthy" && $4 != "Running") { n++ } END { print n + 0 }' <<<"${states}")"
        pending=$(( total - ok ))
        printf '\r[INFO] Argo CD: %d of %d apps synced and healthy...   ' "${ok}" "${total}"
        (( pending == 0 )) && break
        if (( i >= 6 )) && ! awk -F'|' '$5 != "true" && ($4 == "Running" || $3 == "Progressing" || $2 == "Unknown") { busy = 1 } END { exit !busy }' <<<"${states}"; then
            break # what is left is broken either way
        fi
        sleep 5
    done
    echo

    if (( pending == 0 )); then
        log_ok "All ${total} Argo CD apps are synced and healthy${want:+ at ${want:0:7}}."
        return 0
    fi

    log_warn "Not synced and healthy yet:"
    awk -F'|' '$5 != "true" && !($2 == "Synced" && $3 == "Healthy" && $4 != "Running") {
        printf "    %-24s %-10s %-12s %s\n", $1, $2, $3, ($4 == "Running" ? "syncing" : "") }' <<<"${states}"
    echo "  Some apps take a few minutes to start; check them in the Command Center (Apps)."
}
