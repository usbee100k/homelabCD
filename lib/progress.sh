#!/usr/bin/env bash

#############################################
# STEP PROGRESS
#############################################
#
# next_step "Name"  starts a step: clears the screen and shows
#                   "Step N/TOTAL". TOTAL is counted from the role script
#                   that calls it, so it always matches the real steps.
# finish_step       ends it; in watch mode it pauses before the next one.
# ask_step_mode     asks once whether to pause after each step.
#                   STEP_PAUSE=true|false skips the question.
#############################################

TOTAL_STEPS=0
CURRENT_STEP=0

STEP_NAME=""


# Counts the next_step calls in the script that runs the steps.
count_steps() {
    local script="$1"
    [[ -f "${script}" ]] || return 0
    grep -c '^[[:space:]]*next_step[[:space:]]' "${script}" || true
}


ask_step_mode() {

    if [[ -n "${STEP_PAUSE:-}" ]]; then
        return 0
    fi

    # Nobody at the keyboard (e.g. automation): run straight through.
    if [[ ! -t 0 ]]; then
        STEP_PAUSE=false
        return 0
    fi

    echo
    echo "============================================================"
    echo "                 HOMELAB INSTALLER"
    echo "============================================================"
    echo
    echo "Watch each step?"
    echo "  y  pause after every step so you can read what it did"
    echo "  n  run all steps automatically (as before)"
    echo

    local answer
    read -rp "Pause after each step? [y/N]: " answer

    if [[ "${answer}" =~ ^[Yy] ]]; then
        STEP_PAUSE=true
    else
        STEP_PAUSE=false
    fi
    export STEP_PAUSE
}


next_step() {

    CURRENT_STEP=$((CURRENT_STEP+1))

    STEP_NAME="$1"

    if (( TOTAL_STEPS == 0 )); then
        TOTAL_STEPS="$(count_steps "${BASH_SOURCE[1]:-}")"
        (( TOTAL_STEPS > 0 )) || TOTAL_STEPS="?"
    fi

    clear

    echo "============================================================"
    echo "                 HOMELAB INSTALLER"
    echo "============================================================"
    echo
    echo "Hostname      : $(hostname)"
    echo "Role          : ${NODE_ROLE:-unknown}"
    echo "Kubernetes    : ${KUBERNETES_VERSION:-unknown}"
    echo
    echo "Step ${CURRENT_STEP}/${TOTAL_STEPS}"
    echo
    echo ">>> ${STEP_NAME}"
    echo
}


finish_step() {

    echo
    log_ok "${STEP_NAME}"

    if [[ "${STEP_PAUSE:-false}" == "true" && "${CURRENT_STEP}" != "${TOTAL_STEPS}" ]]; then
        local answer
        echo
        read -rp "Step ${CURRENT_STEP}/${TOTAL_STEPS} done. ENTER = next step, a = run the rest automatically: " answer
        if [[ "${answer}" =~ ^[Aa] ]]; then
            STEP_PAUSE=false
        fi
    else
        sleep 1
    fi
}
