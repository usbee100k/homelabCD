#!/usr/bin/env bash


ask_github_repo() {

    if [[ -n "${GITHUB_REPO}" ]]; then
        return
    fi


    echo
    echo "=========================================="
    echo " GitOps Repository Configuration"
    echo "=========================================="
    echo


    read -rp "Enter GitHub repository URL: " USER_REPO


    if [[ -z "${USER_REPO}" ]]; then

        log_error "GitHub repository URL cannot be empty."

        exit 1

    fi


    GITHUB_REPO="${USER_REPO}"


    save_github_repo

}



save_github_repo() {


    yq -i \
    ".github.repo = \"${GITHUB_REPO}\"" \
    "${CONFIG_FILE}"


    log_ok "GitHub repository saved."

}