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



    #############################################
    # Generate Key If Missing
    #############################################

    if [[ ! -f "${SSH_KEY_PATH}" ]]; then

        ssh-keygen \
            -t ed25519 \
            -N "" \
            -f "${SSH_KEY_PATH}" \
            -C "argocd@${CLUSTER_NAME}"


        chmod 600 "${SSH_KEY_PATH}"


        log_ok "Argo CD SSH key generated."

    else

        log_ok "Argo CD SSH key already exists."

    fi



    #############################################
    # Verify Public Key Exists
    #############################################

    if [[ ! -f "${SSH_KEY_PATH}.pub" ]]; then

        log_error "SSH public key missing: ${SSH_KEY_PATH}.pub"

        return 1

    fi



    #############################################
    # Display Public Key
    #############################################

    echo
    echo "================================================="
    echo " ADD ARGO CD SSH KEY TO GITHUB"
    echo "================================================="
    echo
    echo "Repository:"
    echo "${GITHUB_REPO:-unknown}"
    echo
    echo "Go to:"
    echo "GitHub → Repository → Settings → Deploy keys → Add deploy key"
    echo
    echo "Add this key:"
    echo
    cat "${SSH_KEY_PATH}.pub"
    echo
    echo "================================================="
    echo


    read -rp "Press ENTER after adding the key to GitHub..."

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
    # Source directory
    #############################################

    local SRC_DIR
    SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"


    #############################################
    # GitHub repository
    #############################################

    [[ -n "${GITHUB_REPO:-}" ]] || \
        die "GITHUB_REPO missing"


    local REPO_URL
    local GITHUB_USER
    local GITOPS_REPO
    local SSH_REPO_URL
    local CONFIRM


    while true; do

        REPO_URL="${GITHUB_REPO}"


        #############################################
        # Normalize URL
        #############################################

        if [[ "${REPO_URL}" == git@github.com:* ]]; then
            REPO_URL="${REPO_URL#git@github.com:}"
        fi


        if [[ "${REPO_URL}" == https://github.com/* ]]; then
            REPO_URL="${REPO_URL#https://github.com/}"
        fi


        REPO_URL="${REPO_URL%.git}"


        GITHUB_USER="${REPO_URL%%/*}"
        GITOPS_REPO="${REPO_URL##*/}"


        SSH_REPO_URL="git@github.com:${GITHUB_USER}/${GITOPS_REPO}.git"


        log_info "GitOps repository detected:"
        echo
        echo "  ${SSH_REPO_URL}"
        echo


        read -rp "Is this correct? [Y/n]: " CONFIRM
        CONFIRM="${CONFIRM:-Y}"


        case "${CONFIRM}" in

            Y|y)
                break
                ;;

            N|n)

                echo
                echo "Enter the correct GitHub repository:"
                echo

                read -rp "GitHub username: " GITHUB_USER
                read -rp "GitHub repository name: " GITOPS_REPO


                SSH_REPO_URL="git@github.com:${GITHUB_USER}/${GITOPS_REPO}.git"


                echo
                echo "New GitOps repository:"
                echo
                echo "  ${SSH_REPO_URL}"
                echo


                read -rp "Use this repository? [Y/n]: " CONFIRM2
                CONFIRM2="${CONFIRM2:-Y}"


                if [[ "${CONFIRM2}" =~ ^[Yy]$ ]]; then

                    GITHUB_REPO="${SSH_REPO_URL}"
                    break

                fi
                ;;

            *)
                echo "Please answer Y or N."
                ;;

        esac

    done



    #############################################
    # Real user home
    #############################################

    local REAL_USER
    local REAL_HOME

    REAL_USER="${SUDO_USER:-$USER}"
    REAL_HOME="$(getent passwd "${REAL_USER}" | cut -d: -f6)"


    local GITOPS_DIR="${REAL_HOME}/${GITOPS_REPO}"



    #############################################
    # Prevent source = destination
    #############################################

    if [[ "${SRC_DIR}" == "${GITOPS_DIR}" ]]; then
        log_error "Source repo and GitOps repo are the same directory."
        log_error "Use a separate GitOps repository."
        return 1
    fi



    #############################################
    # Clone repository
    #############################################

    if [[ ! -d "${GITOPS_DIR}/.git" ]]; then

        log_info "Cloning GitOps repository..."

        git clone \
            "git@github.com:${GITHUB_USER}/${GITOPS_REPO}.git" \
            "${GITOPS_DIR}" || {
                log_error "Failed to clone GitOps repository."
                return 1
            }

    fi


    #############################################
    # Force SSH remote
    #############################################

    git -C "${GITOPS_DIR}" remote set-url origin "${SSH_REPO_URL}"



    #############################################
    # Clean and update repo
    #############################################

    git -C "${GITOPS_DIR}" fetch origin

    git -C "${GITOPS_DIR}" reset --hard origin/main



    #############################################
    # Copy manifests
    #############################################

    rsync -av \
        --exclude ".git" \
        --exclude ".github" \
        --exclude "generated" \
        --exclude "scripts" \
        --exclude "*.sh" \
        --exclude "secrets/" \
        --exclude "cluster-info.yaml" \
        "${SRC_DIR}/" "${GITOPS_DIR}/"



    #############################################
    # Configure Git identity
    #############################################

    cd "${GITOPS_DIR}"


    git config user.name "${GIT_AUTHOR_NAME:-Homelab Installer}"

    git config user.email "${GIT_AUTHOR_EMAIL:-homelab@localhost}"



    #############################################
    # Commit changes
    #############################################

    git add .


    if git diff --cached --quiet; then
        log_ok "GitOps repository already up-to-date."
        return 0
    fi


    git commit \
        -m "Update Kubernetes manifests"


    git push "${SSH_REPO_URL}" main


    log_ok "GitOps repository updated."

}