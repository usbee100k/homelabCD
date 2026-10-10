#!/usr/bin/env bash

#############################################
# GITOPS REPOSITORY
#############################################
#
# Argo CD deploys the cluster from the user's GitOps repository. After the
# first bootstrap that repository is THEIRS: they can edit any file on
# GitHub, or in the clone homelabCD keeps on the bootstrap node
# (~/<repo>, owned by them, `git push` works there), and homelabCD never
# overwrites those edits.
#
# How template updates still reach the repository:
#
#   The branch homelabcd-templates holds exactly what homelabCD generated,
#   with the values from the saved configuration (config/cluster.yaml,
#   config/ingress.yaml) filled in. An update renders the new templates
#   with the SAME saved values, commits them on that branch and merges it
#   into the branch Argo CD watches. Git then brings in only homelabCD's
#   own changes; the user's edits are kept, and a line both sides changed
#   stops the update so the user can choose.
#
# Entry points:
#   sync_gitops_repo            bootstrap: clone, then apply all templates
#   gitops_prepare              other operations: bring the clone up to date
#   gitops_apply_templates      merge freshly rendered templates (all, or
#                               only the given paths)
#   gitops_commit_push "msg"    commit the clone's changes and push
#   update_gitops_templates     "Update GitOps Templates" (--run gitops-update)
#############################################

GITOPS_TEMPLATE_BRANCH="homelabcd-templates"

# git on the GitOps clone: as root (with the deploy key) on a clone the
# user owns, and with homelabCD as the author of its own commits.
gitops_git() {
    GIT_SSH_COMMAND="${GITOPS_SSH}" git \
        -c safe.directory="${GITOPS_DIR}" \
        -c user.name="${GIT_AUTHOR_NAME:-Homelab Installer}" \
        -c user.email="${GIT_AUTHOR_EMAIL:-homelab@localhost}" \
        -C "${GITOPS_DIR}" "$@"
}

gitops_has_ref() {
    gitops_git rev-parse -q --verify "$1^{commit}" >/dev/null 2>&1
}

# The clone belongs to the user, so they can edit it without sudo.
gitops_fix_ownership() {
    if [[ -n "${GITOPS_DIR:-}" && -d "${GITOPS_DIR}" && "${REAL_USER:-root}" != root ]]; then
        chown -R "${REAL_USER}:" "${GITOPS_DIR}"
    fi
}

# Lets the user push from the clone: a copy of the deploy key they can
# read, used by `git push` in that clone only.
gitops_user_access() {

    if [[ "${REAL_USER}" == root ]]; then
        gitops_git config core.sshCommand "ssh -i ${SSH_KEY_PATH} -o IdentitiesOnly=yes"
        return 0
    fi

    local group key
    group="$(id -gn "${REAL_USER}")"
    key="${REAL_HOME}/.ssh/homelabcd-gitops-${GITOPS_REPO}"

    install -d -m 700 -o "${REAL_USER}" -g "${group}" "${REAL_HOME}/.ssh"
    install -m 600 -o "${REAL_USER}" -g "${group}" "${SSH_KEY_PATH}" "${key}"

    gitops_git config core.sshCommand \
        "ssh -i ${key} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

    # Git won't commit without a name. If the user hasn't set one, use
    # theirs for this folder (older versions set "Homelab Installer").
    local name
    name="$(gitops_git config --local user.name || true)"

    if ! git config -f "${REAL_HOME}/.gitconfig" user.name >/dev/null 2>&1 &&
        [[ -z "${name}" || "${name}" == "Homelab Installer" ]]; then
        gitops_git config --local user.name "${REAL_USER}"
        gitops_git config --local user.email "${REAL_USER}@$(hostname -s)"
    fi
}


#############################################
# CLONE / UPDATE THE LOCAL CHECKOUT
#############################################
#
# Sets GITOPS_DIR, GITOPS_BRANCH, GITOPS_SSH. Never throws away the
# user's work: uncommitted edits or commits that diverged from GitHub
# stop here with instructions instead.
#############################################

gitops_checkout() {

    [[ -n "${GITHUB_REPO:-}" ]] || die "GITHUB_REPO missing"
    [[ -n "${SSH_KEY_PATH:-}" ]] || die "SSH_KEY_PATH missing"

    local url="${GITHUB_REPO}"

    if [[ "${url}" == https://github.com/* ]]; then
        url="git@github.com:${url#https://github.com/}"
    fi

    url="${url%.git}.git"
    export GITHUB_REPO="${url}"

    GITOPS_REPO="${url##*/}"
    GITOPS_REPO="${GITOPS_REPO%.git}"

    REAL_USER="${SUDO_USER:-$USER}"
    REAL_HOME="$(getent passwd "${REAL_USER}" | cut -d: -f6)"

    GITOPS_DIR="${REAL_HOME}/${GITOPS_REPO}"
    export GITOPS_DIR

    if [[ "${ROOT_DIR}" == "${GITOPS_DIR}" ]]; then
        log_error "Source repo and GitOps repo are the same directory."
        return 1
    fi

    GITOPS_SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o IdentitiesOnly=yes -i ${SSH_KEY_PATH}"

    GITOPS_BRANCH="${GIT_BRANCH:-main}"

    # Protect against a malformed defaults.env where GITHUB_REPO
    # was accidentally appended to the GIT_BRANCH value.
    if [[ "${GITOPS_BRANCH}" == *"GITHUB_REPO="* ]]; then
        log_warn "Detected malformed GIT_BRANCH value: ${GITOPS_BRANCH}"
        log_warn "Falling back to branch 'main'."
        GITOPS_BRANCH="main"
        export GIT_BRANCH="main"
    fi

    #############################################
    # Access and clone
    #############################################

    log_info "Verifying access to ${url}..."

    if ! GIT_SSH_COMMAND="${GITOPS_SSH}" git ls-remote "${url}" HEAD >/dev/null 2>&1; then
        log_error "Cannot access GitHub repository:"
        log_error "  ${url}"
        log_error "Verify that the deploy key was added to this repository."
        return 1
    fi

    log_ok "GitHub repository access verified."

    if [[ ! -d "${GITOPS_DIR}/.git" ]]; then

        if [[ -e "${GITOPS_DIR}" ]]; then
            log_error "GitOps directory already exists but is not a Git repository:"
            log_error "  ${GITOPS_DIR}"
            return 1
        fi

        log_info "Cloning GitOps repository into ${GITOPS_DIR}..."

        if ! GIT_SSH_COMMAND="${GITOPS_SSH}" git clone -q "${url}" "${GITOPS_DIR}"; then
            log_error "Failed to clone GitOps repository: ${url}"
            return 1
        fi
    fi

    gitops_git remote set-url origin "${url}"

    #############################################
    # Never overwrite the user's work
    #############################################

    if [[ -n "$(gitops_git status --porcelain --untracked-files=no)" ]]; then
        gitops_fix_ownership
        log_error "The GitOps folder has changes that aren't committed yet:"
        gitops_git status --short --untracked-files=no
        echo
        echo "  Commit and push them first, then run this again:"
        echo "    cd ${GITOPS_DIR}"
        echo "    git add -A && git commit -m \"My changes\" && git push"
        echo "  (or throw them away: git checkout -- .)"
        return 1
    fi

    log_info "Fetching GitOps repository..."

    if ! gitops_git fetch -q origin; then
        log_error "Failed to fetch GitOps repository."
        return 1
    fi

    #############################################
    # The branch Argo CD watches
    #############################################

    local b="${GITOPS_BRANCH}"

    if gitops_has_ref "refs/heads/${b}"; then
        [[ "$(gitops_git symbolic-ref --short -q HEAD || true)" == "${b}" ]] ||
            gitops_git checkout -q "${b}"
    elif gitops_has_ref "refs/remotes/origin/${b}"; then
        gitops_git checkout -q -b "${b}" --track "origin/${b}"
    elif gitops_has_ref HEAD; then
        gitops_git checkout -q -b "${b}"
    else
        gitops_git symbolic-ref HEAD "refs/heads/${b}" # empty repository
    fi

    # Take edits made on GitHub; keep commits made here that aren't pushed yet.
    if gitops_has_ref "refs/remotes/origin/${b}" &&
        ! gitops_git merge -q --ff-only "origin/${b}" >/dev/null 2>&1; then
        gitops_fix_ownership
        log_error "This folder and GitHub both have new commits on ${b}:"
        log_error "  ${GITOPS_DIR}"
        echo "  Combine them first, then run this again:"
        echo "    cd ${GITOPS_DIR} && git pull && git push"
        return 1
    fi

    #############################################
    # Template branch: GitHub's copy is the record
    #############################################

    local t="${GITOPS_TEMPLATE_BRANCH}"

    if gitops_has_ref "refs/remotes/origin/${t}"; then
        if ! gitops_has_ref "refs/heads/${t}" ||
            gitops_git merge-base --is-ancestor "refs/heads/${t}" "refs/remotes/origin/${t}"; then
            gitops_git update-ref "refs/heads/${t}" "refs/remotes/origin/${t}"
        fi
    fi

    gitops_user_access

    # A repository set up before homelabCD tracked its templates.
    if ! gitops_has_ref "refs/heads/${t}" &&
        gitops_has_ref "refs/heads/${b}" &&
        gitops_git cat-file -e "refs/heads/${b}:bootstrap/root-app.yaml" 2>/dev/null; then
        gitops_start_tracking || return 1
    fi

    gitops_fix_ownership

    log_ok "GitOps repository up to date: ${GITOPS_DIR}"
}


#############################################
# RENDER TEMPLATES
#############################################
#
# Writes homelabCD's GitOps files to $1 with the saved values filled in.
# The values always come from the saved configuration, never from the
# repository, so rendering a newer homelabCD fills in the same values
# (domain, ACME email, MetalLB pool, subdomains, VPN...) as last time and
# only the template changes differ. Missing values stop it: an empty value
# would otherwise reach the repository as a "change".
#############################################

gitops_render_templates() {

    local out="$1"

    local missing=()

    [[ -n "${BASE_DOMAIN:-}" ]] || missing+=("domains.base")
    [[ -n "${ACME_EMAIL:-}" ]] || missing+=("domains.acmeEmail")
    [[ -n "${METALLB_RANGE:-}" ]] || missing+=("network.metallbRange")

    if [[ "${VPN_ENABLED:-false}" == "true" ]]; then
        [[ -n "${VPN_ENDPOINT:-}" ]] || missing+=("vpn.endpoint")
        [[ -n "${VPN_LB_IP:-}" ]] || missing+=("vpn.ip")
        [[ -n "${VPN_ALLOWED_IPS:-}" ]] || missing+=("vpn.allowedIPs")
    fi

    if (( ${#missing[@]} > 0 )); then
        log_error "Saved settings missing from config/cluster.yaml: ${missing[*]}"
        log_error "Nothing was changed. Fill them in there and run this again."
        return 1
    fi

    rsync -a \
        --delete \
        --exclude ".git" \
        --exclude ".github" \
        --exclude ".src" \
        --exclude "bin" \
        --exclude "logs" \
        --exclude "generated" \
        --exclude "scripts" \
        --exclude "*.sh" \
        --exclude "secrets/" \
        --exclude "cluster-info.yaml" \
        --exclude "apps/applications/" \
        "${ROOT_DIR}/" \
        "${out}/"

    # apps/applications holds apps imported from Docker Compose (KubesTUI);
    # they live only in the GitOps repo. An empty list keeps the
    # "applications" Argo CD app valid until the first import.
    mkdir -p "${out}/apps/applications"
    cat > "${out}/apps/applications/kustomization.yaml" <<'KUSTOMIZATION'
# Apps imported from Docker Compose (KubesTUI). Managed by the importer.
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
KUSTOMIZATION

    find "${out}" \
        -type f \
        \( -name "*.yaml" -o -name "*.yml" \) \
        -exec sed -i \
            -e "s|REPLACE_REPO_URL|${GITHUB_REPO}|g" \
            -e "s|REPLACE_BRANCH|${GITOPS_BRANCH}|g" \
            -e "s|REPLACE_ACME_EMAIL|${ACME_EMAIL}|g" \
            -e "s|REPLACE_METALLB_RANGE|${METALLB_RANGE}|g" \
            -e "s|REPLACE_BASE_DOMAIN|${BASE_DOMAIN}|g" \
            -e "s|REPLACE_VPN_ENDPOINT|${VPN_ENDPOINT:-}|g" \
            -e "s|REPLACE_VPN_PORT|${VPN_PORT:-51820}|g" \
            -e "s|REPLACE_VPN_LB_IP|${VPN_LB_IP:-}|g" \
            -e "s|REPLACE_VPN_ALLOWED_IPS|${VPN_ALLOWED_IPS:-}|g" \
            {} +

    # The VPN is optional: without it, wg-easy is left out entirely.
    if [[ "${VPN_ENABLED:-false}" != "true" ]]; then
        sed -i '/wg-easy\/app.yaml/d' \
            "${out}/apps/infrastructure/kustomization.yaml"
    fi

    render_gitops_ingresses "${out}" >/dev/null

    # Anything still unfilled would reach the cluster as a literal
    # placeholder: stop before it gets to the repository.
    local leftover
    # (Comments may mention placeholders; only real values count.)
    leftover="$(grep -rlE '^[^#]*(REPLACE_[A-Z_]+|__HOSTNAME__)' "${out}" \
        --include='*.yaml' --include='*.yml' || true)"

    if [[ -n "${leftover}" ]]; then
        log_error "These templates still have unfilled values:"
        sed "s|^${out}/|  |" <<<"${leftover}"
        log_error "Nothing was changed. Check config/cluster.yaml and config/ingress.yaml."
        return 1
    fi
}

# Stages directory $1 (all of it, or only paths $3...) on top of the
# template branch, using a separate index so the checkout isn't touched.
# Prints the resulting tree.
gitops_template_tree() {

    local dir="$1" base="$2"
    shift 2

    local idx
    idx="$(mktemp -u)"

    if [[ -n "${base}" ]]; then
        GIT_INDEX_FILE="${idx}" gitops_git read-tree "${base}"
    else
        GIT_INDEX_FILE="${idx}" gitops_git read-tree --empty
    fi

    local paths=("$@")

    if (( ${#paths[@]} == 0 )); then
        paths=(.)
        # Imported apps belong to the repository, not to the templates.
        [[ -n "${base}" ]] && paths+=(":(exclude)apps/applications")
    fi

    GIT_INDEX_FILE="${idx}" gitops_git --work-tree="${dir}" add -A -- "${paths[@]}"
    GIT_INDEX_FILE="${idx}" gitops_git write-tree

    rm -f "${idx}"
}


#############################################
# START TRACKING (repositories from older homelabCD versions)
#############################################
#
# Records the current templates as the starting point without changing
# any file in the repository: the commit is merged with "-s ours", so
# everything already there (including the user's edits) stays as it is.
# Later updates bring in only what homelabCD changes after this.
#############################################

gitops_start_tracking() {

    local t="${GITOPS_TEMPLATE_BRANCH}" b="${GITOPS_BRANCH}"

    log_info "Starting to track homelabCD templates in your repository (no files change)..."

    local render tree commit
    render="$(mktemp -d)"

    if ! gitops_render_templates "${render}"; then
        rm -rf "${render}"
        return 1
    fi

    tree="$(gitops_template_tree "${render}" "")"
    rm -rf "${render}"

    commit="$(gitops_git commit-tree "${tree}" -p "refs/heads/${b}" \
        -m "homelabCD templates (starting point)")"

    gitops_git update-ref "refs/heads/${t}" "${commit}"
    # --no-ff: the commit is a child of the branch, and a fast-forward
    # would replace the files with the templates.
    gitops_git merge -q --no-ff -s ours --no-edit \
        -m "Start tracking homelabCD templates" "refs/heads/${t}"

    if ! gitops_git push -q origin "${t}" "${b}"; then
        log_error "Failed to push the GitOps repository (does the deploy key allow write access?)"
        return 1
    fi

    log_ok "Template tracking started (branch ${t})."
}


#############################################
# APPLY TEMPLATES
#############################################
#
# gitops_apply_templates "message" [path...]
#
# Renders the templates, commits them on the template branch (only the
# given paths, when any) and merges that into the branch Argo CD watches.
#############################################

gitops_apply_templates() {

    local message="$1"
    shift

    local t="${GITOPS_TEMPLATE_BRANCH}" b="${GITOPS_BRANCH}"
    local has_tmpl=false has_main=false

    gitops_has_ref "refs/heads/${t}" && has_tmpl=true
    gitops_has_ref "refs/heads/${b}" && has_main=true

    log_info "Rendering homelabCD templates with your saved settings..."

    local render tree
    render="$(mktemp -d)"

    if ! gitops_render_templates "${render}"; then
        rm -rf "${render}"
        return 1
    fi

    if [[ "${has_tmpl}" == true ]]; then
        tree="$(gitops_template_tree "${render}" "refs/heads/${t}" "$@")"
    else
        tree="$(gitops_template_tree "${render}" "" "$@")"
    fi

    rm -rf "${render}"

    #############################################
    # Commit on the template branch (if anything changed)
    #############################################

    if [[ "${has_tmpl}" == true && "${tree}" == "$(gitops_git rev-parse "refs/heads/${t}^{tree}")" ]]; then

        if [[ "${has_main}" == true ]] &&
            gitops_git merge-base --is-ancestor "refs/heads/${t}" "refs/heads/${b}"; then
            gitops_fix_ownership
            log_ok "Templates already up to date; nothing to change."
            return 0
        fi

    else

        local parent=()
        [[ "${has_tmpl}" == true ]] && parent=(-p "refs/heads/${t}")

        local commit
        commit="$(gitops_git commit-tree "${tree}" "${parent[@]}" -m "${message}")"
        gitops_git update-ref "refs/heads/${t}" "${commit}"
    fi

    # Push the record first: the next update merges from it, and a manual
    # merge after a conflict needs it on GitHub too.
    if ! gitops_git push -q origin "${t}"; then
        gitops_fix_ownership
        log_error "Failed to push the GitOps repository (does the deploy key allow write access?)"
        return 1
    fi

    #############################################
    # Merge into the branch Argo CD watches
    #############################################

    local before=""

    if [[ "${has_main}" == true ]]; then

        before="$(gitops_git rev-parse HEAD)"

        # First apply into a repository with files of its own (e.g. the
        # README GitHub creates): the templates win where both have a file.
        local first=()
        [[ "${has_tmpl}" == true ]] || first=(--allow-unrelated-histories -X theirs)

        local out
        if ! out="$(gitops_git merge --no-edit "${first[@]}" \
            -m "${message}" "refs/heads/${t}" 2>&1)"; then

            local conflicts
            conflicts="$(gitops_git diff --name-only --diff-filter=U || true)"
            gitops_git merge --abort >/dev/null 2>&1 || true
            gitops_fix_ownership

            if [[ -z "${conflicts}" ]]; then
                log_error "Could not merge the templates:"
                echo "${out}"
                return 1
            fi

            log_error "Your edits and the new homelabCD templates changed the same lines in:"
            sed 's/^/    /' <<<"${conflicts}"
            echo
            echo "  Nothing in your repository was changed. To combine them yourself:"
            echo "    cd ${GITOPS_DIR}"
            echo "    git pull && git merge ${t}"
            echo "    (edit the files above: keep what you want between the <<<<<<< and >>>>>>> marks)"
            echo "    git add -A && git commit && git push"
            return 1
        fi

    else
        gitops_git checkout -q -B "${b}" "refs/heads/${t}" # first commit
    fi

    if ! gitops_git push -q -u origin "${b}"; then
        gitops_fix_ownership
        log_error "Failed to push the GitOps repository (does the deploy key allow write access?)"
        return 1
    fi

    gitops_fix_ownership

    if [[ -n "${before}" ]]; then
        gitops_git --no-pager diff --stat "${before}" HEAD || true
    fi

    log_ok "GitOps repository updated: ${message}"
}


#############################################
# ENTRY POINTS
#############################################

# Bootstrap: clone the repository and apply all templates.
sync_gitops_repo() {

    log_info "Syncing manifests to GitOps repository..."

    gitops_checkout || return 1
    gitops_apply_templates "Apply homelabCD templates"
}

# Other operations: find the deploy key from the saved repo URL and bring
# the local checkout up to date (GITOPS_DIR). Doesn't change the templates.
gitops_prepare() {

    ensure_gitops_repo

    generate_argocd_ssh_key >/dev/null </dev/null
    gitops_checkout
}

# Commits everything in the checkout and pushes.
gitops_commit_push() {

    local message="$1"

    gitops_git add -A

    if gitops_git diff --cached --quiet; then
        gitops_fix_ownership
        log_ok "GitOps repository already up-to-date."
        return 0
    fi

    gitops_git commit -q -m "${message}"

    if ! gitops_git push -q origin "HEAD:${GITOPS_BRANCH:-${GIT_BRANCH:-main}}"; then
        gitops_fix_ownership
        die "Failed to push the GitOps repository (does the deploy key allow write access?)"
    fi

    gitops_fix_ownership
    log_ok "Pushed: ${message}"
}

# "Update GitOps Templates": merge the templates of this homelabCD
# version into the repository, keeping the user's edits.
update_gitops_templates() {

    gitops_prepare || return 1
    gitops_apply_templates "Update homelabCD templates"
}
