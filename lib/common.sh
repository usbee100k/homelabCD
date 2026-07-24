#!/usr/bin/env bash



#############################################
# UI Helpers
#############################################

header()
{
    clear

    echo "============================================================"
    echo "                 HOMELAB INSTALLER"
    echo "============================================================"
    echo
    echo "$1"
    echo
}


#############################################
# COMMON FUNCTIONS
#############################################


pause() {

    read -rp "Press Enter to continue..."

}



header() {

    clear

    echo "================================================"
    echo "          HOMELAB KUBERNETES PLATFORM"
    echo "================================================"
    echo

    echo "Cluster : ${CLUSTER_NAME:-unknown}"

    echo "Version : ${KUBERNETES_VERSION:-unknown}"

    echo "VIP     : ${VIP_ADDRESS:-unknown}"

    echo

}



main_menu() {


while true
do

    header


    echo "Select Operation"
    echo

    echo "1) Bootstrap New Cluster"
    echo "2) Join Additional Control Plane"
    echo "3) Join Worker Node"
    echo "4) Repair Existing Node"
    echo "5) Generate Join Commands"
    echo "6) Cluster Health Check"
    echo "7) Exit"

    echo


    read -rp "Choice: " MENU_OPTION



    case "${MENU_OPTION}" in


    1)

        source "${ROOT_DIR}/roles/bootstrap.sh"

        ;;


    2)

        source "${ROOT_DIR}/roles/control-plane.sh"

        ;;


    3)

        source "${ROOT_DIR}/roles/worker.sh"

        ;;


    4)

        repair_node

        pause

        ;;


    5)

        generate_join_commands

        pause

        ;;


    6)

        cluster_health

        pause

        ;;


    7)

        echo

        log_info "Exiting installer."

        exit 0

        ;;


    *)

        log_error "Invalid selection."

        sleep 2

        ;;


    esac


done

}