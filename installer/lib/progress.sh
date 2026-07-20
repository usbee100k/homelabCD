#!/usr/bin/env bash

TOTAL_STEPS=11
CURRENT_STEP=0

STEP_NAME=""

next_step() {

    CURRENT_STEP=$((CURRENT_STEP+1))

    STEP_NAME="$1"

    clear

    echo "============================================================"
    echo "                 HOMELAB INSTALLER"
    echo "============================================================"
    echo
    echo "Hostname      : $(hostname)"
    echo "Role          : ${NODE_ROLE}"
    echo "Kubernetes    : ${KUBERNETES_VERSION}"
    echo
    echo "Step ${CURRENT_STEP}/${TOTAL_STEPS}"
    echo
    echo ">>> ${STEP_NAME}"
    echo
}

finish_step() {

    echo
    log_ok "${STEP_NAME}"
    sleep 1

}