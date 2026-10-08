#!/usr/bin/env bash

set -Eeuo pipefail

#############################################
# ROLE BOOTSTRAP
#############################################

if [[ -z "${ROOT_DIR:-}" ]]; then
    ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
    export ROOT_DIR
fi

# Must match a case in download_bootstrap_secrets; set unconditionally
# so a value inherited from the caller cannot select the wrong secret.
export NODE_ROLE="controlplane"

#############################################
# Load Configuration
#############################################

if [[ -f "${ROOT_DIR}/config/defaults.env" ]]; then
    source "${ROOT_DIR}/config/defaults.env"
fi

if [[ -f "${ROOT_DIR}/config/versions.env" ]]; then
    source "${ROOT_DIR}/config/versions.env"
fi

if [[ -f "${ROOT_DIR}/config/bootstrap.env" ]]; then
    source "${ROOT_DIR}/config/bootstrap.env"
fi

export KUBERNETES_VERSION="${KUBERNETES_VERSION:-unknown}"

#############################################
# Load Required Libraries
#############################################

LIBRARIES=(
    logging
    common
    progress
    config
    github
    validation
    system
    networking
    containerd
    kubeadm
    kubeadm-config
    bootstrap-dependencies
    bootstrap-secrets
    bootstrap-upload
    bootstrap-download
    secrets
    inventory
    node-labels
    longhorn-disk
    metallb
    health
)

for lib in "${LIBRARIES[@]}"; do
    if [[ -f "${ROOT_DIR}/lib/${lib}.sh" ]]; then
        source "${ROOT_DIR}/lib/${lib}.sh"
    else
        echo "[ERROR] Missing library: ${lib}.sh"
        exit 1
    fi
done

#############################################
# Load Configuration Values
#############################################

if declare -F load_config >/dev/null; then
    load_config
fi

#############################################
# ADDITIONAL CONTROL PLANE JOIN
#############################################

join_controlplane() {

    local JOIN_SCRIPT="${ROOT_DIR}/generated/secrets/controlplane_join.sh"

    log_info "Joining Kubernetes Control Plane"

    #########################################
    # Prevent Duplicate Join
    #########################################

    if [[ -f /etc/kubernetes/admin.conf ]]; then
        log_error "This node is already a member of a Kubernetes cluster."
        echo
        echo "To rejoin it, first remove it from the cluster on another control plane:"
        echo "  kubectl drain $(hostname -s) --ignore-daemonsets --delete-emptydir-data"
        echo "  kubectl delete node $(hostname -s)"
        echo "then on this node run: kubeadm reset -f"
        echo
        exit 1
    fi

    ask_step_mode

    #########################################
    # Dedicated Longhorn Disk (optional)
    #########################################

    select_longhorn_disk

    #########################################
    # Validate Host
    #########################################

    next_step "Validating Host"

    validate_system

    finish_step

    #########################################
    # Prepare Operating System
    #########################################

    next_step "Preparing Operating System"

    update_system
    disable_swap
    configure_kernel_modules
    configure_sysctl
    mount_bpf

    finish_step

    #########################################
    # Install Container Runtime
    #########################################

    next_step "Installing Container Runtime"

    install_containerd

    systemctl enable containerd
    systemctl restart containerd

    for i in {1..30}; do

        if [[ -S /run/containerd/containerd.sock ]]; then
            log_ok "Containerd socket ready."
            break
        fi

        sleep 2

    done

    if [[ ! -S /run/containerd/containerd.sock ]]; then

        log_error "Containerd socket missing."

        systemctl status containerd --no-pager

        exit 1

    fi

    finish_step

    #########################################
    # Install Kubernetes Packages
    #########################################

    next_step "Installing Kubernetes Packages"

    install_kubernetes

    prepare_longhorn_disk

    finish_step

    #########################################
    # Retrieve Join Credentials
    #########################################
    #
    # Prefer a join command already on disk: KubesTUI and
    # remote_join_node generate a fresh one on the bootstrap
    # node and copy it here. The copy in the bootstrap package
    # carries a certificate key that expires after 2 hours,
    # so it is only used as a last resort.
    #########################################

    next_step "Retrieving Cluster Join Credentials"

    if [[ "${HOMELAB_JOIN_PROVIDED:-false}" == "true" && -f "${JOIN_SCRIPT}" ]]; then

        log_ok "Using fresh join command provided by KubesTUI."

    elif [[ "${HOMELAB_REMOTE_MODE:-false}" == "true" ]]; then

        log_info "Remote mode detected."

        if [[ -z "${BOOTSTRAP_PACKAGE_DIR:-}" || ! -d "${BOOTSTRAP_PACKAGE_DIR}" ]]; then
            log_error "Bootstrap package not found: ${BOOTSTRAP_PACKAGE_DIR:-<unset>}"
            exit 1
        fi

        log_info "Using bootstrap package transferred by KubesTUI."

        export BOOTSTRAP_PACKAGE_DIR

        download_bootstrap_secrets

    elif [[ -f "${JOIN_SCRIPT}" ]]; then

        log_ok "Using join credentials copied from the bootstrap node."

    else

        if [[ -z "${BOOTSTRAP_REPO:-}" ]]; then

            echo
            echo "================================================="
            echo " Bootstrap Repository Required"
            echo "================================================="
            echo
            echo "Example:"
            echo "git@github.com:user/bootstrap-repo.git"
            echo

            read -rp "Enter Bootstrap Git Repository URL: " BOOTSTRAP_REPO

            if [[ -z "${BOOTSTRAP_REPO}" ]]; then
                log_error "Bootstrap repository cannot be empty."
                exit 1
            fi

            export BOOTSTRAP_REPO

            if [[ -f "${ROOT_DIR}/config/defaults.env" ]]; then

                sed -i \
                    '/^BOOTSTRAP_REPO=/d' \
                    "${ROOT_DIR}/config/defaults.env"

                echo "BOOTSTRAP_REPO=\"${BOOTSTRAP_REPO}\"" \
                    >> "${ROOT_DIR}/config/defaults.env"

                log_ok "Bootstrap repository saved."

            fi

        fi

        log_info "Verifying GitHub SSH Access"

        ensure_github_ssh_access

        download_bootstrap_secrets

        log_warn "Using the join command from the bootstrap package."
        log_warn "If the join fails with a certificate-key error, it is older than 2 hours;"
        log_warn "regenerate it on the bootstrap node: sudo ./install.sh --run join-commands"

    fi

    if [[ ! -f "${JOIN_SCRIPT}" ]]; then
        log_error "Missing control plane join command."
        exit 1
    fi

    if ! grep -q "kubeadm join" "${JOIN_SCRIPT}" ||
        ! grep -q -- "--control-plane" "${JOIN_SCRIPT}"; then
        log_error "Invalid control plane join script."
        exit 1
    fi

    chmod +x "${JOIN_SCRIPT}"

    finish_step

    #########################################
    # Join Control Plane
    #########################################

    next_step "Joining Kubernetes Control Plane"

    if ! bash "${JOIN_SCRIPT}"; then

        log_error "kubeadm join failed."

        echo
        echo "Debug commands:"
        echo "  systemctl status kubelet"
        echo "  journalctl -u kubelet -xe"
        echo

        exit 1

    fi

    # The join script contains a bootstrap token and the certificate
    # key for the cluster CA; do not leave it on disk.
    rm -f "${JOIN_SCRIPT}"

    finish_step

    #########################################
    # Wait For kubelet
    #########################################

    next_step "Waiting For kubelet"

    until systemctl is-active --quiet kubelet; do
        sleep 2
    done

    finish_step

    #########################################
    # Configure kubectl
    #########################################

    next_step "Configuring kubectl"

    configure_kubectl

    finish_step

    #########################################
    # Wait For Node Registration
    #########################################

    next_step "Waiting For Node Registration"

    local NODE_NAME=""

    for i in {1..60}; do
        NODE_NAME="$(current_node_name)" && break
        sleep 5
    done

    if [[ -z "${NODE_NAME}" ]]; then
        log_error "Node $(hostname) did not register with the cluster."
        exit 1
    fi

    kubectl wait \
        --for=condition=Ready \
        node/"${NODE_NAME}" \
        --timeout=5m

    finish_step

    #########################################
    # Register Node
    #########################################

    next_step "Registering Node"

    register_node

    finish_step

    #########################################
    # Apply Labels
    #########################################

    next_step "Applying Node Labels"

    apply_node_labels

    install_metallb_node_selector

    install_worker_role_labeler

    finish_step

    #########################################
    # Cluster Validation
    #########################################

    next_step "Validating Cluster"

    kubectl get --raw='/readyz?verbose'

    kubectl get nodes -o wide

    kubectl get pods \
        -n kube-system \
        -o wide

    finish_step

    #########################################
    # Success
    #########################################

    log_ok "Control Plane Joined Successfully."

    echo
    echo "Control Plane Join Complete"
    echo
    echo "Node has been:"
    echo " ├── Joined to the Kubernetes control plane"
    echo " ├── Waited until Ready"
    echo " ├── Registered in cluster inventory"
    echo " ├── Kubernetes labels applied"
    echo " ├── MetalLB node selector and worker role labeler enabled"
    echo " └── Cluster health validated"
    echo
}

join_controlplane
