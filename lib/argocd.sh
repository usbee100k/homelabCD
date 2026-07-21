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
        --timeout 10m \
        --wait

    log_info "Waiting for Argo CD API..."

    kubectl wait \
        --for=condition=available \
        deployment/argocd-server \
        -n argocd \
        --timeout=300s

    log_ok "Argo CD Installed."

}

generate_argocd_ssh_key() {

    log_info "Checking Argo CD SSH deploy key"


    SSH_KEY_PATH="/etc/kubernetes/argocd/id_ed25519"

    export SSH_KEY_PATH


    mkdir -p /etc/kubernetes/argocd


    if [[ -f "${SSH_KEY_PATH}" ]]; then

        log_ok "Argo CD SSH key already exists."

        return

    fi


    ssh-keygen \
        -t ed25519 \
        -N "" \
        -f "${SSH_KEY_PATH}" \
        -C "argocd@${CLUSTER_NAME}"


    chmod 600 "${SSH_KEY_PATH}"


    log_ok "Argo CD SSH key generated."

}



#############################################
# ARGO CD PRIVATE REPOSITORY
#############################################


configure_argocd_repository()
{

    log_info "Configuring Argo CD private repository"


    local repo_url

    repo_url="${GITHUB_REPO}"

    if [[ "${repo_url}" == https://github.com/* ]]; then
        repo_url="${repo_url/https:\/\/github.com\//git@github.com:}"
    fi


    kubectl create secret generic bootstrap-repository \
        -n argocd \
        --from-literal=type=git \
        --from-literal=url="${repo_url}" \
        --from-file=sshPrivateKey="${SSH_KEY_PATH}" \
        --dry-run=client \
        -o yaml \
        | kubectl apply -f -



    kubectl label secret bootstrap-repository \
        -n argocd \
        argocd.argoproj.io/secret-type=repository \
        --overwrite



    log_ok "Argo CD repository configured"

}



#############################################
# GITOPS BOOTSTRAP
#############################################


bootstrap_gitops() {

    log_info "Bootstrapping GitOps"

    [[ -n "${GITHUB_REPO:-}" ]] || \
        die "GITHUB_REPO missing"

    configure_argocd_repository

    kubectl apply \
        -f "${ROOT_DIR}/bootstrap/projects/default-project.yaml"

    mkdir -p "${ROOT_DIR}/generated"

    sed \
        -e "s|REPLACE_REPO_URL|${GITHUB_REPO}|g" \
        -e "s|REPLACE_BRANCH|${GIT_BRANCH:-main}|g" \
        "${ROOT_DIR}/bootstrap/root-app.yaml" \
        > "${ROOT_DIR}/generated/root-app.yaml"

    kubectl apply \
        -f "${ROOT_DIR}/generated/root-app.yaml"

    log_ok "GitOps bootstrap complete."

}