#!/usr/bin/env bash

#############################################
# HERMES AGENT: LOCAL LLM
#############################################
#
# Hermes's network policy blocks the LAN. hermes.localLLM in
# config/cluster.yaml names the one machine running a local LLM server
# (Ollama 11434, LM Studio 1234, llama.cpp 8080) it may reach; empty means
# none, and the policy for it is left out of the GitOps repo.
#
#   configure_hermes_llm   prompt (bootstrap, or the operation below)
#   setup_hermes_llm       "Hermes Local LLM" (install.sh --run hermes-llm):
#                          ask, save, push only Hermes's files
#############################################

configure_hermes_llm() {

    local force="${1:-}" answer value def

    if [[ "${force}" != "--force" && -n "${HERMES_LOCAL_LLM:-}" ]]; then
        log_ok "Hermes local LLM: ${HERMES_LOCAL_LLM}"
        return 0
    fi

    echo
    echo "============================================="
    echo " Hermes Agent: local LLM (optional)"
    echo "============================================="
    echo
    echo "Hermes can use an LLM server running on a machine in your LAN"
    echo "(Ollama, LM Studio or llama.cpp, e.g. your gaming PC). Everything"
    echo "else on the LAN stays blocked for it. Without one, use a cloud"
    echo "model (API key in the Hermes dashboard)."
    [[ -n "${HERMES_LOCAL_LLM:-}" ]] && echo "Now: ${HERMES_LOCAL_LLM}"
    echo

    def=N
    [[ -n "${HERMES_LOCAL_LLM:-}" ]] && def=Y
    read -rp "Use a local LLM server? [$([[ ${def} == Y ]] && echo Y/n || echo y/N)]: " answer || answer=""
    answer="${answer:-${def}}"

    if [[ ! "${answer}" =~ ^[Yy] ]]; then
        HERMES_LOCAL_LLM=""
        export HERMES_LOCAL_LLM
        save_config
        log_info "No local LLM for Hermes. Add one later from KubesTUI: Hermes Local LLM."
        return 0
    fi

    local octet='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'

    while true; do
        read -rp "IP of the machine running it${HERMES_LOCAL_LLM:+ [${HERMES_LOCAL_LLM}]}: " value || value=""
        value="${value:-${HERMES_LOCAL_LLM:-}}"
        value="${value//[[:space:]]/}"
        if [[ "${value}" =~ ^${octet}\.${octet}\.${octet}\.${octet}$ ]]; then
            break
        fi
        echo "[ERROR] Enter one IPv4 address, e.g. 192.168.50.177"
    done

    HERMES_LOCAL_LLM="${value}"
    export HERMES_LOCAL_LLM
    save_config

    log_ok "Hermes may reach ${HERMES_LOCAL_LLM} on ports 11434, 1234 and 8080."
    echo
    echo "  On that machine:"
    echo "   1. Reserve its IP in your router so it never changes"
    echo "   2. Make the server listen on the network (LM Studio: Serve on"
    echo "      Local Network; Ollama: OLLAMA_HOST=0.0.0.0)"
    echo "   3. Allow its port through the firewall (private networks)"
    echo "   4. In the Hermes dashboard, add a custom OpenAI-compatible"
    echo "      provider: http://${HERMES_LOCAL_LLM}:1234/v1 (LM Studio) or"
    echo "      http://${HERMES_LOCAL_LLM}:11434/v1 (Ollama)"
    echo
}

setup_hermes_llm() {

    header 2>/dev/null || true

    local before="${HERMES_LOCAL_LLM:-}"

    # Bring the GitOps checkout up to date first, while the saved settings
    # are still the old ones (see lib/gitops.sh).
    gitops_prepare

    configure_hermes_llm --force

    if [[ "${HERMES_LOCAL_LLM:-}" == "${before}" ]]; then
        log_info "Nothing changed; nothing to push."
        return 0
    fi

    # Only Hermes's own files; the rest of the repository is left as it is.
    gitops_apply_templates "Hermes local LLM: ${HERMES_LOCAL_LLM:-none}" \
        apps/ai/hermes || return 1

    log_ok "Pushed; Argo CD updates Hermes's network policy within a few minutes."
}
