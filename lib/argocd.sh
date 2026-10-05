#!/usr/bin/env bash

set -Eeuo pipefail


#############################################
# ARGO CD INSTALLATION
#############################################

install_argocd() {

    log_info "Installing Argo CD"

    ARGOCD_DOMAIN="argocd.${BASE_DOMAIN}"

    READY_NODES=$(
        kubectl get nodes --no-headers 2>/dev/null |
            awk '$2 == "Ready" && $0 !~ /SchedulingDisabled/ {count++} END {print count+0}'
    )

    if (( READY_NODES >= 2 )); then
        ARGOCD_REPLICAS=2
    else
        ARGOCD_REPLICAS=1
    fi

    log_info "Detected ${READY_NODES} Ready node(s); using ${ARGOCD_REPLICAS} Argo CD replicas."

    #############################################
    # Namespace
    #############################################

    kubectl create namespace argocd \
        --dry-run=client \
        -o yaml | kubectl apply -f -

    #############################################
    # Helm repository
    #############################################

    helm repo add argo https://argoproj.github.io/argo-helm \
        >/dev/null 2>&1 || true

    helm repo update

    #############################################
    # Handle existing Helm release
    #############################################

    if helm status argocd -n argocd >/dev/null 2>&1; then

        STATUS="$(
            helm status argocd -n argocd -o json |
                jq -r '.info.status'
        )"

        case "${STATUS}" in

            failed|pending-install|pending-upgrade|pending-rollback)

                log_warn "Previous Argo CD release is in '${STATUS}' state."
                log_warn "Removing stuck Argo CD release..."

                helm uninstall argocd \
                    --namespace argocd \
                    --wait \
                    || true

                kubectl delete namespace argocd \
                    --ignore-not-found=true \
                    --wait=true \
                    || true

                kubectl create namespace argocd
                ;;

            deployed)

                log_info "Argo CD already installed. Applying current configuration..."
                ;;

            *)

                log_warn "Argo CD release is in unexpected state '${STATUS}'."
                ;;

        esac
    fi

    #############################################
    # Install / Upgrade
    #############################################

    helm upgrade --install argocd argo/argo-cd \
        --namespace argocd \
        --create-namespace \
        --values "${ROOT_DIR}/bootstrap/argocd/values.yaml" \
        --set-string "global.domain=${ARGOCD_DOMAIN}" \
        --set-string "configs.cm.url=https://${ARGOCD_DOMAIN}" \
        --set "server.replicas=${ARGOCD_REPLICAS}" \
        --set "repoServer.replicas=${ARGOCD_REPLICAS}" \
        --set "applicationSet.replicas=${ARGOCD_REPLICAS}" \
        --wait \
        --timeout 15m

    #############################################
    # Apply Ingress
    #############################################

    sed "s/__HOSTNAME__/${ARGOCD_DOMAIN}/g" \
        "${ROOT_DIR}/bootstrap/argocd/ingress.yaml" |
        kubectl apply -f -

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
        --timeout=300s \
        || true

    #############################################
    # Verify resources
    #############################################

    kubectl get deployment argocd-server \
        -n argocd >/dev/null

    kubectl get deployment argocd-repo-server \
        -n argocd >/dev/null

    log_ok "Argo CD installed/configured."
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

    install_argocd_replica_scaler
}


#############################################
# VERIFY CLUSTER DNS
#############################################

verify_cluster_dns() {

    log_info "Verifying cluster DNS..."

    kubectl delete pod dns-test \
        --ignore-not-found=true \
        >/dev/null 2>&1

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

    kubectl delete pod dns-test \
        --wait=false \
        >/dev/null

    log_ok "Cluster DNS is working."
}


#############################################
# GITOPS REPOSITORY SELECTION
#############################################

configure_gitops_repository() {

    log_info "Configure GitOps repository"

    # IMPORTANT:
    # These variables must NOT be local.
    # They are needed by the functions that run afterward.

    while true; do

        echo
        read -rp "GitHub username: " GITHUB_USER

        while [[ -z "${GITHUB_USER}" ]]; do
            log_warn "GitHub username cannot be empty."
            read -rp "GitHub username: " GITHUB_USER
        done

        read -rp "Repository name: " GITOPS_REPO

        while [[ -z "${GITOPS_REPO}" ]]; do
            log_warn "Repository name cannot be empty."
            read -rp "Repository name: " GITOPS_REPO
        done

        GITHUB_REPO="git@github.com:${GITHUB_USER}/${GITOPS_REPO}.git"

        echo
        echo "GitOps repository:"
        echo
        echo "  ${GITHUB_REPO}"
        echo

        read -rp "Use this repository? [Y/n]: " CONFIRM
        CONFIRM="${CONFIRM:-Y}"

        case "${CONFIRM}" in

            Y|y)
                break
                ;;

            N|n)
                echo
                continue
                ;;

            *)
                echo "Please answer Y or N."
                ;;

        esac
    done

    export GITHUB_USER
    export GITOPS_REPO
    export GITHUB_REPO

    #############################################
    # Save selected repository
    #############################################

    if [[ -f "${ROOT_DIR}/config/defaults.env" ]]; then

        sed -i '/^GITHUB_REPO=/d' \
            "${ROOT_DIR}/config/defaults.env"

        # Make sure the file ends with a newline before appending.
        if [[ -s "${ROOT_DIR}/config/defaults.env" ]]; then
            LAST_BYTE="$(tail -c 1 "${ROOT_DIR}/config/defaults.env" | od -An -t x1 | tr -d ' ')"

            if [[ "${LAST_BYTE}" != "0a" ]]; then
                printf '\n' >> "${ROOT_DIR}/config/defaults.env"
            fi
        fi

        printf 'GITHUB_REPO="%s"\n' \
            "${GITHUB_REPO}" \
            >> "${ROOT_DIR}/config/defaults.env"

        log_ok "GITHUB_REPO updated to ${GITHUB_REPO}"
    fi
}


#############################################
# SSH KEY
#############################################

generate_argocd_ssh_key() {

    log_info "Checking Argo CD SSH deploy key"

    #############################################
    # SAFETY FALLBACK
    #############################################

    if [[ -z "${GITHUB_USER:-}" || -z "${GITOPS_REPO:-}" ]]; then

        echo
        echo "=========================================================="
        echo "              GITHUB REPOSITORY REQUIRED"
        echo "=========================================================="
        echo

        read -rp "GitHub username: " GITHUB_USER
        read -rp "GitHub repository name: " GITOPS_REPO

        while [[ -z "${GITHUB_USER}" || -z "${GITOPS_REPO}" ]]; do
            log_warn "GitHub username and repository name are required."
            read -rp "GitHub username: " GITHUB_USER
            read -rp "GitHub repository name: " GITOPS_REPO
        done

        GITHUB_REPO="git@github.com:${GITHUB_USER}/${GITOPS_REPO}.git"

        export GITHUB_USER
        export GITOPS_REPO
        export GITHUB_REPO
    fi

    #############################################
    # Repo-specific key
    #############################################

    local KEY_ID

    KEY_ID="${GITHUB_USER}-${GITOPS_REPO}"
    KEY_ID="${KEY_ID//[^[:alnum:]_.-]/_}"

    SSH_KEY_PATH="/etc/kubernetes/argocd/${KEY_ID}_id_ed25519"
    export SSH_KEY_PATH

    mkdir -p "$(dirname "${SSH_KEY_PATH}")"

    #############################################
    # Generate key
    #############################################

    if [[ ! -f "${SSH_KEY_PATH}" ]]; then

        ssh-keygen \
            -t ed25519 \
            -N "" \
            -f "${SSH_KEY_PATH}" \
            -C "argocd@${GITHUB_USER}/${GITOPS_REPO}"

        chmod 600 "${SSH_KEY_PATH}"

        log_ok "Argo CD SSH key generated."

    else

        chmod 600 "${SSH_KEY_PATH}"

        log_ok "Argo CD SSH key already exists."
    fi

    #############################################
    # Verify public key
    #############################################

    if [[ ! -f "${SSH_KEY_PATH}.pub" ]]; then
        log_error "Missing public key: ${SSH_KEY_PATH}.pub"
        return 1
    fi

    #############################################
    # Show deploy key
    #############################################

    echo
    echo "=========================================================="
    echo "             ADD THIS DEPLOY KEY TO GITHUB"
    echo "=========================================================="
    echo
    echo "Repository:"
    echo "  ${GITHUB_REPO}"
    echo
    echo "Add deploy key here:"
    echo "  https://github.com/${GITHUB_USER}/${GITOPS_REPO}/settings/keys"
    echo
    echo "Enable:"
    echo "  ✓ Allow write access"
    echo
    echo "Public key:"
    echo
    cat "${SSH_KEY_PATH}.pub"
    echo
    echo "=========================================================="
    echo

    read -rp "Press ENTER after adding the deploy key to GitHub..."
}

#############################################
# VERIFY GITHUB REPOSITORY ACCESS
#############################################

verify_argocd_github_access() {

    log_info "Verifying GitHub access to ${GITHUB_REPO}..."

    [[ -n "${GITHUB_REPO:-}" ]] || \
        die "GITHUB_REPO missing"

    [[ -n "${SSH_KEY_PATH:-}" ]] || \
        die "SSH_KEY_PATH missing"

    while true; do

        local OUTPUT

        if OUTPUT="$(
            GIT_SSH_COMMAND="ssh \
-o BatchMode=yes \
-o StrictHostKeyChecking=accept-new \
-o IdentitiesOnly=yes \
-i ${SSH_KEY_PATH}" \
            git ls-remote "${GITHUB_REPO}" HEAD 2>&1
        )"; then

            log_ok "GitHub repository access verified."

            return 0
        fi

        echo
        echo "================================================="
        echo " GitHub repository access failed"
        echo "================================================="
        echo
        echo "Repository:"
        echo "  ${GITHUB_REPO}"
        echo
        echo "Make sure you have:"
        echo "  1. Added this public key as a Deploy Key"
        echo "  2. Added it to THIS repository"
        echo "  3. Enabled 'Allow write access'"
        echo "  4. Saved the Deploy Key"
        echo
        echo "Current response:"
        echo
        echo "${OUTPUT}"
        echo

        read -rp "Press ENTER to retry..."
    done
}


#############################################
# ARGO CD REPOSITORY
#############################################

configure_argocd_repository() {

    log_info "Configuring Argo CD repository..."

    [[ -n "${GITHUB_REPO:-}" ]] || \
        die "GITHUB_REPO missing"

    [[ -n "${SSH_KEY_PATH:-}" ]] || \
        die "SSH_KEY_PATH missing"

    local REPO_URL="${GITHUB_REPO}"

    #############################################
    # Normalize to SSH URL
    #############################################

    if [[ "${REPO_URL}" == https://github.com/* ]]; then

        REPO_URL="${REPO_URL#https://github.com/}"
        REPO_URL="git@github.com:${REPO_URL}"

    fi

    REPO_URL="${REPO_URL%.git}.git"

    #############################################
    # Remove old repository secret
    #############################################

    kubectl delete secret bootstrap-repository \
        -n argocd \
        --ignore-not-found

    #############################################
    # Create repository secret
    #############################################

    kubectl create secret generic bootstrap-repository \
        -n argocd \
        --from-literal=type=git \
        --from-literal=url="${REPO_URL}" \
        --from-file=sshPrivateKey="${SSH_KEY_PATH}"

    #############################################
    # Label as Argo CD repository
    #############################################

    kubectl label secret bootstrap-repository \
        -n argocd \
        argocd.argoproj.io/secret-type=repository \
        --overwrite

    #############################################
    # Restart repo server
    #############################################

    kubectl rollout restart deployment argocd-repo-server \
        -n argocd

    kubectl rollout status deployment argocd-repo-server \
        -n argocd \
        --timeout=120s

    log_ok "Argo CD repository configured."
}


#############################################
# SYNC GITOPS REPOSITORY
#############################################

sync_gitops_repo() {

    log_info "Syncing manifests to GitOps repository..."

    #############################################
    # Source directory
    #############################################

    local SRC_DIR

    SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

    #############################################
    # Validate variables
    #############################################

    [[ -n "${GITHUB_REPO:-}" ]] || \
        die "GITHUB_REPO missing"

    [[ -n "${SSH_KEY_PATH:-}" ]] || \
        die "SSH_KEY_PATH missing"

    #############################################
    # Repository URL
    #############################################

    local SSH_REPO_URL="${GITHUB_REPO}"

    #############################################
    # Normalize URL
    #############################################

    if [[ "${SSH_REPO_URL}" == https://github.com/* ]]; then

        SSH_REPO_URL="${SSH_REPO_URL#https://github.com/}"
        SSH_REPO_URL="git@github.com:${SSH_REPO_URL}"

    fi

    SSH_REPO_URL="${SSH_REPO_URL%.git}.git"

    export GITHUB_REPO="${SSH_REPO_URL}"

    #############################################
    # Extract repository name
    #############################################

    local GITOPS_REPO

    GITOPS_REPO="${SSH_REPO_URL##*/}"
    GITOPS_REPO="${GITOPS_REPO%.git}"

    #############################################
    # Real user
    #############################################

    local REAL_USER
    local REAL_HOME

    REAL_USER="${SUDO_USER:-$USER}"
    REAL_HOME="$(getent passwd "${REAL_USER}" | cut -d: -f6)"

    #############################################
    # GitOps directory
    #############################################

    GITOPS_DIR="${REAL_HOME}/${GITOPS_REPO}"
    export GITOPS_DIR

    #############################################
    # Prevent source == destination
    #############################################

    if [[ "${SRC_DIR}" == "${GITOPS_DIR}" ]]; then

        log_error "Source repo and GitOps repo are the same directory."

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
    # Verify repository access
    #############################################

    log_info "Verifying access to ${SSH_REPO_URL}..."

    if ! GIT_SSH_COMMAND="${GIT_SSH_COMMAND}" \
        git ls-remote "${SSH_REPO_URL}" HEAD >/dev/null 2>&1; then

        log_error "Cannot access GitHub repository:"
        log_error "  ${SSH_REPO_URL}"
        log_error "Verify that the deploy key was added to this repository."

        return 1
    fi

    log_ok "GitHub repository access verified."

    #############################################
    # Clone repository
    #############################################

    if [[ ! -d "${GITOPS_DIR}/.git" ]]; then

        if [[ -e "${GITOPS_DIR}" ]]; then

            log_error "GitOps directory already exists but is not a Git repository:"
            log_error "  ${GITOPS_DIR}"

            return 1
        fi

        log_info "Cloning GitOps repository..."

        if ! GIT_SSH_COMMAND="${GIT_SSH_COMMAND}" \
            git clone \
                "${SSH_REPO_URL}" \
                "${GITOPS_DIR}"; then

            log_error "Failed to clone GitOps repository:"
            log_error "  ${SSH_REPO_URL}"

            return 1
        fi
    fi

    #############################################
    # Configure remote
    #############################################

    git -C "${GITOPS_DIR}" \
        remote set-url origin "${SSH_REPO_URL}"

    #############################################
    # Fetch
    #############################################

    log_info "Fetching GitOps repository..."

    if ! GIT_SSH_COMMAND="${GIT_SSH_COMMAND}" \
        git -C "${GITOPS_DIR}" fetch origin; then

        log_error "Failed to fetch GitOps repository."

        return 1
    fi

    #############################################
    # Git branch
    #############################################

    local GITOPS_BRANCH

    GITOPS_BRANCH="${GIT_BRANCH:-main}"

    # Protect against a malformed defaults.env where GITHUB_REPO
    # was accidentally appended to the GIT_BRANCH value.
    if [[ "${GITOPS_BRANCH}" == *"GITHUB_REPO="* ]]; then
        log_warn "Detected malformed GIT_BRANCH value:"
        log_warn "  ${GITOPS_BRANCH}"
        log_warn "Falling back to branch 'main'."

        GITOPS_BRANCH="main"
        export GIT_BRANCH="main"
    fi

    #############################################
    # Ensure local branch exists
    #############################################

    git -C "${GITOPS_DIR}" checkout -B "${GITOPS_BRANCH}"

    #############################################
    # Reset to remote branch if it exists
    #############################################

    if git -C "${GITOPS_DIR}" \
        show-ref --verify --quiet \
        "refs/remotes/origin/${GITOPS_BRANCH}"; then

        git -C "${GITOPS_DIR}" reset --hard \
            "origin/${GITOPS_BRANCH}"

    else

        log_warn "Remote branch origin/${GITOPS_BRANCH} does not exist yet."

    fi

    #############################################
    # Copy manifests
    #############################################

    log_info "Copying manifests..."

    rsync -av \
        --delete \
        --exclude ".git" \
        --exclude ".github" \
        --exclude "generated" \
        --exclude "scripts" \
        --exclude "*.sh" \
        --exclude "secrets/" \
        --exclude "cluster-info.yaml" \
        "${SRC_DIR}/" \
        "${GITOPS_DIR}/"

    #############################################
    # Replace template variables
    #############################################

    log_info "Updating GitOps manifests..."

    find "${GITOPS_DIR}" \
        -type f \
        \( -name "*.yaml" -o -name "*.yml" \) \
        -exec sed -i \
            -e "s|REPLACE_REPO_URL|${SSH_REPO_URL}|g" \
            -e "s|REPLACE_BRANCH|${GITOPS_BRANCH}|g" \
            {} +

    #############################################
    # Render ingress hostnames
    #############################################

    render_gitops_ingresses

    log_ok "GitOps manifests updated."

    #############################################
    # Git identity
    #############################################

    git -C "${GITOPS_DIR}" config user.name \
        "${GIT_AUTHOR_NAME:-Homelab Installer}"

    git -C "${GITOPS_DIR}" config user.email \
        "${GIT_AUTHOR_EMAIL:-homelab@localhost}"

    #############################################
    # Commit
    #############################################

    git -C "${GITOPS_DIR}" add .

    if git -C "${GITOPS_DIR}" diff --cached --quiet; then

        log_ok "GitOps repository already up-to-date."

        return 0
    fi

    git -C "${GITOPS_DIR}" commit \
        -m "Update Kubernetes manifests"

    #############################################
    # Push
    #############################################

    log_info "Pushing GitOps changes..."

    if ! GIT_SSH_COMMAND="${GIT_SSH_COMMAND}" \
        git -C "${GITOPS_DIR}" push \
            -u origin "${GITOPS_BRANCH}"; then

        log_error "Failed to push GitOps repository."
        log_error "Make sure the deploy key has 'Allow write access' enabled."

        return 1
    fi

    log_ok "GitOps repository updated."
}

#############################################
# GITOPS BOOTSTRAP
#############################################

bootstrap_gitops() {

    log_info "Bootstrapping GitOps"

    #############################################
    # ASK USER FOR GITHUB INFORMATION FIRST
    #############################################

    echo
    echo "=========================================================="
    echo "              GITOPS REPOSITORY CONFIGURATION"
    echo "=========================================================="
    echo

    while true; do

        read -rp "GitHub username: " GITHUB_USER

        if [[ -z "${GITHUB_USER}" ]]; then
            log_warn "GitHub username cannot be empty."
            continue
        fi

        read -rp "GitHub repository name: " GITOPS_REPO

        if [[ -z "${GITOPS_REPO}" ]]; then
            log_warn "GitHub repository name cannot be empty."
            continue
        fi

        GITHUB_REPO="git@github.com:${GITHUB_USER}/${GITOPS_REPO}.git"

        echo
        echo "Using GitHub repository:"
        echo
        echo "  ${GITHUB_REPO}"
        echo

        read -rp "Is this correct? [Y/n]: " CONFIRM
        CONFIRM="${CONFIRM:-Y}"

        case "${CONFIRM}" in

            Y|y)
                break
                ;;

            N|n)
                echo
                echo "Please enter the repository information again."
                echo
                ;;

            *)
                echo "Please answer Y or N."
                ;;

        esac
    done

    #############################################
    # SET REPOSITORY VARIABLES
    #############################################

    BOOTSTRAP_REPO="${GITHUB_REPO}"

    export GITHUB_USER
    export GITOPS_REPO
    export GITHUB_REPO
    export BOOTSTRAP_REPO

    log_ok "GitHub repository selected:"
    log_ok "${GITHUB_REPO}"

    #############################################
    # SAVE REPOSITORY
    #############################################

    if [[ -f "${ROOT_DIR}/config/defaults.env" ]]; then

        # Remove old repository values.
        sed -i '/^GITHUB_REPO=/d' \
            "${ROOT_DIR}/config/defaults.env"

        sed -i '/^BOOTSTRAP_REPO=/d' \
            "${ROOT_DIR}/config/defaults.env"

        # Make absolutely sure the file ends with a newline.
        if [[ -s "${ROOT_DIR}/config/defaults.env" ]]; then

            LAST_BYTE="$(
                tail -c 1 "${ROOT_DIR}/config/defaults.env" |
                    od -An -t x1 |
                    tr -d '[:space:]'
            )"

            if [[ "${LAST_BYTE}" != "0a" ]]; then
                printf '\n' >> "${ROOT_DIR}/config/defaults.env"
            fi
        fi

        # Save the selected GitHub repository.
        printf 'GITHUB_REPO="%s"\n' \
            "${GITHUB_REPO}" \
            >> "${ROOT_DIR}/config/defaults.env"

        # Bootstrap repository is the same repository selected by the user.
        printf 'BOOTSTRAP_REPO="%s"\n' \
            "${BOOTSTRAP_REPO}" \
            >> "${ROOT_DIR}/config/defaults.env"

        log_ok "GitHub repository saved to config/defaults.env"
    fi

    #############################################
    # GENERATE DEPLOY KEY
    #############################################

    generate_argocd_ssh_key

    #############################################
    # VERIFY DEPLOY KEY
    #############################################

    verify_argocd_github_access

    #############################################
    # SYNC GITOPS REPOSITORY
    #############################################

    sync_gitops_repo

    #############################################
    # CONFIGURE ARGO CD REPOSITORY
    #############################################

    configure_argocd_repository

    #############################################
    # RESTART REPO SERVER
    #############################################

    log_info "Restarting Argo CD repo-server..."

    kubectl -n argocd rollout restart \
        deployment argocd-repo-server

    kubectl -n argocd rollout status \
        deployment argocd-repo-server \
        --timeout=180s

    log_ok "Argo CD repo-server restarted."

    #############################################
    # INSTALL PROJECT
    #############################################

    kubectl apply \
        -f "${ROOT_DIR}/bootstrap/projects/default-project.yaml"

    #############################################
    # GENERATE ROOT APPLICATION
    #############################################

    mkdir -p "${ROOT_DIR}/generated"

    sed \
        -e "s|REPLACE_REPO_URL|${GITHUB_REPO}|g" \
        -e "s|REPLACE_BRANCH|${GIT_BRANCH:-main}|g" \
        "${ROOT_DIR}/bootstrap/root-app.yaml" \
        > "${ROOT_DIR}/generated/root-app.yaml"

    #############################################
    # APPLY ROOT APPLICATION
    #############################################

    kubectl apply \
        -f "${ROOT_DIR}/generated/root-app.yaml"

    #############################################
    # FORCE INITIAL REFRESH
    #############################################

    kubectl annotate application homelab-root \
        -n argocd \
        argocd.argoproj.io/refresh=hard \
        --overwrite

    log_ok "GitOps bootstrap complete."
}

#############################################
# ARGO CD REPLICA SCALER
#############################################

install_argocd_replica_scaler() {

    log_info "Installing Argo CD replica scaler..."

    cat >/usr/local/sbin/argocd-replica-scaler.sh <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

export KUBECONFIG=/etc/kubernetes/admin.conf

READY_NODES=$(
    kubectl get nodes --no-headers 2>/dev/null |
        awk '$2 == "Ready" && $0 !~ /SchedulingDisabled/ {count++} END {print count+0}'
)

if (( READY_NODES >= 2 )); then
    DESIRED_REPLICAS=2
else
    DESIRED_REPLICAS=1
fi

for deployment in \
    argocd-server \
    argocd-repo-server \
    argocd-applicationset-controller
do

    if kubectl -n argocd get deployment "${deployment}" >/dev/null 2>&1; then

        CURRENT_REPLICAS=$(
            kubectl -n argocd \
                get deployment "${deployment}" \
                -o jsonpath='{.spec.replicas}'
        )

        if [[ "${CURRENT_REPLICAS}" != "${DESIRED_REPLICAS}" ]]; then

            logger -t argocd-replica-scaler \
                "Ready nodes=${READY_NODES}; scaling ${deployment} ${CURRENT_REPLICAS} -> ${DESIRED_REPLICAS}"

            kubectl -n argocd scale deployment "${deployment}" \
                --replicas="${DESIRED_REPLICAS}"
        fi
    fi
done
EOF

    chmod +x /usr/local/sbin/argocd-replica-scaler.sh

    cat >/etc/systemd/system/argocd-replica-scaler.service <<'EOF'
[Unit]
Description=Argo CD Replica Scaler
After=network-online.target kubelet.service
Wants=network-online.target
Requires=kubelet.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/argocd-replica-scaler.sh
EOF

    cat >/etc/systemd/system/argocd-replica-scaler.timer <<'EOF'
[Unit]
Description=Automatically scale Argo CD replicas based on Ready nodes

[Timer]
OnBootSec=60s
OnUnitActiveSec=60s
Unit=argocd-replica-scaler.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now argocd-replica-scaler.timer

    log_ok "Argo CD replica scaler enabled."
}