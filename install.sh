#!/usr/bin/env bash

set -Eeuo pipefail


#############################################
# Error Handling
#############################################

trap 'echo >&2 "[ERROR] ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}"; exit 1' ERR


#############################################
# Root Directory
#############################################

readonly ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export ROOT_DIR

readonly INSTALLER_MODE="${1:-}"
readonly INSTALLER_OP="${2:-}"


#############################################
# kbtui: straight into KubesTUI
#############################################
#
# The kbtui command passes --tui. The startup checks below still run,
# but their output is only shown if one of them fails. (The first run,
# before KubesTUI is built, shows everything.)
#############################################

STARTUP_LOG=""

if [[ "${INSTALLER_MODE}" == "--tui" && -x "${ROOT_DIR}/bin/kubestui" ]]; then
    STARTUP_LOG="$(mktemp)"
    exec 3>&1 4>&2 >"${STARTUP_LOG}" 2>&1
    trap 'exec 1>&3 2>&4; cat "${STARTUP_LOG}"; rm -f "${STARTUP_LOG}"' EXIT
fi



#############################################
# Helpers
#############################################

die() {
    echo >&2 "[ERROR] $*"
    exit 1
}


require_file() {
    [[ -f "$1" ]] || die "Missing required file: $1"
}


source_required() {
    require_file "$1"
    source "$1"
}


source_optional() {
    [[ -f "$1" ]] && source "$1"
}


require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}


require_function() {
    declare -F "$1" >/dev/null || die "Required function '$1' not found."
}



#############################################
# Bootstrap Encryption Tools BEFORE VALIDATION
#############################################

install_encryption_tools() {


    #################################
    # AGE
    #################################

    if command -v age >/dev/null 2>&1; then

        echo "[ OK ] age already installed: $(age --version | head -1)"

    else

        echo "[INFO] Installing age..."

        apt update
        apt install -y age


        if ! command -v age >/dev/null 2>&1; then

            die "age installation failed"

        fi


        echo "[ OK ] age installed"

    fi


    #################################
    # SOPS
    #################################

    if command -v sops >/dev/null 2>&1; then

        echo "[ OK ] sops already installed: $(sops --version | head -1)"

        return 0

    fi



    echo "[INFO] Installing sops..."



    apt update
    apt install -y curl



    SOPS_VERSION="v3.10.2"



    echo "[INFO] Installing sops ${SOPS_VERSION}..."



    curl \
        --fail \
        --location \
        --retry 5 \
        --connect-timeout 20 \
        --max-time 600 \
        -o /usr/local/bin/sops \
        "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.amd64"



    chmod +x /usr/local/bin/sops



    if ! command -v sops >/dev/null 2>&1; then

        die "SOPS installation failed"

    fi



    echo "[ OK ] sops installed: $(sops --version | head -1)"

}

#############################################
# Root Check
#############################################

(( EUID == 0 )) || die "Please run this installer as root."


#############################################
# Install Bootstrap Tools
#############################################

install_encryption_tools



#############################################
# Load Libraries
#############################################

LIBRARIES=(
    logging
    common
    progress
    secrets
    inventory
    node-labels
    longhorn-disk
    longhorn-migrate
    domains
    vpn
    compose
    config
    github
    validation
    system
    networking
    containerd
    kubevip
    kubeadm
    kubeadm-config
    helm
    cilium
    argocd
    gitops
    health
    report
    repair
    join
    bootstrap-dependencies
    bootstrap-secrets
    bootstrap-upload
    bootstrap-download
    kubestui
    remote-join
)


for lib in "${LIBRARIES[@]}"; do
    source_required "${ROOT_DIR}/lib/${lib}.sh"
done



#############################################
# Validate Functions
#############################################

for fn in \
    validate_system \
    detect_network \
    load_config \
    main_menu
do
    require_function "$fn"
done



#############################################
# Validate Host
#############################################

validate_system



detect_network

#############################################
# Step 3 — Install Prerequisites
#############################################

# Minimal bootstrap commands the installer itself needs to run.
for cmd in \
    bash \
    curl \
    git \
    jq \
    sed \
    awk \
    grep \
    ip \
    systemctl
do
    require_command "$cmd"
done

# yq is required for configuration loading in Step 4.
if ! command -v yq >/dev/null 2>&1; then
    echo "Installing yq..."
    curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64" \
        -o /usr/local/bin/yq
    chmod +x /usr/local/bin/yq
fi
require_command yq





#############################################
# Step 4 — Load Configuration
#############################################

mkdir -p "${ROOT_DIR}/config"

if [[ ! -f "${ROOT_DIR}/config/defaults.env" ]]; then

    if [[ -f "${ROOT_DIR}/config/defaults.example.env" ]]; then

        cp \
            "${ROOT_DIR}/config/defaults.example.env" \
            "${ROOT_DIR}/config/defaults.env"

        echo "Created config/defaults.env"

    else

cat > "${ROOT_DIR}/config/defaults.env" <<'EOF'
#!/usr/bin/env bash

CLUSTER_NAME="homelab"
GITHUB_REPO=""
BOOTSTRAP_REPO=""
GIT_BRANCH="main"
KUBERNETES_VERSION="v1.36.2"
EOF

        chmod 644 "${ROOT_DIR}/config/defaults.env"

        echo "Created default configuration."

    fi

fi

source_required "${ROOT_DIR}/config/defaults.env"
source_optional "${ROOT_DIR}/config/versions.env"
source_optional "${ROOT_DIR}/config/bootstrap.env"
source_optional "${ROOT_DIR}/config/encryption.env"

load_config

# install.sh runs as root; root has no ~/.kube/config because
# configure_kubectl writes it for the sudo user. Use the admin
# kubeconfig on control planes so kubectl works for every operation.
if [[ -z "${KUBECONFIG:-}" && -f /etc/kubernetes/admin.conf ]]; then
    export KUBECONFIG=/etc/kubernetes/admin.conf
fi

#############################################
# Step 5 — Continue with Kubernetes Setup
#############################################



#############################################
# Launch Installer
#############################################

export CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-containerd}"
export CNI="${CNI:-cilium}"

if [[ "${INSTALLER_MODE}" == "--run" ]]; then
    case "${INSTALLER_OP}" in
        bootstrap)
            source "${ROOT_DIR}/roles/bootstrap.sh"
            ;;
        controlplane)
            source "${ROOT_DIR}/roles/controlplane.sh"
            ;;
        worker)
            source "${ROOT_DIR}/roles/worker.sh"
            ;;
        remote-worker)
            remote_join_node worker
            ;;
        remote-controlplane)
            remote_join_node controlplane
            ;;
        repair)
            repair_node
            ;;
        join-commands)
            generate_join_commands
            ;;
        longhorn-disk)
            migrate_longhorn_disk
            ;;
        kubestui-dist)
            build_kubestui_dist
            ;;
        vpn-setup)
            setup_vpn
            ;;
        vpn-status)
            vpn_status || exit 1
            ;;
        compose-import)
            compose_import
            ;;
        compose-remove)
            compose_remove
            ;;
        update)
            update_homelabcd || exit 1
            ;;
        gitops-update)
            update_gitops_templates || exit 1
            ;;
        health)
            # Report failures through the exit code, not the ERR trap.
            cluster_health || exit 1
            ;;
        config)
            show_cluster_config
            ;;
        *)
            die "Unknown installer operation: ${INSTALLER_OP:-<empty>}"
            ;;
    esac
    exit 0
fi

install_kubestui || log_warn "KubesTUI install failed; falling back to text menu."

# Startup succeeded: drop its hidden output and give KubesTUI the terminal.
if [[ -n "${STARTUP_LOG}" ]]; then
    exec 1>&3 2>&4 3>&- 4>&-
    trap - EXIT
    rm -f "${STARTUP_LOG}"
fi

export HOMELABCD_ROOT="${ROOT_DIR}"
export HOMELABCD_INSTALL="${ROOT_DIR}/install.sh"
export CLUSTER_NAME="${CLUSTER_NAME:-homelab}"
export KUBERNETES_VERSION="${KUBERNETES_VERSION:-unknown}"
export VIP_ADDRESS="${VIP_ADDRESS:-unknown}"
export CONTAINER_RUNTIME CNI ROOT_DIR

if [[ -x "${ROOT_DIR}/bin/kubestui" ]]; then
    exec "${ROOT_DIR}/bin/kubestui"
fi

log_warn "KubesTUI binary not found; using text menu."
main_menu