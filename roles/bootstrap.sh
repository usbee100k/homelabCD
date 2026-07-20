#!/usr/bin/env bash

header

log_info "Bootstrap Cluster"

validate_system

detect_network

show_summary

read -rp "Continue? (y/N): " ANSWER

[[ "$ANSWER" != "y" ]] && main_menu

update_system
install_prerequisites
disable_swap
configure_kernel_modules
configure_sysctl
mount_bpf

install_containerd

install_kubernetes

install_kubevip

generate_kubeadm_config

initialize_cluster

configure_kubectl

generate_join_commands

install_helm

install_cilium_cli

install_cilium

wait_for_cilium

wait_for_nodes

wait_for_coredns

cluster_health

log_ok "Cluster Bootstrap Complete."

pause

main_menu
