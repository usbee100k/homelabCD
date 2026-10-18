#!/usr/bin/env bash

#############################################
# ETCD MEMBERS OF THE CONTROL PLANES
#############################################
#
# etcd refuses to add a member while one of its members is unreachable,
# so a control plane that is down blocks every new control plane. These
# helpers show the control plane count before a join and can replace a
# control plane (down or up): its etcd member and node are removed.
# etcdctl runs inside the etcd pod of a control plane that is up.
#############################################

ETCD_CERT_ARGS=(
    --cacert=/etc/kubernetes/pki/etcd/ca.crt
    --cert=/etc/kubernetes/pki/etcd/server.crt
    --key=/etc/kubernetes/pki/etcd/server.key
)

# "name ReadyStatus" for each control plane.
control_plane_states() {
    kubectl get nodes -l node-role.kubernetes.io/control-plane --request-timeout=15s \
        -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}'
}

# etcdctl in the etcd pod of control plane $1, against the given endpoint.
etcd_on() {
    local via="$1" endpoint="$2"
    shift 2
    kubectl -n kube-system exec "etcd-${via}" -- \
        etcdctl --endpoints="${endpoint}" "${ETCD_CERT_ARGS[@]}" "$@"
}

node_internal_ip() {
    kubectl get node "$1" \
        -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null
}

# Prints the etcd member ID of the control plane at IP $1 (empty when it has
# none), asking the etcd of control plane $2. Fails when etcd cannot be asked.
etcd_member_at() {
    local ip="$1" via="$2" list
    list="$(etcd_on "${via}" https://127.0.0.1:2379 member list)" || return 1
    awk -F', ' -v u="https://${ip}:2380" '$4 == u {print $1}' <<< "${list}"
}

# Removes control plane $1 from etcd and from the cluster, through control
# plane $2. With $3 = up, $1 is drained first. A control plane reported down
# whose etcd still answers is left alone (returns 2): it is not what blocks
# a join then.
remove_control_plane() {
    local node="$1" via="$2" state="${3:-down}" ip id

    ip="$(node_internal_ip "${node}")"
    if [[ -z "${ip}" ]]; then
        log_error "No address known for ${node}."
        return 1
    fi

    if [[ "${state}" == "up" ]]; then
        kubectl drain "${node}" --ignore-daemonsets --delete-emptydir-data --timeout=180s ||
            log_warn "Some pods did not leave ${node}; removing it anyway."
    elif etcd_on "${via}" "https://${ip}:2379" endpoint health \
        --command-timeout=5s >/dev/null 2>&1; then
        log_warn "etcd on ${node} still answers; leaving ${node} in place."
        return 2
    fi

    if ! id="$(etcd_member_at "${ip}" "${via}")"; then
        log_error "Could not read the etcd members through ${via}."
        return 1
    fi

    if [[ -n "${id}" ]]; then
        etcd_on "${via}" https://127.0.0.1:2379 member remove "${id}" || return 1
    fi

    kubectl delete node "${node}" --wait=false
    log_ok "${node} removed from etcd and the cluster."

    if [[ "${state}" == "up" ]]; then
        log_info "On ${node}, run now: sudo kubeadm reset -f"
        echo "       (or add it back later; the installer resets it first)."
    fi
}

# Asks until the answer is one of 1..$3; blank (or end of input) is $2.
read_choice() {
    local prompt="$1" def="$2" max="$3" answer

    while true; do
        read -rp "${prompt}" answer || answer=""
        [[ -z "${answer}" ]] && { echo "${def}"; return; }
        if [[ "${answer}" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= max )); then
            echo "${answer}"
            return
        fi
    done
}

# How many of $1 etcd members can be down: it needs more than half up.
etcd_can_lose() { echo $(( ($1 - 1) / 2 )); }

# Runs before a control plane joins. Shows how many control planes the
# cluster has and what one more means for etcd, and lets the user add it,
# replace one (keeping the count) or cancel. A control plane that is down
# must be replaced first: etcd refuses to add a member while one of its
# members is unreachable. Fails when the join should not go ahead.
plan_control_planes() {
    local states self up=() down=() candidates=() name status total after
    local via def choice node i answer

    states="$(control_plane_states 2>/dev/null)" || return 0
    self="$(hostname -s | tr '[:upper:]' '[:lower:]')"

    while read -r name status; do
        [[ -n "${name}" ]] || continue
        if [[ "${status}" == "True" ]]; then
            up+=("${name}")
        else
            down+=("${name}")
        fi
    done <<< "${states}"

    total=$(( ${#up[@]} + ${#down[@]} ))
    (( total > 0 )) || return 0

    if (( ${#up[@]} * 2 <= total )); then
        log_error "Only ${#up[@]} of ${total} control planes are up (${down[*]} down)."
        echo "etcd needs more than half of them to make any change. Start one of them again first."
        return 1
    fi

    # etcdctl runs in the etcd pod of this machine when it is a control
    # plane that is up; this machine is never offered for removal.
    via="${up[0]}"
    for name in "${up[@]}"; do
        if [[ "${name}" == "${self}" ]]; then
            via="${self}"
        else
            candidates+=("${name}")
        fi
    done

    echo
    echo -n "This cluster has ${total} control plane(s): ${up[*]}"
    (( ${#down[@]} == 0 )) || echo -n " (DOWN: ${down[*]})"
    echo "."

    if (( ${#down[@]} > 0 )); then
        echo "etcd will not add a new control plane while ${down[*]} is unreachable."
        echo "  1) Replace ${down[*]} with the new machine, staying at ${total} (${down[*]} can be"
        echo "     added back later as a control plane; the installer resets it first)"
        echo "  2) Cancel (start ${down[*]} again, then add the new one)"
        choice="$(read_choice "Choice [2]: " 2 2)"
        if [[ "${choice}" != 1 ]]; then
            log_error "Cancelled; nothing was changed."
            return 1
        fi
        for node in "${down[@]}"; do
            remove_control_plane "${node}" "${via}" down || (( $? == 2 )) || return 1
        done
        return 0
    fi

    after=$(( total + 1 ))

    if (( total == 1 )); then
        echo "Adding one makes 2. etcd needs more than half of its members up, so with"
        echo "2 losing EITHER one stops the cluster: less safe than 1. 3 can lose one."
        echo "The only control plane cannot be swapped out (its etcd holds the cluster)."
        echo "  1) Add it, making 2 (a third control plane will follow)"
        echo "  2) Cancel (to stay at 1, add the new machine as a worker instead)"
        choice="$(read_choice "Choice [2]: " 2 2)"
        if [[ "${choice}" != 1 ]]; then
            log_error "Cancelled; the cluster stays at 1 control plane."
            return 1
        fi
        return 0
    fi

    echo "${total} control planes can lose $(etcd_can_lose "${total}"); adding one makes ${after}, which can lose $(etcd_can_lose "${after}")."

    def=1
    if (( after % 2 == 0 )); then
        def=3
        log_warn "An even number adds no safety: ${after} can lose $(etcd_can_lose "${after}"), the same as ${total},"
        echo "       and etcd has one more member to wait for."
    fi

    echo "  1) Add it, making ${after}"
    echo "  2) Replace one of them with the new machine, staying at ${total}"
    echo "  3) Cancel"
    choice="$(read_choice "Choice [${def}]: " "${def}" 3)"

    case "${choice}" in
        1) return 0 ;;
        3) log_error "Cancelled; the cluster stays at ${total} control planes."; return 1 ;;
    esac

    if (( ${#candidates[@]} == 0 )); then
        log_error "No control plane can be replaced from here."
        return 1
    fi

    for i in "${!candidates[@]}"; do
        echo "  $(( i + 1 ))) ${candidates[i]}"
    done
    choice="$(read_choice "Control plane to replace (blank = cancel): " 0 "${#candidates[@]}")"
    if [[ "${choice}" == 0 ]]; then
        log_error "Cancelled; nothing was changed."
        return 1
    fi
    node="${candidates[choice - 1]}"

    echo "${node} will be drained (its pods move to other nodes) and removed from etcd"
    echo "and the cluster before the new machine joins."
    read -rp "Replace ${node}? [y/N] " answer || answer=""
    if [[ ! "${answer}" =~ ^[Yy] ]]; then
        log_error "Cancelled; nothing was changed."
        return 1
    fi

    remove_control_plane "${node}" "${via}" up
}
