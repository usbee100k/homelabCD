##!/usr/bin/env bash

set -Eeuo pipefail


#############################################
# ARGO CD INSTALLATION
#############################################

install_argocd() {

    log_info "Installing Argo CD"


    #############################################
    # Skip existing install
    #############################################

    if helm status argocd -n argocd >/dev/null 2>&1; then

        log_ok "Argo CD already installed. Skipping."
        return 0

    fi


    #############################################
    # Namespace
    #############################################

    kubectl create namespace argocd \
        --dry-run=client \
        -o yaml | kubectl apply -f -



    #############################################
    # Helm
    #############################################

    helm repo add argo https://argoproj.github.io/argo-helm \
        >/dev/null 2>&1 || true


    helm repo update



    helm upgrade --install argocd argo/argo-cd \
        --namespace argocd \
        --timeout 10m \
        --create-namespace



    log_ok "Argo CD deployed."

}



#############################################
# WAIT FOR ARGO CD
#############################################


wait_for_argocd() {

    log_info "Waiting for Argo CD..."


    kubectl wait \
        --namespace argocd \
        --for=create deployment/argocd-server \
        --timeout=300s



    kubectl wait \
        --namespace argocd \
        --for=condition=Available \
        deployment/argocd-server \
        --timeout=300s



    kubectl wait \
        --namespace argocd \
        --for=condition=Available \
        deployment/argocd-repo-server \
        --timeout=300s



    log_ok "Argo CD Ready."

}




#############################################
# SSH KEY
#############################################

generate_argocd_ssh_key() {

    log_info "Checking Argo CD SSH deploy key"


    SSH_KEY_PATH="${SSH_KEY_PATH:-/etc/kubernetes/argocd/id_ed25519}"


    export SSH_KEY_PATH


    mkdir -p "$(dirname "${SSH_KEY_PATH}")"



    if [[ -f "${SSH_KEY_PATH}" ]]; then

        log_ok "Argo CD SSH key already exists."
        return 0

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
# ARGO CD REPOSITORY
#############################################

configure_argocd_repository() {

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



    log_ok "Argo CD repository configured."

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