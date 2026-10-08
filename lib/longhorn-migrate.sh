#!/usr/bin/env bash

set -Eeuo pipefail

#############################################
# MOVE A NODE TO A DEDICATED LONGHORN DISK
#############################################
#
# Converts a node that already stores Longhorn data on its OS disk
# (/var/lib/longhorn) to a dedicated disk, without downtime:
#
#   1. Checks every volume is healthy.
#   2. On the node (over SSH unless it is this machine): lists unused
#      disks, then formats and mounts the chosen one at
#      LONGHORN_DISK_MOUNT, using lib/longhorn-disk.sh.
#   3. Adds that disk to Longhorn with nothing reserved.
#   4. Evicts every replica from the node's old disk(s) and waits.
#   5. Removes the old disk(s) from Longhorn and labels the node
#      homelab.io/longhorn-disk=dedicated.
#
# Nothing in Longhorn changes until the new disk is mounted, and
# Longhorn itself refuses to remove a disk that still holds replicas.
# Safe to re-run: every step checks whether it is already done, so an
# interrupted run (Ctrl+C during eviction) resumes where it stopped.
#
# Needs: kubectl (admin), jq, ssh. Run from a control plane.
#############################################

LONGHORN_NS="longhorn-system"
LONGHORN_NEW_DISK_NAME="dedicated-disk"


lh_node_json() {
    kubectl -n "${LONGHORN_NS}" get nodes.longhorn.io "$1" -o json
}


# Disk names on a Longhorn node whose path is not the dedicated mount.
lh_old_disks() {
    lh_node_json "$1" | jq -r --arg p "${LONGHORN_DISK_MOUNT}" \
        '.spec.disks // {} | to_entries[] | select(.value.path != $p) | .key'
}


# Replicas on the node that are not on the dedicated disk. Counted from
# the replica objects themselves, so a disk whose status has not been
# reported yet can never look empty.
lh_old_replica_count() {
    kubectl -n "${LONGHORN_NS}" get replicas.longhorn.io -o json |
        jq --arg n "$1" --arg p "${LONGHORN_DISK_MOUNT}" \
            '[.items[] | select(.spec.nodeID == $n and (.spec.diskPath // "") != $p)] | length'
}


lh_disk_condition() {
    lh_node_json "$1" | jq -r --arg d "$2" --arg c "$3" \
        '[.status.diskStatus[$d].conditions // [] | .[] | select(.type == $c) | .status][0] // "Unknown"'
}


human_bytes() {
    numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || echo "${1:-0} bytes"
}


#############################################
# Step 1: choose node
#############################################

lh_choose_node() {

    local rows
    rows="$(
        kubectl -n "${LONGHORN_NS}" get nodes.longhorn.io -o json |
            jq -r --arg p "${LONGHORN_DISK_MOUNT}" '
                .items[]
                | .metadata.name as $n
                | (.spec.disks // {} | [.[].path]) as $paths
                | [$n, ($paths | join(",")), (if ($paths | index($p)) == null then "os-disk"
                     elif ($paths | length) == 1 then "dedicated"
                     else "in-progress" end)]
                | @tsv'
    )"

    [[ -n "${rows}" ]] || die "No Longhorn nodes found. Is Longhorn installed?"

    echo
    echo "Longhorn nodes:"
    echo

    local -a names=()
    local i=1 name paths state

    while IFS=$'\t' read -r name paths state; do
        names+=("${name}")
        printf '  %d) %-20s %-10s %s\n' "${i}" "${name}" "${state}" "${paths:-<no disks>}"
        i=$((i + 1))
    done <<< "${rows}"

    echo

    local choice
    while true; do
        read -rp "Node to move to a dedicated disk [1-${#names[@]}]: " choice
        if [[ "${choice}" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#names[@]} )); then
            break
        fi
        echo "[ERROR] Enter a number from the list."
    done

    LH_NODE="${names[$((choice - 1))]}"
}


#############################################
# Step 2: safety checks
#############################################

lh_preflight() {

    local node="$1"
    local bad

    log_info "Checking volume health..."

    bad="$(
        kubectl -n "${LONGHORN_NS}" get volumes.longhorn.io -o json |
            jq -r '.items[] | select(.status.robustness == "degraded" or .status.robustness == "faulted")
                   | "\(.metadata.name)  \(.status.robustness)"'
    )"

    if [[ -n "${bad}" ]]; then
        log_error "These volumes are not healthy. Fix them before moving data:"
        sed 's/^/    /' <<< "${bad}"
        return 1
    fi

    log_ok "All volumes healthy."

    local used others
    used="$(
        kubectl -n "${LONGHORN_NS}" get replicas.longhorn.io -o json |
            jq --arg n "${node}" '[.items[] | select(.spec.nodeID == $n) | .spec.volumeSize | tonumber] | add // 0'
    )"

    others="$(
        kubectl -n "${LONGHORN_NS}" get nodes.longhorn.io -o json |
            jq --arg n "${node}" '[.items[] | select(.metadata.name != $n)
                | (.spec.disks // {}) as $spec
                | .status.diskStatus // {} | to_entries[]
                | ((.value.storageAvailable // 0) - ($spec[.key].storageReserved // 0))
                | if . < 0 then 0 else . end] | add // 0'
    )"

    echo
    echo "  Replica data on ${node}:          $(human_bytes "${used}") (provisioned size)"
    echo "  Free space on the other nodes:    $(human_bytes "${others}")"
    echo
    echo "  Copies can also move straight onto the new disk on ${node},"
    echo "  so the other nodes do not need to hold all of it."
    echo
}


#############################################
# Step 3: prepare the disk on the node
#############################################

lh_node_ip() {
    kubectl get node "$1" \
        -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'
}


lh_is_local_node() {
    local node="$1"
    [[ "${node}" == "$(hostname | tr '[:upper:]' '[:lower:]')" ||
       "${node}" == "$(hostname -s | tr '[:upper:]' '[:lower:]')" ]]
}


# Runs select_longhorn_disk + prepare_longhorn_disk on the node.
# Returns 0 only if a dedicated disk is mounted afterwards.
lh_prepare_disk_on_node() {

    local node="$1"
    local script='
        source "$1/logging.sh"
        die() { log_error "$1"; exit 1; }
        source "$1/longhorn-disk.sh"
        select_longhorn_disk
        prepare_longhorn_disk
        [[ "${LONGHORN_DISK:-none}" == "existing" ]]
    '

    if lh_is_local_node "${node}"; then
        log_info "${node} is this machine; preparing the disk locally."
        bash -c "${script}" _ "${ROOT_DIR}/lib"
        return
    fi

    local ip user port dest remote_dir
    ip="$(lh_node_ip "${node}")"
    [[ -n "${ip}" ]] || die "Could not find the IP of ${node}."

    read -rp "SSH user for ${node} (${ip}) [${SUDO_USER:-root}]: " user
    user="${user:-${SUDO_USER:-root}}"
    port="${JOIN_SSH_PORT:-22}"
    dest="${user}@${ip}"

    local -a ssh_opts=(-p "${port}" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)

    log_info "Connecting to ${dest}..."

    remote_dir="$(ssh "${ssh_opts[@]}" "${dest}" 'mktemp -d')" ||
        die "Could not SSH to ${dest}."

    tar -C "${ROOT_DIR}/lib" -czf - logging.sh longhorn-disk.sh |
        ssh "${ssh_opts[@]}" "${dest}" "tar -C '${remote_dir}' -xzf -"

    ssh "${ssh_opts[@]}" "${dest}" "cat > '${remote_dir}/run.sh'" <<< "${script}"

    local rc=0
    # -t: the disk prompt and sudo need a terminal.
    ssh -t "${ssh_opts[@]}" "${dest}" \
        "sudo bash '${remote_dir}/run.sh' '${remote_dir}'" || rc=$?

    ssh "${ssh_opts[@]}" "${dest}" "rm -rf '${remote_dir}'" || true

    return "${rc}"
}


#############################################
# Step 4: add the new disk to Longhorn
#############################################

lh_add_new_disk() {

    local node="$1"

    if lh_node_json "${node}" | jq -e --arg d "${LONGHORN_NEW_DISK_NAME}" '.spec.disks[$d]' >/dev/null; then
        log_ok "Longhorn already has ${LONGHORN_NEW_DISK_NAME} on ${node}."
    else
        log_info "Adding ${LONGHORN_DISK_MOUNT} to Longhorn on ${node}..."

        kubectl -n "${LONGHORN_NS}" patch nodes.longhorn.io "${node}" --type merge -p "$(
            jq -cn --arg d "${LONGHORN_NEW_DISK_NAME}" --arg p "${LONGHORN_DISK_MOUNT}" '
                {spec: {disks: {($d): {
                    path: $p, allowScheduling: true, storageReserved: 0,
                    tags: ["dedicated"], diskType: "filesystem"}}}}'
        )" >/dev/null
    fi

    log_info "Waiting for Longhorn to accept the new disk..."

    local i ready schedulable
    for i in {1..60}; do
        ready="$(lh_disk_condition "${node}" "${LONGHORN_NEW_DISK_NAME}" Ready)"
        schedulable="$(lh_disk_condition "${node}" "${LONGHORN_NEW_DISK_NAME}" Schedulable)"
        if [[ "${ready}" == "True" && "${schedulable}" == "True" ]]; then
            log_ok "New disk is Ready and Schedulable."
            return 0
        fi
        sleep 5
    done

    log_error "Longhorn did not mark the new disk Ready/Schedulable (Ready=${ready}, Schedulable=${schedulable})."
    log_error "The old disk is untouched. Check the node in the Longhorn UI, then re-run this operation."
    return 1
}


#############################################
# Step 5: evict and remove the old disk(s)
#############################################

lh_evict_old_disks() {

    local node="$1"
    local -a disks=()
    local disk

    mapfile -t disks < <(lh_old_disks "${node}")

    if (( ${#disks[@]} == 0 )); then
        log_ok "No old disks left on ${node}."
        return 0
    fi

    for disk in "${disks[@]}"; do
        log_info "Evicting replicas from ${disk}..."
        kubectl -n "${LONGHORN_NS}" patch nodes.longhorn.io "${node}" --type merge -p "$(
            jq -cn --arg d "${disk}" '{spec: {disks: {($d): {allowScheduling: false, evictionRequested: true}}}}'
        )" >/dev/null
    done

    echo
    echo "Longhorn is now copying data off the old disk. This takes as long"
    echo "as the data needs; apps keep running. Ctrl+C is safe: eviction"
    echo "continues in the background and re-running this operation resumes."
    echo

    local remaining
    while true; do

        remaining="$(lh_old_replica_count "${node}")"

        if (( ${remaining:-1} == 0 )); then
            echo
            log_ok "All replicas moved off the old disk."
            break
        fi

        printf '\r  %s  replicas left on old disk: %-6s' "$(date +%H:%M:%S)" "${remaining}"
        sleep 15

    done

    for disk in "${disks[@]}"; do
        log_info "Removing ${disk} from Longhorn..."
        kubectl -n "${LONGHORN_NS}" patch nodes.longhorn.io "${node}" --type json \
            -p "$(jq -cn --arg d "${disk}" '[{op: "remove", path: ("/spec/disks/" + $d)}]')" >/dev/null
    done

    log_ok "Old disk(s) removed from Longhorn."
}


#############################################
# Entry point
#############################################

migrate_longhorn_disk() {

    header 2>/dev/null || true

    echo
    echo "============================================="
    echo " Move Node to Dedicated Longhorn Disk"
    echo "============================================="

    command -v jq >/dev/null 2>&1 || die "jq is required."

    kubectl get crd nodes.longhorn.io >/dev/null 2>&1 ||
        die "Longhorn is not installed (no nodes.longhorn.io CRD)."

    LH_NODE=""
    lh_choose_node

    local node="${LH_NODE}"
    local -a old=()
    mapfile -t old < <(lh_old_disks "${node}")

    if (( ${#old[@]} == 0 )) &&
        lh_node_json "${node}" | jq -e --arg d "${LONGHORN_NEW_DISK_NAME}" '.spec.disks[$d]' >/dev/null; then
        log_ok "${node} already uses only the dedicated disk."
        kubectl label node "${node}" "${LONGHORN_DISK_LABEL}" --overwrite >/dev/null
        return 0
    fi

    lh_preflight "${node}" || return 1

    echo "This will, on ${node}:"
    echo "  1. Format a spare disk you pick and mount it at ${LONGHORN_DISK_MOUNT}"
    echo "  2. Add it to Longhorn with all its space available"
    echo "  3. Move every replica off: ${old[*]:-<none>}"
    echo "  4. Remove the old disk(s) from Longhorn"
    echo

    local confirm
    read -rp "Type ${node} to continue (anything else cancels): " confirm
    [[ "${confirm}" == "${node}" ]] || { log_warn "Cancelled. Nothing was changed."; return 0; }

    echo
    echo "--- Step 1/4: prepare the disk on ${node} ---"

    if ! lh_prepare_disk_on_node "${node}"; then
        log_warn "No dedicated disk was prepared on ${node}. Nothing in Longhorn was changed."
        return 1
    fi

    echo
    echo "--- Step 2/4: add the disk to Longhorn ---"

    lh_add_new_disk "${node}" || return 1

    echo
    echo "--- Step 3/4 and 4/4: move replicas and remove the old disk ---"

    lh_evict_old_disks "${node}"

    kubectl label node "${node}" "${LONGHORN_DISK_LABEL}" --overwrite >/dev/null

    echo
    log_ok "${node} now stores Longhorn data on its dedicated disk."
    echo
    echo "The old data folder on the OS disk is no longer used. To reclaim"
    echo "its space, on ${node} run:"
    echo "  sudo du -sh /var/lib/longhorn      # check first"
    echo "  sudo rm -rf /var/lib/longhorn/replicas"
    echo
}
