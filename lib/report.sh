#!/usr/bin/env bash


#############################################
# GENERATE CLUSTER REPORT
#############################################

generate_report() {

    REPORT_DIR="${ROOT_DIR}/generated"
    REPORT_FILE="${REPORT_DIR}/cluster-info.yaml"


    mkdir -p "${REPORT_DIR}"


    # Validate required variables
    REQUIRED_VARS=(
        CLUSTER_NAME
        KUBERNETES_VERSION
        VIP_ADDRESS
        GITHUB_REPO
    )


    for VAR in "${REQUIRED_VARS[@]}"; do

        if [[ -z "${!VAR}" ]]; then
            log_error "Missing required variable: ${VAR}"
            exit 1
        fi

    done


    log_info "Generating cluster report"


    cat > "${REPORT_FILE}" <<EOF
cluster:
  name: ${CLUSTER_NAME}

kubernetes:
  version: ${KUBERNETES_VERSION}

network:
  vip: ${VIP_ADDRESS}

gitops:
  repository: ${GITHUB_REPO}

created:
  date: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

EOF


    if [[ ! -f "${REPORT_FILE}" ]]; then
        log_error "Failed to create cluster report"
        exit 1
    fi


    log_ok "Cluster report generated: ${REPORT_FILE}"

}