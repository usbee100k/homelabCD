#!/usr/bin/env bash

set -Eeuo pipefail


#############################################
# ARGO CD INSTALLATION
#############################################


install_argocd() {


    log_info "Installing Argo CD"



    kubectl create namespace argocd \
        --dry-run=client \
        -o yaml | kubectl apply -f -



    helm repo add argo \
        https://argoproj.github.io/argo-helm \
        >/dev/null 2>&1



    helm repo update \
        >/dev/null 2>&1



    helm upgrade \
        --install argocd \
        argo/argo-cd \
        --namespace argocd \
        --values "${ROOT_DIR}/bootstrap/argocd/values.yaml" \
        --wait



    log_info "Waiting for Argo CD API..."



    kubectl wait \
        --for=condition=available \
        deployment/argocd-server \
        -n argocd \
        --timeout=300s



    log_ok "Argo CD Installed."

}



#############################################
# GITOPS BOOTSTRAP
#############################################


bootstrap_gitops() {


    log_info "Bootstrapping GitOps"



    if [[ -z "${GITHUB_REPO:-}" ]]; then

        log_error "GITHUB_REPO is missing."

        exit 1

    fi



    #########################################
    # Create Argo Project
    #########################################


    kubectl apply \
        -f "${ROOT_DIR}/bootstrap/projects/default-project.yaml"



    #########################################
    # Configure Root Application
    #########################################


    mkdir -p "${ROOT_DIR}/generated"



    sed \
    -e "s|REPLACE_REPO_URL|${GITHUB_REPO}|g" \
    -e "s|REPLACE_BRANCH|${GIT_BRANCH:-main}|g" \
    "${ROOT_DIR}/bootstrap/root-app.yaml" \
    > "${ROOT_DIR}/generated/root-app.yaml"



    kubectl apply \
        -f "${ROOT_DIR}/generated/root-app.yaml"



    log_ok "GitOps Repository Connected."

}