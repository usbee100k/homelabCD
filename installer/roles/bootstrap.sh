#!/usr/bin/env bash

header

NODE_ROLE="Bootstrap"

validate_system

detect_network

show_summary

read -rp "Continue? (y/N): " ANSWER

[[ "$ANSWER" != "y" ]] && main_menu

next_step "Updating Ubuntu"
update_system
finish_step

next_step "Installing Prerequisites"
install_prerequisites
finish_step

next_step "Disabling Swap"
disable_swap
finish_step

next_step "Configuring Kernel"
configure_kernel_modules
configure_sysctl
mount_bpf
finish_step

next_step "Installing Containerd"
install_containerd
finish_step

next_step "Installing Kubernetes"
install_kubernetes
finish_step

next_step "Installing kube-vip"
install_kubevip
finish_step

next_step "Initializing Cluster"
generate_kubeadm_config
initialize_cluster
configure_kubectl
generate_join_commands
finish_step

next_step "Installing Helm"
install_helm
finish_step

next_step "Installing Cilium"
install_cilium_cli
install_cilium
wait_for_cilium
finish_step

next_step "Cluster Health Check"
wait_for_nodes
wait_for_coredns
cluster_health
finish_step

next_step "Installing Argo CD"
install_argocd
finish_step

next_step "Bootstrapping GitOps"
bootstrap_gitops
finish_step

echo
echo "============================================================"
echo
log_ok "Bootstrap Complete"
echo
echo "Next Step:"
echo
echo "Install ArgoCD"
echo
pause

main_menu
