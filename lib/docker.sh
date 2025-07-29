#!/usr/bin/env bash

# shellcheck disable=SC2154
FB_FUNC_NAMES+=('docker_build_images')
# FB_FUNC_DESCS used externally
# shellcheck disable=SC2034
FB_FUNC_DESCS['docker_build_images']='build docker images with required dependencies pre-installed'
docker_build_images() {
	DISTROS=('debian:bookworm' 'ubuntu:24.04' 'archlinux:latest' 'fedora:42')
	# DISTROS=('debian:bookworm')
	DOCKERFILE_DIR="${IGN_DIR}/Dockerfiles"
	test -d "${DOCKERFILE_DIR}" && rm -rf "${DOCKERFILE_DIR}"
	mkdir -p "${DOCKERFILE_DIR}"
	for distro in "${DISTROS[@]}"; do
		image_tag="ffmpeg_builder_${distro}"
		echo_info "source package manager for ${image_tag}"

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
		} >"${dockerfile}"

		echo_info "building ${image_tag}"
		docker build \
			-t "${image_tag}" \
			-f "${dockerfile}" \
			.
	done
}

# shellcheck disable=SC2154
FB_FUNC_NAMES+=('docker_run_image')
# FB_FUNC_DESCS used externally
# shellcheck disable=SC2034
FB_FUNC_DESCS['docker_run_image']='run docker images to build ffmpeg'
docker_run_image() {
	DISTROS=('debian:bookworm' 'ubuntu:24.04' 'archlinux:latest' 'fedora:42')
	# DISTROS=('debian:bookworm')
	DOCKERFILE_DIR="${IGN_DIR}/Dockerfiles"
	test -d "${DOCKERFILE_DIR}" && rm -rf "${DOCKERFILE_DIR}"
	mkdir -p "${DOCKERFILE_DIR}"
	for distro in "${DISTROS[@]}"; do
		image_tag="ffmpeg_builder_${distro}"
		echo_info "source package manager for ${image_tag}"

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
		cat "${distroFmtPkgMgr}"

		dockerfile="${DOCKERFILE_DIR}/Dockerfile_${distroFmt}"
		{
			echo "FROM ${distro}"
			echo 'SHELL ["/bin/bash", "-c"]'
			echo "RUN ${pkg_mgr_update} && ${pkg_mgr_upgrade}"
			echo "RUN ${pkg_install} ${req_pkgs}"
		} >"${dockerfile}"

		echo_info "building ${image_tag}"
		docker build \
			-t "${image_tag}" \
			-f "${dockerfile}" \
			.
	done
}
