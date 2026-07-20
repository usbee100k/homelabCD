#!/usr/bin/env bash

#############################################
# System Information
#############################################

system_information() {

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
        gpg \
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

configure_kubectl() {

mkdir -p "$HOME/.kube"

cp /etc/kubernetes/admin.conf "$HOME/.kube/config"

chown $(id -u):$(id -g) "$HOME/.kube/config"

log_ok "kubectl configured."

}

generate_join_commands() {

mkdir -p generated

kubeadm token create --print-join-command \
    >generated/worker-join.sh

CERT_KEY=$(kubeadm init phase upload-certs --upload-certs | tail -1)

cat >generated/controlplane-join.sh <<EOF
$(cat generated/worker-join.sh) \
--control-plane \
--certificate-key ${CERT_KEY}
EOF

chmod +x generated/*.sh

log_ok "Join commands saved."

}

