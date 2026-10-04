#!/usr/bin/env bash

#############################################
# Install Go + KubesTUI into ${ROOT_DIR}/bin
#############################################

install_go_toolchain() {
    local go_ver="${GO_VERSION:-1.24.6}"
    local arch
    arch="$(uname -m)"

    case "${arch}" in
        x86_64) arch="amd64" ;;
        aarch64 | arm64) arch="arm64" ;;
        *)
            log_error "Unsupported architecture for Go: ${arch}"
            return 1
            ;;
    esac

    export PATH="/usr/local/go/bin:${PATH}"

    if command -v go >/dev/null 2>&1; then
        log_ok "Go already installed: $(go version)"
        return 0
    fi

    log_info "Installing Go ${go_ver}..."

    local tarball="/tmp/go${go_ver}.linux-${arch}.tar.gz"

    curl \
        --fail \
        --location \
        --retry 5 \
        --connect-timeout 20 \
        --max-time 600 \
        -o "${tarball}" \
        "https://go.dev/dl/go${go_ver}.linux-${arch}.tar.gz"

    rm -rf /usr/local/go
    tar -C /usr/local -xzf "${tarball}"
    rm -f "${tarball}"

    export PATH="/usr/local/go/bin:${PATH}"

    command -v go >/dev/null 2>&1 || {
        log_error "Go installation failed"
        return 1
    }

    log_ok "Go installed: $(go version)"
}


install_kubestui() {
    local dest="${ROOT_DIR}/bin/kubestui"
    local src="${KUBESTUI_SRC:-${ROOT_DIR}/.src/KubesTUI}"
    local repo="${KUBESTUI_REPO:-https://github.com/usbee100k/KubesTUI.git}"

    mkdir -p "${ROOT_DIR}/bin" "${ROOT_DIR}/.src"

    if [[ -x "${dest}" && "${KUBESTUI_FORCE:-0}" != "1" ]]; then
        log_ok "KubesTUI already installed: ${dest}"
        return 0
    fi

    install_go_toolchain

    if [[ -d "${src}/.git" ]]; then
        log_info "Updating KubesTUI from ${src}"
        git -C "${src}" pull --ff-only || log_warn "KubesTUI git pull failed; building existing checkout"
    elif [[ -f "${src}/main.go" ]]; then
        log_ok "Using local KubesTUI sources: ${src}"
    else
        log_info "Cloning KubesTUI from ${repo}"
        rm -rf "${src}"
        if ! git clone --depth 1 "${repo}" "${src}"; then
            log_error "Failed to clone ${repo}"
            log_error "Push KubesTUI to GitHub or set KUBESTUI_SRC to a local checkout."
            return 1
        fi
    fi

    log_info "Building KubesTUI -> ${dest}"

    (
        cd "${src}"
        go mod tidy
        CGO_ENABLED=0 go build -o "${dest}" .
    )

    chmod +x "${dest}"

    log_ok "KubesTUI installed: ${dest}"
}
