#!/usr/bin/env bash

VALID_DOCKER_IMAGES=(
	'ubuntu'
	'fedora'
	'debian'
	'archlinux'
)
DOCKER_WORKDIR='/workdir'

set_docker_run_flags() {
	local cargo_git="${IGN_DIR}/cargo/git"
	local cargo_registry="${IGN_DIR}/cargo/registry"
	test -d "${cargo_git}" || mkdir -p "${cargo_git}"
	test -d "${cargo_registry}" || mkdir -p "${cargo_registry}"
	DOCKER_RUN_FLAGS=(
		--rm
		-v "${cargo_git}:/root/.cargo/git"
		-v "${cargo_registry}:/root/.cargo/registry"
		-v "${REPO_DIR}:${REPO_DIR}"
		-w "${REPO_DIR}"
		-e "DEBUG=${DEBUG}"
	)
	for opt in "${FB_COMP_OPTS[@]}"; do
		declare -n defOptVal="DEFAULT_${opt}"
		declare -n optVal="${opt}"
		if [[ -v optVal && ${optVal} != "${defOptVal}" ]]; then
			DOCKER_RUN_FLAGS+=("-e" "${opt}=${optVal}")
		fi
	done
}

check_docker() {
	if missing_cmd docker; then
		echo_info "install docker"
		curl https://get.docker.com -sSf | bash
	fi
	set_docker_run_flags || return 1
}

# get full image digest for a given image
get_docker_image_tag() {
	local image="$1"
	local tag=''
	case "${image}" in
	ubuntu) tag='ubuntu:24.04@sha256:9cbed754112939e914291337b5e554b07ad7c392491dba6daf25eef1332a22e8' ;;
	debian) tag='debian:13@sha256:833c135acfe9521d7a0035a296076f98c182c542a2b6b5a0fd7063d355d696be' ;;
	fedora) tag='fedora:42@sha256:6af051ad0a294182c3a957961df6203d91f643880aa41c2ffe3d1302e7505890' ;;
	archlinux) tag='debian:13@sha256:833c135acfe9521d7a0035a296076f98c182c542a2b6b5a0fd7063d355d696be' ;;
	esac
	echo "${tag}"
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

validate_selected_image() {
	local selectedImage="$1"
	local valid=1
	for image in "${VALID_DOCKER_IMAGES[@]}"; do
		if [[ ${selectedImage} == "${image}" ]]; then
			valid=0
			break
		fi
	done
	if [[ valid -eq 1 ]]; then
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
	local image="$1"
	validate_selected_image "${image}" || return 1
	check_docker || return 1
	test -d "${DOCKER_DIR}" || mkdir -p "${DOCKER_DIR}"
	PLATFORM="${PLATFORM:-$(echo_platform)}"

	echo_info "sourcing package manager for ${image}"
	local dockerDistro="$(get_docker_image_tag "${image}")"
	# specific file for evaluated package manager info
	distroPkgMgr="${DOCKER_DIR}/$(bash_basename "${image}")-pkg_mgr"
	# get package manager info
	docker run \
		"${DOCKER_RUN_FLAGS[@]}" \
		"${dockerDistro}" \
		bash -c "./scripts/print_pkg_mgr.sh" | tr -d '\r' >"${distroPkgMgr}"
	# shellcheck disable=SC1090
	cat "${distroPkgMgr}"
	# shellcheck disable=SC1090
	source "${distroPkgMgr}"

	dockerfile="${DOCKER_DIR}/Dockerfile_$(bash_basename "${image}")"
	{
		echo "FROM ${dockerDistro}"
		echo 'SHELL ["/bin/bash", "-c"]'
		echo 'RUN ln -sf /bin/bash /bin/sh'
		echo 'ENV DEBIAN_FRONTEND=noninteractive'
		# arch is rolling release, so highly likely
		# an updated is required between pkg changes
		if line_contains "${dockerDistro}" 'arch'; then
			local archRuns=''
			archRuns+="${pkg_mgr_update}"
			archRuns+=" && ${pkg_mgr_upgrade}"
			archRuns+=" && ${pkg_install} ${req_pkgs[*]}"
			echo "RUN ${archRuns}"
		else
			echo "RUN ${pkg_mgr_update}"
			echo "RUN ${pkg_mgr_upgrade}"
			printf "RUN ${pkg_install} %s\n" "${req_pkgs[@]}"
		fi
		echo 'RUN pipx install virtualenv'
		echo 'RUN pipx ensurepath'
		echo 'ENV CARGO_HOME="/root/.cargo"'
		echo 'ENV RUSTUP_HOME="/root/.rustup"'
		echo 'ENV PATH="/root/.cargo/bin:$PATH"'
		local rustupVersion='1.28.2'
		local rustcVersion='1.88.0'
		local cargoInst=''
		cargoInst+="cd tmp && wget https://github.com/rust-lang/rustup/archive/refs/tags/${rustupVersion}.tar.gz -O rustup.tar.gz"
		cargoInst+=" && tar -xf rustup.tar.gz && cd rustup-${rustupVersion}"
		cargoInst+=" && bash rustup-init.sh -y --default-toolchain=${rustcVersion}"
		cargoInst+=" && rm -rf /tmp/*"
		echo "RUN ${cargoInst}"
		echo "RUN cargo install cargo-c"
		# since any user may run this image,
		# open up root tools to everyone
		echo 'ENV PATH="/root/.local/bin:$PATH"'
		echo 'RUN chmod 777 -R /root/'
		echo "WORKDIR ${DOCKER_WORKDIR}"

	} >"${dockerfile}"

	image_tag="$(set_distro_image_tag "${image}")"
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
}

FB_FUNC_NAMES+=('docker_save_image')
FB_FUNC_DESCS['docker_save_image']='save docker image into tar.zst'
FB_FUNC_COMPLETION['docker_save_image']="${VALID_DOCKER_IMAGES[*]}"
docker_save_image() {
	local image="$1"
	validate_selected_image "${image}" || return 1
	check_docker || return 1
	image_tag="$(set_distro_image_tag "${image}")"
	echo_info "saving docker image for ${image_tag}"
	docker save "${image_tag}" |
		zstd -T0 >"${DOCKER_DIR}/$(docker_image_archive_name "${image_tag}")" ||
		return 1
}

FB_FUNC_NAMES+=('docker_load_image')
FB_FUNC_DESCS['docker_load_image']='load docker image from tar.zst'
FB_FUNC_COMPLETION['docker_load_image']="${VALID_DOCKER_IMAGES[*]}"
docker_load_image() {
	local image="$1"
	validate_selected_image "${image}" || return 1
	check_docker || return 1
	image_tag="$(set_distro_image_tag "${image}")"
	echo_info "loading docker image for ${image_tag}"
	local archive="${DOCKER_DIR}/$(docker_image_archive_name "${image_tag}")"
	test -f "$archive" || return 1
	zstdcat -T0 "$archive" |
		docker load || return 1
	docker system prune -f
}

FB_FUNC_NAMES+=('docker_run_image')
FB_FUNC_DESCS['docker_run_image']='run docker image with given flags'
FB_FUNC_COMPLETION['docker_run_image']="${VALID_DOCKER_IMAGES[*]}"
docker_run_image() {
	local image="$1"
	shift
	validate_selected_image "${image}" || return 1
	check_docker || return 1

	local cmd=("$@")
	local runCmd=()
	if [[ ${cmd[*]} == '' ]]; then
		DOCKER_RUN_FLAGS+=("-it")
	else
		runCmd+=("${cmd[@]}")
	fi

	image_tag="$(set_distro_image_tag "${image}")"

	# if a docker registry is defined, pull from it
	if [[ ${DOCKER_REGISTRY} != '' ]]; then
		docker_login || return 1
		docker pull \
			"${DOCKER_REGISTRY}/${image_tag}" || return 1
		docker tag "${DOCKER_REGISTRY}/${image_tag}" "${image_tag}"
	fi

	echo_info "running ffmpeg build with ${image_tag}"
	docker run \
		"${DOCKER_RUN_FLAGS[@]}" \
		-u "$(id -u):$(id -g)" \
		"${image_tag}" \
		"${runCmd[@]}" || return 1

	docker system prune -f

	return 0
}

FB_FUNC_NAMES+=('build_with_docker')
FB_FUNC_DESCS['build_with_docker']='run docker image with given flags'
FB_FUNC_COMPLETION['build_with_docker']="${VALID_DOCKER_IMAGES[*]}"
build_with_docker() {
	local image="$1"
	docker_run_image "${image}" ./scripts/build.sh || return 1
}

FB_FUNC_NAMES+=('docker_build_multiarch_image')
FB_FUNC_DESCS['docker_build_multiarch_image']='build multiarch docker image'
FB_FUNC_COMPLETION['docker_build_multiarch_image']="${VALID_DOCKER_IMAGES[*]}"
docker_build_multiarch_image() {
	local image="$1"
	validate_selected_image "${image}" || return 1
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
