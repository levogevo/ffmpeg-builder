#!/usr/bin/env bash

validate_selected_distro() {
	local distro="${1:-}"
	local validDistros=('debian:bookworm' 'ubuntu:24.04' 'archlinux:latest' 'fedora:42')
	if [[ ${DISTRO} == '' ]]; then
		DISTROS=("${validDistros[@]}")
	else
		DISTROS=("${DISTRO}")
	fi
}

# shellcheck disable=SC2154
FB_FUNC_NAMES+=('docker_build_images')
# FB_FUNC_DESCS used externally
# shellcheck disable=SC2034
FB_FUNC_DESCS['docker_build_images']='build docker images with required dependencies pre-installed'
docker_build_images() {
	validate_selected_distro "$@"
	DOCKERFILE_DIR="${IGN_DIR}/Dockerfiles"
	test -d "${DOCKERFILE_DIR}" && rm -rf "${DOCKERFILE_DIR}"
	mkdir -p "${DOCKERFILE_DIR}"
	for distro in "${DISTROS[@]}"; do
		image_tag="ffmpeg_builder_${distro}"
		echo_info "sourcing package manager for ${image_tag}"

		# distro without problematic characters
		distroFmt="${distro//:/-}"
		# specific file for evaluated package manager info
		distroFmtPkgMgr="${DOCKERFILE_DIR}/${distroFmt}-pkg_mgr"
		# get package manager info
		docker run --rm -it \
			-v "${REPO_DIR}":/workdir \
			-w /workdir \
			"${distro}" \
			bash -c "./scripts/print_pkg_mgr.sh" | tr -d '\r' >"${distroFmtPkgMgr}"
		# shellcheck disable=SC1090
		source "${distroFmtPkgMgr}"

		dockerfile="${DOCKERFILE_DIR}/Dockerfile_${distroFmt}"
		{
			echo "FROM ${distro}"
			echo 'SHELL ["/bin/bash", "-c"]'
			echo "RUN ${pkg_mgr_update} && ${pkg_mgr_upgrade}"
			echo "RUN ${pkg_install} ${req_pkgs}"
			echo 'RUN pipx install virtualenv'
			echo 'RUN pipx ensurepath'
			echo 'RUN curl https://sh.rustup.rs -sSf | bash -s -- -y'
			echo 'RUN ln -sf /bin/bash /bin/sh'
			echo 'ENV PATH="~/.cargo/bin:$PATH"'
			echo 'RUN rustup default stable && rustup update stable'
			echo 'RUN cargo install cargo-c'

		} >"${dockerfile}"

		echo_info "building ${image_tag}"
		docker build \
			-t "${image_tag}" \
			-f "${dockerfile}" \
			. || return 1
	done
}

# shellcheck disable=SC2154
FB_FUNC_NAMES+=('docker_run_image')
# FB_FUNC_DESCS used externally
# shellcheck disable=SC2034
FB_FUNC_DESCS['docker_run_image']='run docker images to build ffmpeg'
docker_run_image() {
	docker_build_images "$@"
	for distro in "${DISTROS[@]}"; do
		image_tag="ffmpeg_builder_${distro}"
		echo_info "running ffmpeg build for ${image_tag}"
		docker run --rm -it \
			-v "${REPO_DIR}":/workdir \
			-w /workdir \
			"${image_tag}" \
			./scripts/build.sh || return 1
	done
}
