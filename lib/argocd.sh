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

    helm repo add argo https://argoproj.github.io/argo-helm \
        >/dev/null 2>&1 || true

    helm repo update

    #############################################
    # Remove failed Helm release
    #############################################

    if helm status argocd -n argocd >/dev/null 2>&1; then

        STATUS="$(helm status argocd -n argocd -o json | jq -r '.info.status')"

        if [[ "${STATUS}" == "failed" ]]; then

            log_warn "Previous Argo CD installation failed. Removing it..."

            helm uninstall argocd \
                -n argocd \
                --wait || true

            kubectl delete namespace argocd \
                --ignore-not-found=true \
                --wait=true

            kubectl create namespace argocd

        elif [[ "${STATUS}" == "deployed" ]]; then

            log_ok "Argo CD already installed."
            return 0

        fi
    fi

    #############################################
    # Install
    #############################################

    helm upgrade --install argocd argo/argo-cd \
        --namespace argocd \
        --create-namespace \
        --wait \
        --timeout 15m

    #############################################
    # Wait for CRDs
    #############################################

    log_info "Waiting for CRDs..."

    kubectl wait \
        --for=condition=Established \
        crd/applications.argoproj.io \
        --timeout=300s

    kubectl wait \
        --for=condition=Established \
        crd/appprojects.argoproj.io \
        --timeout=300s

    kubectl wait \
        --for=condition=Established \
        crd/applicationsets.argoproj.io \
        --timeout=300s || true

    #############################################
    # Verify resources actually exist
    #############################################

    kubectl get deployment argocd-server -n argocd >/dev/null
    kubectl get deployment argocd-repo-server -n argocd >/dev/null

    log_ok "Argo CD installed."
}

#############################################
# WAIT FOR ARGO CD
#############################################

wait_for_argocd() {

    log_info "Waiting for Argo CD..."

    kubectl rollout status \
        deployment/argocd-server \
        -n argocd \
        --timeout=10m

    kubectl rollout status \
        deployment/argocd-repo-server \
        -n argocd \
        --timeout=10m

    if kubectl get deployment argocd-dex-server -n argocd >/dev/null 2>&1; then
        kubectl rollout status \
            deployment/argocd-dex-server \
            -n argocd \
            --timeout=10m
    fi

    if kubectl get deployment argocd-redis -n argocd >/dev/null 2>&1; then
        kubectl rollout status \
            deployment/argocd-redis \
            -n argocd \
            --timeout=10m
    fi

    if kubectl get statefulset argocd-application-controller -n argocd >/dev/null 2>&1; then

        kubectl rollout status \
            statefulset/argocd-application-controller \
            -n argocd \
            --timeout=10m

    else

        kubectl rollout status \
            deployment/argocd-application-controller \
            -n argocd \
            --timeout=10m
    fi

    log_ok "Argo CD Ready."
}


verify_cluster_dns() {

    log_info "Verifying cluster DNS..."

    kubectl delete pod dns-test \
        --ignore-not-found=true >/dev/null 2>&1

    kubectl run dns-test \
        --image=busybox:1.36 \
        --restart=Never \
        --command -- sleep 300

    kubectl wait \
        --for=condition=Ready pod/dns-test \
        --timeout=120s

    if ! kubectl exec dns-test -- nslookup kubernetes.default.svc; then
    log_error "Cluster DNS verification failed."

    kubectl get pods -A -o wide
    kubectl get svc -A
    kubectl get endpoints -A

    exit 1
    fi

    kubectl delete pod dns-test --wait=false >/dev/null

    log_ok "Cluster DNS is working."
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





#############################################
# Sync manifests into GitOps repo
#############################################

sync_gitops_repo() {

    log_info "Syncing manifests to GitOps repository..."

    #############################################
    # Source directory (project root)
    #############################################

    local SRC_DIR
    SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

    #############################################
    # GitHub repository
    #############################################

    [[ -n "${GITHUB_REPO:-}" ]] || \
        die "GITHUB_REPO missing"

    local REPO_URL="${GITHUB_REPO}"
    local GITHUB_USER
    local GITOPS_REPO

    # Convert SSH URL if needed
    if [[ "${REPO_URL}" == git@github.com:* ]]; then
        REPO_URL="${REPO_URL#git@github.com:}"
    fi

    # Convert HTTPS URL if needed
    if [[ "${REPO_URL}" == https://github.com/* ]]; then
        REPO_URL="${REPO_URL#https://github.com/}"
    fi

    REPO_URL="${REPO_URL%.git}"

    GITHUB_USER="${REPO_URL%%/*}"
    GITOPS_REPO="${REPO_URL##*/}"

    log_info "Using GitOps repository:"
    echo "  git@github.com:${GITHUB_USER}/${GITOPS_REPO}.git"
    
    
    #############################################
    # Determine real user home
    #############################################

    local REAL_USER
    local REAL_HOME

    REAL_USER="${SUDO_USER:-$USER}"
    REAL_HOME="$(getent passwd "${REAL_USER}" | cut -d: -f6)"

    local GITOPS_DIR="${REAL_HOME}/${GITOPS_REPO}"

    #############################################
    # Clone repository if missing
    #############################################

    if [[ ! -d "${GITOPS_DIR}/.git" ]]; then

        log_info "Cloning GitOps repository..."

        git clone "git@github.com:${GITHUB_USER}/${GITOPS_REPO}.git" "${GITOPS_DIR}" || {
            log_error "Failed to clone GitOps repository."
            return 1
        }

    fi

    #############################################
    # Verify repository
    #############################################

    if [[ ! -d "${GITOPS_DIR}/.git" ]]; then
        log_error "Unable to access GitOps repository."
        return 1
    fi

    #############################################
    # Update repository
    #############################################

    git -C "${GITOPS_DIR}" pull --rebase

    #############################################
    # Copy manifests
    #############################################

    rsync -av --delete \
        --exclude ".git" \
        --exclude ".github" \
        --exclude "generated" \
        --exclude "scripts" \
        --exclude "*.sh" \
        "${SRC_DIR}/" "${GITOPS_DIR}/"

    #############################################
    # Commit changes
    #############################################

    cd "${GITOPS_DIR}"

    git add .

    if git diff --cached --quiet; then
        log_ok "GitOps repository already up-to-date."
        return 0
    fi

    git commit -m "Update Kubernetes manifests"

    git push origin main

    log_ok "GitOps repository updated."

}

