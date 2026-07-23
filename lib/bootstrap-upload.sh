#!/usr/bin/env bash


#############################################
# ENSURE GITHUB SSH ACCESS
#############################################

ensure_github_ssh_access() {

    SSH_DIR="${HOME}/.ssh"
    SSH_KEY="${SSH_DIR}/id_ed25519"
    SSH_PUB="${SSH_KEY}.pub"

    export GIT_SSH_COMMAND="ssh -i ${SSH_KEY} -o IdentitiesOnly=yes"


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

    
    # Add github host key
    ssh-keyscan github.com >> "${SSH_DIR}/known_hosts" 2>/dev/null
    chmod 600 "${SSH_DIR}/known_hosts"


     # Test first - if already working, do nothing
    log_info "Testing GitHub SSH authentication"


    SSH_TEST=$(ssh -T git@github.com 2>&1 || true)


    if [[ "${SSH_TEST}" == *"successfully authenticated"* ]]; then

        log_ok "GitHub SSH authentication successful."
        return 0

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






    while true; do

        read -rp "Press ENTER after adding the SSH key to GitHub..."


        log_info "Testing GitHub SSH authentication"


        ssh -T git@github.com > /tmp/github-ssh-test.log 2>&1 || true


        SSH_TEST=$(cat /tmp/github-ssh-test.log)


        if [[ "${SSH_TEST}" == *"successfully authenticated"* ]]; then

            log_ok "GitHub SSH authentication successful."
            return 0

        fi


        echo
        log_error "GitHub SSH authentication failed."
        echo
        echo "${SSH_TEST}"
        echo
        echo "Your SSH public key:"
        echo
        cat "${SSH_PUB}"
        echo
        echo "Add it here:"
        echo "https://github.com/settings/keys"
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


    # Configure git identity for this repository
    git config user.name "${GIT_USER_NAME:-homelab-bootstrap}"
    git config user.email "${GIT_USER_EMAIL:-homelab-bootstrap@localhost}"


    git add .


    if git diff --cached --quiet; then

        log_info "No changes to commit."

    else

        git commit \
            -m "Update encrypted cluster bootstrap"


        if [[ $? -ne 0 ]]; then

            log_error "Git commit failed."
            exit 1

        fi


        git push


        if [[ $? -ne 0 ]]; then

            log_error "Git push failed."
            exit 1

        fi

    fi


    cd "${ROOT_DIR}" || exit 1


    rm -rf "${TEMP_DIR}"


    log_ok "Encrypted bootstrap uploaded."

}