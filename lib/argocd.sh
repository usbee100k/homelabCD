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
#
# ensure_gitops_repo asks for the GitOps repository ONCE per bootstrap and
# saves it (config/defaults.env and config/cluster.yaml). Every later step
# calls it and gets the saved answer without asking again. A repository
# saved by an earlier run is reused; edit config/cluster.yaml (github.repo)
# to change it.
#############################################

ensure_gitops_repo() {

    # Known already: this run, or saved by an earlier one.
    if [[ -z "${GITHUB_USER:-}" || -z "${GITOPS_REPO:-}" ]] && [[ -n "${GITHUB_REPO:-}" ]]; then
        local path="${GITHUB_REPO#*github.com}"
        path="${path#[:/]}"
        path="${path%.git}"
        GITHUB_USER="${path%%/*}"
        GITOPS_REPO="${path##*/}"
    fi

    if [[ -n "${GITHUB_USER:-}" && -n "${GITOPS_REPO:-}" ]]; then
        GITHUB_REPO="git@github.com:${GITHUB_USER}/${GITOPS_REPO}.git"
        export GITHUB_USER GITOPS_REPO GITHUB_REPO
        return 0
    fi

    # Same layout as the deploy key screen: label, then the value
    # indented underneath (answers are typed on the indented line).
    echo
    echo "=========================================================="
    echo "              GITOPS REPOSITORY FOR THIS CLUSTER"
    echo "=========================================================="
    echo
    echo "Argo CD deploys everything from this GitHub repository."
    echo "Create it first (empty, private is fine)."
    echo
    echo "Example:"
    echo "  https://github.com/your-username/your-repository"
    echo "  GitHub username  ->  your-username"
    echo "  Repository name  ->  your-repository"
    echo

    local CONFIRM

    while true; do

        echo "GitHub username:"
        read -rp "  " GITHUB_USER
        GITHUB_USER="${GITHUB_USER//[[:space:]]/}"

        if [[ -z "${GITHUB_USER}" ]]; then
            log_warn "GitHub username cannot be empty."
            echo
            continue
        fi

        echo
        echo "Repository name:"
        read -rp "  " GITOPS_REPO
        GITOPS_REPO="${GITOPS_REPO//[[:space:]]/}"
        GITOPS_REPO="${GITOPS_REPO%.git}"

        if [[ -z "${GITOPS_REPO}" ]]; then
            log_warn "Repository name cannot be empty."
            echo
            continue
        fi

        GITHUB_REPO="git@github.com:${GITHUB_USER}/${GITOPS_REPO}.git"

        echo
        echo "Repository:"
        echo "  ${GITHUB_REPO}"
        echo
        echo "On GitHub:"
        echo "  https://github.com/${GITHUB_USER}/${GITOPS_REPO}"
        echo
        echo "=========================================================="
        echo

        read -rp "Is this correct? [Y/n]: " CONFIRM
        CONFIRM="${CONFIRM:-Y}"

        case "${CONFIRM}" in
            Y|y) break ;;
            N|n) echo; echo "Enter the repository again:"; echo ;;
            *) echo "Please answer Y or N."; echo ;;
        esac
    done

    BOOTSTRAP_REPO="${GITHUB_REPO}"
    export GITHUB_USER GITOPS_REPO GITHUB_REPO BOOTSTRAP_REPO

    log_ok "GitHub repository selected: ${GITHUB_REPO}"

    # Save it so later steps (and later runs) don't ask again.
    if [[ -f "${ROOT_DIR}/config/defaults.env" ]]; then

        sed -i '/^GITHUB_REPO=/d; /^BOOTSTRAP_REPO=/d' "${ROOT_DIR}/config/defaults.env"

        # Make sure the file ends with a newline before appending.
        if [[ -s "${ROOT_DIR}/config/defaults.env" ]] &&
            [[ "$(tail -c 1 "${ROOT_DIR}/config/defaults.env" | od -An -t x1 | tr -d '[:space:]')" != "0a" ]]; then
            printf '\n' >> "${ROOT_DIR}/config/defaults.env"
        fi

        printf 'GITHUB_REPO="%s"\nBOOTSTRAP_REPO="%s"\n' "${GITHUB_REPO}" "${BOOTSTRAP_REPO}" \
            >> "${ROOT_DIR}/config/defaults.env"
    fi

    if declare -F save_config >/dev/null; then
        save_config # github.repo in config/cluster.yaml (used by VPN / Compose import)
    fi
}

# Kept for compatibility with older callers.
configure_gitops_repository() {
    ensure_gitops_repo
}


#############################################
# SSH KEY
#############################################

generate_argocd_ssh_key() {

    log_info "Checking Argo CD SSH deploy key"

    ensure_gitops_repo

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
    # Already added to GitHub? Then don't ask again.
    #############################################

    if GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -o ConnectTimeout=10 -i ${SSH_KEY_PATH}" \
        git ls-remote "${GITHUB_REPO}" HEAD >/dev/null 2>&1; then
        log_ok "Deploy key already has access to ${GITHUB_REPO}."
        return 0
    fi

    #############################################
    # Show deploy key
    #############################################

    # Same layout as the repository screen: label, then the value
    # indented underneath.
    echo
    echo "=========================================================="
    echo "              ADD THIS DEPLOY KEY TO GITHUB"
    echo "=========================================================="
    echo
    echo "Argo CD uses this key to read and update the repository."
    echo "Add it once; KubesTUI can copy it for you (Ctrl+K)."
    echo
    echo "Repository:"
    echo "  ${GITHUB_REPO}"
    echo
    echo "Add deploy key here:"
    echo "  https://github.com/${GITHUB_USER}/${GITOPS_REPO}/settings/keys"
    echo
    echo "Title:"
    echo "  argocd-$(hostname -s)"
    echo
    echo "Enable:"
    echo "  ✓ Allow write access"
    echo
    echo "Public key:"
    echo "  $(cat "${SSH_KEY_PATH}.pub")"
    echo
    echo "=========================================================="
    echo

    # Ctrl+C here is almost always an attempt to copy the key, so one
    # press doesn't end the bootstrap; a second within 3 seconds does.
    local last_int=-10
    trap 'echo
        if (( SECONDS - last_int <= 3 )); then trap - INT; kill -INT $$; fi
        last_int=${SECONDS}
        log_warn "Ctrl+C does not copy here: select the key with the mouse, or press Ctrl+K in KubesTUI."
        log_warn "Press Ctrl+C again within 3 seconds to cancel the bootstrap."' INT

    # Retry only when the read was interrupted (status > 128), not on EOF.
    local rc
    while true; do
        rc=0
        read -rp "Press ENTER after adding the deploy key to GitHub..." || rc=$?
        (( rc > 128 )) || break
    done

    trap - INT
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
# GITOPS BOOTSTRAP
#############################################

bootstrap_gitops() {

    log_info "Bootstrapping GitOps"

    # Asked once earlier in the bootstrap; reused here.
    ensure_gitops_repo

    BOOTSTRAP_REPO="${GITHUB_REPO}"
    export BOOTSTRAP_REPO

    log_ok "GitHub repository: ${GITHUB_REPO}"

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

# The GitOps repository itself (sync_gitops_repo, gitops_prepare,
# gitops_commit_push, template updates) is in lib/gitops.sh.
