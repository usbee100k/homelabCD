#!/usr/bin/env bash


generate_report() {


REPORT_DIR="${ROOT_DIR}/generated"

mkdir -p "${REPORT_DIR}"


cat <<EOF > "${REPORT_DIR}/cluster-info.yaml"

cluster:
  name: ${CLUSTER_NAME}

kubernetes:
  version: ${KUBERNETES_VERSION}

network:
  vip: ${VIP_ADDRESS}

gitops:
  repository: ${GITHUB_REPO}

created:
  date: $(date)

EOF


log_ok "Cluster report generated."

}