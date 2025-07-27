#!/usr/bin/env bash

FB_FUNC_NAMES+=('docker_build_images')
# FB_FUNC_DESCS used externally
# shellcheck disable=SC2034
FB_FUNC_DESCS['docker_build_images']='build docker images with required dependencies pre-installed'
docker_build_images() {
	DISTROS=(debian ubuntu archlinux fedora)
	DOCKERFILE_DIR="${IGN_DIR}/Dockerfiles"
	test -d "${DOCKERFILE_DIR}" || mkdir -p "${DOCKERFILE_DIR}"
	for distro in "${DISTROS[@]}"; do
		echo "\
FROM ${distro}
COPY scripts/ /ffmpeg-builder/scripts/
COPY main.sh /ffmpeg-builder/
RUN bash -c 'source /ffmpeg-builder/main.sh ; install_deps' || exit 1" \
			>"${DOCKERFILE_DIR}/Dockerfile_${distro}"
		image_tag="ffmpeg_builder_${distro}"
		dockerfile="Dockerfile_${distro}"
		echo_info "building ${image_tag}"
		docker build \
			-t "${image_tag}" \
			-f "${DOCKERFILE_DIR}/${dockerfile}" \
			"${REPO_DIR}/"
	done
}
