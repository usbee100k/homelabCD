#!/usr/bin/env bash

detect_network() {

    DEFAULT_INTERFACE=$(ip route | awk '/default/ {print $5}')

    LOCAL_IP=$(hostname -I | awk '{print $1}')

    GATEWAY=$(ip route | awk '/default/ {print $3}')

}
