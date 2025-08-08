#!/usr/bin/env bash

VALID_DOCKER_IMAGES=(
	'ubuntu-22.04' 'ubuntu-24.04'
	'fedora-41' 'fedora-42'
	'debian-12'
	'archlinux-latest'
)
DOCKER_WORKDIR='/workdir'
DOCKER_RUN_FLAGS=(
	--rm
	-v "${REPO_DIR}:${DOCKER_WORKDIR}"
	-w "${DOCKER_WORKDIR}"
	-e "DEBUG=${DEBUG}"
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

echo_platform() {
	local platKernel platCpu
	platKernel="$(uname)"
	platKernel="${platKernel,,}"
	if [[ ${HOSTTYPE} == 'x86_64' ]]; then
		platCpu='amd64'
	else
		platCpu='arm64'
	fi

	echo "${platKernel}/${platCpu}"
}

# sets DISTROS
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

docker_login() {
	echo_if_fail docker login \
		-u "${DOCKER_REGISTRY_USER}" \
		-p "${DOCKER_REGISTRY_PASS}" \
		"${DOCKER_REGISTRY}"
}

FB_FUNC_NAMES+=('docker_build_image')
FB_FUNC_DESCS['docker_build_image']='build docker image with required dependencies pre-installed'
FB_FUNC_COMPLETION['docker_build_image']="${VALID_DOCKER_IMAGES[*]}"
docker_build_image() {
	validate_selected_image "$@" || return 1
	check_docker || return 1
	test -d "${DOCKER_DIR}" || mkdir -p "${DOCKER_DIR}"
	PLATFORM="${PLATFORM:-$(echo_platform)}"

	for distro in "${DISTROS[@]}"; do
		image_tag="$(set_distro_image_tag "${distro}")"
		echo_info "sourcing package manager for ${image_tag}"

		# docker expects colon instead of dash
		dockerDistro="${distro//-/:}"
		# specific file for evaluated package manager info
		distroPkgMgr="${DOCKER_DIR}/${distro}-pkg_mgr"
		# get package manager info

		# TODO REMOVE
		if is_root_owned "${IGN_DIR}"; then
			docker run \
				"${DOCKER_RUN_FLAGS[@]}" \
				"${dockerDistro}" \
				rm -rf "${DOCKER_WORKDIR}"/gitignore
		fi
		if ! echo_if_fail ls; then
			docker run \
				"${DOCKER_RUN_FLAGS[@]}" \
				"${dockerDistro}" \
				rm -rf "${DOCKER_WORKDIR}"/gitignore
		fi

		docker run \
			"${DOCKER_RUN_FLAGS[@]}" \
			"${dockerDistro}" \
			bash -c "./scripts/print_pkg_mgr.sh" | tr -d '\r' >"${distroPkgMgr}"
		# shellcheck disable=SC1090
		cat "${distroPkgMgr}"
		source "${distroPkgMgr}"

		dockerfile="${DOCKER_DIR}/Dockerfile_${distro}"
		{
			echo "FROM ${dockerDistro}"
			echo 'SHELL ["/bin/bash", "-c"]'
			echo 'RUN ln -sf /bin/bash /bin/sh'
			echo 'ENV DEBIAN_FRONTEND=noninteractive'
			echo "RUN ${pkg_mgr_update}"
			echo "RUN ${pkg_mgr_upgrade}"
			printf "RUN ${pkg_install} %s\n" "${req_pkgs[@]}"
			echo 'RUN pipx install virtualenv'
			echo 'RUN pipx ensurepath'
			echo 'RUN curl https://sh.rustup.rs -sSf | bash -s -- -y'
			echo 'ENV PATH="~/.cargo/bin:$PATH"'
			echo 'RUN rustup default stable && rustup update stable'
			echo 'RUN cargo install cargo-c'
			# since any user may run this image,
			# open up root tools to everyone
			echo 'RUN chmod 777 -R /root/'
			echo 'ENV PATH="/root/.cargo/bin:$PATH"'
			echo 'ENV PATH="/root/.local/bin:$PATH"'
			echo 'ENV RUSTUP_HOME="/root/.rustup"'
			echo 'ENV CARGO_HOME="/root/.rustup"'
			echo "WORKDIR ${DOCKER_WORKDIR}"

		} >"${dockerfile}"

		docker buildx build \
			--platform "${PLATFORM}" \
			-t "${image_tag}" \
			-f "${dockerfile}" \
			. || return 1

		# if a docker registry is defined, push to it
		if [[ ${DOCKER_REGISTRY} != '' ]]; then
			docker_login || return 1
			docker buildx build \
				--push \
				--platform "${PLATFORM}" \
				-t "${DOCKER_REGISTRY}/${image_tag}" \
				-f "${dockerfile}" \
				. || return 1
		fi

		docker system prune -f
	done
}

FB_FUNC_NAMES+=('docker_save_image')
FB_FUNC_DESCS['docker_save_image']='save docker image into tar.zst'
FB_FUNC_COMPLETION['docker_save_image']="${VALID_DOCKER_IMAGES[*]}"
docker_save_image() {
	validate_selected_image "$@" || return 1
	check_docker || return 1
	for distro in "${DISTROS[@]}"; do
		image_tag="$(set_distro_image_tag "${distro}")"
		echo_info "saving docker image for ${image_tag}"
		docker save "${image_tag}" |
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
	validate_selected_image "$@" || return 1
	check_docker || return 1

	for distro in "${DISTROS[@]}"; do
		image_tag="$(set_distro_image_tag "${distro}")"

		# if a docker registry is defined, pull from it
		if [[ ${DOCKER_REGISTRY} != '' ]]; then
			docker_login || return 1
			docker pull \
				"${DOCKER_REGISTRY}/${image_tag}"
			docker tag "${DOCKER_REGISTRY}/${image_tag}" "${image_tag}"
		fi

		echo_info "running ffmpeg build for ${image_tag}"

		# TODO REMOVE
		if is_root_owned "${IGN_DIR}"; then
			docker run \
				"${DOCKER_RUN_FLAGS[@]}" \
				"${image_tag}" \
				rm -rf "${DOCKER_WORKDIR}"/gitignore
		fi
		if ! echo_if_fail ls; then
			docker run \
				"${DOCKER_RUN_FLAGS[@]}" \
				"${image_tag}" \
				rm -rf "${DOCKER_WORKDIR}"/gitignore
		fi

		docker run \
			"${DOCKER_RUN_FLAGS[@]}" \
			-u "$(id -u):$(id -g)" \
			"${image_tag}" \
			./scripts/build.sh || return 1
	done
}

FB_FUNC_NAMES+=('docker_build_multiarch_image')
FB_FUNC_DESCS['docker_build_multiarch_image']='build multiarch docker image'
FB_FUNC_COMPLETION['docker_build_multiarch_image']="${VALID_DOCKER_IMAGES[*]}"
docker_build_multiarch_image() {
	validate_selected_image "$@" || return 1
	check_docker || return 1
	PLATFORM='linux/amd64,linux/arm64'

	# check if we need to create multiplatform builder
	local buildxPlats="$(docker buildx inspect | grep Platforms)"
	IFS=','
	local createBuilder=0
	for plat in $PLATFORM; do
		grep -q "${plat}" <<<"${buildxPlats}" || createBuilder=1
	done
	unset IFS

	if [[ ${createBuilder} == 1 ]]; then
		echo_info "creating multiplatform (${PLATFORM}) docker builder"
		docker buildx create \
			--use \
			--platform="${PLATFORM}" \
			--name my-multiplatform-builder \
			--driver=docker-container
	fi

	docker_build_image "$@"
}
