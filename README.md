# Homelab Installer

A production-ready Kubernetes Homelab Deployment Framework.

Features

✓ HA Kubernetes

✓ kube-vip

✓ containerd

✓ Cilium

✓ Longhorn

✓ ArgoCD

✓ GitOps

✓ Monitoring

✓ Health Checks

✓ One-command deployment

Supported OS

Ubuntu Server 24.04

Status

Early Development



git clone <installer>

cd installer

cp config/defaults.example.env config/defaults.env

sudo ./install.sh



Choose:
1 - First Control Plane
2 - Additional Control Plane
3 - Worker
