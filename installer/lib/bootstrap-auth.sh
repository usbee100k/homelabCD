#!/usr/bin/env bash
# lib/bootstrap-auth.sh
# Automated bootstrap-repo authentication.
# Tries SSH → saved token → prompted token, stores the token for next time.

# Validate we can reach the bootstrap repo. Auto-discovers auth, stores token once.
validate_bootstrap_access() {
    local url="${BOOTSTRAP_REPO:-}"
    [[ -n "$url" ]] || return 1

    # Already works (SSH key, embedded token, or public repo)?
    if git ls-remote --exit-code "$url" HEAD >/dev/null 2>&1; then
        return 0
    fi

    # SSH URL but key auth failed — nothing we can automate.
    [[ "$url" == git@* ]] && return 1

    # HTTPS: try the saved token, then prompt once.
    if [[ -z "${BOOTSTRAP_GIT_TOKEN:-}" ]]; then
        read -rs -p "GitHub token for bootstrap repo: " token < /dev/tty; echo
        [[ -n "$token" ]] || return 1
        _save_bootstrap_token "$token"
    fi

    # Inject token into the URL and test.
    local authed
    authed="$(sed -E "s#(https?://)#\1${BOOTSTRAP_GIT_TOKEN}@#" <<<"$url")"
    git ls-remote --exit-code "$authed" HEAD >/dev/null 2>&1
}

_save_bootstrap_token() {
    local file="${ROOT_DIR}/config/encryption.env"
    mkdir -p "$(dirname "$file")"; touch "$file"; chmod 600 "$file"
    grep -q '^BOOTSTRAP_GIT_TOKEN=' "$file" \
        && sed -i "s|^BOOTSTRAP_GIT_TOKEN=.*|BOOTSTRAP_GIT_TOKEN=\"$1\"|" "$file" \
        || printf 'BOOTSTRAP_GIT_TOKEN="%s"\n' "$1" >>"$file"
    export BOOTSTRAP_GIT_TOKEN="$1"
}