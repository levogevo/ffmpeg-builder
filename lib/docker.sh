#!/usr/bin/env bash

VALID_DOCKER_IMAGES=(
	'ubuntu-22.04' 'ubuntu-24.04'
	'fedora-41' 'fedora-42'
	'archlinux-latest'
	'debian-bookworm'
)

check_docker() {
	if missing_cmd docker; then
		echo_info "install docker"
		curl https://get.docker.com -sSf | bash
	fi
}

# change dash to colon for docker and add namespace
set_distro_image_tag() {
	local image_tag="${1}"
	echo "ffmpeg_builder_${image_tag//-/:}"
}

# change colon to dash and add extension type
docker_image_archive_name() {
	local image_tag="${1}"
	echo "${image_tag//:/-}.tar.zst"
}

validate_selected_image() {
	local selectedImage="${1:-}"
	for distro in "${VALID_DOCKER_IMAGES[@]}"; do
		if [[ ${selectedImage} == "${distro}" ]]; then
			DISTROS+=("${distro}")
		fi
	done
	if [[ ${DISTROS[*]} == '' ]]; then
		echo_fail "${selectedImage} is not valid"
		echo_info "valid images:" "${VALID_DOCKER_IMAGES[@]}"
		return 1
	fi
}

FB_FUNC_NAMES+=('docker_build_image')
FB_FUNC_DESCS['docker_build_image']='build docker image with required dependencies pre-installed'
FB_FUNC_COMPLETION['docker_build_image']="${VALID_DOCKER_IMAGES[*]}"
docker_build_image() {
	validate_selected_image "$@" || return 1
	check_docker || return 1
	test -d "${DOCKER_DIR}" || mkdir -p "${DOCKER_DIR}"
	local platform="${PLATFORM:-linux/amd64}"
	for distro in "${DISTROS[@]}"; do
		image_tag="$(set_distro_image_tag "${distro}")"
		echo_info "sourcing package manager for ${image_tag}"

		# distro without problematic characters
		distroFmt="${distro//:/-}"
		# specific file for evaluated package manager info
		distroFmtPkgMgr="${DOCKER_DIR}/${distroFmt}-pkg_mgr"
		# get package manager info
		docker run --rm \
			--platform "${platform}" \
			-v "${REPO_DIR}":/workdir \
			-w /workdir \
			"${distro}" \
			bash -c "./scripts/print_pkg_mgr.sh" | tr -d '\r' >"${distroFmtPkgMgr}"
		# shellcheck disable=SC1090
		cat "${distroFmtPkgMgr}"
		source "${distroFmtPkgMgr}"

		dockerfile="${DOCKER_DIR}/Dockerfile_${distroFmt}"
		{
			echo "FROM ${distro}"
			echo 'SHELL ["/bin/bash", "-c"]'
			echo 'RUN ln -sf /bin/bash /bin/sh'
			echo 'ENV DEBIAN_FRONTEND=noninteractive'
			echo "RUN ${pkg_mgr_update} && ${pkg_mgr_upgrade}"
			echo "RUN ${pkg_install} ${req_pkgs}"
			echo 'RUN pipx install virtualenv'
			echo 'RUN pipx ensurepath'
			echo 'RUN curl https://sh.rustup.rs -sSf | bash -s -- -y'
			echo 'ENV PATH="~/.cargo/bin:$PATH"'
			echo 'RUN rustup default stable && rustup update stable'
			echo 'RUN cargo install cargo-c'

		} >"${dockerfile}"

		echo_info "building ${image_tag}"
		docker build \
			--platform "${platform}" \
			-t "${image_tag}" \
			-f "${dockerfile}" \
			. || return 1
		docker system prune -f
	done
}

FB_FUNC_NAMES+=('docker_save_image')
FB_FUNC_DESCS['docker_save_image']='save docker image into tar.zst'
FB_FUNC_COMPLETION['docker_save_image']="${VALID_DOCKER_IMAGES[*]}"
docker_save_image() {
	validate_selected_image "$@" || return 1
	check_docker || return 1
	local platform="${PLATFORM:-linux/amd64}"
	for distro in "${DISTROS[@]}"; do
		image_tag="$(set_distro_image_tag "${distro}")"
		echo_info "saving docker image for ${image_tag}"
		docker save --platform "${platform}" "${image_tag}" |
			zstd -T0 >"${DOCKER_DIR}/$(docker_image_archive_name "${image_tag}")" ||
			return 1
	done
}

FB_FUNC_NAMES+=('docker_load_image')
FB_FUNC_DESCS['docker_load_image']='load docker image from tar.zst'
FB_FUNC_COMPLETION['docker_load_image']="${VALID_DOCKER_IMAGES[*]}"
docker_load_image() {
	validate_selected_image "$@" || return 1
	check_docker || return 1
	local platform="${PLATFORM:-linux/amd64}"
	for distro in "${DISTROS[@]}"; do
		image_tag="$(set_distro_image_tag "${distro}")"
		echo_info "loading docker image for ${image_tag}"
		local archive="${DOCKER_DIR}/$(docker_image_archive_name "${image_tag}")"
		test -f "$archive" || return 1
		zstdcat -T0 "$archive" |
			docker load || return 1
		docker system prune -f
	done
}

FB_FUNC_NAMES+=('docker_run_image')
FB_FUNC_DESCS['docker_run_image']='run docker image to build ffmpeg'
FB_FUNC_COMPLETION['docker_run_image']="${VALID_DOCKER_IMAGES[*]}"
docker_run_image() {
	check_docker || return 1
	local platform="${PLATFORM:-linux/amd64}"
	for distro in "${DISTROS[@]}"; do
		image_tag="$(set_distro_image_tag "${distro}")"
		echo_info "running ffmpeg build for ${image_tag}"
		docker run --rm \
			--platform "${platform}" \
			-v "${REPO_DIR}":/workdir \
			-w /workdir \
			"${image_tag}" \
			./scripts/build.sh || return 1
	done
}

FB_FUNC_NAMES+=('docker_run_amd64_image_on_arm64')
FB_FUNC_DESCS['docker_run_amd64_image_on_arm64']='run docker image to build ffmpeg for amd64 on arm64'
FB_FUNC_COMPLETION['docker_run_amd64_image_on_arm64']="${VALID_DOCKER_IMAGES[*]}"
docker_run_amd64_image_on_arm64() {
	if missing_cmd qemu-x86_64-static; then
		determine_pkg_mgr || return 1
		${pkg_install} qemu-user-static || return 1
	fi
	check_docker || return 1
	docker run --privileged --rm tonistiigi/binfmt --install all || return 1
	docker_run_image "$@"
}
