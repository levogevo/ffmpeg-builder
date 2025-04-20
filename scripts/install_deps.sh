#!/usr/bin/env bash

# shellcheck disable=SC2317
# shellcheck disable=SC2034

determine_darwin_pkg_mgr() {
    if ! command -v brew >/dev/null; then
        echo_warning "brew not found"
        echo_info "install brew:"
        # shellcheck disable=SC2016
        echo '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
        return 1
    fi
    PKG_MGR=brew
    check_pkg_exists() { 
        "${PKG_MGR}" list "${1}"
    }
    PKG_MGR_UPD="${PKG_MGR} update"
    PKG_MGR_INST="${PKG_MGR} install"
}

determine_linux_debian_pkg_mgr() {
    if command -v apt-get >/dev/null; then
        PKG_MGR=apt-get
    else
        echo_fail "no package manager found"
        return 1
    fi
    check_pkg_exists() { 
        dpkg -l "${1}" >/dev/null 2>/dev/null
    }
    export DEBIAN_FRONTEND=noninteractive 
    PKG_MGR_UPD="${SUDO} ${PKG_MGR} update"
    PKG_MGR_INST="${SUDO} ${PKG_MGR} install -y"
}

determine_linux_arch_pkg_mgr() {
    if command -v pacman >/dev/null; then
        PKG_MGR=pacman
    else
        echo_fail "no package manager found"
        return 1
    fi
    check_pkg_exists() { 
        local pkg_check="${1}"
        "${PKG_MGR}" -Qi "${pkg_check}" >/dev/null 2>/dev/null
    }
    PKG_MGR_UPD="${SUDO} ${PKG_MGR} -Syy"
    PKG_MGR_INST="${SUDO} ${PKG_MGR} -S --noconfirm --needed"
}

determine_linux_fedora_pkg_mgr() {
    if command -v dnf >/dev/null; then
        PKG_MGR=dnf
    else
        echo_fail "no package manager found"
        return 1
    fi
    check_pkg_exists() { 
        local pkg_check="${1}"
        test "${pkg_check}" == 'wget' && pkg_check=wget2
        "${PKG_MGR}" list -q --installed "${pkg_check}" >/dev/null 2>/dev/null
    }
    PKG_MGR_UPD="${SUDO} ${PKG_MGR} check-update"
    PKG_MGR_INST="${SUDO} ${PKG_MGR} install -y"
}

determine_os() {
    unset OS
    local UNAME="$(uname)"
    if test "${UNAME}" == 'Linux'; then
        # shellcheck disable=SC1091
        source /etc/os-release
        OS="${UNAME}-${ID_LIKE}"
    elif test "${UNAME}" == 'Darwin'; then
        OS="${UNAME}"
    else
        echo_exit "Unable to determine OS for ${UNAME}"
    fi
    export OS
    OS="${OS,,}"
    OS="${OS//-/_}"
    
    if test "$(jq -r ".target_windows" "$COMPILE_CFG")" == 'true'; then
        echo_info "targeting windows"
        export TARGET_WINDOWS=1
        OS+="_windows"
    fi

    return 0
}

determine_pkg_mgr() {
    unset PKG_MGR PKG_MGR_UPD PKG_MGR_INST
    determine_"${OS}"_pkg_mgr
    return 0
}

check_for_req_pkgs() {
    echo_info "OS=${OS}"
    echo_info "checking for required packages"
    local common_pkgs=(
        autoconf automake cmake libtool 
        texinfo wget nasm yasm python3
        meson doxygen jq ccache gawk
    )
    # shellcheck disable=SC2034
    local brew_pkgs=(
        "${common_pkgs[@]}" pkgconf mkvtoolnix
    )
    local common_linux_pkgs=(
        "${common_pkgs[@]}" clang valgrind
        curl bc lshw xxd pkgconf 
    )
    # shellcheck disable=SC2034
    local apt_get_pkgs=(
        "${common_linux_pkgs[@]}" build-essential
        git-core libass-dev libfreetype6-dev
        libsdl2-dev libva-dev libvdpau-dev
        libvorbis-dev libxcb1-dev pipx 
        libxcb-shm0-dev libxcb-xfixes0-dev
        zlib1g-dev libssl-dev ninja-build
        gobjc++ mawk libnuma-dev
        mediainfo mkvtoolnix libgtest-dev
    )
    # shellcheck disable=SC2034
    local pacman_pkgs=(
        "${common_linux_pkgs[@]}" base-devel
        python-pipx ninja
    )
    # shellcheck disable=SC2034
    local dnf_pkgs=(
        "${common_linux_pkgs[@]}" openssl-devel
        pipx ninja-build
    )

    if test "${TARGET_WINDOWS}" -eq 1; then
        apt_get_pkgs+=(gcc-mingw-w64 g++-mingw-w64)
    fi

    local req_pkgs_env_name="${PKG_MGR/-/_}_pkgs"
    declare -n req_pkgs="${req_pkgs_env_name}"
    local missing_pkgs=()
    for pkg in "${req_pkgs[@]}"; do
        check_pkg_exists "${pkg}" || missing_pkgs+=("${pkg}")
    done
    if ! test "${#missing_pkgs}" -eq 0; then
        echo_warn "missing packages:" "${missing_pkgs[@]}"
        # shellcheck disable=SC2086
        ${PKG_MGR_UPD}
        # shellcheck disable=SC2086
        ${PKG_MGR_INST} "${missing_pkgs[@]}" || return 1
    fi
    echo_pass "packages from ${PKG_MGR} installed"
    echo_if_fail pipx install virtualenv || return 1
    echo_if_fail pipx ensurepath || return 1
    echo_pass "pipx is installed"
    # shellcheck disable=SC1091
    test -f "${HOME}/.cargo/env" && source "${HOME}/.cargo/env"

    if ! command -v cargo >/dev/null; then
        echo_warn "missing cargo"

        if ! command -v rustup >/dev/null; then
            echo_warn "missing rustup"
            echo_warn "installing rustup"
            curl https://sh.rustup.rs -sSf | sh -s -- -y
            # shellcheck disable=SC2016
            grep -q 'source "${HOME}/.cargo/env"' "${HOME}/.bashrc" || \
                echo 'source "${HOME}/.cargo/env"' >> "${HOME}/.bashrc"
            # shellcheck disable=SC1091
            source "${HOME}/.bashrc"
        fi
    fi

    echo_if_fail rustup default stable
    echo_if_fail rustup update stable
    echo_pass "rustup is installed"
    echo_if_fail cargo install cargo-c || return 1
    echo_pass "cargo-c is installed"
    echo_pass "all required packages installed"
    return 0
}

FB_FUNC_NAMES+=('install_deps')
FB_FUNC_DESCS['install_deps']='install required dependencies'
install_deps() {
    unset SUDO
    test "$(id -u)" -eq 0 || SUDO=sudo
    determine_pkg_mgr || return 1
    check_for_req_pkgs || return 1
}