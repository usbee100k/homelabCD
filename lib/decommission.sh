#!/usr/bin/env bash

#############################################
# DECOMMISSION A NODE
#############################################
#
# "Decommission Node" (install.sh --run decommission): takes a worker or
# control plane out of the cluster for good.
#
#   node up:   Longhorn moves its volume copies to other nodes, its pods
#              are drained, a control plane leaves etcd, and the machine is
#              reset (kubeadm reset) through a privileged Job on it.
#   node down: its pods are force-removed (out-of-service taint), a control
#              plane leaves etcd; the machine itself must be reset when it
#              is back on, or it rejoins.
#
# Then the node is deleted from Kubernetes and Longhorn. Uses
# lib/etcd-members.sh for the etcd part.
#############################################

# Volumes whose only healthy copy is on node $1 (one name per line).
longhorn_volumes_only_on() {

    local node="$1"

    kubectl -n longhorn-system get replicas.longhorn.io --request-timeout=30s \
        -o jsonpath='{range .items[*]}{.spec.volumeName}{"\t"}{.spec.nodeID}{"\t"}{.spec.healthyAt}{"\t"}{.spec.failedAt}{"\n"}{end}' 2>/dev/null |
        awk -F'\t' -v n="${node}" '
            $3 != "" && $4 == "" { if ($2 == n) here[$1] = 1; else elsewhere[$1] = 1 }
            END { for (v in here) if (!(v in elsewhere)) print v }' | sort
}

longhorn_replicas_on() {
    kubectl -n longhorn-system get replicas.longhorn.io --request-timeout=30s \
        -o jsonpath="{range .items[?(@.spec.nodeID==\"$1\")]}{.metadata.name}{\"\\n\"}{end}" 2>/dev/null |
        grep -c . || true
}

# Asks Longhorn to move node $1's volume copies elsewhere and waits.
longhorn_evict_node() {

    local node="$1" left i answer

    kubectl -n longhorn-system get nodes.longhorn.io "${node}" >/dev/null 2>&1 || return 0

    log_info "Asking Longhorn to move ${node}'s volume copies to other nodes..."
    kubectl -n longhorn-system patch nodes.longhorn.io "${node}" --type merge \
        -p '{"spec":{"allowScheduling":false,"evictionRequested":true}}' >/dev/null || {
        log_warn "Could not start the Longhorn eviction."
        return 0
    }

    while true; do
        for (( i = 0; i < 180; i++ )); do
            left="$(longhorn_replicas_on "${node}")"
            (( left == 0 )) && { log_ok "No volume copies left on ${node}."; return 0; }
            (( i % 6 == 0 )) && log_info "${left} volume copies still on ${node}..."
            sleep 10
        done
        read -rp "Copies are still moving after 30 minutes. Keep waiting? [Y/n] " answer || answer=n
        [[ "${answer:-Y}" =~ ^[Yy] ]] || { log_warn "Continuing; Longhorn rebuilds the rest from other copies."; return 0; }
    done
}

# Resets the machine behind Ready node $1 through a privileged Job on it.
# The reset runs as its own systemd unit, so it finishes after the node
# (and this Job) are gone.
reset_node_machine() {

    local node="$1" job="homelabcd-decommission" ns="kube-system" i out

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
  ttlSecondsAfterFinished: 300
  template:
    spec:
      nodeName: ${node}
      hostPID: true
      restartPolicy: Never
      tolerations:
        - operator: Exists
      containers:
        - name: reset
          image: busybox:1.37
          securityContext:
            privileged: true
          command:
            - nsenter
            - -t
            - "1"
            - -m
            - -u
            - -i
            - -n
            - -p
            - --
            - /bin/sh
            - -c
            - |
              systemd-run --unit=homelabcd-decommission --collect --quiet /bin/sh -c '
                sleep 20
                kubeadm reset -f
                systemctl disable --now kubelet
                rm -rf /etc/cni/net.d /etc/kubernetes /var/lib/kubelet /var/lib/etcd
                systemctl restart containerd
              ' && echo "HOMELABCD: RESET STARTED"
YAML

    for (( i = 0; i < 60; i++ )); do
        out="$(kubectl -n "${ns}" logs "job/${job}" 2>/dev/null || true)"
        [[ "${out}" == *"RESET STARTED"* ]] && return 0
        sleep 2
    done

    return 1
}

decommission_node() {

    header 2>/dev/null || true

    command -v kubectl >/dev/null 2>&1 && kubectl get nodes >/dev/null 2>&1 || {
        log_error "Run this on a control plane (kubectl must reach the cluster)."
        return 1
    }

    local self names=() roles=() states=() ips=() name role ready ip i pick
    local node state is_cp cp_states cp_up=0 cp_total=0 via="" answer only

    self="$(hostname -s | tr '[:upper:]' '[:lower:]')"

    while IFS=$'\t' read -r name role ready ip; do
        [[ -n "${name}" ]] || continue
        names+=("${name}")
        if [[ "${role}" == *control-plane* ]]; then roles+=("control plane"); else roles+=("worker"); fi
        if [[ "${ready}" == True ]]; then states+=("Ready"); else states+=("DOWN"); fi
        ips+=("${ip}")
    done < <(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\t"}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}')

    echo
    echo "Decommission a node: take it out of the cluster for good."
    echo
    for i in "${!names[@]}"; do
        printf "  %d) %-12s %-14s %-6s %s%s\n" "$(( i + 1 ))" "${names[i]}" "${roles[i]}" \
            "${states[i]}" "${ips[i]}" "$([[ "${names[i]}" == "${self}" ]] && echo "  (this machine)")"
    done
    echo

    pick="$(read_choice "Node to decommission (blank = cancel): " 0 "${#names[@]}")"
    [[ "${pick}" != 0 ]] || { log_info "Nothing was changed."; return 0; }

    i=$(( pick - 1 ))
    node="${names[i]}"
    state="${states[i]}"
    is_cp=false
    [[ "${roles[i]}" == "control plane" ]] && is_cp=true

    if [[ "${node}" == "${self}" ]]; then
        log_error "${node} is the machine this runs on. Decommission it from another control plane."
        return 1
    fi

    if [[ "${is_cp}" == true ]]; then
        cp_states="$(control_plane_states)"
        while read -r name ready; do
            [[ -n "${name}" ]] || continue
            cp_total=$(( cp_total + 1 ))
            if [[ "${ready}" == True ]]; then
                cp_up=$(( cp_up + 1 ))
                # etcdctl runs in the etcd pod of this machine if it is a
                # control plane, else of another one that is up.
                if [[ "${name}" != "${node}" ]] && [[ -z "${via}" || "${name}" == "${self}" ]]; then
                    via="${name}"
                fi
            fi
        done <<< "${cp_states}"

        if (( cp_total <= 1 )); then
            log_error "${node} is the only control plane; removing it would remove the cluster."
            return 1
        fi

        # Members left after removing it, and how many of those are up.
        local left=$(( cp_total - 1 )) left_up="${cp_up}"
        [[ "${state}" == Ready ]] && left_up=$(( left_up - 1 ))
        if (( left_up * 2 <= left )); then
            log_error "Removing ${node} would leave ${left_up} of ${left} control planes up; etcd needs more than half."
            echo "Start the control planes that are down again first."
            return 1
        fi

        echo "${node} is a control plane: it also leaves etcd. ${left} control plane(s) remain"
        echo "($(etcd_can_lose "${left}") of them can fail)."
        (( left % 2 == 0 )) &&
            log_warn "An even number adds no safety; consider adding or removing one more later."
    fi

    if [[ "${state}" == Ready ]]; then
        echo
        echo "${node} is up. This will:"
        echo "  - move its Longhorn volume copies to other nodes and drain its pods"
        [[ "${is_cp}" == true ]] && echo "  - remove it from etcd"
        echo "  - reset the machine (kubeadm reset; its files and OS stay)"
        echo "  - delete it from Kubernetes and Longhorn"
    else
        echo
        echo "${node} is DOWN. This will:"
        echo "  - force-remove its pods (they start again on other nodes)"
        [[ "${is_cp}" == true ]] && echo "  - remove it from etcd"
        echo "  - delete it from Kubernetes and Longhorn"
        echo "  When the machine is on again, run there: sudo kubeadm reset -f"
        echo "  (otherwise it registers itself again)."

        only="$(longhorn_volumes_only_on "${node}")"
        if [[ -n "${only}" ]]; then
            echo
            log_warn "These volumes have their only healthy copy on ${node}; their data is lost"
            log_warn "if it is removed now (bring ${node} back instead to keep it):"
            sed 's/^/    /' <<< "${only}"
        fi
    fi

    echo
    read -rp "Type the node name (${node}) to decommission it: " answer || answer=""
    if [[ "${answer}" != "${node}" ]]; then
        log_info "Nothing was changed."
        return 0
    fi

    kubectl cordon "${node}" >/dev/null || true

    if [[ "${state}" == Ready ]]; then

        longhorn_evict_node "${node}"

        log_info "Draining ${node}..."
        kubectl drain "${node}" --ignore-daemonsets --delete-emptydir-data --timeout=300s ||
            log_warn "Some pods did not leave ${node}; continuing."

        if [[ "${is_cp}" == true ]]; then
            remove_control_plane_member "${node}" "${via}" || return 1
        fi

        log_info "Resetting the machine ${node}..."
        if reset_node_machine "${node}"; then
            # Delete the node only once its kubelet has stopped, or the
            # kubelet registers it again.
            log_info "Waiting for ${node}'s kubelet to stop..."
            for (( i = 0; i < 60; i++ )); do
                [[ "$(kubectl get node "${node}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == True ]] || break
                sleep 3
            done
        else
            log_warn "Could not reset ${node} from here; run there: sudo kubeadm reset -f"
        fi
    else
        log_info "Force-removing ${node}'s pods..."
        kubectl taint node "${node}" node.kubernetes.io/out-of-service=nodeshutdown:NoExecute \
            --overwrite >/dev/null || true
        sleep 10
        kubectl get pods -A --field-selector "spec.nodeName=${node}" \
            -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' |
            while read -r ns pod; do
                [[ -n "${pod}" ]] || continue
                kubectl -n "${ns}" delete pod "${pod}" --grace-period=0 --force --wait=false >/dev/null 2>&1 || true
            done

        if [[ "${is_cp}" == true ]]; then
            remove_control_plane_member "${node}" "${via}" || return 1
        fi
    fi

    kubectl delete node "${node}" --wait=false >/dev/null
    kubectl -n longhorn-system delete nodes.longhorn.io "${node}" --wait=false >/dev/null 2>&1 || true

    log_ok "${node} has been decommissioned."
    [[ "${state}" == Ready ]] || echo "When the machine is on again, run there: sudo kubeadm reset -f"
}
