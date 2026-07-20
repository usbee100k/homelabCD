#!/usr/bin/env bash

install_kubevip() {

    log_info "Installing kube-vip..."

    mkdir -p /etc/kubernetes/manifests

    KUBEVIP_VERSION=$(curl -s https://api.github.com/repos/kube-vip/kube-vip/releases/latest | jq -r .tag_name)

    ctr image pull ghcr.io/kube-vip/kube-vip:${KUBEVIP_VERSION}

    ctr run \
        --rm \
        --net-host \
        ghcr.io/kube-vip/kube-vip:${KUBEVIP_VERSION} \
        vip /kube-vip manifest pod \
        --interface "${DEFAULT_INTERFACE}" \
        --address "${VIP_ADDRESS}" \
        --controlplane \
        --arp \
        --leaderElection \
        >/etc/kubernetes/manifests/kube-vip.yaml

    log_ok "kube-vip configured."

}
