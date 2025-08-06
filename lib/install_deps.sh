#!/usr/bin/env bash

# shellcheck disable=SC2120
determine_pkg_mgr() {
	# sudo used externally
	# shellcheck disable=SC2034
	test "$(id -u)" -eq 0 && SUDO='' || SUDO='sudo '

	# pkg-mgr update-cmd upgrade-cmd install-cmd check-cmd
	# shellcheck disable=SC2016
	local PKG_MGR_MAP='
brew:brew update:brew upgrade:brew install:brew list --formula ${pkg}
apt-get:${SUDO}apt-get update:${SUDO}apt-get upgrade -y:${SUDO}apt-get install -y:dpkg -l ${pkg}
pacman:${SUDO}pacman -Syy:${SUDO}pacman -Syu --noconfirm:${SUDO}pacman -S --noconfirm --needed:pacman -Qi ${pkg}
dnf:${SUDO}dnf check-update || true:${SUDO}dnf upgrade --refresh -y:${SUDO}dnf install -y:dnf list -q --installed ${pkg}
'
	local supported_pkg_mgr=()
	unset pkg_mgr pkg_mgr_update pkg_mgr_upgrade pkg_install pkg_check
	while read -r line; do
		test "${line}" == '' && continue
		IFS=':' read -r pkg_mgr pkg_mgr_update pkg_mgr_upgrade pkg_install pkg_check <<<"${line}"
		supported_pkg_mgr+=("${pkg_mgr}")
		if ! has_cmd "${pkg_mgr}"; then
			pkg_mgr=''
			continue
		fi
		# update/install may use SUDO
		eval "pkg_mgr_update=\"${pkg_mgr_update}\""
		eval "pkg_mgr_upgrade=\"${pkg_mgr_upgrade}\""
		eval "pkg_install=\"${pkg_install}\""
		break
	done <<<"${PKG_MGR_MAP}"

	if [[ ${pkg_mgr} == '' ]]; then
		echo_fail "system does not use a supported package manager" "${supported_pkg_mgr[@]}"
		return 1
	fi

	return 0
}

print_req_pkgs() {
	local common_pkgs=(
		autoconf automake cmake libtool
		texinfo nasm yasm python3 wget
		meson doxygen jq ccache gawk
	)
	# shellcheck disable=SC2034
	local brew_pkgs=(
		"${common_pkgs[@]}" pkgconf
		mkvtoolnix pipx
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
		gobjc++ mawk libnuma-dev libcpuinfo-dev
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
		pipx ninja-build fontconfig-devel wget2
		cpuinfo-devel
	)

	local req_pkgs_env_name="${pkg_mgr/-/_}_pkgs"
	declare -n req_pkgs="${req_pkgs_env_name}"
	local sorted_req_pkgs=($(printf '%s\n' "${req_pkgs[@]}" | sort))
	echo "${sorted_req_pkgs[@]}"
}

FB_FUNC_NAMES+=('print_pkg_mgr')
# FB_FUNC_DESCS used externally
# shellcheck disable=SC2034
FB_FUNC_DESCS['print_pkg_mgr']='print out evaluated package manager commands and required packages'
print_pkg_mgr() {
	determine_pkg_mgr || return 1
	echo "export pkg_mgr=\"${pkg_mgr}\""
	echo "export pkg_mgr_update=\"${pkg_mgr_update}\""
	echo "export pkg_mgr_upgrade=\"${pkg_mgr_upgrade}\""
	echo "export pkg_install=\"${pkg_install}\""
	echo "export pkg_check=\"${pkg_check}\""
	echo "export req_pkgs=($(print_req_pkgs))"
}

print_os() {	
	if [[ -f /etc/os-release ]]; then
		source /etc/os-release ; echo "${ID}-${VERSION_ID}"
	fi
}

check_for_req_pkgs() {
	echo_info "checking for required packages"
	local missing_pkgs=()
	for pkg in $(print_req_pkgs); do
		# pkg_check has ${pkg} unexpanded
		eval "pkg_check=\"${pkg_check}\""
		${pkg_check} "${pkg}" >/dev/null 2>&1 || missing_pkgs+=("${pkg}")
	done

	if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
		echo_warn "missing packages:" "${missing_pkgs[@]}"
		# shellcheck disable=SC2086
		${pkg_mgr_update}
		# shellcheck disable=SC2086
		${pkg_install} "${missing_pkgs[@]}" || return 1
	fi

	echo_pass "packages from ${pkg_mgr} installed"
	echo_if_fail pipx install virtualenv || return 1
	echo_if_fail pipx ensurepath || return 1
	echo_pass "pipx is installed"

	# shellcheck disable=SC1091
	test -f "${HOME}/.cargo/env" && source "${HOME}/.cargo/env"

	if missing_cmd cargo; then
		if missing_cmd rustup; then
			echo_warn "installing rustup"
			curl https://sh.rustup.rs -sSf | sh -s -- -y
			# shellcheck disable=SC2016
			grep -q 'source "${HOME}/.cargo/env"' "${HOME}/.bashrc" ||
				echo 'source "${HOME}/.cargo/env"' >>"${HOME}/.bashrc"
			# shellcheck disable=SC1091
			source "${HOME}/.bashrc"
		fi
	fi

	echo_if_fail rustup default stable || return 1
	echo_if_fail rustup update stable || return 1
	echo_pass "rustup is installed"
	echo_if_fail cargo install cargo-c || return 1
	echo_pass "cargo-c is installed"
	echo_pass "all required packages installed"

	return 0
}

FB_FUNC_NAMES+=('install_deps')
# FB_FUNC_DESCS used externally
# shellcheck disable=SC2034
FB_FUNC_DESCS['install_deps']='install required dependencies'
install_deps() {
	determine_pkg_mgr || return 1
	check_for_req_pkgs || return 1
}
