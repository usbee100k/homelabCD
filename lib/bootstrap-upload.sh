#!/usr/bin/env bash


#############################################
# ENSURE GITHUB SSH ACCESS
#############################################

ensure_github_ssh_access() {

    SSH_DIR="${HOME}/.ssh"
    SSH_KEY="${SSH_DIR}/id_ed25519"
    SSH_PUB="${SSH_KEY}.pub"


    mkdir -p "${SSH_DIR}"
    chmod 700 "${SSH_DIR}"


    # Generate SSH key if missing
    if [[ ! -f "${SSH_KEY}" ]]; then

        log_info "No SSH key found. Generating GitHub SSH key..."

        ssh-keygen \
            -t ed25519 \
            -C "$(hostname)" \
            -f "${SSH_KEY}" \
            -N ""

        chmod 600 "${SSH_KEY}"
        chmod 644 "${SSH_PUB}"

    fi


    echo
    echo "================================================="
    echo " GitHub SSH public key"
    echo "================================================="
    cat "${SSH_PUB}"
    echo "================================================="
    echo
    echo "Add this key to:"
    echo "https://github.com/settings/keys"
    echo


    # Add github host key
    ssh-keyscan github.com >> "${SSH_DIR}/known_hosts" 2>/dev/null
    chmod 600 "${SSH_DIR}/known_hosts"


    while true; do

        read -rp "Press ENTER after adding the SSH key to GitHub..."


        log_info "Testing GitHub SSH authentication"


        SSH_TEST=$(ssh -T git@github.com 2>&1)


        if echo "${SSH_TEST}" | grep -qi "successfully authenticated"; then

            log_ok "GitHub SSH authentication successful."
            break

        fi


        echo
        log_error "GitHub SSH authentication failed."
        echo
        echo "Make sure this key exists in GitHub:"
        echo
        cat "${SSH_PUB}"
        echo
        echo "Retry after adding it."
        echo

    done

}



#############################################
# UPLOAD BOOTSTRAP PACKAGE
#############################################

upload_bootstrap_package() {


    if [[ -z "${BOOTSTRAP_REPO}" ]]; then

        log_error "BOOTSTRAP_REPO is not set."
        exit 1

    fi


    ensure_github_ssh_access


    if [[ ! -d "${ROOT_DIR}/generated/bootstrap" ]]; then

        log_error "Bootstrap package missing."
        exit 1

    fi


    TEMP_DIR="/tmp/bootstrap-upload"


    rm -rf "${TEMP_DIR}"


    log_info "Preparing bootstrap repository"


    git clone \
        "${BOOTSTRAP_REPO}" \
        "${TEMP_DIR}"


    if [[ $? -ne 0 ]]; then

        log_error "Failed to clone bootstrap repository."
        exit 1

    fi


    cp -r \
        "${ROOT_DIR}/generated/bootstrap/"* \
        "${TEMP_DIR}/"


    cd "${TEMP_DIR}" || exit 1


    git add .


    if git diff --cached --quiet; then

        log_info "No changes to commit."

    else

        git commit \
            -m "Update encrypted cluster bootstrap"

        git push

    fi


    cd "${ROOT_DIR}" || exit 1


    rm -rf "${TEMP_DIR}"


    log_ok "Encrypted bootstrap uploaded."

}