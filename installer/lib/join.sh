#!/usr/bin/env bash


#############################################
# GENERATE JOIN COMMANDS
#############################################


generate_join_commands() {


    mkdir -p "${ROOT_DIR}/generated"



    log_info "Generating Kubernetes join commands"



    kubeadm token create \
        --print-join-command \
        > "${ROOT_DIR}/generated/worker_join.sh"



    chmod +x "${ROOT_DIR}/generated/worker_join.sh"



    CERT_KEY=$(kubeadm init phase upload-certs \
        --upload-certs \
        | tail -1)



    JOIN_COMMAND=$(kubeadm token create \
        --print-join-command)



cat > "${ROOT_DIR}/generated/controlplane_join.sh" <<EOF

#!/usr/bin/env bash

${JOIN_COMMAND} \
    --control-plane \
    --certificate-key ${CERT_KEY}

EOF



chmod +x "${ROOT_DIR}/generated/controlplane_join.sh"



log_ok "Join commands generated."

}