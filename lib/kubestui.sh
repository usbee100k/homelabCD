#!/usr/bin/env bash

#############################################
# Install Go + KubesTUI into ${ROOT_DIR}/bin
#############################################

install_go_toolchain() {
    # Keep in step with the "go" line in KubesTUI's go.mod.
    local go_ver="${GO_VERSION:-1.26.8}"
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

    install_kbtui_command

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
        # Build beside it, then swap: a running KubesTUI keeps working.
        CGO_ENABLED=0 go build -o "${dest}.new" .
        mv -f "${dest}.new" "${dest}"
    )

    chmod +x "${dest}"

    log_ok "KubesTUI installed: ${dest}"
}


#############################################
# Workstation builds (Share KubesTUI)
#############################################
#
# Cross-compiles KubesTUI for the computers that may control the cluster
# (Windows, macOS, Linux; amd64 and arm64) into ${ROOT_DIR}/bin/dist,
# with SHA256SUMS. KubesTUI's "Share KubesTUI with a Workstation" serves
# these on the LAN; the file names match the GitHub release assets.
#############################################

build_kubestui_dist() {
    local src="${KUBESTUI_SRC:-${ROOT_DIR}/.src/KubesTUI}"
    local out="${ROOT_DIR}/bin/dist"
    local version target os arch ext

    install_go_toolchain

    [[ -f "${src}/main.go" ]] || {
        log_error "KubesTUI sources not found at ${src}. Run install.sh once to fetch them."
        return 1
    }

    version="$(git -C "${src}" describe --tags --always --dirty 2>/dev/null || echo dev)"

    mkdir -p "${out}"
    rm -f "${out}"/kubestui-* "${out}/SHA256SUMS"

    for target in windows/amd64 windows/arm64 darwin/amd64 darwin/arm64 linux/amd64 linux/arm64; do
        os="${target%/*}"
        arch="${target#*/}"
        ext=""
        [[ "${os}" == windows ]] && ext=".exe"

        log_info "Building kubestui-${os}-${arch}${ext}"

        (
            cd "${src}"
            CGO_ENABLED=0 GOOS="${os}" GOARCH="${arch}" go build -trimpath \
                -ldflags "-s -w -X main.version=${version}" \
                -o "${out}/kubestui-${os}-${arch}${ext}" .
        )
    done

    (cd "${out}" && sha256sum kubestui-* > SHA256SUMS)

    log_ok "Workstation builds ready in ${out} (${version})"
}


#############################################
# kbtui: single-word launcher
#############################################
#
# KubesTUI needs the environment install.sh exports
# (HOMELABCD_INSTALL, VIP_ADDRESS, ...), so the
# launcher goes through install.sh, re-running
# itself with sudo when needed.
#############################################

install_kbtui_command() {

    local target="/usr/local/bin/kbtui"

    cat >"${target}" <<EOF
#!/usr/bin/env bash
# No arguments: open KubesTUI straight away (install.sh hides the startup checks).
if (( \$# == 0 )); then
    set -- --tui
fi
if (( EUID != 0 )); then
    exec sudo bash "${ROOT_DIR}/install.sh" "\$@"
fi
exec bash "${ROOT_DIR}/install.sh" "\$@"
EOF

    chmod 755 "${target}"

    log_ok "KubesTUI launcher installed: kbtui"
}


#############################################
# Update homelabCD and KubesTUI
#############################################
#
# Pulls the latest homelabCD into ROOT_DIR and rebuilds KubesTUI from its
# repository. --autostash keeps the answers the installer saved in
# config/. A running KubesTUI keeps the old version until it is reopened.
#############################################

update_homelabcd() {

    log_info "Updating homelabCD in ${ROOT_DIR}"

    if [[ ! -d "${ROOT_DIR}/.git" ]]; then

        log_warn "${ROOT_DIR} is not a git clone; skipping the homelabCD update."
        log_warn "Clone homelabCD with git to update it from here."

    else

        # Run git as the owner of the clone: as root, git refuses it
        # ("dubious ownership") and would leave root-owned files behind.
        local owner
        local as=()

        owner="$(stat -c %U "${ROOT_DIR}")"
        [[ "${owner}" == "$(id -un)" ]] || as=(runuser -u "${owner}" --)

        local before after

        before="$("${as[@]}" git -C "${ROOT_DIR}" rev-parse --short HEAD)"

        if ! "${as[@]}" git -C "${ROOT_DIR}" pull --ff-only --autostash; then
            log_error "Could not update homelabCD (see the git message above)."
            return 1
        fi

        after="$("${as[@]}" git -C "${ROOT_DIR}" rev-parse --short HEAD)"

        if [[ "${before}" == "${after}" ]]; then
            log_ok "homelabCD is already up to date (${after})."
        else
            log_ok "homelabCD updated: ${before} -> ${after}"
            "${as[@]}" git -C "${ROOT_DIR}" log --oneline "${before}..${after}"
        fi
    fi

    echo

    KUBESTUI_FORCE=1 install_kubestui || return 1

    echo
    log_ok "Update complete. Quit KubesTUI (Q) and run kbtui to use the new version."
    echo "  New templates for your GitOps repo: run \"Update GitOps Templates\" afterwards."
}
