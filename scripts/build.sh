#!/usr/bin/env bash

set_compile_opts() {
    unset CLEAN OPT_LVL LDFLAGS \
        C_FLAGS CXX_FLAGS CPP_FLAGS \
        CONFIGURE_FLAGS MESON_FLAGS \
        RUSTFLAGS CMAKE_FLAGS \
        FFMPEG_EXTRA_FLAGS \
        PKG_CONFIG_PATH
    export CLEAN OPT_LVL LDFLAGS \
        C_FLAGS CXX_FLAGS CPP_FLAGS \
        CONFIGURE_FLAGS MESON_FLAGS \
        RUSTFLAGS CMAKE_FLAGS \
        FFMPEG_EXTRA_FLAGS \
        PKG_CONFIG_PATH
    
    # set job count for all builds
    JOBS="$(nproc)"
    export JOBS
    
    machine="$(cc -dumpmachine)"
    test "${machine}" != '' || return 1

    # set prefix flags
    CONFIGURE_FLAGS+=("--prefix=${PREFIX}")
    MESON_FLAGS+=("--prefix" "${PREFIX}")
    CMAKE_FLAGS+=("-DCMAKE_PREFIX_PATH=${PREFIX}")
    CMAKE_FLAGS+=("-DCMAKE_INSTALL_PREFIX=${PREFIX}")
    PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH}"
    PKG_CONFIG_PATH="${PREFIX}/lib/${machine}/pkgconfig:${PKG_CONFIG_PATH}"
    echo_info "PKG_CONFIG_PATH = ${PKG_CONFIG_PATH}"

    # add prefix include 
    C_FLAGS+=("-I${PREFIX}/include")

    # enabling a clean build
    if test "$(jq .clean "${COMPILE_CFG}")" == 'true'; then
        CLEAN='make clean ;'
        echo_info "performing clean build"
    else
        CLEAN=''
    fi

    # enabling link-time optimization
    # shellcheck disable=SC2034
    unset LTO_SWITCH LTO_FLAG LTO_BOOL
    export LTO_SWITCH LTO_FLAG LTO_BOOL
    if test "$(jq .lto "${COMPILE_CFG}")" == 'true'; then
        echo_info "building with LTO"
        LTO_SWITCH='ON'
        LTO_FLAG='-flto'
        LTO_BOOL='true'
        C_FLAGS+=("${LTO_FLAG}")
        CONFIGURE_FLAGS+=('--enable-lto')
        RUSTFLAGS+=("-C lto=yes" "-C inline-threshold=1000" "-C codegen-units=1")
    else
        echo_info "building without LTO"
        LTO_SWITCH='OFF'
        LTO_FLAG=''
        LTO_BOOL='false'
        RUSTFLAGS+=("-C lto=no")
    fi

    # setting optimization level
    OPT_LVL="$(jq .optimization "${COMPILE_CFG}")"
    if test "${OPT_LVL}" == ''; then
        OPT_LVL='0'
    fi
    C_FLAGS+=("-O${OPT_LVL}")
    RUSTFLAGS+=("-C opt-level=${OPT_LVL}")
    MESON_FLAGS+=("--optimization=${OPT_LVL}")
    echo_info "building with optimization: ${OPT_LVL}"
    
    # static/shared linking
    unset PKG_CFG_FLAGS
    export PKG_CFG_FLAGS
    if test "$(jq .static "${COMPILE_CFG}")" == 'true'; then
        LDFLAGS+='-static'
        CONFIGURE_FLAGS+=('--enable-static')
        CMAKE_FLAGS+=("-DBUILD_SHARED_LIBS=OFF")
        MESON_FLAGS+=('--default-library=static')
        PKG_CFG_FLAGS='--static'
    fi
    if test "$(jq .shared "${COMPILE_CFG}")" == 'true'; then
        CONFIGURE_FLAGS+=('--enable-shared')
        CMAKE_FLAGS+=("-DBUILD_SHARED_LIBS=ON")
        CMAKE_FLAGS+=("-DCMAKE_INSTALL_RPATH=${PREFIX}/lib;${PREFIX}/lib/${machine}")
        FFMPEG_EXTRA_FLAGS+=('--enable-rpath')
    fi

    # architecture/cpu compile flags
    export CPU ARCH
    CPU="$(jq -r .cpu "${COMPILE_CFG}")"
    ARCH="$(jq -r .arch "${COMPILE_CFG}")"
    # arm prefers -mcpu over -march
    # https://community.arm.com/arm-community-blogs/b/tools-software-ides-blog/posts/compiler-flags-across-architectures-march-mtune-and-mcpu
    arch_flags=""
    test_arch="$(uname -m)"
    if [[ "${test_arch}" == "x86_64" ]]; then
        arch_flags="-march=${CPU}"
    elif [[ "${test_arch}" == "aarch64" || \
            "${test_arch}" == "arm64" ]]
    then
        arch_flags="-mcpu=${CPU}"
    fi

    C_FLAGS+=("${arch_flags}")
    CXX_FLAGS=("${C_FLAGS[@]}")
    CPP_FLAGS=("${C_FLAGS[@]}")
    RUSTFLAGS+=("-C target-cpu=${CPU}")
    CMAKE_FLAGS+=("-DCMAKE_C_FLAGS='${C_FLAGS[*]}'")
    CMAKE_FLAGS+=("-DCMAKE_CXX_FLAGS='${CXX_FLAGS[*]}'")
    dump_arr CONFIGURE_FLAGS
    dump_arr C_FLAGS
    dump_arr RUSTFLAGS
    dump_arr CMAKE_FLAGS
    dump_arr PKG_CFG_FLAGS

    # extra ffmpeg flags
    if [[ "${TARGET_WINDOWS}" == '1' ]]; then
        FFMPEG_EXTRA_FLAGS+=(
            '--cross-prefix=x86_64-w64-mingw32-'
            '--target-os=mingw32'
            '--cc=x86_64-w64-mingw32-gcc'
            '--cxx=x86_64-w64-mingw32-g++'
            '--ar=x86_64-w64-mingw32-gcc-ar'
            '--ranlib=x86_64-w64-mingw32-gcc-ranlib'
            '--nm=x86_64-w64-mingw32-gcc-nm'
        )
    fi
    dump_arr FFMPEG_EXTRA_FLAGS

    # shellcheck disable=SC2178
    RUSTFLAGS="${RUSTFLAGS[*]}"
    echo
}
# set_compile_opts || return 1

get_json_conf() {
    local build="${1}"
    # make sure there is a build config for the enabled build
    test "$(jq -r ".${build}" "$BUILD_CFG")" == 'null' && return 1

    unset ver ext url deps extracted_dir
    export ver ext url deps extracted_dir
    ver="$(jq -r ".${build}.ver" "$BUILD_CFG")"
    ext="$(jq -r ".${build}.ext" "$BUILD_CFG")"
    eval "url=\"$(jq -r ".${build}.url" "$BUILD_CFG")\""
    jq -r ".${build}.deps[]" "$BUILD_CFG" >/dev/null 2>/dev/null && \
        mapfile -t deps < <(jq -r ".${build}.deps[]" "$BUILD_CFG")
    jq -r ".${build}.deps[]" "$BUILD_CFG" >/dev/null 2>/dev/null && \
        mapfile -t deps < <(jq -r ".${build}.deps[]" "$BUILD_CFG")
    extracted_dir="${BUILD_DIR}/${build}-v${ver}"
}

download_release() {
    local build="${1}"
    # set env for wget download
    get_json_conf "${build}" || return 1
    local base_path="${build}-v${ver}"
    local base_dl_path="${DL_DIR}/${base_path}"

    # remove other versions of a download
    for wrong_ver_dl in "${DL_DIR}/${build}"*; do
        if [[ "${wrong_ver_dl}" =~ ${base_path} ]]; then
            continue
        fi
        echo_warn "removing wrong version: ${wrong_ver_dl}"
        rm -rf "${wrong_ver_dl}"
    done
    # remove other versions of a build
    for wrong_ver_build in "${BUILD_DIR}/${build}"*; do
        if [[ "${wrong_ver_build}" =~ ${base_path} ]]; then
            continue
        fi
        echo_warn "removing wrong version: ${extracted_dir}"
        rm -rf "${wrong_ver_build}"
    done

    if test "${ext}" != "git"; then
        wget_out="${base_dl_path}.${ext}"
        
        # download archive if not present
        if ! test -f "${wget_out}"; then
            echo_info "downloading ${build}"
            echo_if_fail wget "${url}" -O "${wget_out}"
        fi

        # create new build directory
        test -d "${extracted_dir}" || \
        {
            mkdir "${extracted_dir}"
            tar -xf "${wget_out}" --strip-components=1 -C "${extracted_dir}"
        }
    else
        # for git downloads
        test -d "${base_dl_path}" || {
            git clone "${url}" "${base_dl_path}" || return 1
            cp -r "${base_dl_path}" "${extracted_dir}" || return 1
        }
    fi
}

FB_FUNC_NAMES+=('do_build')
# shellcheck disable=SC2034
FB_FUNC_DESCS['do_build']='build a specific project'
# shellcheck disable=SC2034
FB_FUNC_COMPLETION['do_build']="${BUILDS[*]}"
do_build() {
    local build="${1}"
    download_release "${build}" || return 1
    get_json_conf "${build}" || return 1
    for dep in "${deps[@]}"; do
        do_build "${dep}" || return 1
    done
    get_json_conf "${build}" || return 1
    echo_info "building ${build}"
    pushd "$extracted_dir" >/dev/null || return 1
    echo_if_fail build_"${build}"
    retval=$?
    popd >/dev/null || return 1
    test ${retval} -eq 0 || return ${retval}
    echo_pass "built ${build}"
}

FB_FUNC_NAMES+=('build')
# shellcheck disable=SC2034
FB_FUNC_DESCS['build']='build ffmpeg with desired configuration'
build() {
    # set_compile_opts || return 1

    test -d "${DL_DIR}" || mkdir -p "${DL_DIR}"
    test -d "${CCACHE_DIR}" || mkdir -p "${CCACHE_DIR}"
    test -d "${BUILD_DIR}" || mkdir -p "${BUILD_DIR}"
    ${SUDO} mkdir -p "${PREFIX}"

    testfile="${PREFIX}/ffmpeg-build-testfile"
    if ! touch "${testfile}" 2> /dev/null; then
        # we cannot modify the install prefix
        # so we need to use sudo        
        unset SUDO
        test "$(id -u)" -eq 0 || SUDO=sudo
        export SUDO
    fi
    test -f "${testfile}" && ${SUDO} rm "${testfile}"

    for build in "${FFMPEG_ENABLES[@]}"; do
        do_build "${build}" || return 1
    done
    do_build "ffmpeg" || return 1

    return 0
}

build_hdr10plus_tool() {
    test "${CLEAN}" != '' && cargo clean
    ccache cargo build --release
    test -d "${PREFIX}/bin/" || mkdir "${PREFIX}/bin/"
    ${SUDO} cp target/release/hdr10plus_tool "${PREFIX}/bin/" || return 1

    # build libhdr10plus
    cd hdr10plus || return 1
    ccache cargo cbuild --release
    ${SUDO} bash -lc "cargo cinstall --prefix=${PREFIX} --release" || return 1
}

build_dovi_tool() {
    test "${CLEAN}" != '' && cargo clean
    ccache cargo build --release
    test -d "${PREFIX}/bin/" || mkdir "${PREFIX}/bin/"
    ${SUDO} cp target/release/dovi_tool "${PREFIX}/bin/" || return 1

    # build libdovi
    cd dolby_vision || return 1
    ccache cargo cbuild --release
    ${SUDO} bash -lc "cargo cinstall --prefix=${PREFIX} --release" || return 1
}

build_libsvtav1_psy() {
    ${SUDO} ${CLEAN}
    cmake \
        "${CMAKE_FLAGS[@]}" \
        -DSVT_AV1_LTO="${LTO_SWITCH}" \
        -DENABLE_AVX512=ON \
        -DBUILD_TESTING=OFF \
        -DCOVERAGE=OFF \
        -DLIBDOVI_FOUND=1 \
        -DLIBHDR10PLUS_RS_FOUND=1 || return 1
    ccache make -j"${JOBS}" || return 1
    ${SUDO} make -j"${JOBS}" install || return 1
}

build_libopus() {
    ${SUDO} ${CLEAN}
    ./configure \
        "${CONFIGURE_FLAGS[@]}" || return 1
    ccache make -j"${JOBS}" || return 1
    ${SUDO} make -j"${JOBS}" install || return 1
    return 0
}

build_libdav1d() {
    test "${CLEAN}" != '' && {
        ${SUDO} rm -rf build.user
        mkdir build.user
    }
    meson \
        setup . build.user \
        "${MESON_FLAGS[@]}" \
        -Dc_args="${C_FLAGS}" \
        -Dcpp_args="${CPP_FLAGS}" \
        -Db_lto="${LTO_BOOL}" || return 1
    ccache ninja -vC build.user || return 1
    ${SUDO} ninja -vC build.user install || return 1
}

build_ffmpeg() {
    for enable in "${FFMPEG_ENABLES[@]}"; do
        test "${enable}" == 'libsvtav1_psy' && enable='libsvtav1'
        CONFIGURE_FLAGS+=("--enable-${enable}")
    done
    ${SUDO} $CLEAN
    ./configure \
        "${CONFIGURE_FLAGS[@]}" \
        "${FFMPEG_EXTRA_FLAGS[@]}" \
        --pkg-config='pkg-config' \
        --pkg-config-flags="${PKG_CFG_FLAGS}" \
        --disable-debug --enable-nonfree \
        --enable-gpl --enable-version3 \
        --cpu="${CPU}" --arch="${ARCH}" \
        --extra-cflags="${C_FLAGS[*]}" \
        --extra-cxxflags="${CXX_FLAGS[*]}" \
        --extra-ldflags="${LDFLAGS}" \
        --disable-doc \
        --disable-htmlpages \
        --disable-podpages \
        --disable-txtpages \
        --disable-autodetect || return 1
    ccache make -j"${JOBS}" || return 1
    ${SUDO} make -j"${JOBS}" install || return 1
    return 0
}