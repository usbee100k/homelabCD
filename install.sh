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
# Step 1 — Load Libraries
#############################################

LIBRARIES=(
    logging
    common
    progress
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
# Step 1b — Validate Required Functions
#############################################

#    setup_bootstrap_ssh 
#    validate_bootstrap_config 

for fn in \
    validate_system \
    detect_network \
    load_config \
    main_menu
do
    require_function "$fn"
done

#############################################
# Step 2 — Validate the Host
#############################################

(( EUID == 0 )) || die "Please run this installer as root."

validate_system
detect_network

#############################################
# Step 3 — Install Prerequisites
#############################################

# Minimal bootstrap commands the installer itself needs to run.
for cmd in \
    bash \
    curl \
    age \
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
# INSTALL BOOTSTRAP DEPENDENCIES
#############################################

install_bootstrap_dependencies() {

    log_info "Checking bootstrap dependencies"


    #############################################
    # BASE PACKAGES
    #############################################

    REQUIRED_PACKAGES=(
        curl
        git
        openssh-client
    )


    for PKG in "${REQUIRED_PACKAGES[@]}"; do

        if dpkg -s "${PKG}" >/dev/null 2>&1; then

            log_ok "${PKG} already installed"

        else

            log_info "Installing ${PKG}..."

            sudo apt update
            sudo apt install -y "${PKG}"

        fi

    done



    #############################################
    # AGE
    #############################################

    if command -v age >/dev/null 2>&1; then

        log_ok "age already installed: $(age --version | head -1)"

    else

        log_info "Installing age..."

        sudo apt update
        sudo apt install -y age


        if ! command -v age >/dev/null 2>&1; then

            log_error "Failed to install age"
            exit 1

        fi


        log_ok "age installed"

    fi



    #############################################
    # SOPS
    #############################################

    if command -v sops >/dev/null 2>&1; then

        log_ok "sops already installed: $(sops --version | head -1)"

    else

        log_info "Installing sops..."


        SOPS_VERSION=$(curl -fsSL \
            https://api.github.com/repos/getsops/sops/releases/latest \
            | grep tag_name \
            | cut -d '"' -f4)



        if [[ -z "${SOPS_VERSION}" ]]; then

            log_error "Unable to determine latest SOPS version"
            exit 1

        fi


        log_info "Downloading SOPS ${SOPS_VERSION}"


        curl -fsSL \
            -o /tmp/sops.deb \
            "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops_${SOPS_VERSION#v}_amd64.deb"



        sudo dpkg -i /tmp/sops.deb || sudo apt-get install -f -y



        rm -f /tmp/sops.deb



        if ! command -v sops >/dev/null 2>&1; then

            log_error "Failed to install sops"
            exit 1

        fi


        log_ok "sops installed: $(sops --version | head -1)"

    fi



    #############################################
    # FINAL VERIFY
    #############################################

    for CMD in age sops git ssh curl; do

        if ! command -v "${CMD}" >/dev/null 2>&1; then

            log_error "Missing required command: ${CMD}"
            exit 1

        fi

    done


    log_ok "Bootstrap dependencies ready"

}

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

#############################################
# Step 5 — Continue with Kubernetes Setup
#############################################



#############################################
# Launch Installer
#############################################

main_menu