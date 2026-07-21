#!/usr/bin/env bash
# lib/bootstrap-auth.sh
# SSH key-based authentication for the bootstrap repository.
# Uses the SSH URL (git@host:org/repo.git) and the user's SSH key.
# No tokens, no URL prompting — just key auth.

# Ensure the bootstrap repo is an SSH URL.
_bootstrap_ssh_url() {
    local url="${BOOTSTRAP_REPO:-}"
    # Already SSH — use as-is.
    [[ "$url" == git@* ]] && { echo "$url"; return; }
    # Convert https://host/org/repo.git → git@host:org/repo.git
    sed -E 's#https?://([^/@]+@)?([^/]+)/#git@\2:#' <<<"$url"
}

# Make sure the host is in known_hosts so git doesn't hang on a prompt.
_bootstrap_trust_host() {
    local host
    host="$(sed -E 's#git@([^:]+):.*#\1#' <<<"$1")"
    ssh-keygen -F "$host" >/dev/null 2>&1 \
        || ssh-keyscan -t ed25519,rsa "$host" >>~/.ssh/known_hosts 2>/dev/null
}

# Validate SSH key access to the bootstrap repo.
validate_bootstrap_access() {
    local ssh_url
    ssh_url="$(_bootstrap_ssh_url)"
    [[ -n "$ssh_url" ]] || return 1

    export BOOTSTRAP_REPO="$ssh_url"
    _bootstrap_trust_host "$ssh_url"

    git ls-remote --exit-code "$ssh_url" HEAD >/dev/null 2>&1
}