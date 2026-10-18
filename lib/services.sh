#!/usr/bin/env bash

#############################################
# TURN EXTRA SERVICES ON OR OFF
#############################################
#
# "Turn Services On/Off" (install.sh --run services): stops or starts the
# optional apps (qBittorrent, PostgreSQL, the apps under apps/ai,
# apps/databases and apps/applications) without touching git. Core apps
# (Longhorn, ingress, cert-manager, Argo CD, ...) are never offered.
#
#   off: Argo CD stops reconciling the app (skip-reconcile annotation, so
#        selfHeal does not start it again), its Deployments and StatefulSets
#        scale to 0 and its CronJobs are suspended. Volumes, Secrets and
#        settings stay, so nothing is lost.
#   on:  the replica counts and CronJobs are restored and Argo CD takes
#        over again.
#
# The app's own Application keeps the annotation across GitOps syncs: its
# parent app applies client-side, which keeps fields git does not set.
#############################################

SERVICES_SKIP_ANNOTATION="argocd.argoproj.io/skip-reconcile"
SERVICES_REPLICAS_ANNOTATION="homelabcd.io/replicas-before-off"
SERVICES_SUSPEND_ANNOTATION="homelabcd.io/suspended-by-off"

# Apps that are extras by name; the rest come from their GitOps path.
SERVICES_EXTRA_NAMES=" qbittorrent postgresql "
SERVICES_EXTRA_PATHS="apps/ai/ apps/databases/ apps/applications/"

# "name|namespace|off" for each optional app ("off" is true/empty).
services_list() {

    kubectl -n argocd get applications.argoproj.io --request-timeout=30s \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.source.path}{.spec.sources[0].path}{"\t"}{.spec.destination.namespace}{"\t"}{.metadata.annotations.argocd\.argoproj\.io/skip-reconcile}{"\n"}{end}' |
        awk -F'\t' -v names="${SERVICES_EXTRA_NAMES}" -v paths="${SERVICES_EXTRA_PATHS}" '
            BEGIN { np = split(paths, p, " ") }
            {
                extra = index(names, " " $1 " ") > 0
                for (i = 1; i <= np && !extra; i++)
                    if (index($2, p[i]) == 1 && $2 != p[i]) extra = 1
                if (extra && $3 != "") print $1 "|" $3 "|" $4
            }' | sort
}

# "Kind|name|replicas|saved" of app $1's Deployments, StatefulSets and CronJobs in
# namespace $2 (CronJobs give their suspend flag instead of replicas).
services_workloads() {

    local app="$1" ns="$2"

    kubectl -n "${ns}" get deployments,statefulsets,cronjobs --request-timeout=30s \
        -o jsonpath='{range .items[*]}{.kind}{"\t"}{.metadata.name}{"\t"}{.spec.replicas}{.spec.suspend}{"\t"}{.metadata.annotations.argocd\.argoproj\.io/tracking-id}{"\t"}{.metadata.annotations.homelabcd\.io/replicas-before-off}{.metadata.annotations.homelabcd\.io/suspended-by-off}{"\n"}{end}' 2>/dev/null |
        awk -F'\t' -v app="${app}" 'index($4, app ":") == 1 { print $1 "|" $2 "|" $3 "|" $5 }'
}

# "running/wanted" pods of app $1 in namespace $2.
services_pods() {
    kubectl -n "$2" get deployments,statefulsets --request-timeout=30s \
        -o jsonpath='{range .items[*]}{.metadata.annotations.argocd\.argoproj\.io/tracking-id}{"\t"}{.status.readyReplicas}{"\t"}{.spec.replicas}{"\n"}{end}' 2>/dev/null |
        awk -F'\t' -v app="$1" 'index($1, app ":") == 1 { r += $2; w += $3 } END { print r + 0 "/" w + 0 }'
}

service_off() {

    local app="$1" ns="$2" kind name value saved

    kubectl -n argocd annotate applications.argoproj.io "${app}" \
        "${SERVICES_SKIP_ANNOTATION}=true" --overwrite >/dev/null || {
        log_error "Could not pause Argo CD for ${app}; nothing was changed."
        return 1
    }

    while IFS='|' read -r kind name value saved; do
        [[ -n "${name}" ]] || continue
        case "${kind}" in
            Deployment|StatefulSet)
                [[ "${value:-1}" != 0 ]] || continue
                kubectl -n "${ns}" annotate "${kind,,}" "${name}" \
                    "${SERVICES_REPLICAS_ANNOTATION}=${value:-1}" --overwrite >/dev/null &&
                    kubectl -n "${ns}" scale "${kind,,}" "${name}" --replicas=0 >/dev/null ||
                    log_warn "Could not stop ${kind} ${name}."
                ;;
            CronJob)
                [[ "${value}" != true ]] || continue
                kubectl -n "${ns}" annotate cronjob "${name}" \
                    "${SERVICES_SUSPEND_ANNOTATION}=true" --overwrite >/dev/null &&
                    kubectl -n "${ns}" patch cronjob "${name}" --type merge \
                        -p '{"spec":{"suspend":true}}' >/dev/null ||
                    log_warn "Could not suspend CronJob ${name}."
                ;;
        esac
    done < <(services_workloads "${app}" "${ns}")

    log_ok "${app} is off (its data and settings are kept)."
}

service_on() {

    local app="$1" ns="$2" kind name value saved

    while IFS='|' read -r kind name value saved; do
        [[ -n "${name}" && -n "${saved}" ]] || continue
        case "${kind}" in
            Deployment|StatefulSet)
                kubectl -n "${ns}" scale "${kind,,}" "${name}" --replicas="${saved}" >/dev/null ||
                    log_warn "Could not start ${kind} ${name}."
                kubectl -n "${ns}" annotate "${kind,,}" "${name}" "${SERVICES_REPLICAS_ANNOTATION}-" >/dev/null 2>&1 || true
                ;;
            CronJob)
                kubectl -n "${ns}" patch cronjob "${name}" --type merge \
                    -p '{"spec":{"suspend":false}}' >/dev/null ||
                    log_warn "Could not resume CronJob ${name}."
                kubectl -n "${ns}" annotate cronjob "${name}" "${SERVICES_SUSPEND_ANNOTATION}-" >/dev/null 2>&1 || true
                ;;
        esac
    done < <(services_workloads "${app}" "${ns}")

    # Argo CD takes over again; selfHeal brings anything still off in line
    # with git.
    kubectl -n argocd annotate applications.argoproj.io "${app}" \
        "${SERVICES_SKIP_ANNOTATION}-" >/dev/null || {
        log_error "Could not hand ${app} back to Argo CD."
        return 1
    }

    log_ok "${app} is on; its pods are starting."
}

toggle_services() {

    header 2>/dev/null || true

    command -v kubectl >/dev/null 2>&1 && kubectl get nodes >/dev/null 2>&1 || {
        log_error "Run this on a control plane (kubectl must reach the cluster)."
        return 1
    }

    local apps=() nss=() offs=() app ns off i pick list

    while true; do
        apps=() nss=() offs=()
        list="$(services_list)" || {
            log_error "Could not read the Argo CD apps."
            return 1
        }
        while IFS='|' read -r app ns off; do
            [[ -n "${app}" ]] || continue
            apps+=("${app}")
            nss+=("${ns}")
            offs+=("${off}")
        done <<< "${list}"

        if (( ${#apps[@]} == 0 )); then
            log_info "No optional services are deployed."
            return 0
        fi

        echo
        echo "Optional services (core apps like Longhorn and ingress are not listed):"
        echo
        for i in "${!apps[@]}"; do
            if [[ "${offs[i]}" == true ]]; then
                printf "  %d) %-20s OFF\n" "$(( i + 1 ))" "${apps[i]}"
            else
                printf "  %d) %-20s on   %s pods running\n" "$(( i + 1 ))" "${apps[i]}" \
                    "$(services_pods "${apps[i]}" "${nss[i]}")"
            fi
        done
        echo

        pick="$(read_choice "Service to turn on/off (blank = done): " 0 "${#apps[@]}")"
        [[ "${pick}" != 0 ]] || return 0

        i=$(( pick - 1 ))
        if [[ "${offs[i]}" == true ]]; then
            service_on "${apps[i]}" "${nss[i]}"
        else
            service_off "${apps[i]}" "${nss[i]}"
        fi
    done
}
