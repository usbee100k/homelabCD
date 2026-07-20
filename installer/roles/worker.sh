#!/usr/bin/env bash

header

log_info "Worker Node"

validate_system

detect_network

system_information

read -rp "Continue? (y/N): " CONTINUE

[[ "$CONTINUE" != "y" ]] && main_menu

update_system
install_prerequisites
disable_swap
configure_kernel_modules
configure_sysctl
mount_bpf
install_containerd
install_kubernetes

log_ok "Worker prerequisites complete."

pause

main_menu
