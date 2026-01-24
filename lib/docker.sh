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
    ensure_dir "${cargo_git}" "${cargo_registry}"
    DOCKER_RUN_FLAGS=(
        --rm
        -v "${cargo_git}:/root/.cargo/git"
        -v "${cargo_registry}:/root/.cargo/registry"
        -v "${REPO_DIR}:${REPO_DIR}"
        -w "${REPO_DIR}"
        -e "DEBUG=${DEBUG}"
        -e "HEADLESS=${HEADLESS}"
        -t
        "--memory-swap=-1"
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
    ubuntu) tag='ubuntu:24.04@sha256:c35e29c9450151419d9448b0fd75374fec4fff364a27f176fb458d472dfc9e54' ;;
    debian) tag='debian:13@sha256:0d01188e8dd0ac63bf155900fad49279131a876a1ea7fac917c62e87ccb2732d' ;;
    fedora) tag='fedora:42@sha256:b3d16134560afa00d7cc2a9e4967eb5b954512805f3fe27d8e70bbed078e22ea' ;;
    archlinux) tag='ogarcia/archlinux:latest@sha256:1d70273180e43b1f51b41514bdaa73c61f647891a53a9c301100d5c4807bf628' ;;
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
FB_FUNC_DESCS['docker_build_image']='build a docker image with the required dependencies pre-installed'
FB_FUNC_COMPLETION['docker_build_image']="${VALID_DOCKER_IMAGES[*]}"
docker_build_image() {
    local image="$1"
    validate_selected_image "${image}" || return 1
    check_docker || return 1
    PLATFORM="${PLATFORM:-$(echo_platform)}"

    echo_info "sourcing package manager for ${image}"
    local dockerDistro="$(get_docker_image_tag "${image}")"
    # specific file for evaluated package manager info
    local distroPkgMgr="${DOCKER_DIR}/$(bash_basename "${image}")-pkg_mgr"
    # get package manager info
    docker run \
        "${DOCKER_RUN_FLAGS[@]}" \
        "${dockerDistro}" \
        bash -c "DEBUG=0 ./scripts/print_pkg_mgr.sh" | tr -d '\r' >"${distroPkgMgr}"
    # shellcheck disable=SC1090
    cat "${distroPkgMgr}"
    # shellcheck disable=SC1090
    source "${distroPkgMgr}"

    local dockerfile="${DOCKER_DIR}/Dockerfile_$(bash_basename "${image}")"
    local embedPath='/Dockerfile'
    {
        echo "FROM ${dockerDistro}"
        echo 'SHELL ["/bin/bash", "-c"]'
        echo 'RUN ln -sf /bin/bash /bin/sh'
        echo 'ENV DEBIAN_FRONTEND=noninteractive'
        echo "RUN ${pkg_mgr_update} && ${pkg_mgr_upgrade} && ${pkg_install} ${req_pkgs[*]}"

        # ENV for pipx/rust
        echo 'ENV PIPX_HOME=/root/.local'
        echo 'ENV PIPX_BIN_DIR=/root/.local/bin'
        echo 'ENV PATH="/root/.local/bin:$PATH"'
        echo 'ENV CARGO_HOME="/root/.cargo"'
        echo 'ENV RUSTUP_HOME="/root/.rustup"'
        echo 'ENV PATH="/root/.cargo/bin:$PATH"'
        # add to profile
        echo 'RUN export PIPX_HOME=${PIPX_HOME} >> /etc/profile'
        echo 'RUN export PIPX_BIN_DIR=${PIPX_BIN_DIR} >> /etc/profile'
        echo 'RUN export CARGO_HOME=${CARGO_HOME} >> /etc/profile'
        echo 'RUN export RUSTUP_HOME=${RUSTUP_HOME} >> /etc/profile'
        echo 'RUN export PATH=${PATH} >> /etc/profile'

        # make nobody:nogroup usable
        echo 'RUN sed -i '/nobody/d' /etc/passwd || true'
        echo 'RUN echo "nobody:x:65534:65534:nobody:/root:/bin/bash" >> /etc/passwd'
        echo 'RUN sed -i '/nogroup/d' /etc/group || true'
        echo 'RUN echo "nogroup:x:65534:" >> /etc/group'
        # open up permissions before switching user
        echo 'RUN chmod 777 -R /root/'
        # run as nobody:nogroup for rest of install
        echo 'USER 65534:65534'
        # pipx
        echo "RUN pipx install virtualenv"
        echo "RUN pipx install meson"
        # rust
        local rustupVersion='1.28.2'
        local rustcVersion='1.90.0'
        local rustupTarball="rustup-${rustupVersion}.tar.gz"
        local rustupTarballPath="${DOCKER_DIR}/${rustupTarball}"
        if [[ ! -f ${rustupTarballPath} ]]; then
            wget https://github.com/rust-lang/rustup/archive/refs/tags/${rustupVersion}.tar.gz -O "${rustupTarballPath}"
        fi

        echo "ADD ${rustupTarball} /tmp/"
        echo "RUN cd /tmp/rustup-${rustupVersion} && bash rustup-init.sh -y --default-toolchain=${rustcVersion}"
        # install cargo-binstall
        echo "RUN curl -L --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/cargo-bins/cargo-binstall/main/install-from-binstall-release.sh | bash"
        # install cargo-c
        echo "RUN cargo-binstall -y cargo-c"

        # final mods for PS1
        echo
        echo 'USER root'
        echo "RUN echo \"PS1='id=\\\$(id -u)@${image}:\w\\$ '\" >> /etc/bash.bashrc"
        echo 'USER 65534:65534'
        echo

        # embed dockerfile into docker image itself
        # shellcheck disable=SC2094
        echo "COPY $(bash_basename "${dockerfile}") ${embedPath}"

        echo "WORKDIR ${DOCKER_WORKDIR}"

    } >"${dockerfile}"

    # docker buildx is too aggressive with invalidating
    # build layer caches. Instead of relying on docker
    # to check for when to rebuild, compare the to-build
    # dockerfile with the embedded dockerfile
    local oldDockerfile="${dockerfile}.old"
    docker_run_image "${image}" cp "${embedPath}" "${oldDockerfile}"
    if diff "${dockerfile}" "${oldDockerfile}"; then
        echo_pass "no dockerfile changes detected, skipping rebuild"
        return 0
    else
        echo_warn "dockerfile changes detected, proceeding with build"
    fi

    image_tag="$(set_distro_image_tag "${image}")"
    docker buildx build \
        --platform "${PLATFORM}" \
        -t "${image_tag}" \
        -f "${dockerfile}" \
        "${DOCKER_DIR}" || return 1

    # if a docker registry is defined, push to it
    if [[ ${DOCKER_REGISTRY} != '' ]]; then
        docker_login || return 1
        docker buildx build \
            --push \
            --platform "${PLATFORM}" \
            -t "${DOCKER_REGISTRY}/${image_tag}" \
            -f "${dockerfile}" \
            "${DOCKER_DIR}" || return 1
    fi
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
    zstdcat -T0 "$archive" | docker load || return 1
    docker system prune -f
}

FB_FUNC_NAMES+=('docker_run_image')
FB_FUNC_DESCS['docker_run_image']='run a docker image with the given arguments'
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

    local image_tag="$(set_distro_image_tag "${image}")"

    # if a docker registry is defined, pull from it
    if [[ ${DOCKER_REGISTRY} != '' ]]; then
        echo_if_fail docker_login || return 1
        echo_if_fail docker pull \
            "${DOCKER_REGISTRY}/${image_tag}" || return 1
        docker tag "${DOCKER_REGISTRY}/${image_tag}" "${image_tag}"
    fi

    echo_info "running docker image ${image_tag}"
    docker run \
        "${DOCKER_RUN_FLAGS[@]}" \
        -u "$(id -u):$(id -g)" \
        "${image_tag}" \
        "${runCmd[@]}"

    local rv=$?
    echo_if_fail docker image prune -f
    return ${rv}
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
