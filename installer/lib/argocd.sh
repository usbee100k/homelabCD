#!/usr/bin/env bash

install_argocd() {

    log_info "Installing Argo CD..."

    kubectl create namespace argocd \
        --dry-run=client \
        -o yaml | kubectl apply -f -

    helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1

    helm repo update >/dev/null 2>&1

    helm upgrade \
        --install argocd \
        argo/argo-cd \
        --namespace argocd \
        --values bootstrap/argocd/values.yaml \
        --wait

    log_ok "Argo CD Installed."

}

bootstrap_gitops() {

    log_info "Bootstrapping GitOps..."

    kubectl apply -f bootstrap/projects/default-project.yaml

    kubectl apply -f bootstrap/root-app.yaml

    log_ok "GitOps Bootstrap Complete."

}