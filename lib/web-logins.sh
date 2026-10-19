#!/usr/bin/env bash

#############################################
# WEB UI LOGINS
#############################################
#
# "Change Web UI Login" (install.sh --run web-logins): shows the login of
# each web UI and changes its username and/or password, each the way that
# app keeps it:
#
#   Argo CD      bcrypt hash in argocd-secret (the user is always admin)
#   Rancher      a PasswordChangeRequest (Rancher keeps usernames fixed)
#   Hermes       Secret hermes-dashboard-auth, then a restart
#   pgAdmin      its user database (the login is an email address)
#   qBittorrent  its web API, from inside the pod (no login needed there)
#
# Passwords go to the pods on stdin, never on a command line here, and are
# never written to git or to a file.
#############################################

# "id|name" of the web UIs that are deployed.
web_logins_list() {
    kubectl -n argocd get secret argocd-secret >/dev/null 2>&1 && echo "argocd|Argo CD"
    kubectl get users.management.cattle.io >/dev/null 2>&1 && echo "rancher|Rancher"
    kubectl -n hermes get secret hermes-dashboard-auth >/dev/null 2>&1 && echo "hermes|Hermes"
    kubectl -n postgresql get deployment pgadmin >/dev/null 2>&1 && echo "pgadmin|pgAdmin"
    kubectl -n qbittorrent get deployment qbittorrent >/dev/null 2>&1 && echo "qbittorrent|qBittorrent"
    return 0
}

# JSON string body: escapes \ and ".
web_logins_json() {
    local s="${1//\\/\\\\}"
    printf '%s' "${s//\"/\\\"}"
}

# Percent-encodes $1 for a form body.
web_logins_urlencode() {
    local s="$1" out="" c i LC_ALL=C
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        case "${c}" in
            [A-Za-z0-9._~-]) out+="${c}" ;;
            *) out+="$(printf '%%%02X' "'${c}")" ;;
        esac
    done
    printf '%s' "${out}"
}

web_logins_random() {
    head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-20
}

# Asks for a new password (twice); blank makes a random one. At least $1
# characters. Sets WEB_LOGIN_PASSWORD and WEB_LOGIN_RANDOM.
web_logins_read_password() {

    local min="$1" again

    WEB_LOGIN_RANDOM=false
    while true; do
        read -rsp "New password (blank = random, at least ${min} characters): " WEB_LOGIN_PASSWORD || return 1
        echo
        if [[ -z "${WEB_LOGIN_PASSWORD}" ]]; then
            WEB_LOGIN_PASSWORD="$(web_logins_random)"
            WEB_LOGIN_RANDOM=true
            return 0
        fi
        if (( ${#WEB_LOGIN_PASSWORD} < min )); then
            log_warn "Use at least ${min} characters."
            continue
        fi
        read -rsp "Type it again: " again || return 1
        echo
        [[ "${again}" == "${WEB_LOGIN_PASSWORD}" ]] && return 0
        log_warn "They don't match; try again."
    done
}

web_logins_show_password() {
    if [[ "${WEB_LOGIN_RANDOM}" == true ]]; then
        echo
        echo "  New password: ${WEB_LOGIN_PASSWORD}"
        echo "  (shown only now; save it in your password manager)"
    fi
}

# ---------- Argo CD ----------

web_login_argocd() {

    local hash

    echo "Argo CD's built-in user is always 'admin'; only the password changes."
    web_logins_read_password 8 || return 1

    hash="$(printf '%s' "${WEB_LOGIN_PASSWORD}" |
        kubectl -n argocd exec -i deploy/argocd-server -c server -- \
            sh -c 'argocd account bcrypt --password "$(cat)"' 2>/dev/null)"
    if [[ "${hash}" != '$2'* ]]; then
        log_error "Could not hash the password in the argocd-server pod; nothing was changed."
        return 1
    fi

    kubectl -n argocd patch secret argocd-secret --type merge --patch-file <(
        printf '{"stringData":{"admin.password":"%s","admin.passwordMtime":"%s"}}' \
            "${hash}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    ) >/dev/null || {
        log_error "Could not update argocd-secret."
        return 1
    }

    # The first password no longer works; Argo CD's docs say to delete it.
    kubectl -n argocd delete secret argocd-initial-admin-secret --ignore-not-found >/dev/null 2>&1 || true

    log_ok "Argo CD: log in as admin with the new password (open sessions are logged out)."
    web_logins_show_password
}

# ---------- Rancher ----------

web_login_rancher() {

    local ids=() names=() id name i pick current out

    while IFS='|' read -r id name; do
        [[ -n "${name}" ]] || continue
        ids+=("${id}")
        names+=("${name}")
    done < <(kubectl get users.management.cattle.io \
        -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.username}{"\n"}{end}')

    if (( ${#ids[@]} == 0 )); then
        log_error "Rancher has no local users."
        return 1
    fi

    echo "Rancher keeps usernames fixed; only the password changes."
    if (( ${#ids[@]} == 1 )); then
        i=0
    else
        for i in "${!ids[@]}"; do
            echo "  $(( i + 1 ))) ${names[i]}"
        done
        pick="$(read_choice "User (blank = cancel): " 0 "${#ids[@]}")"
        [[ "${pick}" != 0 ]] || return 0
        i=$(( pick - 1 ))
    fi
    echo "User: ${names[i]}"

    web_logins_read_password 12 || return 1

    # kubectl fails when Rancher refuses the change.
    rancher_change() {
        kubectl create -f - -o jsonpath='{.status.summary}' 2>&1 <<JSON
{"apiVersion":"ext.cattle.io/v1","kind":"PasswordChangeRequest",
 "spec":{"userID":"${ids[i]}","currentPassword":"$(web_logins_json "${current}")",
         "newPassword":"$(web_logins_json "${WEB_LOGIN_PASSWORD}")"}}
JSON
    }

    current=""
    if ! out="$(rancher_change)" || [[ "${out}" == *ail* ]]; then
        # Rancher may want the current password before it changes it.
        read -rsp "Rancher asks for ${names[i]}'s current password: " current || return 1
        echo
        if ! out="$(rancher_change)" || [[ "${out}" == *ail* ]]; then
            log_error "Rancher did not change the password:"
            echo "  ${out}"
            echo "  For a new random admin password instead, run:"
            echo "  kubectl -n cattle-system exec deploy/rancher -c rancher -- reset-password"
            return 1
        fi
    fi

    log_ok "Rancher: ${names[i]} has the new password."
    web_logins_show_password
}

# ---------- Hermes ----------

web_login_hermes() {

    local user new_user

    user="$(kubectl -n hermes get secret hermes-dashboard-auth -o jsonpath='{.data.username}' | base64 -d)"
    read -rp "Username [${user}]: " new_user || return 1
    new_user="${new_user:-${user}}"
    web_logins_read_password 8 || return 1

    kubectl -n hermes patch secret hermes-dashboard-auth --type merge --patch-file <(
        printf '{"stringData":{"username":"%s","password":"%s"}}' \
            "$(web_logins_json "${new_user}")" "$(web_logins_json "${WEB_LOGIN_PASSWORD}")"
    ) >/dev/null || {
        log_error "Could not update the Secret hermes-dashboard-auth."
        return 1
    }

    log_info "Restarting Hermes so it uses the new login..."
    kubectl -n hermes rollout restart deployment hermes >/dev/null
    kubectl -n hermes rollout status deployment hermes --timeout=300s >/dev/null ||
        log_warn "Hermes is still starting; the new login works once it is up."

    log_ok "Hermes: log in as ${new_user} with the new password."
    web_logins_show_password
}

# ---------- pgAdmin ----------

# Runs python in the pgAdmin pod with the JSON in $1 on stdin.
pgadmin_python() {
    local script="$2"
    printf '%s' "$1" | kubectl -n postgresql exec -i deploy/pgadmin -- /venv/bin/python3 -c "${script}"
}

web_login_pgadmin() {

    local user new_user out

    user="$(pgadmin_python '{}' '
import sqlite3
db = sqlite3.connect("/var/lib/pgadmin/pgadmin4.db")
row = db.execute("select email from user where auth_source = ? order by id limit 1", ("internal",)).fetchone()
print(row[0] if row else "")' 2>/dev/null)"

    if [[ -z "${user}" ]]; then
        log_error "Could not read pgAdmin's user (is the pgadmin pod running?)."
        return 1
    fi

    echo "pgAdmin logs in with an email address. This changes only the pgAdmin"
    echo "login, not the PostgreSQL database password."
    read -rp "Login email [${user}]: " new_user || return 1
    new_user="${new_user:-${user}}"
    if [[ "${new_user}" != *@*.* ]]; then
        log_error "pgAdmin needs an email address such as admin@home.lan."
        return 1
    fi
    web_logins_read_password 8 || return 1

    # Renaming in place keeps the user's saved servers and settings; the
    # password goes through pgAdmin's own setup.py so it is hashed its way.
    out="$(pgadmin_python "{\"old\":\"$(web_logins_json "${user}")\",\"new\":\"$(web_logins_json "${new_user}")\",\"password\":\"$(web_logins_json "${WEB_LOGIN_PASSWORD}")\"}" '
import json, sqlite3, subprocess, sys
d = json.load(sys.stdin)
if d["new"] != d["old"]:
    db = sqlite3.connect("/var/lib/pgadmin/pgadmin4.db")
    db.execute("update user set email = ?, username = ? where email = ?", (d["new"], d["new"], d["old"]))
    db.commit()
r = subprocess.run(["/venv/bin/python3", "/pgadmin4/setup.py", "update-user", d["new"],
                    "--password", d["password"]], capture_output=True, text=True)
print("OK" if r.returncode == 0 else r.stdout + r.stderr)' 2>&1)"

    if [[ "${out}" != *OK* ]]; then
        log_error "pgAdmin did not take the new login:"
        echo "${out}" | tail -5
        return 1
    fi

    log_ok "pgAdmin: log in as ${new_user} with the new password."
    web_logins_show_password
}

# ---------- qBittorrent ----------

# wget in the qbittorrent pod's port-sync container, which reaches the web
# API on localhost (WebUI\LocalHostAuth is off there). Body on stdin.
qbittorrent_api() {
    kubectl -n qbittorrent exec -i deploy/qbittorrent -c port-sync -- \
        sh -c 'body="$(cat)"; if [ -n "${body}" ]; then wget -qO- --post-data "${body}" "http://127.0.0.1:8080/api/v2/app/$0"; else wget -qO- "http://127.0.0.1:8080/api/v2/app/$0"; fi' "$1"
}

web_login_qbittorrent() {

    local prefs user new_user json

    prefs="$(qbittorrent_api preferences < /dev/null 2>/dev/null)"
    if [[ "${prefs}" != *web_ui_username* ]]; then
        log_error "qBittorrent's web API does not answer (is the qbittorrent pod running?)."
        return 1
    fi
    user="$(sed -n 's/.*"web_ui_username":"\([^"]*\)".*/\1/p' <<< "${prefs}")"

    read -rp "Username [${user}]: " new_user || return 1
    new_user="${new_user:-${user}}"
    web_logins_read_password 8 || return 1

    json="{\"web_ui_username\":\"$(web_logins_json "${new_user}")\",\"web_ui_password\":\"$(web_logins_json "${WEB_LOGIN_PASSWORD}")\"}"
    printf 'json=%s' "$(web_logins_urlencode "${json}")" | qbittorrent_api setPreferences >/dev/null || {
        log_error "qBittorrent did not take the new login."
        return 1
    }

    log_ok "qBittorrent: log in as ${new_user} with the new password."
    web_logins_show_password
}

change_web_logins() {

    header 2>/dev/null || true

    command -v kubectl >/dev/null 2>&1 && kubectl get nodes >/dev/null 2>&1 || {
        log_error "Run this on a control plane (kubectl must reach the cluster)."
        return 1
    }

    local ids=() names=() id name i pick

    while IFS='|' read -r id name; do
        [[ -n "${id}" ]] || continue
        ids+=("${id}")
        names+=("${name}")
    done < <(web_logins_list)

    if (( ${#ids[@]} == 0 )); then
        log_info "No web UI with a login of its own is deployed."
        return 0
    fi

    echo
    echo "Change the login of a web UI:"
    echo
    for i in "${!ids[@]}"; do
        echo "  $(( i + 1 ))) ${names[i]}"
    done
    echo
    echo "(wg-easy and imported apps: change the login in the app's own settings page.)"
    echo

    pick="$(read_choice "Web UI (blank = cancel): " 0 "${#ids[@]}")"
    [[ "${pick}" != 0 ]] || { log_info "Nothing was changed."; return 0; }

    i=$(( pick - 1 ))
    echo
    "web_login_${ids[i]}"
}
