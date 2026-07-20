#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${ROOT_DIR}/config/defaults.env"
source "${ROOT_DIR}/config/versions.env"

source "${ROOT_DIR}/lib/logging.sh"
source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/lib/validation.sh"
source "${ROOT_DIR}/lib/system.sh"
source "${ROOT_DIR}/lib/networking.sh"
source "${ROOT_DIR}/lib/containerd.sh"
source "${ROOT_DIR}/lib/kubevip.sh"
source "${ROOT_DIR}/lib/kubeadm.sh"
source "${ROOT_DIR}/lib/helm.sh"
source "${ROOT_DIR}/lib/cilium.sh"
source "${ROOT_DIR}/lib/health.sh"
source "${ROOT_DIR}/lib/argocd.sh"

main_menu
