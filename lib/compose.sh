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
        COMPOSE_SOURCE_NODE="${COMPOSE_SOURCE_NODE:-}" \
        COMPOSE_SOURCE_DIR="${COMPOSE_SOURCE_DIR:-}" \
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
        # An app homelabCD left out (wg-easy without the VPN) never shows up.
        if (( i == 7 )) && ! kubectl -n argocd get application "${app}" >/dev/null 2>&1; then
            log_warn "Argo CD has no app named ${app}: it isn't deployed in this cluster."
            echo "  The change is saved in the GitOps repo and applies if ${app} is deployed later."
            return 0
        fi
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

    local out app
    out="$(run_compose_tool compose-import)" || return 1
    app="$(head -n 1 <<<"${out}")"
    [[ -n "${app}" ]] || return 1

    # Folders whose data should come along (the compose file was on a
    # node): copy them into the new volumes before Argo CD starts the app.
    if grep -qE $'^COPY(FILE)?\t' <<<"${out}"; then
        if ! compose_copy_data "${app}" "${out}"; then
            log_error "Copying the data failed; ${app} was not imported. Nothing was pushed."
            gitops_git checkout -q -- .
            gitops_git clean -qfd
            gitops_fix_ownership
            return 1
        fi
    fi

    gitops_commit_push "Import ${app} from Docker Compose"

    watch_argocd_app "${app}" || true

    echo
    echo "  Files: ${GITOPS_DIR}/apps/applications/${app}/ (see README.md there)"
    echo
}

# compose_copy_data APP OUT
# OUT lines "COPY<tab>NODE<tab>FOLDER<tab>CLAIM": copy FOLDER on NODE into
# the app's new Longhorn volume CLAIM (created now from the generated
# manifest; Argo CD adopts it).
compose_copy_data() {

    local app="$1" out="$2" tag node src claim manifest
    local res="${GITOPS_DIR}/apps/applications/${app}/resources"

    kubectl create namespace "${app}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null || return 1

    # From another machine (not a cluster node): straight over SSH.
    if [[ -n "${COMPOSE_SOURCE_EXTERNAL:-}" ]]; then
        compose_copy_from_machine "${app}" "${out}"
        return
    fi

    while IFS=$'\t' read -r tag node src claim; do
        [[ "${tag}" == COPY && -n "${claim}" ]] || continue
        echo
        log_info "Bringing ${src} from ${node} into the Longhorn volume ${claim}..."
        manifest="${res}/pvc-${claim}.yaml"
        [[ -f "${manifest}" ]] || { log_error "Missing ${manifest}"; return 1; }
        kubectl -n "${app}" apply -f "${manifest}" >/dev/null || return 1
        run_copy_job "${app}" "import-copy-${claim:0:50}" host "${src}" pvc "${claim}" "${node}" || return 1
    done <<<"${out}"
}

# compose_copy_from_machine APP OUT
# The compose file came from another machine over SSH (a CasaOS or Docker
# box): KubesTUI forwards its key for this session (SSH_AUTH_SOCK) and
# passes the host key it trusted. Optionally stops the app there (STOP
# line), then streams each folder (COPY) and file (COPYFILE) into its new
# Longhorn volume through a short-lived pod.
compose_copy_from_machine() {

    local app="$1" out="$2" tag node src claim name manifest pod size proj ids rc
    local res="${GITOPS_DIR}/apps/applications/${app}/resources"
    local target="${COMPOSE_SOURCE_EXTERNAL}" port="${COMPOSE_SOURCE_PORT:-22}"

    if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
        log_error "No SSH key was forwarded from KubesTUI; run the import from KubesTUI."
        return 1
    fi
    if [[ -z "${COMPOSE_SOURCE_HOSTKEY:-}" ]]; then
        log_error "No host key for ${target}."
        return 1
    fi
    local kh
    kh="$(mktemp)"
    printf '%s\n' "${COMPOSE_SOURCE_HOSTKEY}" >"${kh}"
    local -a SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="${kh}"
        -o GlobalKnownHostsFile=/dev/null -o ConnectTimeout=15 -o ServerAliveInterval=30 -p "${port}" "${target}")

    if ! "${SSH[@]}" true; then
        log_error "Can't log in to ${target} over SSH from $(hostname)."
        rm -f "${kh}"
        return 1
    fi

    # Reading the apps' folders may need root there: none (root),
    # passwordless sudo, or the sudo password, asked once (not saved).
    local pw="" sudo=""
    if ! "${SSH[@]}" '[ "$(id -u)" = 0 ]'; then
        if "${SSH[@]}" 'sudo -n true' 2>/dev/null; then
            sudo="sudo -n"
        else
            echo
            read -r -s -p "  sudo password for ${target} (to read the app's files; Enter to try without): " pw || true
            echo
            if [[ -n "${pw}" ]]; then
                if ! printf '%s\n' "${pw}" | "${SSH[@]}" "sudo -S -p '' true" 2>/dev/null; then
                    log_error "sudo refused that password on ${target}."
                    rm -f "${kh}"
                    return 1
                fi
                sudo="sudo -S -p ''"
            fi
        fi
    fi
    # on_machine CMD: runs CMD there; the sudo password (if any) is its stdin.
    on_machine() { printf '%s\n' "${pw}" | "${SSH[@]}" "$1"; }

    proj="$(awk -F'\t' '$1=="STOP"{print $2; exit}' <<<"${out}")"
    if [[ -n "${proj}" ]]; then
        echo
        log_info "Stopping ${proj} on ${target}..."
        ids="$(on_machine "${sudo} docker ps -q --filter label=com.docker.compose.project=$(printf %q "${proj}")" 2>/dev/null | tr '\n' ' ' || true)"
        if [[ -n "${ids// /}" ]]; then
            if on_machine "${sudo} docker stop ${ids}" >/dev/null; then
                log_ok "Stopped ${proj} on ${target} (start it there again if you need it)."
            else
                log_warn "Couldn't stop ${proj} on ${target}; copying while it runs."
            fi
        else
            log_info "${proj} isn't running on ${target}."
        fi
    fi

    # fd 3: commands in the loop (ssh, kubectl) can't eat the list.
    while IFS=$'\t' read -r -u 3 tag node src claim name; do
        [[ ( "${tag}" == COPY || "${tag}" == COPYFILE ) && -n "${claim}" ]] || continue
        echo
        log_info "Bringing ${target}:${src} into the Longhorn volume ${claim}..."
        manifest="${res}/pvc-${claim}.yaml"
        [[ -f "${manifest}" ]] || { log_error "Missing ${manifest}"; rm -f "${kh}"; return 1; }
        kubectl -n "${app}" apply -f "${manifest}" >/dev/null || { rm -f "${kh}"; return 1; }

        pod="import-recv-${claim:0:40}"
        kubectl -n "${app}" delete pod "${pod}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
        kubectl apply -f - >/dev/null <<YAML || { rm -f "${kh}"; return 1; }
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  namespace: ${app}
  labels:
    app.kubernetes.io/managed-by: homelabcd
spec:
  restartPolicy: Never
  tolerations:
    - operator: Exists
  containers:
    - name: recv
      image: busybox:1.37
      command: ["sleep", "86400"]
      volumeMounts:
        - name: to
          mountPath: /to
  volumes:
    - name: to
      persistentVolumeClaim:
        claimName: "${claim}"
YAML
        if ! kubectl -n "${app}" wait --for=condition=Ready "pod/${pod}" --timeout=300s >/dev/null; then
            log_error "The volume ${claim} didn't come up."
            kubectl -n "${app}" describe pod "${pod}" 2>/dev/null | tail -n 15 || true
            kubectl -n "${app}" delete pod "${pod}" --wait=false >/dev/null 2>&1 || true
            rm -f "${kh}"
            return 1
        fi

        if [[ "${tag}" == COPY ]]; then
            size="$(on_machine "${sudo} du -sh $(printf %q "${src}") 2>/dev/null | cut -f1" 2>/dev/null || true)"
            log_info "Copying ${size:-the folder} (progress below)..."
            if on_machine "${sudo} tar -C $(printf %q "${src}") -cf - ." |
                dd bs=1M status=progress |
                kubectl -n "${app}" exec -i "${pod}" -- tar -xf - -C /to; then
                rc=(0 0 0)
            else
                rc=("${PIPESTATUS[@]}")
            fi
        else
            if on_machine "${sudo} cat $(printf %q "${src}")" |
                dd bs=1M status=progress |
                kubectl -n "${app}" exec -i "${pod}" -- sh -c "cat > /to/$(printf %q "${name}")"; then
                rc=(0 0 0)
            else
                rc=("${PIPESTATUS[@]}")
            fi
        fi
        kubectl -n "${app}" delete pod "${pod}" --wait=false >/dev/null 2>&1 || true
        if [[ "${rc[0]}" != 0 || "${rc[1]}" != 0 || "${rc[2]}" != 0 ]]; then
            log_error "Copying ${src} failed (machine ${rc[0]}, transfer ${rc[1]}, volume ${rc[2]})."
            if [[ "${rc[0]}" != 0 && -z "${sudo}" ]]; then
                log_error "If it says Permission denied, use a user with sudo, or root."
            fi
            rm -f "${kh}"
            return 1
        fi
        log_ok "Copied."
    done 3<<<"${out}"
    rm -f "${kh}"
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

# "Change App Storage": where an app keeps each folder (Longhorn volume
# or a folder on a node). KubesTUI writes the choice to the app's
# storage-patch.yaml in the GitOps repo; this commits it and lets Argo CD
# roll it out. If asked to copy the files, the app is stopped first (Argo
# CD paused for it), the files copied by a Job, and then the change pushed
# and Argo CD resumed, which starts the app with the new storage.
app_storage() {

    header 2>/dev/null || true

    quiet_gitops_prepare

    local out app copied=false
    out="$(run_compose_tool app-storage)" || return 1
    app="$(head -n 1 <<<"${out}")"
    [[ -n "${app}" ]] || return 0

    if grep -qx 'COPY=1' <<<"${out}"; then
        if ! storage_copy_files "${app}" "${out}"; then
            log_error "Copying failed; nothing was changed. ${app} starts again with its old storage."
            gitops_git checkout -q -- .
            gitops_git clean -qfd
            gitops_fix_ownership
            storage_resume_app "${app}"
            return 1
        fi
        copied=true
    fi

    gitops_commit_push "Change storage of ${app}"

    [[ "${copied}" == true ]] && storage_resume_app "${app}"

    kubectl -n argocd annotate application "${app}" \
        argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true

    watch_argocd_app "${app}" || true
}

# Lets Argo CD manage the app again (after storage_copy_files paused it).
storage_resume_app() {
    kubectl -n argocd annotate application "$1" \
        argocd.argoproj.io/skip-reconcile- >/dev/null 2>&1 || true
}

# storage_copy_files APP PLAN
# PLAN: KEY=value lines from `kubestui app-storage` (NS, KIND, NAME,
# FROM_TYPE/FROM, TO_TYPE/TO: pvc + claim or host + path, NODE).
storage_copy_files() {

    local app="$1" plan="$2"
    local ns kind name from_type from to_type to node job i

    val() { sed -n "s/^$1=//p" <<<"${plan}" | head -n 1; }

    ns="$(val NS)"; kind="$(val KIND)"; name="$(val NAME)"
    from_type="$(val FROM_TYPE)"; from="$(val FROM)"
    to_type="$(val TO_TYPE)"; to="$(val TO)"; node="$(val NODE)"
    job="storage-copy-${name}"
    job="${job:0:63}"

    echo
    log_info "Stopping ${name} so its files can be copied (Argo CD paused for ${app})..."

    kubectl -n argocd annotate application "${app}" \
        argocd.argoproj.io/skip-reconcile=true --overwrite >/dev/null || return 1

    kubectl -n "${ns}" scale "${kind}/${name}" --replicas=0 >/dev/null || return 1

    for i in {1..60}; do
        [[ "$(kubectl -n "${ns}" get "${kind}/${name}" -o jsonpath='{.status.replicas}' 2>/dev/null)" =~ ^0?$ ]] && break
        sleep 5
    done
    log_ok "${name} stopped."

    # A new Longhorn volume doesn't exist until Argo CD creates it, so
    # create it now from the GitOps files (Argo CD adopts it later).
    if [[ "${to_type}" == pvc ]] && ! kubectl -n "${ns}" get pvc "${to}" >/dev/null 2>&1; then
        local dir
        dir="$(dirname "$(grep -rl --include=storage-pvcs.yaml "name: ${to}$" "${GITOPS_DIR}/apps" | head -n 1)")"
        [[ -d "${dir}" ]] || { log_error "Can't find the new volume ${to} in the GitOps repo."; return 1; }
        kubectl kustomize "${dir}" | yq "select(.kind == \"PersistentVolumeClaim\" and .metadata.name == \"${to}\")" \
            | kubectl -n "${ns}" apply -f - >/dev/null || return 1
        log_ok "Created Longhorn volume ${to}."
    fi

    run_copy_job "${ns}" "${job}" "${from_type}" "${from}" "${to_type}" "${to}" "${node}"
}

# run_copy_job NS JOB FROM_TYPE FROM TO_TYPE TO NODE
# Copies everything in one storage into another with a Job (cp -a, with
# progress): TYPE is pvc (FROM/TO = claim) or host (FROM/TO = folder on
# NODE). The Job runs on NODE when one is given.
run_copy_job() {

    local ns="$1" job="$2" from_type="$3" from="$4" to_type="$5" to="$6" node="$7" i

    vol() { # vol NAME TYPE SOURCE HOSTTYPE
        if [[ "$2" == pvc ]]; then
            printf '        - name: %s\n          persistentVolumeClaim:\n            claimName: "%s"\n' "$1" "$3"
        else
            printf '        - name: %s\n          hostPath:\n            path: "%s"\n            type: %s\n' "$1" "$3" "$4"
        fi
    }

    kubectl -n "${ns}" delete job "${job}" --ignore-not-found --wait=true >/dev/null

    kubectl apply -f - >/dev/null <<YAML || return 1
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job}
  namespace: ${ns}
  labels:
    app.kubernetes.io/managed-by: homelabcd
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: Never
$( [[ -n "${node}" ]] && printf '      nodeName: %s\n' "${node}" )
      tolerations:
        - operator: Exists
      containers:
        - name: copy
          image: busybox:1.37
          command:
            - /bin/sh
            - -c
            - |
              set -e
              echo "Copying \$(du -sh /from | cut -f1) from the old location..."
              cp -a /from/. /to/ &
              pid=\$!
              while kill -0 \$pid 2>/dev/null; do
                sleep 30
                echo "  copied so far: \$(du -sh /to | cut -f1)"
              done
              wait \$pid
              echo "Copied. New location now holds \$(du -sh /to | cut -f1)."
              echo "HOMELABCD: COPY DONE"
          volumeMounts:
            - name: from
              mountPath: /from
              readOnly: true
            - name: to
              mountPath: /to
      volumes:
$(vol from "${from_type}" "${from}" Directory)
$(vol to "${to_type}" "${to}" DirectoryOrCreate)
YAML

    log_info "Copying files (this can take a while for large folders)..."

    local phase=""
    for i in {1..120}; do
        phase="$(kubectl -n "${ns}" get pods -l job-name="${job}" \
            -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
        [[ "${phase}" == Running || "${phase}" == Succeeded || "${phase}" == Failed ]] && break
        sleep 5
    done

    kubectl -n "${ns}" logs -f "job/${job}" 2>&1 || true

    local result=""
    while :; do
        result="$(kubectl -n "${ns}" get job "${job}" \
            -o jsonpath='{.status.succeeded}/{.status.failed}' 2>/dev/null || true)"
        [[ -z "${result}" || "${result}" == 1/* || "${result}" == */[1-9]* ]] && break # empty: Job gone
        sleep 10
    done

    if [[ "${result}" != 1/* ]]; then
        kubectl -n "${ns}" logs "job/${job}" 2>&1 | tail -n 20 || true
        kubectl -n "${ns}" describe pod -l job-name="${job}" 2>/dev/null | tail -n 15 || true
        return 1
    fi

    kubectl -n "${ns}" delete job "${job}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    log_ok "Files copied."
}
