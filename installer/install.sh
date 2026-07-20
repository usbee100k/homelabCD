#!/usr/bin/env bash

set -Eeuo pipefail


#############################################
# PATH SETUP
#############################################

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export ROOT_DIR


#############################################
# CONFIGURATION
#############################################

source "${ROOT_DIR}/config/defaults.env"
source "${ROOT_DIR}/config/versions.env"


#############################################
# CORE LIBRARIES
#############################################

source "${ROOT_DIR}/lib/logging.sh"
source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/lib/progress.sh"
source "${ROOT_DIR}/config/bootstrap.env"
source "${ROOT_DIR}/lib/bootstrap-repo.sh"
source "${ROOT_DIR}/lib/secrets.sh"
source "${ROOT_DIR}/lib/inventory.sh"
source "${ROOT_DIR}/lib/node-labels.sh"
source "${ROOT_DIR}/lib/hardware-labels.sh"

source "${ROOT_DIR}/lib/config.sh"
source "${ROOT_DIR}/lib/github.sh"

source "${ROOT_DIR}/lib/validation.sh"
source "${ROOT_DIR}/lib/system.sh"
source "${ROOT_DIR}/lib/networking.sh"

source "${ROOT_DIR}/lib/containerd.sh"
source "${ROOT_DIR}/lib/kubevip.sh"
source "${ROOT_DIR}/lib/kubeadm.sh"
source "${ROOT_DIR}/lib/kubeadm-config.sh"

source "${ROOT_DIR}/lib/helm.sh"
source "${ROOT_DIR}/lib/cilium.sh"

source "${ROOT_DIR}/lib/argocd.sh"

source "${ROOT_DIR}/lib/health.sh"
source "${ROOT_DIR}/lib/report.sh"
source "${ROOT_DIR}/lib/repair.sh"
source "${ROOT_DIR}/lib/join.sh"



#############################################
# LOAD CLUSTER CONFIG
#############################################

load_config


#############################################
# GITHUB CONFIGURATION
#############################################

ask_github_repo


#############################################
# SYSTEM CHECK
#############################################

validate_system

detect_network


#############################################
# START INSTALLER MENU
#############################################

main_menu
