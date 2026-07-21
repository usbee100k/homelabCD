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
    # shellcheck source=/dev/null
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
# Root Check
#############################################

(( EUID == 0 )) || die "Please run this installer as root."

#############################################
# Required Commands
#############################################

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

#############################################
# Configuration
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

#############################################
# Load Configuration
#############################################

source_required "${ROOT_DIR}/config/defaults.env"
source_optional "${ROOT_DIR}/config/versions.env"
source_optional "${ROOT_DIR}/config/bootstrap.env"
source_optional "${ROOT_DIR}/config/encryption.env"

#############################################
# Load Libraries
#############################################

LIBRARIES=(
    logging
    common
    progress
    bootstrap-repo
    secrets
    inventory
    node-labels
    hardware-labels
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
    health
    report
    repair
    join
    bootstrap-secrets
    bootstrap-upload
    bootstrap-download
)

for lib in "${LIBRARIES[@]}"; do
    source_required "${ROOT_DIR}/lib/${lib}.sh"
done

#############################################
# Validate Required Functions
#############################################

for fn in \
    load_config \
    ask_github_repo \
    ask_bootstrap_repo \
    validate_github_access \
    validate_bootstrap_access \
    validate_system \
    detect_network \
    main_menu
do
    require_function "$fn"
done

#############################################
# Load Cluster Configuration
#############################################

load_config

#############################################
# GitHub Configuration
#############################################

ask_github_repo
ask_bootstrap_repo

validate_github_access
validate_bootstrap_access

#############################################
# System Validation
#############################################

validate_system
detect_network

#############################################
# Launch Installer
#############################################

main_menu