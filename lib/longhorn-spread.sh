#!/usr/bin/env bash

#############################################
# Spread Longhorn storage across the nodes
#############################################
#
# Longhorn keeps every volume as copies (replicas) on several nodes'
# disks; the volume itself attaches to whichever node runs its app. For a
# node going down to lose nothing, a volume's copies must be on different
# nodes, and its app must be able to start on another node. This shows
# where the copies are and fixes what stops them from spreading:
#
#   1. Longhorn keeps copies only on nodes where its engine runs, and it
#      skips nodes with a taint it doesn't tolerate: control planes,
#      unless taint-toleration lists their taint. Changing that restarts
#      Longhorn's parts on the nodes, which Longhorn only allows while no
#      volume is in use, so the apps using volumes are stopped for a
#      minute or two (Argo CD paused for them) and then started again.
#   2. One copy per node (replica-soft-anti-affinity=false) and
#      rebalancing (replica-auto-balance=best-effort): Longhorn builds a
#      copy on a node without one before removing the extra copy from a
#      crowded node.
#   3. Failover (node-down-pod-deletion-policy): when a node goes down,
#      Longhorn removes its stuck pods so their apps start on another
#      node with their volumes, instead of waiting for the node.
#
# Safe to re-run; a run that was interrupted starts the apps it stopped.
#############################################

LH_SPREAD_NS="longhorn-system"

# Longhorn's own parts (engine, CSI plugin, instance managers) run on
# nodes with these taints too; control planes carry them.
LH_SPREAD_TOLERATION="node-role.kubernetes.io/control-plane:NoSchedule;node-role.kubernetes.io/master:NoSchedule"

# On a workload this stopped: the replicas to start it with again, and
# the Argo CD app paused for it.
LH_SPREAD_MARK="homelabcd.io/spread-replicas"
LH_SPREAD_APP_MARK="homelabcd.io/spread-app"

# setting|value|what it does
LH_SPREAD_SETTINGS=(
    "replica-soft-anti-affinity|false|one copy per node, never two copies on the same node"
    "replica-auto-balance|best-effort|move extra copies from crowded nodes to nodes without one"
    "node-down-pod-deletion-policy|delete-both-statefulset-and-deployment-pod|when a node goes down, its apps start on another node with their volumes"
)

lh_spread_setting() {
    kubectl -n "${LH_SPREAD_NS}" get settings.longhorn.io "$1" -o jsonpath='{.value}' 2>/dev/null || true
}

lh_spread_set() {
    kubectl -n "${LH_SPREAD_NS}" patch settings.longhorn.io "$1" --type merge \
        -p "$(jq -cn --arg v "$2" '{value: $v}')" >/dev/null
}

# lh_spread_read DIR: saves the cluster's nodes, Longhorn nodes, replicas,
# volumes and engine images as JSON files in DIR.
lh_spread_read() {
    local dir="$1"
    kubectl get nodes -o json >"${dir}/nodes.json" &&
        kubectl -n "${LH_SPREAD_NS}" get nodes.longhorn.io -o json >"${dir}/lhnodes.json" &&
        kubectl -n "${LH_SPREAD_NS}" get replicas.longhorn.io -o json >"${dir}/replicas.json" &&
        kubectl -n "${LH_SPREAD_NS}" get volumes.longhorn.io -o json >"${dir}/volumes.json" &&
        kubectl -n "${LH_SPREAD_NS}" get engineimages.longhorn.io -o json >"${dir}/engines.json"
}

# lh_spread_nodes DIR: one TSV line per node: name, Ready, engine runs
# there, has a Longhorn disk, copies held, usable bytes, reserved bytes
# (volumes scheduled there), taints, runs apps (no NoSchedule taint).
lh_spread_nodes() {
    jq -r --slurpfile lh "$1/lhnodes.json" --slurpfile rep "$1/replicas.json" --slurpfile ei "$1/engines.json" '
        .items[] | .metadata.name as $n
        | ([.status.conditions[]? | select(.type == "Ready") | .status][0] // "Unknown") as $ready
        | ([$ei[0].items[] | select(.status.state == "deployed") | (.status.nodeDeploymentMap // {})[$n] // false] | any) as $engine
        | [$lh[0].items[] | select(.metadata.name == $n)] as $me
        | ([$rep[0].items[] | select(.spec.nodeID == $n)] | length) as $copies
        | ([$me[] | .status.diskStatus // {} | .[] | .storageMaximum] | add // 0) as $max
        | ([$me[] | .spec.disks // {} | .[] | .storageReserved] | add // 0) as $keep
        | ([$me[] | .status.diskStatus // {} | .[] | .storageScheduled] | add // 0) as $sched
        | [.spec.taints[]? | select(.effect != "PreferNoSchedule") | .key] as $taints
        | [$n, ($ready == "True" | tostring), ($engine | tostring), (($me | length) > 0 | tostring),
           ($copies | tostring), ([$max - $keep, 0] | max | tostring), ($sched | tostring),
           ($taints | join(",")),
           ([$taints[] | select(startswith("node.kubernetes.io/") | not)] | length == 0 | tostring)] | @tsv
    ' "$1/nodes.json"
}

# lh_spread_volumes DIR: one TSV line per volume: claim (or volume name),
# health, copies wanted, nodes holding copies ("toji×2 gojo"), how many
# different nodes.
lh_spread_volumes() {
    jq -r --slurpfile rep "$1/replicas.json" '
        .items[] | .metadata.name as $v
        | (.status.kubernetesStatus // {}) as $k
        | [$rep[0].items[] | select(.spec.volumeName == $v and (.spec.nodeID // "") != "") | .spec.nodeID] as $on
        | [(if ($k.pvcName // "") != "" then $k.namespace + "/" + $k.pvcName else $v end),
           (.status.robustness // "unknown"), (.spec.numberOfReplicas | tostring),
           ($on | group_by(.) | map(if length > 1 then "\(.[0])×\(length)" else .[0] end) | join(" ")),
           ($on | unique | length | tostring)] | @tsv
    ' "$1/volumes.json" | sort
}

# lh_spread_cp_blocked DIR: Ready control planes with a Longhorn disk
# where Longhorn's engine doesn't run (the toleration is missing).
lh_spread_cp_blocked() {
    lh_spread_nodes "$1" | awk -F'\t' '$2 == "true" && $3 == "false" && $4 == "true" &&
        $8 ~ /node-role\.kubernetes\.io\/(control-plane|master)/ {print $1}'
}

# lh_spread_problems: one line per reason a node going down would lose a
# volume or stop an app (used by the health check). Empty when none.
lh_spread_problems() {
    local dir out
    kubectl -n "${LH_SPREAD_NS}" get settings.longhorn.io replica-soft-anti-affinity >/dev/null 2>&1 || return 0
    dir="$(mktemp -d)"
    if ! lh_spread_read "${dir}" 2>/dev/null; then
        rm -rf "${dir}"
        return 0
    fi
    out="$(lh_spread_cp_blocked "${dir}" | paste -sd ' ' -)"
    [[ -z "${out}" ]] || echo "Longhorn can't keep copies on ${out} (control-plane taint not tolerated)"
    lh_spread_volumes "${dir}" | awk -F'\t' '$3 > 1 && $5 == 1 {print "All copies of " $1 " are on one node (" $4 ")"}'
    lh_spread_volumes "${dir}" | awk -F'\t' '$5 == 0 {print "No copies of " $1 " exist (" $2 ")"}'
    [[ "$(lh_spread_setting node-down-pod-deletion-policy)" != do-nothing ]] ||
        echo "Apps wait for a down node instead of starting elsewhere (node-down-pod-deletion-policy)"
    rm -rf "${dir}"
}

lh_spread_gb() {
    awk -v b="${1:-0}" 'BEGIN { printf "%.1fG", b / 1073741824 }'
}

# lh_spread_show DIR: where the copies are, per node and per volume.
lh_spread_show() {
    local name ready engine disk copies usable sched taints apps state where

    echo
    echo "Nodes:"
    printf '  %-14s %-9s %-44s %s\n' NODE STATE LONGHORN "COPIES  SPACE (reserved of usable)"
    while IFS=$'\t' read -r name ready engine disk copies usable sched taints apps; do
        [[ -n "${name}" ]] || continue
        state="Ready"
        [[ "${ready}" == true ]] || state="NotReady"
        if [[ "${disk}" != true ]]; then
            where="no Longhorn disk"
        elif [[ "${ready}" != true ]]; then
            where="down: copies there are unavailable"
        elif [[ "${engine}" == true ]]; then
            where="keeps copies"
        elif [[ "${taints}" == *node-role.kubernetes.io/* ]]; then
            where="can't keep copies (control-plane taint)"
        else
            where="can't keep copies (engine not running)"
        fi
        printf '  %-14s %-9s %-44s %-7s %s of %s\n' "${name}" "${state}" "${where}" "${copies}" \
            "$(lh_spread_gb "${sched}")" "$(lh_spread_gb "${usable}")"
    done < <(lh_spread_nodes "$1")

    echo
    echo "Volumes:"
    local claim health want on count note
    printf '  %-40s %-10s %s\n' VOLUME HEALTH "COPIES ON"
    while IFS=$'\t' read -r claim health want on count; do
        [[ -n "${claim}" ]] || continue
        note=""
        if (( count == 0 )); then
            on="none"
            note="  ${RED}← no copy anywhere${NC}"
        elif (( want > 1 && count == 1 )); then
            note="  ${YELLOW}← all on one node${NC}"
        fi
        printf '  %-40s %-10s %s (%s wanted)' "${claim}" "${health}" "${on}" "${want}"
        echo -e "${note}"
    done < <(lh_spread_volumes "$1")
}

# Workloads using a Longhorn volume that are running: kind, namespace,
# name, replicas, Argo CD app ("" if none).
lh_spread_workloads() {
    local claims
    claims="$(jq -r '.items[] | .status.kubernetesStatus // {} | select((.pvcName // "") != "") | .namespace + "/" + .pvcName' "$1/volumes.json")"
    kubectl get deployments,statefulsets -A -o json | jq -r --arg claims "${claims}" '
        ($claims | split("\n")) as $c
        | .items[] | select((.spec.replicas // 1) > 0)
        | .metadata.namespace as $ns | .metadata.name as $name
        | ([.spec.template.spec.volumes[]? | .persistentVolumeClaim.claimName // empty | $ns + "/" + .]
           + [(.spec.volumeClaimTemplates // [])[] | .metadata.name as $t
              | $c[] | select(startswith($ns + "/" + $t + "-" + $name + "-"))]) as $uses
        | select([$uses[] | IN($c[])] | any)
        | (((.metadata.annotations // {})["argocd.argoproj.io/tracking-id"] // "") | split(":")[0]) as $tracked
        | [.kind, $ns, $name, (.spec.replicas // 1 | tostring),
           (if $tracked != "" then $tracked else ((.metadata.labels // {})["app.kubernetes.io/instance"] // "") end)] | @tsv'
}

# Starts the workloads this stopped (marked with LH_SPREAD_MARK) and lets
# Argo CD manage their apps again.
lh_spread_resume_apps() {
    local kind ns name want app apps=()

    while IFS=$'\t' read -r kind ns name want app; do
        [[ -n "${name}" ]] || continue
        if kubectl -n "${ns}" scale "${kind}/${name}" --replicas="${want}" >/dev/null 2>&1; then
            kubectl -n "${ns}" annotate "${kind}/${name}" "${LH_SPREAD_MARK}-" "${LH_SPREAD_APP_MARK}-" >/dev/null 2>&1 || true
            log_ok "Started ${ns}/${name}."
        else
            log_warn "Couldn't start ${ns}/${name}: kubectl -n ${ns} scale ${kind}/${name} --replicas=${want}"
        fi
        [[ -z "${app}" ]] || apps+=("${app}")
    done < <(kubectl get deployments,statefulsets -A -o json 2>/dev/null | jq -r --arg m "${LH_SPREAD_MARK}" --arg a "${LH_SPREAD_APP_MARK}" '
        .items[] | select((.metadata.annotations // {})[$m] != null)
        | [(.kind | ascii_downcase), .metadata.namespace, .metadata.name,
           .metadata.annotations[$m], ((.metadata.annotations // {})[$a] // "")] | @tsv' || true)

    for app in $(printf '%s\n' "${apps[@]}" | sort -u); do
        kubectl -n argocd annotate application "${app}" argocd.argoproj.io/skip-reconcile- >/dev/null 2>&1 || true
    done
}

# Waits until no Longhorn volume is attached; prints what still is.
lh_spread_wait_detached() {
    local i out
    for i in {1..60}; do
        out="$(kubectl -n "${LH_SPREAD_NS}" get volumes.longhorn.io -o json | jq -r '
            .items[] | select(.status.state != "detached")
            | (.status.kubernetesStatus // {}) as $k
            | (if ($k.pvcName // "") != "" then $k.namespace + "/" + $k.pvcName else .metadata.name end)
              + " (" + .status.state + ", "
              + ([$k.workloadsStatus[]? | .podName] | if length > 0 then "used by " + join(", ") else "no pod" end) + ")"' || true)"
        [[ -n "${out}" ]] || return 0
        (( i % 3 == 1 )) && echo "  waiting for $(wc -l <<<"${out}") volume(s) to be released..."
        sleep 5
    done
    log_error "These volumes are still in use:"
    sed 's/^/    /' <<<"${out}"
    echo "  Close anything using them (a volume open in KubesTUI's Files, a running Job) and run this again."
    return 1
}

# Waits until Longhorn's engine runs on every Ready node with a disk.
lh_spread_wait_engines() {
    local dir="$1" i missing
    for i in {1..60}; do
        if lh_spread_read "${dir}" 2>/dev/null; then
            missing="$(lh_spread_nodes "${dir}" | awk -F'\t' '$2 == "true" && $4 == "true" && $3 == "false" {print $1}' | paste -sd ' ' -)"
            [[ -n "${missing}" ]] || return 0
            (( i % 3 == 1 )) && echo "  waiting for Longhorn to start on ${missing}..."
        fi
        sleep 5
    done
    log_warn "Longhorn's engine still isn't running on ${missing}; it keeps trying (see: kubectl -n ${LH_SPREAD_NS} get pods -o wide)."
    return 1
}

# Waits up to 3 minutes for the restarted workloads to be ready.
lh_spread_wait_ready() {
    local kind ns name want ready i pending
    for i in {1..36}; do
        pending=()
        while IFS=$'\t' read -r kind ns name want _; do
            [[ -n "${name}" ]] || continue
            ready="$(kubectl -n "${ns}" get "${kind,,}/${name}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
            (( ${ready:-0} >= want )) || pending+=("${ns}/${name}")
        done <"$1"
        (( ${#pending[@]} > 0 )) || { log_ok "All the apps are running again."; return 0; }
        sleep 5
    done
    log_warn "Not ready yet (still starting or already unhealthy before): ${pending[*]}"
}

# Allows Longhorn on the control planes: stops the apps using volumes,
# sets taint-toleration, waits for Longhorn there and starts the apps.
lh_spread_tolerate() {
    local dir="$1" current kind ns name want app

    lh_spread_workloads "${dir}" >"${dir}/workloads.tsv"

    trap 'echo; lh_spread_resume_apps; exit 130' INT TERM

    echo
    log_info "Stopping the apps that use volumes (Argo CD paused for them)..."
    while IFS=$'\t' read -r kind ns name want app; do
        [[ -n "${name}" ]] || continue
        if [[ -n "${app}" ]]; then
            kubectl -n argocd annotate application "${app}" argocd.argoproj.io/skip-reconcile=true \
                --overwrite >/dev/null 2>&1 || true
        fi
        kubectl -n "${ns}" annotate "${kind,,}/${name}" --overwrite \
            "${LH_SPREAD_MARK}=${want}" "${LH_SPREAD_APP_MARK}=${app}" >/dev/null &&
            kubectl -n "${ns}" scale "${kind,,}/${name}" --replicas=0 >/dev/null &&
            echo "  stopped ${ns}/${name}"
    done <"${dir}/workloads.tsv"

    local ok=true
    if ! lh_spread_wait_detached; then
        ok=false
    else
        current="$(lh_spread_setting taint-toleration)"
        if lh_spread_set taint-toleration "${current:+${current};}${LH_SPREAD_TOLERATION}"; then
            log_ok "Longhorn now runs on the control planes too (taint-toleration)."
            lh_spread_wait_engines "${dir}" && log_ok "Longhorn's engine runs on every Ready node."
        else
            log_error "Longhorn didn't accept the new taint-toleration (see the message above)."
            ok=false
        fi
    fi

    echo
    log_info "Starting the apps again..."
    lh_spread_resume_apps
    trap - INT TERM
    [[ -s "${dir}/workloads.tsv" ]] && lh_spread_wait_ready "${dir}/workloads.tsv"

    [[ "${ok}" == true ]]
}

spread_longhorn_storage() {

    header 2>/dev/null || true

    if ! kubectl get nodes >/dev/null 2>&1; then
        log_error "Can't reach the cluster API with kubectl from this node."
        return 1
    fi
    if ! kubectl -n "${LH_SPREAD_NS}" get settings.longhorn.io replica-soft-anti-affinity >/dev/null 2>&1; then
        log_error "Longhorn isn't installed (or not ready yet)."
        return 1
    fi

    # A run that was interrupted while the apps were stopped.
    if kubectl get deployments,statefulsets -A -o json | jq -e --arg m "${LH_SPREAD_MARK}" \
        '[.items[] | select((.metadata.annotations // {})[$m] != null)] | length > 0' >/dev/null; then
        log_warn "A previous run stopped some apps; starting them first."
        lh_spread_resume_apps
    fi

    local dir rc=0
    dir="$(mktemp -d)"
    lh_spread_run "${dir}" || rc=$?
    rm -rf "${dir}"
    return "${rc}"
}

lh_spread_run() {

    local dir="$1"

    lh_spread_read "${dir}" || { log_error "Couldn't read Longhorn's state."; return 1; }
    lh_spread_show "${dir}"

    # What isn't set up yet.
    local blocked changes=() entry key value why
    blocked="$(lh_spread_cp_blocked "${dir}" | paste -sd ' ' -)"
    for entry in "${LH_SPREAD_SETTINGS[@]}"; do
        IFS='|' read -r key value why <<<"${entry}"
        [[ "$(lh_spread_setting "${key}")" == "${value}" ]] || changes+=("${entry}")
    done

    # Who could take over a down node's apps: Ready nodes without a
    # taint that keeps apps off.
    local hosts down
    hosts="$(lh_spread_nodes "${dir}" | awk -F'\t' '$2 == "true" && $9 == "true" {print $1}' | paste -sd ' ' -)"
    down="$(lh_spread_nodes "${dir}" | awk -F'\t' '$2 != "true" {print $1}' | paste -sd ' ' -)"

    echo
    if [[ -n "${down}" ]]; then
        log_warn "Down: ${down}. Longhorn can't use their copies or keep new ones there until they're back."
    fi
    if [[ "$(wc -w <<<"${hosts}")" -lt 2 ]]; then
        log_warn "Apps can run on only ${hosts:-no node} right now (the other nodes are down, or control planes that don't run apps). For apps to move when a node goes down, at least two nodes that run apps (workers) must be up."
    fi

    if [[ -z "${blocked}" ]] && (( ${#changes[@]} == 0 )); then
        log_ok "Longhorn is already set to spread copies across the nodes and fail over."
        echo "  Copies still on one node are moved as nodes come back (it rebuilds one at a time)."
        return 0
    fi

    echo
    echo "This will:"
    if [[ -n "${blocked}" ]]; then
        echo "  - Let Longhorn keep copies on ${blocked} (taint-toleration)."
        echo "    Longhorn restarts its parts for this, which it only does while no volume is"
        echo "    in use: the apps using volumes are stopped for a minute or two, then started."
        if [[ -n "$(lh_spread_workloads "${dir}")" ]]; then
            echo "    Stopped meanwhile: $(lh_spread_workloads "${dir}" | awk -F'\t' '{print $2 "/" $3}' | paste -sd ' ' - | sed 's/ /, /g')"
        fi
    fi
    for entry in "${changes[@]}"; do
        IFS='|' read -r key value why <<<"${entry}"
        echo "  - ${why^} (${key}=${value})."
    done
    echo "  Longhorn then builds copies on the other nodes in the background; each old copy"
    echo "  is removed only after its new one is ready. Your data isn't touched."
    echo

    local answer
    read -r -p "Go ahead? (y/N): " answer || true
    if [[ ! "${answer,,}" =~ ^y ]]; then
        echo "Nothing changed."
        return 0
    fi

    local failed=false
    if [[ -n "${blocked}" ]]; then
        lh_spread_tolerate "${dir}" || failed=true
    fi

    echo
    for entry in "${changes[@]}"; do
        IFS='|' read -r key value why <<<"${entry}"
        if lh_spread_set "${key}" "${value}"; then
            log_ok "${key} = ${value}"
        else
            log_error "Couldn't set ${key} (see the message above)."
            failed=true
        fi
    done

    # The GitOps repo's Longhorn values set these at install; older
    # templates don't have them yet.
    if ! kubectl -n "${LH_SPREAD_NS}" get configmap longhorn-default-setting -o jsonpath='{.data}' 2>/dev/null |
        grep -q 'replica-auto-balance'; then
        echo
        log_info "Run \"Update GitOps Templates\" too, so your GitOps repo's Longhorn settings match (a reinstalled Longhorn keeps them)."
    fi

    echo
    log_info "Where the copies are now (Longhorn keeps moving them in the background):"
    sleep 10
    lh_spread_read "${dir}" && lh_spread_show "${dir}"
    echo
    echo "  Watch it in the Command Center's Storage panel (7): the COPIES column, or run this again."

    [[ "${failed}" == false ]]
}
