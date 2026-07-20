#!/usr/bin/env bash

pause() {
    read -rp "Press Enter to continue..."
}

header() {
    clear

    echo "========================================="
    echo "      Homelab Installer v0.1"
    echo "========================================="
    echo
}

main_menu() {

    header

    echo "1) Bootstrap Cluster"
    echo "2) Join Control Plane"
    echo "3) Join Worker"
    echo "4) System Information"
    echo "5) Exit"
    echo

    read -rp "Selection: " OPTION

    case "$OPTION" in
        1)
            source roles/bootstrap.sh
            ;;
        2)
            source roles/controlplane.sh
            ;;
        3)
            source roles/worker.sh
            ;;
        4)
            system_information
            pause
            main_menu
            ;;
        5)
            exit 0
            ;;
        *)
            log_error "Invalid Selection"
            sleep 2
            main_menu
            ;;
    esac
}
