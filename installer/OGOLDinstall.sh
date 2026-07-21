#!/usr/bin/env bash

set -Eeuo pipefail


#############################################
# PATH SETUP
#############################################

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export ROOT_DIR

#############################################
# Create default config if missing
#############################################

mkdir -p "${ROOT_DIR}/config"

if [[ ! -f "${ROOT_DIR}/config/defaults.env" ]]; then

    if [[ -f "${ROOT_DIR}/config/defaults.example.env" ]]; then

        cp "${ROOT_DIR}/config/defaults.example.env" \
           "${ROOT_DIR}/config/defaults.env"

        echo
        echo "Created config/defaults.env from defaults.example.env"
        echo

    else

        cat > "${ROOT_DIR}/config/defaults.env" <<EOF
#!/usr/bin/env bash

CLUSTER_NAME="homelab"

GITHUB_REPO=""

BOOTSTRAP_REPO=""

GIT_BRANCH="main"

KUBERNETES_VERSION="v1.36.2"
EOF

        echo
        echo "Created default configuration."
        echo

    fi

fi

#############################################
# Load Configuration
#############################################

source "${ROOT_DIR}/config/defaults.env"

if [[ -f "${ROOT_DIR}/config/versions.env" ]]; then
    source "${ROOT_DIR}/config/versions.env"
fi

#############################################
# CONFIGURATION
#############################################

source "${ROOT_DIR}/config/defaults.env"
source "${ROOT_DIR}/config/versions.env"


#############################################
# CORE LIBRARIES
#############################################

source "${ROOT_DIR}/lib/logging.sh"
source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/lib/progress.sh"
source "${ROOT_DIR}/config/bootstrap.env"
source "${ROOT_DIR}/lib/secrets.sh"
source "${ROOT_DIR}/lib/inventory.sh"
source "${ROOT_DIR}/lib/node-labels.sh"
source "${ROOT_DIR}/lib/hardware-labels.sh"

source "${ROOT_DIR}/lib/config.sh"
source "${ROOT_DIR}/lib/github.sh"

source "${ROOT_DIR}/lib/validation.sh"
source "${ROOT_DIR}/lib/system.sh"
source "${ROOT_DIR}/lib/networking.sh"

source "${ROOT_DIR}/lib/containerd.sh"
source "${ROOT_DIR}/lib/kubevip.sh"
source "${ROOT_DIR}/lib/kubeadm.sh"
source "${ROOT_DIR}/lib/kubeadm-config.sh"

source "${ROOT_DIR}/lib/helm.sh"
source "${ROOT_DIR}/lib/cilium.sh"

source "${ROOT_DIR}/lib/argocd.sh"

source "${ROOT_DIR}/lib/health.sh"
source "${ROOT_DIR}/lib/report.sh"
source "${ROOT_DIR}/lib/repair.sh"
source "${ROOT_DIR}/lib/join.sh"
source "${ROOT_DIR}/config/encryption.env"
source "${ROOT_DIR}/lib/bootstrap-secrets.sh"
source "${ROOT_DIR}/lib/bootstrap-upload.sh"
source "${ROOT_DIR}/lib/bootstrap-download.sh"

#############################################
# LOAD CLUSTER CONFIG
#############################################

load_config


#############################################
# GITHUB CONFIGURATION
#############################################

ask_github_repo

ask_bootstrap_repo

validate_github_access

validate_bootstrap_access


#############################################
# SYSTEM CHECK
#############################################

validate_system

detect_network


#############################################
# START INSTALLER MENU
#############################################

main_menu
