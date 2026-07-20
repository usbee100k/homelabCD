#!/usr/bin/env bash


#############################################
# GITHUB CONFIGURATION
#############################################


ask_github_repo() {


    if [[ -n "${GITHUB_REPO:-}" ]]; then
        return
    fi



    echo

    echo "=========================================="

    echo " GitOps Repository Configuration"

    echo "=========================================="

    echo



    read -rp "Enter GitHub GitOps repository URL: " USER_REPO



    if [[ -z "${USER_REPO}" ]]; then


        log_error "GitOps repository URL cannot be empty."


        exit 1

    fi



    GITHUB_REPO="${USER_REPO}"



    save_github_repo



}



ask_bootstrap_repo() {


    if [[ -n "${BOOTSTRAP_REPO:-}" ]]; then
        return
    fi



    echo

    echo "=========================================="

    echo " Private Bootstrap Repository"

    echo "=========================================="

    echo



    read -rp "Enter private bootstrap repository URL: " USER_BOOTSTRAP



    if [[ -z "${USER_BOOTSTRAP}" ]]; then


        log_error "Bootstrap repository URL cannot be empty."


        exit 1

    fi



    BOOTSTRAP_REPO="${USER_BOOTSTRAP}"



    save_bootstrap_repo



}



save_github_repo() {


    yq -i \
    ".github.repo = \"${GITHUB_REPO}\"" \
    "${CONFIG_FILE}"



    log_ok "GitOps repository saved."

}



save_bootstrap_repo() {


    yq -i \
    ".github.bootstrap_repo = \"${BOOTSTRAP_REPO}\"" \
    "${CONFIG_FILE}"



    log_ok "Bootstrap repository saved."

}



validate_github_access() {


    log_info "Validating GitHub access"



    if ! git ls-remote "${GITHUB_REPO}" >/dev/null 2>&1;

    then


        log_error "Cannot access GitOps repository."


        exit 1

    fi



    log_ok "GitOps repository reachable."

}



validate_bootstrap_access() {


    log_info "Validating bootstrap repository access"



    if ! git ls-remote "${BOOTSTRAP_REPO}" >/dev/null 2>&1;

    then


        log_error "Cannot access private bootstrap repository."


        exit 1

    fi



    log_ok "Bootstrap repository reachable."

}