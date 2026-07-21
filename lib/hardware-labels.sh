#!/usr/bin/env bash



detect_special_hardware() {


NODE_NAME=$(hostname)



# GPU detection

if command -v nvidia-smi >/dev/null 2>&1
then

kubectl label node "${NODE_NAME}" \
gpu=true \
--overwrite

fi



# Storage capability

DISK_COUNT=$(lsblk -dn | wc -l)



if [[ "${DISK_COUNT}" -gt 1 ]]
then

kubectl label node "${NODE_NAME}" \
storage=true \
--overwrite

fi



log_ok "Hardware labels applied."

}