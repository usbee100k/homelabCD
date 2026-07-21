#!/usr/bin/env bash


INVENTORY_DIR="${ROOT_DIR}/../cluster/inventory"

DISCOVERED_FILE="${INVENTORY_DIR}/discovered-nodes.yaml"



create_inventory_dir() {

    mkdir -p "${INVENTORY_DIR}"

}



detect_hardware() {


    HOSTNAME=$(hostname)

    LOCAL_IP=$(ip route get 1.1.1.1 | awk '{print $7; exit}')

    CPU_COUNT=$(nproc)

    MEMORY=$(free -h | awk '/Mem:/ {print $2}')



    DISKS=$(lsblk -dn -o NAME,SIZE | tr '\n' ',')



}



register_node() {


    create_inventory_dir


    detect_hardware



cat > "${DISCOVERED_FILE}" <<EOF

nodes:

  - name: ${HOSTNAME}

    ip: ${LOCAL_IP}

    cpu: ${CPU_COUNT}

    memory: ${MEMORY}

    disks:

      - ${DISKS}

    registered:

      $(date +"%Y-%m-%d")

EOF


log_ok "Node inventory updated."

}