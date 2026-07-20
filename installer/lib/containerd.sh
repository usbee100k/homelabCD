#!/usr/bin/env bash

install_containerd() {

    log_info "Installing containerd..."

    apt-get install -y containerd

    mkdir -p /etc/containerd

    containerd config default >/etc/containerd/config.toml

    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' \
        /etc/containerd/config.toml

    systemctl restart containerd

    systemctl enable containerd

    log_ok "Containerd installed."

}
