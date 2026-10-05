#!/usr/bin/env bash


#############################################
# VERIFY SELECTED GITHUB REPOSITORY ACCESS
#############################################

ensure_github_ssh_access() {

    log_info "Verifying selected GitHub repository access"

    #############################################
    # Validate repository
    #############################################

    [[ -n "${BOOTSTRAP_REPO:-}" ]] || {
        log_error "BOOTSTRAP_REPO is not set."
        return 1
    }

    #############################################
    # Validate deploy key
    #############################################

    [[ -n "${SSH_KEY_PATH:-}" ]] || {
        log_error "SSH_KEY_PATH is not set."
        return 1
    }

    if [[ ! -f "${SSH_KEY_PATH}" ]]; then
        log_error "Deploy key does not exist:"
        log_error "${SSH_KEY_PATH}"
        return 1
    fi

    #############################################
    # SSH command
    #############################################

    export GIT_SSH_COMMAND="ssh \
-o BatchMode=yes \
-o StrictHostKeyChecking=accept-new \
-o IdentitiesOnly=yes \
-i ${SSH_KEY_PATH}"

    #############################################
    # Test repository access
    #############################################

    log_info "Testing access to:"
    log_info "${BOOTSTRAP_REPO}"

    if GIT_SSH_COMMAND="${GIT_SSH_COMMAND}" \
        git ls-remote "${BOOTSTRAP_REPO}" HEAD >/dev/null 2>&1; then

        log_ok "GitHub repository access verified."

        return 0
    fi

    #############################################
    # Failure
    #############################################

    log_error "Cannot access GitHub repository:"
    log_error "${BOOTSTRAP_REPO}"
    echo
    echo "Verify that the deploy key generated for this repository"
    echo "was added to the selected GitHub repository and that"
    echo "'Allow write access' is enabled."
    echo

    return 1
}


#############################################
# UPLOAD BOOTSTRAP PACKAGE
#############################################

upload_bootstrap_package() {

    log_info "Uploading encrypted bootstrap package"

    #############################################
    # Validate bootstrap repository
    #############################################

    if [[ -z "${BOOTSTRAP_REPO:-}" ]]; then
        log_error "BOOTSTRAP_REPO is not set."
        return 1
    fi

    #############################################
    # Validate bootstrap package
    #############################################

    if [[ ! -d "${ROOT_DIR}/generated/bootstrap" ]]; then
        log_error "Bootstrap package missing:"
        log_error "${ROOT_DIR}/generated/bootstrap"
        return 1
    fi

    #############################################
    # Validate deploy key
    #############################################

    if [[ -z "${SSH_KEY_PATH:-}" ]]; then
        log_error "SSH_KEY_PATH is not set."
        return 1
    fi

    if [[ ! -f "${SSH_KEY_PATH}" ]]; then
        log_error "Deploy key not found:"
        log_error "${SSH_KEY_PATH}"
        return 1
    fi

    #############################################
    # SSH command
    #############################################

    local GIT_SSH_COMMAND

    GIT_SSH_COMMAND="ssh \
-o BatchMode=yes \
-o StrictHostKeyChecking=accept-new \
-o IdentitiesOnly=yes \
-i ${SSH_KEY_PATH}"

    #############################################
    # Target branch
    #############################################

    local TARGET_BRANCH

    TARGET_BRANCH="${GIT_BRANCH:-main}"

    #############################################
    # Temporary directory
    #############################################

    local TEMP_DIR="/tmp/bootstrap-upload"

    rm -rf "${TEMP_DIR}"

    #############################################
    # Clone bootstrap repository
    #############################################

    log_info "Cloning bootstrap repository..."

    if ! GIT_SSH_COMMAND="${GIT_SSH_COMMAND}" \
        git clone \
            "${BOOTSTRAP_REPO}" \
            "${TEMP_DIR}"; then

        log_error "Failed to clone bootstrap repository:"
        log_error "${BOOTSTRAP_REPO}"

        rm -rf "${TEMP_DIR}"

        return 1
    fi

    #############################################
    # Fetch all remote branches
    #############################################

    log_info "Fetching bootstrap repository branches..."

    if ! GIT_SSH_COMMAND="${GIT_SSH_COMMAND}" \
        git -C "${TEMP_DIR}" fetch origin; then

        log_error "Failed to fetch bootstrap repository."

        rm -rf "${TEMP_DIR}"

        return 1
    fi

    #############################################
    # Select target branch
    #############################################

    if git -C "${TEMP_DIR}" \
        show-ref --verify --quiet \
        "refs/remotes/origin/${TARGET_BRANCH}"; then

        log_info "Using existing remote branch: ${TARGET_BRANCH}"

        git -C "${TEMP_DIR}" checkout -B \
            "${TARGET_BRANCH}" \
            "origin/${TARGET_BRANCH}"

    else

        log_warn "Remote branch '${TARGET_BRANCH}' does not exist."

        log_info "Creating branch '${TARGET_BRANCH}' from current repository state."

        git -C "${TEMP_DIR}" checkout -B \
            "${TARGET_BRANCH}"
    fi

    #############################################
    # Copy encrypted bootstrap package
    #############################################

    log_info "Copying encrypted bootstrap package..."

    cp -a \
        "${ROOT_DIR}/generated/bootstrap/." \
        "${TEMP_DIR}/"

    #############################################
    # Configure Git identity
    #############################################

    git -C "${TEMP_DIR}" config user.name \
        "${GIT_USER_NAME:-homelab-bootstrap}"

    git -C "${TEMP_DIR}" config user.email \
        "${GIT_USER_EMAIL:-homelab-bootstrap@localhost}"

    #############################################
    # Add changes
    #############################################

    git -C "${TEMP_DIR}" add .

    #############################################
    # Check for changes
    #############################################

    if git -C "${TEMP_DIR}" diff --cached --quiet; then

        log_info "No bootstrap package changes to commit."

        rm -rf "${TEMP_DIR}"

        log_ok "Encrypted bootstrap package already up-to-date."

        return 0
    fi

    #############################################
    # Commit
    #############################################

    if ! git -C "${TEMP_DIR}" commit \
        -m "Update encrypted cluster bootstrap"; then

        log_error "Git commit failed."

        rm -rf "${TEMP_DIR}"

        return 1
    fi

    #############################################
    # Push
    #############################################

    log_info "Pushing encrypted bootstrap package to ${TARGET_BRANCH}..."

    if ! GIT_SSH_COMMAND="${GIT_SSH_COMMAND}" \
        git -C "${TEMP_DIR}" push \
            -u origin \
            "${TARGET_BRANCH}"; then

        log_error "Git push failed."
        log_error "Repository:"
        log_error "${BOOTSTRAP_REPO}"
        log_error "Branch:"
        log_error "${TARGET_BRANCH}"

        rm -rf "${TEMP_DIR}"

        return 1
    fi

    #############################################
    # Cleanup
    #############################################

    rm -rf "${TEMP_DIR}"

    log_ok "Encrypted bootstrap uploaded."
}