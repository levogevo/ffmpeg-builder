#!/usr/bin/env bash

validate_selected_image() {
	local selectedImage="${1:-}"
	local validImages=(
		'debian:bookworm' 'ubuntu:24.04'
		'archlinux:latest' 'archlinuxarm:latest'
		'fedora:42'
	)
	for distro in "${validImages[@]}"; do
		if [[ ${selectedImage} == "${distro}" ]]; then
			DISTROS+=("${distro}")
		fi
	done
	if [[ ${DISTROS[*]} == '' ]]; then
		echo_fail "${selectedImage} is not valid"
		echo_info "valid images:" "${validImages[@]}"
		return 1
	fi
}

# shellcheck disable=SC2154
FB_FUNC_NAMES+=('docker_build_image')
# FB_FUNC_DESCS used externally
# shellcheck disable=SC2034
FB_FUNC_DESCS['docker_build_image']='build docker image with required dependencies pre-installed'
docker_build_image() {
	validate_selected_image "$@" || return 1
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
		docker run --rm \
			-v "${REPO_DIR}":/workdir \
			-w /workdir \
			"${distro}" \
			bash -c "./scripts/print_pkg_mgr.sh" | tr -d '\r' >"${distroFmtPkgMgr}"
		# shellcheck disable=SC1090
		cat "${distroFmtPkgMgr}"
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
		docker system prune -f
	done
}

# shellcheck disable=SC2154
FB_FUNC_NAMES+=('docker_run_image')
# FB_FUNC_DESCS used externally
# shellcheck disable=SC2034
FB_FUNC_DESCS['docker_run_image']='run docker image to build ffmpeg'
docker_run_image() {
	docker_build_image "$@" || return 1
	for distro in "${DISTROS[@]}"; do
		image_tag="ffmpeg_builder_${distro}"
		echo_info "running ffmpeg build for ${image_tag}"
		docker run --rm \
			-v "${REPO_DIR}":/workdir \
			-w /workdir \
			"${image_tag}" \
			./scripts/build.sh || return 1
	done
}
