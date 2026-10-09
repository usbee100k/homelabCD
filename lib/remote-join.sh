#!/usr/bin/env bash

#############################################
# Provision a node over SSH from the bootstrap
# machine. Copies homelabCD, then runs worker
# or controlplane join on the remote host.
#############################################

remote_join_ssh_opts() {
    local port="${JOIN_SSH_PORT:-22}"
    # ServerAlive*: a node that goes away ends the session within ~30s.
    echo -n "-p ${port} -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=3"
}


remote_join_target() {
    local user="${JOIN_SSH_USER:-root}"
    local ip="${JOIN_NODE_IP:?JOIN_NODE_IP is required}"
    echo "${user}@${ip}"
}


remote_join_dir() {
    local user="${JOIN_SSH_USER:-root}"
    if [[ "${user}" == "root" ]]; then
        echo "/root/homelabCD"
    else
        echo "/home/${user}/homelabCD"
    fi
}


remote_join_print_plan() {
    local role="$1"
    local name="${JOIN_NODE_NAME:-<node-name>}"
    local dest
    local remote_dir
    dest="$(remote_join_target)"
    remote_dir="$(remote_join_dir)"

    echo
    echo "Would provision ${role} node from this bootstrap host:"
    echo
    echo "  ssh $(remote_join_ssh_opts) ${dest}"
    echo "  ssh ${dest} sudo hostnamectl set-hostname ${name}"
    echo "  scp -r ${ROOT_DIR}/lib ${ROOT_DIR}/roles ${ROOT_DIR}/config ${ROOT_DIR}/install.sh \\"
    echo "      ${dest}:${remote_dir}/"
    echo "  ssh -t ${dest} sudo bash ${remote_dir}/install.sh --run ${role}"
    echo
}


remote_join_node() {
    local role="${1:?role required (worker|controlplane)}"
    local name="${JOIN_NODE_NAME:-}"
    local ip="${JOIN_NODE_IP:-}"
    local user="${JOIN_SSH_USER:-root}"
    local dest
    local remote_dir
    local ssh_opts
    local remote_cmd

    if [[ "${role}" != "worker" && "${role}" != "controlplane" ]]; then
        log_error "remote_join_node: role must be worker or controlplane"
        return 1
    fi

    if [[ -z "${name}" || -z "${ip}" ]]; then
        log_error "JOIN_NODE_NAME and JOIN_NODE_IP are required"
        return 1
    fi

    dest="$(remote_join_target)"
    remote_dir="$(remote_join_dir)"
    ssh_opts="$(remote_join_ssh_opts)"

    if [[ "${JOIN_DRY_RUN:-0}" == "1" ]]; then
        remote_join_print_plan "${role}"
        return 0
    fi

    require_command ssh
    require_command tar

    echo
    echo "============================================================"
    echo " SSH SESSION  ${dest}  (${name} / ${role})"
    echo "============================================================"
    echo
    echo "You may be prompted for a password or host-key confirmation."
    echo

    log_info "Testing SSH to ${dest}"
    # shellcheck disable=SC2086
    if ! ssh ${ssh_opts} -t "${dest}" "echo SSH_OK; hostname"; then
        log_error "Could not open SSH to ${dest}"
        return 1
    fi

    log_ok "SSH connected"

    if declare -F generate_join_commands >/dev/null; then
        log_info "Refreshing join credentials on this bootstrap node"
        generate_join_commands || log_warn "Join command refresh failed; copying existing files if present"
    fi

    mkdir -p "${ROOT_DIR}/generated/secrets"
    # Always take the freshly generated command: the certificate key
    # in an older copy expires 2 hours after it was created.
    if [[ -f "${ROOT_DIR}/generated/controlplane_join.sh" ]]; then
        cp -f "${ROOT_DIR}/generated/controlplane_join.sh" \
            "${ROOT_DIR}/generated/secrets/controlplane_join.sh"
    fi

    log_info "Setting hostname ${name} on ${dest}"
    # shellcheck disable=SC2086
    ssh ${ssh_opts} -t "${dest}" "sudo hostnamectl set-hostname '${name}'"

    log_info "Creating ${remote_dir} on ${dest}"
    # shellcheck disable=SC2086
    ssh ${ssh_opts} -t "${dest}" "sudo mkdir -p '${remote_dir}' && sudo chown -R '${user}:${user}' '${remote_dir}'"

    log_info "Copying homelabCD libraries and roles to ${dest}:${remote_dir}"
    tar \
        -C "${ROOT_DIR}" \
        --exclude='.git' \
        --exclude='bin' \
        --exclude='.src' \
        --exclude='logs' \
        --exclude='tmp' \
        -czf - \
        install.sh \
        lib \
        roles \
        config \
        scripts \
        templates \
        generated \
        2>/dev/null \
        | ssh ${ssh_opts} "${dest}" "tar -C '${remote_dir}' -xzf -"

    log_info "Running ${role}.sh on ${name} via SSH"
    echo

    remote_cmd="sudo env ROOT_DIR='${remote_dir}' JOIN_NODE_NAME='${name}' bash '${remote_dir}/install.sh' --run '${role}'"

    # shellcheck disable=SC2086
    ssh ${ssh_opts} -t "${dest}" "${remote_cmd}"
}
