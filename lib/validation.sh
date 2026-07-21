check_memory() {

    MEM=$(free -g | awk '/Mem:/ {print $2}')

    if (( MEM < 2 )); then
        log_error "Minimum 2GB RAM required."
        exit 1
    fi

}

check_cpu() {

    CPU=$(nproc)

    if (( CPU < 2 )); then
        log_error "Minimum 2 CPU cores required."
        exit 1
    fi

}

check_internet() {

    if ! ping -c1 google.com >/dev/null 2>&1; then
        log_error "Internet connection unavailable."
        exit 1
    fi

}
