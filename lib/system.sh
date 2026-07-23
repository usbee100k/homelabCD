#!/usr/bin/env bash

#############################################
# System Information
#############################################

system_information() {

    local hostname
    HOSTNAME=$(hostname)
    IP=$(hostname -I | awk '{print $1}')
    CPU=$(nproc)
    RAM=$(free -h | awk '/Mem:/ {print $2}')
    DISK=$(lsblk -d -o SIZE | tail -1)

    echo
    echo "Hostname : $HOSTNAME"
    echo "IP       : $IP"
    echo "CPU      : $CPU Cores"
    echo "Memory   : $RAM"
    echo "Disk     : $DISK"
    echo

}

show_summary() {

    echo
    echo "========================================="
    echo "            Host Summary"
    echo "========================================="
    echo "Hostname : $(hostname)"
    echo "IP       : $(hostname -I |awk '{print $1}')"
    echo "CPU      : $(nproc) Cores"
    echo "Memory   : $(free -h |awk '/Mem:/ {print $2}')"
    echo "Disk     : $(lsblk -d -o SIZE |tail -1)"
    echo "========================================="
    echo

}



validate_system() {

    log_info "Validating system..."

    [[ $EUID -eq 0 ]] || {
        log_error "Installer must be run as root."
        return 1
    }

    command -v apt-get >/dev/null || {
        log_error "apt-get not found."
        return 1
    }

    local cmds=(
        curl
        git
        jq
        awk
        sed
        grep
        systemctl
        ip
    )

    for cmd in "${cmds[@]}"; do
        command -v "$cmd" >/dev/null || {
            log_error "Missing dependency: $cmd"
            return 1
        }
    done

    if swapon --show | grep -q .; then
        log_warn "Swap is enabled."
    fi

    log_ok "System validation passed."

}

#############################################
# System Preparation
#############################################

update_system() {

    log_info "Updating package repositories..."

    apt-get update -y
    apt-get upgrade -y

    log_ok "System updated."

}

install_prerequisites() {

    log_info "Installing prerequisite packages..."

    apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        wget \
        sops \
        age \
        gpg \
        yq \
        jq \
        git \
        vim \
        bash-completion \
        software-properties-common \
        lsb-release \
        nfs-common \
        open-iscsi \
        socat \
        conntrack \
        ebtables \
        ethtool

    systemctl enable --now iscsid

    log_ok "Prerequisites installed."

}

disable_swap() {

    log_info "Disabling swap..."

    swapoff -a

    sed -i '/ swap / s/^/#/' /etc/fstab

    log_ok "Swap disabled."

}

configure_kernel_modules() {

    log_info "Configuring kernel modules..."

cat >/etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

    modprobe overlay
    modprobe br_netfilter

    log_ok "Kernel modules configured."

}

configure_sysctl() {

    log_info "Applying sysctl settings..."

cat >/etc/sysctl.d/kubernetes.conf <<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
vm.swappiness = 0
EOF

    sysctl --system

    log_ok "Sysctl applied."

}

mount_bpf() {

    log_info "Mounting BPF filesystem..."

    mkdir -p /sys/fs/bpf

    mount bpffs /sys/fs/bpf -t bpf 2>/dev/null || true

    if ! grep -q "/sys/fs/bpf" /etc/fstab; then
        echo "bpffs /sys/fs/bpf bpf defaults 0 0" >> /etc/fstab
    fi

    log_ok "BPF filesystem mounted."

}

#############################################
# Utilities
#############################################

reboot_required() {

    if [ -f /var/run/reboot-required ]; then
        log_warn "System reboot is recommended."
    fi

}

############################################
# Kubernetes
############################################

initialize_cluster() {

log_info "Initializing Kubernetes Cluster..."

kubeadm init \
    --config=/tmp/kubeadm-config.yaml \
    --upload-certs

log_ok "Cluster initialized."

}

untaint_controlplane() {

    log_info "Allowing workloads on the control-plane node..."

    kubectl taint nodes "$(hostname)" \
        node-role.kubernetes.io/control-plane- \
        >/dev/null 2>&1 || true

    log_ok "Control-plane taint removed."

}

configure_kubectl() {

    log_info "Configuring kubectl..."

    local TARGET_USER
    local TARGET_HOME

    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        TARGET_USER="${SUDO_USER}"
        TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
    else
        TARGET_USER="$(id -un)"
        TARGET_HOME="$HOME"
    fi

    if [[ ! -f /etc/kubernetes/admin.conf ]]; then
        log_error "Missing /etc/kubernetes/admin.conf"
        return 1
    fi

    mkdir -p "${TARGET_HOME}/.kube"

    # Always refresh the kubeconfig from the current cluster
    cp -f /etc/kubernetes/admin.conf "${TARGET_HOME}/.kube/config"

    chown -R "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.kube"

    chmod 700 "${TARGET_HOME}/.kube"
    chmod 600 "${TARGET_HOME}/.kube/config"

    export KUBECONFIG="${TARGET_HOME}/.kube/config"

    log_ok "kubectl configured for ${TARGET_USER}."
}