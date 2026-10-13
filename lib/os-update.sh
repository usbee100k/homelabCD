#!/usr/bin/env bash

#############################################
# Update the operating system on nodes
#############################################
#
# apt update + apt upgrade on all nodes or the ones picked, one node at
# a time. Runs through Kubernetes (a short Job on each node), so no SSH
# login to every node is needed. The upgrade itself runs as a systemd
# unit on the node, so it finishes even if containerd restarts during it.
# kubelet, kubeadm and kubectl stay held: Kubernetes isn't upgraded here.
# Nothing is rebooted; nodes that need it are listed at the end.
#############################################

update_node_os() {

    local ns="kube-system"
    local names=() roles=() states=() images=()
    local name role state image

    if ! kubectl get nodes >/dev/null 2>&1; then
        log_error "Can't reach the cluster API with kubectl from this node."
        return 1
    fi

    local cps
    cps=" $(kubectl get nodes -l node-role.kubernetes.io/control-plane \
        -o jsonpath='{.items[*].metadata.name}') "

    while IFS=$'\t' read -r name state image; do
        [[ -n "${name}" ]] || continue
        role="worker"
        [[ "${cps}" == *" ${name} "* ]] && role="control-plane"
        [[ "${state}" == "True" ]] && state="Ready" || state="NotReady"
        names+=("${name}")
        roles+=("${role}")
        states+=("${state}")
        images+=("${image}")
    done < <(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\t"}{.status.nodeInfo.osImage}{"\n"}{end}')

    if (( ${#names[@]} == 0 )); then
        log_error "No nodes found."
        return 1
    fi

    echo
    echo "Nodes:"
    local i
    for i in "${!names[@]}"; do
        printf '  %2d) %-16s %-14s %-9s %s\n' "$((i + 1))" "${names[i]}" "${roles[i]}" \
            "${states[i]}" "${images[i]}"
    done
    echo
    echo "Runs: apt update, then apt upgrade -y, on one node at a time."
    echo "Kubernetes packages (kubelet, kubeadm, kubectl) stay on their version."
    echo "Nodes are not rebooted; the ones that need it are listed at the end."
    echo

    local answer picked=()
    read -r -p "Nodes to update: a = all, or numbers like \"1 3\" (blank = cancel): " answer || true

    answer="${answer//,/ }"

    if [[ -z "${answer// /}" ]]; then
        log_ok "Cancelled; nothing changed."
        return 0
    fi

    if [[ "${answer,,}" =~ ^[[:space:]]*(a|all)[[:space:]]*$ ]]; then
        picked=("${!names[@]}")
    else
        local n
        for n in ${answer}; do
            if [[ ! "${n}" =~ ^[0-9]+$ ]] || (( n < 1 || n > ${#names[@]} )); then
                log_error "\"${n}\" isn't a node number (1-${#names[@]})."
                return 1
            fi
            [[ " ${picked[*]} " == *" $((n - 1)) "* ]] || picked+=("$((n - 1))")
        done
    fi

    local ok=() failed=() reboot=() idx job out

    for idx in "${picked[@]}"; do

        name="${names[idx]}"
        job="os-update-${name}"
        job="${job:0:63}"

        echo
        echo "============================================================"
        echo " ${name}  (${roles[idx]})"
        echo "============================================================"

        if [[ "${states[idx]}" != "Ready" ]]; then
            log_warn "${name} is NotReady; skipping it."
            failed+=("${name} (NotReady, skipped)")
            continue
        fi

        kubectl -n "${ns}" delete job "${job}" --ignore-not-found --wait=true >/dev/null

        kubectl apply -f - >/dev/null <<YAML || { failed+=("${name} (could not start)"); continue; }
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job}
  namespace: ${ns}
  labels:
    app.kubernetes.io/managed-by: homelabcd
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    spec:
      nodeName: ${name}
      hostPID: true
      restartPolicy: Never
      tolerations:
        - operator: Exists
      containers:
        - name: apt
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
            - systemd-run
            - --unit=homelabcd-os-update
            - --wait
            - --pipe
            - --collect
            - --quiet
            - --setenv=DEBIAN_FRONTEND=noninteractive
            - --setenv=NEEDRESTART_MODE=l
            - /bin/sh
            - -c
            - |
              set -e
              # Raise the inotify limits (as new nodes get them); the
              # default runs out on busy nodes ("too many open files").
              printf 'fs.inotify.max_user_instances = 8192\nfs.inotify.max_user_watches = 524288\n' > /etc/sysctl.d/90-homelabcd-inotify.conf
              sysctl -q -p /etc/sysctl.d/90-homelabcd-inotify.conf || true
              echo ">>> apt update"
              apt-get -o DPkg::Lock::Timeout=300 update
              echo
              echo ">>> apt upgrade -y"
              apt-get -o DPkg::Lock::Timeout=300 \\
                -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \\
                -y --with-new-pkgs upgrade
              echo
              if [ -f /var/run/reboot-required ]; then echo "HOMELABCD: REBOOT REQUIRED"; fi
              echo "HOMELABCD: DONE"
YAML

        # Wait for the pod to start, then follow its output.
        local phase=""
        for i in {1..60}; do
            phase="$(kubectl -n "${ns}" get pods -l job-name="${job}" \
                -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
            [[ "${phase}" == Running || "${phase}" == Succeeded || "${phase}" == Failed ]] && break
            sleep 2
        done

        out="$(mktemp)"
        kubectl -n "${ns}" logs -f "job/${job}" 2>&1 | tee "${out}" || true

        # logs -f can end early if the connection drops; wait for the result
        # (up to 30 minutes).
        local result=""
        for i in {1..360}; do
            result="$(kubectl -n "${ns}" get job "${job}" \
                -o jsonpath='{.status.succeeded}/{.status.failed}' 2>/dev/null || true)"
            [[ "${result}" == 1/* || "${result}" == */[1-9]* ]] && break
            sleep 5
        done

        # If the live stream broke off, show the whole output now (reading
        # the finished log doesn't need a file watcher on the node).
        if ! grep -q "HOMELABCD: DONE" "${out}"; then
            echo
            log_warn "The live output from ${name} stopped early; full output:"
            kubectl -n "${ns}" logs "job/${job}" 2>&1 | tee "${out}" || true
        fi
        echo

        if [[ "${result}" == 1/* ]]; then
            log_ok "${name}: operating system updated."
            ok+=("${name}")
            grep -q "HOMELABCD: REBOOT REQUIRED" "${out}" && reboot+=("${name}")
        else
            log_error "${name}: the update failed (see the output above)."
            failed+=("${name}")
        fi

        rm -f "${out}"
        kubectl -n "${ns}" delete job "${job}" --ignore-not-found --wait=false >/dev/null

    done

    echo
    echo "============================================================"
    echo " Summary"
    echo "============================================================"
    (( ${#ok[@]} ))     && echo "  Updated      : ${ok[*]}"
    (( ${#failed[@]} )) && echo "  Failed       : ${failed[*]}"
    if (( ${#reboot[@]} )); then
        echo "  Needs reboot : ${reboot[*]}"
    else
        echo "  Needs reboot : none"
    fi
    echo

    local rc=0
    (( ${#failed[@]} == 0 )) || rc=1

    reboot_nodes_menu names reboot || rc=1

    return "${rc}"
}


#############################################
# Reboot nodes safely
#############################################
#
# reboot_nodes_menu NAMES_ARRAY NEED_REBOOT_ARRAY
# Asks which nodes to reboot now (blank = later, manually). Each one is
# drained, rebooted, waited for until Ready with a new boot ID, and
# uncordoned before the next starts, so the cluster stays up (with 3+
# control planes) and pods move off workers first. The node running
# this is rebooted last, without draining, because the session ends.
#############################################

reboot_nodes_menu() {

    local -n all_nodes="$1"
    local -n need_reboot="$2"
    local i n answer self="" picked=()

    self="$(current_node_name 2>/dev/null || true)"

    echo "Reboot nodes now?"
    for i in "${!all_nodes[@]}"; do
        n="${all_nodes[i]}"
        printf '  %2d) %-16s' "$((i + 1))" "${n}"
        [[ " ${need_reboot[*]} " == *" ${n} "* ]] && printf ' needs reboot'
        [[ "${n}" == "${self}" ]] && printf ' (this node: rebooted last, ends this session)'
        echo
    done
    echo
    (( ${#need_reboot[@]} )) && echo "  r = the ones that need it (${need_reboot[*]})"
    echo "  a = all, numbers like \"1 3\", blank = not now (reboot them yourself later)"
    read -r -p "Reboot: " answer || true

    answer="${answer//,/ }"
    answer="${answer,,}"

    if [[ -z "${answer// /}" ]]; then
        if (( ${#need_reboot[@]} )); then
            echo
            echo "Not rebooting. To do it yourself later, one node at a time:"
            echo "  kubectl drain <node> --ignore-daemonsets --delete-emptydir-data"
            echo "  sudo reboot                      (on that node)"
            echo "  kubectl uncordon <node>          (once it is Ready again)"
        fi
        return 0
    fi

    case "${answer// /}" in
        r) picked=("${need_reboot[@]}") ;;
        a|all) picked=("${all_nodes[@]}") ;;
        *)
            for n in ${answer}; do
                if [[ ! "${n}" =~ ^[0-9]+$ ]] || (( n < 1 || n > ${#all_nodes[@]} )); then
                    log_error "\"${n}\" isn't a node number (1-${#all_nodes[@]}). Nothing was rebooted."
                    return 1
                fi
                [[ " ${picked[*]} " == *" ${all_nodes[n - 1]} "* ]] || picked+=("${all_nodes[n - 1]}")
            done
            ;;
    esac

    if (( ${#picked[@]} == 0 )); then
        log_ok "No nodes need a reboot."
        return 0
    fi

    # This node last: rebooting it ends the session.
    local ordered=() rc=0
    for n in "${picked[@]}"; do [[ "${n}" == "${self}" ]] || ordered+=("${n}"); done
    [[ " ${picked[*]} " == *" ${self} "* && -n "${self}" ]] && ordered+=("${self}")

    for n in "${ordered[@]}"; do
        reboot_node_safely "${n}" "${self}" || { rc=1; log_error "Stopped: fix ${n} before rebooting more nodes."; break; }
    done

    return "${rc}"
}


# reboot_node_safely NODE SELF
reboot_node_safely() {

    local node="$1" self="$2" ns="kube-system"
    local job="os-reboot-${node}" boot i ready cur

    echo
    echo "============================================================"
    echo " Rebooting ${node}"
    echo "============================================================"

    boot="$(kubectl get node "${node}" -o jsonpath='{.status.nodeInfo.bootID}')"

    if [[ "${node}" != "${self}" ]]; then
        log_info "Moving pods off ${node} (drain)..."
        if ! kubectl drain "${node}" --ignore-daemonsets --delete-emptydir-data --timeout=5m; then
            log_error "Could not drain ${node}; not rebooting it."
            kubectl uncordon "${node}" >/dev/null 2>&1 || true
            return 1
        fi
    else
        log_warn "${node} is the node running this; it reboots now and this session ends."
        log_warn "When it is back, check: kubectl get nodes"
    fi

    job="${job:0:63}"
    kubectl -n "${ns}" delete job "${job}" --ignore-not-found --wait=true >/dev/null

    # The reboot is scheduled 5 seconds out so the Job can finish first.
    kubectl apply -f - >/dev/null <<YAML || { kubectl uncordon "${node}" >/dev/null 2>&1 || true; return 1; }
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job}
  namespace: ${ns}
  labels:
    app.kubernetes.io/managed-by: homelabcd
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    spec:
      nodeName: ${node}
      hostPID: true
      restartPolicy: Never
      tolerations:
        - operator: Exists
      containers:
        - name: reboot
          image: busybox:1.37
          securityContext:
            privileged: true
          command: ["nsenter", "-t", "1", "-m", "-u", "-i", "-n", "-p", "--",
                    "systemd-run", "--on-active=5", "--collect", "--quiet", "/bin/systemctl", "reboot"]
YAML

    log_info "Waiting for ${node} to restart and be Ready (up to 15 minutes)..."

    for i in {1..180}; do
        sleep 5
        cur="$(kubectl get node "${node}" -o jsonpath='{.status.nodeInfo.bootID}' 2>/dev/null || true)"
        ready="$(kubectl get node "${node}" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
        [[ -n "${cur}" && "${cur}" != "${boot}" && "${ready}" == "True" ]] && break
        (( i % 12 == 0 )) && log_info "Still waiting for ${node} ($(( i * 5 ))s)..."
    done

    if [[ "${cur}" == "${boot}" || "${ready}" != "True" ]]; then
        log_error "${node} did not come back Ready within 15 minutes."
        echo "  Check it, then run: kubectl uncordon ${node}"
        return 1
    fi

    # A control plane's etcd must be healthy again before the next one goes down.
    if kubectl -n "${ns}" get pod "etcd-${node}" >/dev/null 2>&1; then
        kubectl -n "${ns}" wait --for=condition=Ready "pod/etcd-${node}" --timeout=5m >/dev/null 2>&1 ||
            log_warn "etcd on ${node} is not Ready yet."
    fi

    kubectl uncordon "${node}" >/dev/null
    kubectl -n "${ns}" delete job "${job}" --ignore-not-found --wait=false >/dev/null 2>&1 || true

    log_ok "${node} rebooted and is Ready."
}
