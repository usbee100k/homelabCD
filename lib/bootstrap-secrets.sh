#!/usr/bin/env bash

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
# ENCRYPT BOOTSTRAP FILES
#############################################

command -v sops >/dev/null || {
    log_error "sops is not installed"
    exit 1
}

command -v age-keygen >/dev/null || {
    log_error "age is not installed"
    exit 1
}


create_bootstrap_package() {


    BOOTSTRAP_DIR="${ROOT_DIR}/generated/bootstrap"


    mkdir -p "${BOOTSTRAP_DIR}/secrets"



    log_info "Creating encrypted bootstrap package"



    encrypt_bootstrap_file \
    "${ROOT_DIR}/generated/worker_join.sh" \
    "${BOOTSTRAP_DIR}/secrets/worker_join.enc"



    encrypt_bootstrap_file \
    "${ROOT_DIR}/generated/controlplane_join.sh" \
    "${BOOTSTRAP_DIR}/secrets/controlplane_join.enc"



    CLUSTER_INFO="${ROOT_DIR}/generated/cluster-info.yaml"

    if [[ ! -f "${CLUSTER_INFO}" ]]; then
        log_error "Missing cluster info file: ${CLUSTER_INFO}"
        exit 1
    fi

    cp \
        "${CLUSTER_INFO}" \
        "${BOOTSTRAP_DIR}/"



    log_ok "Bootstrap package created."

}

ensure_age_key() {

    if [[ -n "${SUDO_USER}" ]]; then
        REAL_HOME=$(eval echo "~${SUDO_USER}")
    else
        REAL_HOME="${HOME}"
    fi


    AGE_DIR="${REAL_HOME}/.config/sops/age"
    AGE_KEY_FILE="${AGE_DIR}/keys.txt"


    if [[ -f "${AGE_KEY_FILE}" ]]; then

        log_ok "Age key already exists: ${AGE_KEY_FILE}"

    else

        log_info "Generating new age key"

        mkdir -p "${AGE_DIR}"

        age-keygen -o "${AGE_KEY_FILE}"

        chmod 600 "${AGE_KEY_FILE}"

        log_ok "Age key created"
    fi

}


encrypt_bootstrap_file() {

    SOURCE_FILE="$1"
    OUTPUT_FILE="$2"

    if [[ ! -f "${SOURCE_FILE}" ]]; then
        log_error "Missing file: ${SOURCE_FILE}"
        exit 1
    fi


    # Load AGE public key if not already set
    if [[ -z "${AGE_PUBLIC_KEY}" ]]; then

        # Resolve real user's home directory when running with sudo
        if [[ -n "${SUDO_USER}" ]]; then
            REAL_HOME=$(eval echo "~${SUDO_USER}")
        else
            REAL_HOME="${HOME}"
        fi

        AGE_KEY_FILE="${REAL_HOME}/.config/sops/age/keys.txt"


        if [[ ! -f "${AGE_KEY_FILE}" ]]; then
            log_error "Missing age key file: ${AGE_KEY_FILE}"
            exit 1
        fi


        AGE_PUBLIC_KEY=$(age-keygen -y "${AGE_KEY_FILE}")


        if [[ -z "${AGE_PUBLIC_KEY}" ]]; then
            log_error "Failed to generate AGE_PUBLIC_KEY"
            exit 1
        fi


        export AGE_PUBLIC_KEY

        log_info "Using AGE public key: ${AGE_PUBLIC_KEY}"
    fi


    log_info "Encrypting ${SOURCE_FILE}"


    sops \
        --encrypt \
        --age "${AGE_PUBLIC_KEY}" \
        "${SOURCE_FILE}" \
        > "${OUTPUT_FILE}"


    if [[ $? -ne 0 ]]; then
        log_error "Encryption failed for ${SOURCE_FILE}"
        exit 1
    fi


    log_ok "Encrypted: ${OUTPUT_FILE}"

}