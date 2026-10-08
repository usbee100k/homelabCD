#!/usr/bin/env bash

set -Eeuo pipefail

#############################################
# DEDICATED LONGHORN DISK
#############################################
#
# Optionally gives Longhorn a whole disk of its own on this node:
#
#   1. select_longhorn_disk   (early, while the user is at the prompt)
#      Lists disks with nothing mounted and asks which one to use.
#      The disk is only wiped after the user types its exact name.
#
#   2. prepare_longhorn_disk  (after packages, before kubeadm init/join)
#      Formats it, mounts it at LONGHORN_DISK_MOUNT and has kubelet
#      register the node with homelab.io/longhorn-disk=dedicated.
#
# The longhorn-node-labeler CronJob sees that label and tells Longhorn
# to put this node's storage on LONGHORN_DISK_MOUNT, with no space
# reserved. Nodes without a dedicated disk keep using /var/lib/longhorn
# on the OS disk, where Longhorn reserves 30% to protect the OS.
#
# The OS disk is never offered: any disk with a mounted filesystem,
# swap, LVM, RAID or encryption on it is excluded.
#############################################

LONGHORN_DISK_MOUNT="/mnt/longhorn-disk"
LONGHORN_DISK_LABEL="homelab.io/longhorn-disk=dedicated"
LONGHORN_DISK_MIN_GB=10


# Prints one line per disk that is safe to offer: "<path>|<description>"
longhorn_disk_candidates() {

    local name type size rota tran model fstypes kind

    # One query per attribute: lsblk leaves empty columns blank
    # (e.g. TRAN on virtual disks), which would shift a combined read.
    while read -r name; do

        type="$(lsblk -dno TYPE "${name}" 2>/dev/null | xargs)"

        [[ "${type}" == "disk" ]] || continue

        size="$(lsblk -dbno SIZE "${name}" 2>/dev/null | xargs)"
        rota="$(lsblk -dno ROTA "${name}" 2>/dev/null | xargs)"
        tran="$(lsblk -dno TRAN "${name}" 2>/dev/null | xargs)"
        model="$(lsblk -dno MODEL "${name}" 2>/dev/null | xargs)"

        case "${name}" in
            /dev/zram*|/dev/loop*|/dev/sr*|/dev/ram*) continue ;;
        esac

        # Anything mounted (including swap) anywhere on this disk.
        if lsblk -nro MOUNTPOINT "${name}" 2>/dev/null | grep -q .; then
            continue
        fi

        # Part of LVM, software RAID or an encrypted volume.
        if lsblk -nro TYPE "${name}" 2>/dev/null | grep -qE 'lvm|raid|crypt'; then
            continue
        fi

        if (( ${size:-0} < LONGHORN_DISK_MIN_GB * 1024 * 1024 * 1024 )); then
            continue
        fi

        [[ "${rota}" == "1" ]] && kind="HDD" || kind="SSD"
        [[ "${name}" == /dev/nvme* ]] && kind="NVMe"

        fstypes="$(lsblk -nro FSTYPE "${name}" 2>/dev/null | grep . | sort -u | paste -sd, || true)"

        printf '%s|%-14s %6s GB  %-4s  %-5s  %s%s\n' \
            "${name}" \
            "${name}" \
            "$(( size / 1024 / 1024 / 1024 ))" \
            "${kind}" \
            "${tran:--}" \
            "${model:-unknown model}" \
            "${fstypes:+  [has data: ${fstypes}]}"

    done < <(lsblk -dnpo NAME 2>/dev/null)
}


select_longhorn_disk() {

    if [[ "${LONGHORN_DISK:-}" == "none" ]]; then
        return 0
    fi

    if mountpoint -q "${LONGHORN_DISK_MOUNT}" 2>/dev/null; then
        LONGHORN_DISK="existing"
        export LONGHORN_DISK
        log_ok "Dedicated Longhorn disk already mounted at ${LONGHORN_DISK_MOUNT}"
        return 0
    fi

    if [[ ! -t 0 ]]; then
        log_info "Non-interactive run; Longhorn will use the OS disk on this node."
        LONGHORN_DISK="none"
        export LONGHORN_DISK
        return 0
    fi

    local candidates
    candidates="$(longhorn_disk_candidates)"

    echo
    echo "============================================="
    echo " Dedicated Longhorn Disk"
    echo "============================================="
    echo
    echo "Longhorn can store this node's volumes on a disk of its own,"
    echo "using all of its space and leaving the OS disk alone."
    echo "Without one, Longhorn uses a folder on the OS disk and keeps"
    echo "30% of it free for the OS."
    echo

    if [[ -z "${candidates}" ]]; then
        echo "No unused disks found (the OS disk and anything mounted are"
        echo "never offered). Longhorn will use the OS disk on this node."
        LONGHORN_DISK="none"
        export LONGHORN_DISK
        return 0
    fi

    local -a paths=()
    local i=1 path desc

    echo "  0) No, use the OS disk"

    while IFS='|' read -r path desc; do
        paths+=("${path}")
        echo "  ${i}) ${desc}"
        i=$((i + 1))
    done <<< "${candidates}"

    echo

    local choice

    while true; do

        read -rp "Use a dedicated disk for Longhorn? [0-${#paths[@]}] (default 0): " choice

        choice="${choice:-0}"

        if [[ "${choice}" =~ ^[0-9]+$ ]] && (( choice >= 0 && choice <= ${#paths[@]} )); then
            break
        fi

        echo "[ERROR] Enter a number from the list."

    done

    if (( choice == 0 )); then
        LONGHORN_DISK="none"
        export LONGHORN_DISK
        log_info "Longhorn will use the OS disk on this node."
        return 0
    fi

    path="${paths[$((choice - 1))]}"

    echo
    echo "!!! ${path} will be COMPLETELY ERASED !!!"
    echo
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MODEL "${path}" 2>/dev/null || true
    echo

    local confirm
    read -rp "Type ${path} to confirm erasing it (anything else cancels): " confirm

    if [[ "${confirm}" != "${path}" ]]; then
        LONGHORN_DISK="none"
        export LONGHORN_DISK
        log_warn "Cancelled. Longhorn will use the OS disk on this node."
        return 0
    fi

    LONGHORN_DISK="${path}"
    export LONGHORN_DISK

    log_ok "${path} will be formatted for Longhorn after packages are installed."
}


# Adds a label to kubelet's --node-labels in /etc/default/kubelet.
# kubelet applies these when the node registers with the cluster.
add_kubelet_node_label() {

    local label="$1"
    local file="${KUBELET_DEFAULTS_FILE:-/etc/default/kubelet}"
    local args=""

    touch "${file}"

    if grep -q "${label}" "${file}"; then
        return 0
    fi

    if grep -q '^KUBELET_EXTRA_ARGS=' "${file}"; then
        args="$(sed -n 's/^KUBELET_EXTRA_ARGS=//p' "${file}" | tail -n1 | tr -d '"')"
    fi

    if [[ "${args}" == *--node-labels=* ]]; then
        args="$(sed -E "s|--node-labels=([^ ]*)|--node-labels=\1,${label}|" <<< "${args}")"
    else
        args="${args:+${args} }--node-labels=${label}"
    fi

    sed -i '/^KUBELET_EXTRA_ARGS=/d' "${file}"
    echo "KUBELET_EXTRA_ARGS=\"${args}\"" >> "${file}"

    log_ok "kubelet will register this node with ${label}"
}


prepare_longhorn_disk() {

    case "${LONGHORN_DISK:-none}" in
        none)
            return 0
            ;;
        existing)
            add_kubelet_node_label "${LONGHORN_DISK_LABEL}"
            return 0
            ;;
    esac

    local disk="${LONGHORN_DISK}"
    local part uuid

    log_info "Preparing dedicated Longhorn disk ${disk}..."

    # Re-check right before wiping: nothing may have been mounted since the prompt.
    if lsblk -nro MOUNTPOINT "${disk}" 2>/dev/null | grep -q .; then
        die "${disk} has a mounted filesystem; refusing to erase it."
    fi

    wipefs -a "${disk}" >/dev/null

    printf 'label: gpt\n,,L\n' |
        sfdisk --quiet --wipe always --wipe-partitions always "${disk}"

    udevadm settle

    part="$(lsblk -lnpo NAME,TYPE "${disk}" | awk '$2 == "part" {print $1; exit}')"

    [[ -n "${part}" ]] || die "Partition on ${disk} did not appear."

    # -m 0: no blocks reserved for root, so Longhorn can use all of it.
    mkfs.ext4 -q -F -m 0 -L longhorn "${part}"

    uuid="$(blkid -s UUID -o value "${part}")"

    [[ -n "${uuid}" ]] || die "Could not read the UUID of ${part}."

    # Make the empty mount point immutable: if the disk is ever missing
    # at boot, nothing can write into the OS disk underneath it.
    mkdir -p "${LONGHORN_DISK_MOUNT}"
    chattr +i "${LONGHORN_DISK_MOUNT}" 2>/dev/null || true

    sed -i "\|[[:space:]]${LONGHORN_DISK_MOUNT}[[:space:]]|d" /etc/fstab

    echo "UUID=${uuid} ${LONGHORN_DISK_MOUNT} ext4 defaults,nofail,x-systemd.device-timeout=30s 0 2" \
        >> /etc/fstab

    systemctl daemon-reload

    mount "${LONGHORN_DISK_MOUNT}"

    mountpoint -q "${LONGHORN_DISK_MOUNT}" ||
        die "Failed to mount ${part} at ${LONGHORN_DISK_MOUNT}."

    add_kubelet_node_label "${LONGHORN_DISK_LABEL}"

    LONGHORN_DISK="existing"
    export LONGHORN_DISK

    log_ok "Longhorn disk ready: ${part} -> ${LONGHORN_DISK_MOUNT} ($(df -h --output=size "${LONGHORN_DISK_MOUNT}" | tail -n1 | tr -d ' '))"
}
