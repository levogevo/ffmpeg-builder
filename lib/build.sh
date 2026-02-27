#!/usr/bin/env bash

set_compile_opts() {
    test "${FB_COMPILE_OPTS_SET}" == 1 && return 0

    EXPORTED_ENV_NAMES=(
        CC
        CFLAGS
        CXX
        CXXFLAGS
        CPPFLAGS
        LDFLAGS
        RUSTFLAGS
        PKG_CONFIG_PATH
    )
    BUILD_ENV_NAMES=(
        "${EXPORTED_ENV_NAMES[@]}"
        CFLAGS_ARR
        CPPFLAGS_ARR
        LDFLAGS_ARR
        USE_LD
        RUSTFLAGS_ARR
        CONFIGURE_FLAGS
        MESON_FLAGS
        CMAKE_FLAGS
        FFMPEG_EXTRA_FLAGS
        CARGO_CINSTALL_FLAGS
        LTO_FLAG
        PGO_FLAG
        LIB_SUFF
        BUILD_TYPE
    )
    unset "${BUILD_ENV_NAMES[@]}"
    export "${EXPORTED_ENV_NAMES[@]}"

    # set job count for all builds
    JOBS="$(nproc)"
    # local vs system prefix
    test "${PREFIX}" == 'local' && PREFIX="${LOCAL_PREFIX}"

    # check if we need to handle PREFIX with sudo
    local testfile=''
    if [[ -d ${PREFIX} ]]; then
        testfile="${PREFIX}/ffmpeg-build-testfile"
    else
        # try creating in parent path
        testfile="$(bash_dirname "${PREFIX}")/ffmpeg-build-testfile"
    fi
    unset SUDO_MODIFY
    if touch "${testfile}" 2>/dev/null; then
        SUDO_MODIFY=''
    else
        SUDO_MODIFY="${SUDO}"
        echo_warn "using ${SUDO}to install"
        ${SUDO_MODIFY} mkdir -p "${PREFIX}/bin/" || return 1
    fi
    test -f "${testfile}" && ${SUDO_MODIFY} rm "${testfile}"
    test -d "${PREFIX}" || { ${SUDO_MODIFY} mkdir -p "${PREFIX}" || return 1; }

    # set library/pkgconfig directory
    LIBDIR="${PREFIX}/lib"
    LDFLAGS_ARR=("-L${LIBDIR}")

    # android has different library location/names
    # cannot build static due to missing liblog
    if is_android; then
        if [[ ${STATIC} == 'ON' ]]; then
            echo_warn "$(print_os) does not support STATIC=${STATIC}"
            STATIC=OFF
            echo_warn "setting STATIC=${STATIC}"
        fi
        LDFLAGS_ARR+=(
            "-L/system/lib64"
            "-lm"
            "-landroid-shmem"
            "-landroid-posix-semaphore"
        )
    fi

    # use clang
    CC=clang
    CXX=clang++
    CMAKE_FLAGS+=(
        "-DCMAKE_C_COMPILER=${CC}"
        "-DCMAKE_CXX_COMPILER=${CXX}"
    )
    FFMPEG_EXTRA_FLAGS+=(
        "--cc=${CC}"
        "--cxx=${CXX}"
    )

    # hack PATH to inject use of lld as linker
    # PATH cc/c++ may be hardcoded as gcc
    # which breaks when trying to use clang/lld
    # not supported on darwin
    if ! is_darwin; then
        USE_LD=lld
        LDFLAGS_ARR+=("-fuse-ld=${USE_LD}")
        # android does not like LINKER_TYPE despite only using lld
        if ! is_android; then
            CMAKE_FLAGS+=("-DCMAKE_LINKER_TYPE=${USE_LD^^}")
        fi
        CMAKE_FLAGS+=("-DCMAKE_LINKER=${USE_LD}")
        local compilerDir="${LOCAL_PREFIX}/compiler-tools"
        recreate_dir "${compilerDir}" || return 1
        # real:gnu:clang:generic
        local compilerMap="\
${CC}:gcc:clang:cc
${CXX}:g++:clang++:c++
ld.lld:ld:lld:ld"
        local realT gnuT clangT genericT
        while read -r line; do
            IFS=: read -r realT gnuT clangT genericT <<<"${line}"
            # full path to the real tool
            realT="$(command -v "${realT}")"

            # add fuse-ld for the compiler
            local addFlag='-v'
            if line_contains "${realT}" clang; then addFlag+=" -fuse-ld=${USE_LD}"; fi

            # create generic tool version
            echo "#!/usr/bin/env bash
echo \$@ > ${compilerDir}/${genericT}.last-command
exec \"${realT}\" ${addFlag} \"\$@\"" >"${compilerDir}/${genericT}"
            chmod +x "${compilerDir}/${genericT}"
            echo_if_fail "${compilerDir}/${genericT}" --version || return 1

            # copy generic to gnu/clang variants
            # cp "${compilerDir}/${genericT}" "${compilerDir}/${gnuT}" 2>/dev/null
            # cp "${compilerDir}/${genericT}" "${compilerDir}/${clangT}" 2>/dev/null
        done <<<"${compilerMap}"

        # also add fake which command in case one does not exist
        # shellcheck disable=SC2016
        echo '#!/usr/bin/env bash
which=""
test -f /bin/which && which=/bin/which
test -f /usr/bin/which && which=/usr/bin/which
if [[ ${which} == "" ]]; then
    command -v "$@"
else
    ${which} "$@"
fi' >"${compilerDir}/which"
        chmod +x "${compilerDir}/which"
        export PATH="${compilerDir}:${PATH}"
    fi

    # set prefix flags and basic flags
    CONFIGURE_FLAGS+=(
        "--prefix=${PREFIX}"
        "--libdir=${LIBDIR}"
        "--disable-debug"
    )
    MESON_FLAGS+=(
        "--prefix" "${PREFIX}"
        "--libdir" "lib"
        "--bindir" "bin"
        "--buildtype" "release"
    )
    CMAKE_FLAGS+=(
        "-DCMAKE_PREFIX_PATH=${PREFIX}"
        "-DCMAKE_INSTALL_PREFIX=${PREFIX}"
        "-DCMAKE_INSTALL_LIBDIR=lib"
        "-DCMAKE_BUILD_TYPE=Release"
        "-DCMAKE_C_COMPILER_LAUNCHER=ccache"
        "-DCMAKE_CXX_COMPILER_LAUNCHER=ccache"
        "-DCMAKE_VERBOSE_MAKEFILE=ON"
        "-G" "Ninja"
        "-DENABLE_STATIC=${STATIC}"
        "-DBUILD_STATIC_LIBS=${STATIC}"
        "-DBUILD_TESTING=OFF"
    )
    CARGO_CINSTALL_FLAGS=(
        "--release"
        "--verbose"
        "--prefix" "${PREFIX}"
        "--libdir" "${LIBDIR}"
    )
    PKG_CONFIG_PATH="${LIBDIR}/pkgconfig"

    # add prefix include
    # TODO use cygpath for windows
    CPPFLAGS_ARR+=("-I${PREFIX}/include")

    # if PGO is enabled, first build run will be to generate
    # second run will be to use generated profdata
    if [[ ${PGO} == 'ON' ]]; then
        if [[ ${PGO_RUN} == 'generate' ]]; then
            PGO_FLAG="-fprofile-generate"
            CFLAGS_ARR+=("${PGO_FLAG}")
            LDFLAGS_ARR+=("${PGO_FLAG}")
        else
            PGO_FLAG="-fprofile-use=${PGO_PROFDATA}"
            CFLAGS_ARR+=("${PGO_FLAG}")
            LDFLAGS_ARR+=("${PGO_FLAG}")
        fi
    fi

    # enabling link-time optimization
    if [[ ${LTO} == 'ON' ]]; then
        LTO_FLAG='-flto=full'
        CFLAGS_ARR+=("${LTO_FLAG}")
        LDFLAGS_ARR+=("${LTO_FLAG}")
        CONFIGURE_FLAGS+=('--enable-lto')
        MESON_FLAGS+=("-Db_lto=true")
    else
        LTO_FLAG='unreachable-flag'
        MESON_FLAGS+=("-Db_lto=false")
    fi
    # setting optimization level
    if [[ ${OPT} == '' ]]; then
        OPT='0'
    fi
    CFLAGS_ARR+=("-O${OPT}")
    MESON_FLAGS+=("--optimization=${OPT}")

    STATIC_LIB_SUFF='a'
    # darwin has different suffix for dynamic libraries
    if is_darwin; then
        SHARED_LIB_SUFF='dylib'
    else
        SHARED_LIB_SUFF='so'
    fi

    # least problematic place to set this
    CMAKE_FLAGS+=("-DCMAKE_EXE_LINKER_FLAGS=${LDFLAGS_ARR[*]}")

    # static/shared linking
    if [[ ${STATIC} == 'ON' ]]; then
        BUILD_TYPE=static
        CONFIGURE_FLAGS+=(
            '--enable-static'
            '--disable-shared'
        )
        MESON_FLAGS+=('--default-library=static')
        CMAKE_FLAGS+=(
            "-DENABLE_SHARED=OFF"
            "-DBUILD_SHARED_LIBS=OFF"
        )
        # darwin does not support -static
        if is_darwin; then
            FFMPEG_EXTRA_FLAGS+=("--extra-ldflags=${LDFLAGS_ARR[*]}")
        else
            FFMPEG_EXTRA_FLAGS+=("--extra-ldflags=${LDFLAGS_ARR[*]} -static")
        fi
        FFMPEG_EXTRA_FLAGS+=("--pkg-config-flags=--static")
        # remove shared libraries for static builds
        USE_LIB_SUFF="${STATIC_LIB_SUFF}"
        DEL_LIB_SUFF="${SHARED_LIB_SUFF}"
    else
        BUILD_TYPE=shared
        CMAKE_FLAGS+=(
            "-DENABLE_SHARED=ON"
            "-DBUILD_SHARED_LIBS=ON"
            "-DCMAKE_INSTALL_RPATH=${LIBDIR}"
            "-DCMAKE_BUILD_WITH_INSTALL_RPATH=ON"
        )
        if is_darwin; then
            CMAKE_FLAGS+=(
                "-DCMAKE_MACOSX_RPATH=ON"
                "-DCMAKE_INSTALL_NAME_DIR=@rpath"
            )
        fi
        FFMPEG_EXTRA_FLAGS+=("--extra-ldflags=${LDFLAGS_ARR[*]}")
        LDFLAGS_ARR+=("-Wl,-rpath,${LIBDIR}")
        CONFIGURE_FLAGS+=(
            '--enable-shared'
            '--disable-static'
        )
        FFMPEG_EXTRA_FLAGS+=('--enable-rpath')
        # remove static libraries for shared builds
        USE_LIB_SUFF="${SHARED_LIB_SUFF}"
        DEL_LIB_SUFF="${STATIC_LIB_SUFF}"
    fi

    # architecture/cpu compile flags
    # arm prefers -mcpu over -march for native builds
    # https://community.arm.com/arm-community-blogs/b/tools-software-ides-blog/posts/compiler-flags-across-architectures-march-mtune-and-mcpu
    local arch_flags=()
    if [[ ${HOSTTYPE} == "aarch64" && ${ARCH} == 'native' ]]; then
        arch_flags+=("-mcpu=${ARCH}")
    else
        arch_flags+=("-march=${ARCH}")
    fi
    CFLAGS_ARR+=("${arch_flags[@]}")
    RUSTFLAGS_ARR+=(-C "target-cpu=${ARCH}")

    # can fail static builds with -fpic
    # warning: too many GOT entries for -fpic, please recompile with -fPIC
    CFLAGS_ARR+=("-fPIC")
    # add preprocessor flags
    CFLAGS_ARR+=("${CPPFLAGS_ARR[@]}")

    # set exported env names to stringified arrays
    CPPFLAGS="${CPPFLAGS_ARR[*]}"
    CFLAGS="${CFLAGS_ARR[*]}"
    CXXFLAGS="${CFLAGS}"
    LDFLAGS="${LDFLAGS_ARR[*]}"
    RUSTFLAGS="${RUSTFLAGS_ARR[*]}"

    CMAKE_FLAGS+=(
        "-DCMAKE_CFLAGS=${CFLAGS}"
        "-DCMAKE_CXX_FLAGS=${CFLAGS}"
    )
    MESON_FLAGS+=(
        "-Dc_args=${CFLAGS}"
        "-Dcpp_args=${CFLAGS}"
        "-Dc_link_args=${LDFLAGS}"
        "-Dcpp_link_args=${LDFLAGS}"
    )

    # extra ffmpeg flags
    FFMPEG_EXTRA_FLAGS+=(
        "--extra-cflags=${CFLAGS}"
        "--extra-cxxflags=${CFLAGS}"
        '--pkg-config=pkg-config'
    )

    dump_arr "${BUILD_ENV_NAMES[@]}"

    FB_COMPILE_OPTS_SET=1
    echo
}

get_build_conf() {
    local getBuild="${1}"

    local longestBuild=0
    local longestVer=0
    local longestExt=0
    local padding=4

    # name version file-extension url dep1,dep2
    # shellcheck disable=SC2016
    local BUILDS_CONF='
ffmpeg            8.0.1        tar.gz    https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n${ver}.${ext}

libsvtav1_psy     3.0.2-B      tar.gz    https://github.com/BlueSwordM/svt-av1-psyex/archive/refs/tags/v${ver}.${ext} dovi_tool,hdr10plus_tool,cpuinfo
hdr10plus_tool    1.7.2        tar.gz    https://github.com/quietvoid/hdr10plus_tool/archive/refs/tags/${ver}.${ext}
dovi_tool         2.3.1        tar.gz    https://github.com/quietvoid/dovi_tool/archive/refs/tags/${ver}.${ext}
cpuinfo           latest       git       https://github.com/pytorch/cpuinfo/

libsvtav1         3.1.2        tar.gz    https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v${ver}/SVT-AV1-v${ver}.${ext}
librav1e          0.8.1        tar.gz    https://github.com/xiph/rav1e/archive/refs/tags/v${ver}.${ext}
libaom            3.13.1       tar.gz    https://storage.googleapis.com/aom-releases/libaom-${ver}.${ext}
libvmaf           3.0.0        tar.gz    https://github.com/Netflix/vmaf/archive/refs/tags/v${ver}.${ext}
libopus           1.6          tar.gz    https://github.com/xiph/opus/archive/refs/tags/v${ver}.${ext}
libdav1d          1.5.3        tar.xz    https://downloads.videolan.org/videolan/dav1d/${ver}/dav1d-${ver}.${ext}
libx264           latest       git       https://code.videolan.org/videolan/x264.git
libmp3lame        3.100        tar.gz    https://pilotfiber.dl.sourceforge.net/project/lame/lame/${ver}/lame-${ver}.${ext}
libvpx            1.16.0       tar.gz    https://github.com/webmproject/libvpx/archive/refs/tags/v${ver}.${ext}

libvorbis         1.3.7        tar.xz    https://github.com/xiph/vorbis/releases/download/v${ver}/libvorbis-${ver}.${ext} libogg,cmake3
libogg            1.3.6        tar.xz    https://github.com/xiph/ogg/releases/download/v${ver}/libogg-${ver}.${ext}

libopenjpeg       2.5.4        tar.gz    https://github.com/uclouvain/openjpeg/archive/refs/tags/v${ver}.${ext} libtiff,lcms2
lcms2             2.18         tar.gz    https://github.com/mm2/Little-CMS/archive/refs/tags/lcms${ver}.${ext} libtiff,libjpeg
libtiff           4.7.1        tar.gz    https://github.com/libsdl-org/libtiff/archive/refs/tags/v${ver}.${ext} libwebp,libdeflate,xz,zstd
libwebp           1.6.0        tar.gz    https://github.com/webmproject/libwebp/archive/refs/tags/v${ver}.${ext} libpng,libjpeg
libjpeg           3.0.3        tar.gz    https://github.com/winlibs/libjpeg/archive/refs/tags/libjpeg-turbo-${ver}.${ext}
libpng            1.6.53       tar.gz    https://github.com/pnggroup/libpng/archive/refs/tags/v${ver}.${ext} zlib
zlib              1.3.1        tar.gz    https://github.com/madler/zlib/archive/refs/tags/v${ver}.${ext}
libdeflate        1.25         tar.gz    https://github.com/ebiggers/libdeflate/archive/refs/tags/v${ver}.${ext} zlib
zstd              1.5.7        tar.gz    https://github.com/facebook/zstd/archive/refs/tags/v${ver}.${ext}

libplacebo        7.351.0      tar.gz    https://github.com/haasn/libplacebo/archive/refs/tags/v${ver}.${ext} glslang,vulkan_loader,glad
glslang           16.0.0       tar.gz    https://github.com/KhronosGroup/glslang/archive/refs/tags/${ver}.${ext} spirv_tools
spirv_tools       2025.4       tar.gz    https://github.com/KhronosGroup/SPIRV-Tools/archive/refs/tags/v${ver}.${ext} spirv_headers
spirv_headers     1.4.328.1    tar.gz    https://github.com/KhronosGroup/SPIRV-Headers/archive/refs/tags/vulkan-sdk-${ver}.${ext}
glad              2.0.8        tar.gz    https://github.com/Dav1dde/glad/archive/refs/tags/v${ver}.${ext}

libx265           4.1          tar.gz    http://ftp.videolan.org/pub/videolan/x265/x265_${ver}.${ext} libnuma,cmake3
libnuma           2.0.19       tar.gz    https://github.com/numactl/numactl/archive/refs/tags/v${ver}.${ext}
cmake3            3.31.8       tar.gz    https://github.com/Kitware/CMake/archive/refs/tags/v${ver}.${ext}

libass            0.17.4       tar.xz    https://github.com/libass/libass/releases/download/${ver}/libass-${ver}.${ext} libfontconfig,libfreetype,libharfbuzz,libfribidi,libunibreak,libxml2,xz
libfontconfig     2.17.1       tar.xz    https://gitlab.freedesktop.org/api/v4/projects/890/packages/generic/fontconfig/${ver}/fontconfig-${ver}.${ext} libharfbuzz,expat,brotli
libfreetype       2.14.1       tar.xz    https://downloads.sourceforge.net/freetype/freetype-${ver}.${ext} bzip,libpng,zlib,brotli,libharfbuzzNFTP
libharfbuzzNFTP   12.3.0       tar.xz    https://github.com/harfbuzz/harfbuzz/releases/download/${ver}/harfbuzz-${ver}.${ext}
libharfbuzz       12.3.0       tar.xz    https://github.com/harfbuzz/harfbuzz/releases/download/${ver}/harfbuzz-${ver}.${ext} libfreetype
libunibreak       6.1          tar.gz    https://github.com/adah1972/libunibreak/releases/download/libunibreak_${ver//./_}/libunibreak-${ver}.${ext}
libxml2           2.15.1       tar.gz    https://github.com/GNOME/libxml2/archive/refs/tags/v${ver}.${ext}
xz                5.8.2        tar.xz    https://github.com/tukaani-project/xz/releases/download/v${ver}/xz-${ver}.${ext}
libfribidi        1.0.16       tar.xz    https://github.com/fribidi/fribidi/releases/download/v${ver}/fribidi-${ver}.${ext}
bzip              latest       git       https://github.com/libarchive/bzip2.git
brotli            1.2.0        tar.gz    https://github.com/google/brotli/archive/refs/tags/v${ver}.${ext}
expat             2.7.3        tar.xz    https://github.com/libexpat/libexpat/releases/download/R_${ver//./_}/expat-${ver}.${ext}

supmover          2.4.3        tar.gz    https://github.com/MonoS/SupMover/archive/refs/tags/v${ver}.${ext}
'
    local supported_builds=()
    unset ver ext url deps extractedDir
    while read -r line; do
        test "${line}" == '' && continue
        IFS=$' \t' read -r build ver ext url deps <<<"${line}"
        supported_builds+=("${build}")

        # padding support
        longestBuild="$(fb_max "${#build}" "${longestBuild}")"
        longestVer="$(fb_max "${#ver}" "${longestVer}")"
        longestExt="$(fb_max "${#ext}" "${longestExt}")"

        if [[ ${getBuild} != "${build}" ]]; then
            build=''
            continue
        fi
        break
    done <<<"${BUILDS_CONF}"

    # special arg to print supported builds only
    if [[ ${getBuild} == 'supported' ]]; then
        echo "${supported_builds[@]}"
        return 0
    fi

    # special arg to print BUILDS_CONF but formatted with spaces
    if [[ ${getBuild} == 'formatted' ]]; then
        echo "local BUILDS_CONF='"
        while read -r line; do
            IFS=$' \t' read -r build ver ext url deps <<<"${line}"
            print_padded "${build}" $((padding + longestBuild))
            print_padded "${ver}" $((padding + longestVer))
            print_padded "${ext}" $((padding + longestExt))
            print_padded "${url}" "${padding}"
            echo " ${deps}"
        done <<<"${BUILDS_CONF}"
        echo "'"
        return 0
    fi

    if [[ ${build} == '' ]]; then
        echo_fail "build ${getBuild} is not supported"
        return 1
    fi

    # url uses ver and extension
    eval "url=\"$url\""
    # set dependencies array
    # ffmpeg dependencies are everything enabled
    if [[ ${build} == 'ffmpeg' ]]; then
        # shellcheck disable=SC2206
        # shellcheck disable=SC2153
        deps=(${ENABLE})
    else
        # shellcheck disable=SC2206
        deps=(${deps//,/ })
    fi
    # set version based off of remote head
    # and set extracted directory
    if [[ ${ext} == 'git' ]]; then
        ver="$(get_remote_head "${url}")"
        extractedDir="${BUILD_DIR}/${build}-${ext}"
    else
        extractedDir="${BUILD_DIR}/${build}-v${ver}"
    fi

    return 0
}

download_release() {
    local basename="$(bash_basename "${extractedDir}")"
    local download="${DL_DIR}/${basename}"

    # remove other versions of a download
    for alreadyDownloaded in "${DL_DIR}/${build}-"*; do
        if line_contains "${alreadyDownloaded}" "${basename}"; then
            continue
        fi
        if [[ ! -d ${alreadyDownloaded} && ! -f ${alreadyDownloaded} ]]; then
            continue
        fi
        echo_warn "removing wrong version: ${alreadyDownloaded}"
        rm -rf "${alreadyDownloaded}"
    done
    # remove other versions of a build
    for alreadyBuilt in "${BUILD_DIR}/${build}-"*; do
        if line_contains "${alreadyBuilt}" "${basename}"; then
            continue
        fi
        test -d "${alreadyBuilt}" || continue
        echo_warn "removing wrong version: ${alreadyBuilt}"
        rm -rf "${alreadyBuilt}"
    done

    # enabling a clean build
    if [[ ${CLEAN} == 'ON' ]]; then
        DO_CLEAN="rm -rf"
    else
        DO_CLEAN='void'
    fi

    # create new build dir for clean builds
    test -d "${extractedDir}" &&
        { ${DO_CLEAN} "${extractedDir}" || return 1; }

    if test "${ext}" != "git"; then
        wgetOut="${download}.${ext}"

        # download archive if not present
        if ! test -f "${wgetOut}"; then
            echo_info "downloading ${build}"
            echo_if_fail wget "${url}" -O "${wgetOut}"
        fi

        # create new build directory
        test -d "${extractedDir}" ||
            {
                mkdir "${extractedDir}"
                tar -xf "${wgetOut}" \
                    --strip-components=1 \
                    --no-same-permissions \
                    -C "${extractedDir}" || { rm "${wgetOut}" && return 1; }
            }
    else
        # for git downloads
        test -d "${download}" ||
            git clone --recursive "${url}" "${download}" || return 1
        (
            cd "${download}" || exit 1
            local localHEAD remoteHEAD
            localHEAD="$(git rev-parse HEAD)"
            remoteHEAD="$(get_remote_head "${url}")"
            if [[ ${localHEAD} != "${remoteHEAD}" ]]; then
                git stash
                git pull --ff-only
                git submodule update --init --recursive
            fi
            localHEAD="$(git rev-parse HEAD)"
            if [[ ${localHEAD} != "${remoteHEAD}" ]]; then
                echo_exit "could not update git for ${build}"
            fi
        ) || return 1

        # create new build directory
        test -d "${extractedDir}" ||
            cp -r "${download}" "${extractedDir}" || return 1
    fi
}

# given a build, topologically sort
# a build and its dependencies
# to minimize rebuilds
_generate_build_order() (
    local build="$1"
    local depMap=("${build} ${build}")
    get_build_conf "${build}" || return 1
    for dep in "${deps[@]}"; do
        _generate_build_order "${dep}" || return 1
        depMap+=("${dep} ${build}")
    done
    printf '%s\n' "${depMap[@]}"
)
generate_build_order() {
    local build="$1"
    local order
    while read -r line; do
        order+="${line} "
    done <<<"$(_generate_build_order "${build}" | tsort)"
    # remove self-inclusive build from order list
    echo "${order// ${build}/}"
}

FB_FUNC_NAMES+=('do_build')
# shellcheck disable=SC2034
FB_FUNC_DESCS['do_build']='build a specific project'
# shellcheck disable=SC2034
FB_FUNC_COMPLETION['do_build']="$(get_build_conf supported)"
do_build() {
    local build="${1:-''}"
    get_build_conf "${build}" || return 1

    set_compile_opts || return 1

    # set BUILD_ORDER only if unset
    # this recursive function needs to be able
    # to control its callstack to minimize re-calls
    if [[ ${BUILD_ORDER} == '' ]]; then
        BUILD_ORDER="$(generate_build_order "${build}")" || return 1
        for b in ${BUILD_ORDER}; do
            test "${b}" == "${build}" && continue
            do_build "${b}" || return 1
        done
        unset BUILD_ORDER
    fi

    get_build_conf "${build}" || return 1

    # save the metadata for a build to skip re-building identical builds
    local oldMetadataFile="${TMP_DIR}/${build}-old-metadata"
    local newMetadataFile="${TMP_DIR}/${build}-new-metadata"
    local ffmpegOldMetadataFile="${TMP_DIR}/ffmpeg-old-metadata"

    # add build function, version, url, and top-level env to metadata
    {
        local buildFunction="$(type "build_${build}")"
        # include meta builds
        for token in ${buildFunction}; do
            if [[ ${token} == "meta_"*"_build" ]]; then
                type "${token}"
            fi
        done
        echo "${buildFunction}"
        echo "ver: ${ver}"
        echo "url: ${url}"
        echo "LOCAL_PREFIX: ${LOCAL_PREFIX}"
        for patch in "${PATCHES_DIR}/${build}"/*.patch; do
            test -f "${patch}" || continue
            echo -e "patch:${patch}\n$(<"${patch}")" >>"${newMetadataFile}"
        done
        COLOR=OFF SHOW_SINGLE=true dump_arr "${BUILD_ENV_NAMES[@]}"
    } >"${newMetadataFile}"

    # only ffmpeg cares about ENABLE and has special function
    if [[ ${build} == 'ffmpeg' ]]; then
        # shellcheck disable=SC2153
        echo "ENABLE=${ENABLE}" >>"${newMetadataFile}"
        type add_project_versioning_to_ffmpeg >>"${newMetadataFile}"
    fi

    # rebuild if new metadata is different
    local newMetadata="$(<"${newMetadataFile}")"
    local oldMetadata=''
    test -f "${oldMetadataFile}" && oldMetadata="$(<"${oldMetadataFile}")"
    if [[ ${oldMetadata} != "${newMetadata}" || -n ${REQUIRES_REBUILD} ]]; then
        # prepare build
        download_release || return 1
        pushd "${extractedDir}" >/dev/null || return 1
        # check for any patches
        for patch in "${PATCHES_DIR}/${build}"/*.patch; do
            test -f "${patch}" || continue
            echo_if_fail patch -p1 -i "${patch}" || return 1
        done

        echo_info -n "building ${build} "
        # build in background
        local timeBefore=${EPOCHSECONDS}
        spinner start
        LOGNAME="${build}" echo_if_fail "build_${build}"
        local retval=$?
        spinner stop

        popd >/dev/null || return 1
        test ${retval} -eq 0 || return ${retval}
        echo_pass "built ${build} in $((EPOCHSECONDS - timeBefore)) seconds"

        # set new to old for later builds
        cp "${newMetadataFile}" "${oldMetadataFile}"

        # force ffmpeg to rebuild since one of the libraries has changed
        if [[ ${build} != 'ffmpeg' && -f ${ffmpegOldMetadataFile} ]]; then
            rm "${ffmpegOldMetadataFile}"
        fi
        # indicate that build chain will require rebuild
        REQUIRES_REBUILD=1
    else
        echo_info "re-using identical previous build for ${build}"
    fi
}

FB_FUNC_NAMES+=('build')
# shellcheck disable=SC2034
FB_FUNC_DESCS['build']='build ffmpeg with the desired configuration'
build() {
    # if PGO is enabled, build will call build
    # only want to recursively build on the first run
    if [[ ${PGO} == 'ON' && ${PGO_RUN} != 'generate' ]]; then
        PGO_RUN='generate' build || return 1
        # will need to reset compile opts
        unset FB_COMPILE_OPTS_SET
    fi

    set_compile_opts || return 1

    do_build ffmpeg || return 1

    # skip packaging on PGO generate run
    if [[ ${PGO} == 'ON' && ${PGO_RUN} == 'generate' ]]; then
        PATH="${PREFIX}/bin:${PATH}" gen_profdata
        return $?
    fi

    local ffmpegBin="${PREFIX}/bin/ffmpeg"
    # run ffmpeg to show completion
    "${ffmpegBin}" -version || return 1

    # suggestion for path
    hash -r
    local ffmpeg="$(command -v ffmpeg 2>/dev/null)"
    if [[ ${ffmpeg} != "${ffmpegBin}" ]]; then
        echo
        echo_warn "ffmpeg in path (${ffmpeg}) is not the built one (${ffmpegBin})"
        echo_info "consider adding ${PREFIX}/bin to \$PATH"
        echo "echo 'export PATH=\"${PREFIX}/bin:\$PATH\"' >> ~/.bashrc"
    fi

    package || return 1

    return 0
}

# make sure the sysroot has the appropriate library type
# darwin will always link dynamically if a dylib is present
# so they must be remove for static builds
sanitize_sysroot_libs() {
    # do nothing for windows
    if is_windows; then return; fi

    local libs=("$@")

    for lib in "${libs[@]}"; do
        local libPath="${LIBDIR}/${lib}"
        local foundLib=false

        for useLib in "${libPath}"*"${USE_LIB_SUFF}"; do
            test -f "${useLib}" || continue
            foundLib=true
            # darwin sometimes fails to set rpath correctly
            if is_darwin && [[ ${STATIC} == 'OFF' ]]; then
                install_name_tool \
                    -id "${useLib}" \
                    "${useLib}" || return 1
            fi
        done

        if [[ ${foundLib} == false ]]; then
            echo_fail "could not find ${libPath}*${USE_LIB_SUFF}, something is wrong"
            return 1
        fi

        ${SUDO_MODIFY} rm "${libPath}"*".${DEL_LIB_SUFF}"*
    done

    return 0
}

# cargo cinstall destdir prepends with entire prefix
# this breaks windows with msys path augmentation
# so recurse into directories until PREFIX sysroot
# also windows via msys path resolution breaks sometimes
# for PREFIX installs (C:/ instead of /c/)
install_local_destdir() (
    local destdir="$1"
    test "${destdir}" == '' && return 1
    cd "${destdir}" || return 1
    local sysrootDir="$(bash_basename "${PREFIX}")"
    while ! test -d "${sysrootDir}"; do
        cd ./* || return 1
    done
    # final cd
    cd "${sysrootDir}" || return 1
    ${SUDO_MODIFY} cp -r ./* "${PREFIX}/"
)

del_pkgconfig_gcc_s() {
    # HACK PATCH
    # remove '-lgcc_s' from pkgconfig for static builds
    if [[ ${STATIC} == 'ON' ]]; then
        local fname="$1"
        local cfg="${PKG_CONFIG_PATH}/${fname}"
        local newCfg="${TMP_DIR}/${fname}"
        test -f "${cfg}" || return 1
        local del='-lgcc_s'

        test -f "${newCfg}" && rm "${newCfg}"
        while read -r line; do
            if line_contains "${line}" "${del}"; then
                line="${line//${del} /}"
            fi
            echo "${line}" >>"${newCfg}"
        done <"${cfg}"
        # overwrite the pkgconfig
        ${SUDO_MODIFY} cp "${newCfg}" "${cfg}"
    fi
}

### RUST ###
meta_cargoc_build() {
    local destdir="${PWD}/fb-local-install"
    # let rust handle its own lto/pgo
    local newCflags="${CFLAGS//${LTO_FLAG}/}"
    newCflags="${newCflags//${PGO_FLAG}/}"

    CFLAGS="${newCflags}" cargo cinstall \
        --destdir "${destdir}" \
        "${CARGO_CINSTALL_FLAGS[@]}" || return 1
    # cargo cinstall destdir prepends with entire prefix
    # this breaks windows with msys path augmentation
    # so recurse into directories until sysroot is there
    install_local_destdir "${destdir}" || return 1
}

build_hdr10plus_tool() {
    # build libhdr10plus
    cd hdr10plus || return 1
    meta_cargoc_build || return 1
    sanitize_sysroot_libs libhdr10plus-rs || return 1
}

build_dovi_tool() {
    # build libdovi
    cd dolby_vision || return 1
    meta_cargoc_build || return 1
    sanitize_sysroot_libs libdovi || return 1
}

build_librav1e() {
    meta_cargoc_build || return 1
    sanitize_sysroot_libs librav1e || return 1
    del_pkgconfig_gcc_s rav1e.pc || return 1
}

### CMAKE ###
meta_cmake_build() {
    local addFlags=("$@")
    # configure
    cmake \
        -B fb-build \
        "${CMAKE_FLAGS[@]}" \
        "${addFlags[@]}" || return 1
    # build
    cmake \
        --build fb-build \
        --config Release \
        -j "${JOBS}" || return 1
    # install
    ${SUDO_MODIFY} cmake \
        --install fb-build || return 1
}

build_cpuinfo() {
    meta_cmake_build \
        -DCPUINFO_LIBRARY_TYPE="${BUILD_TYPE}" \
        -DCPUINFO_RUNTIME_TYPE="${BUILD_TYPE}" \
        -DCPUINFO_BUILD_UNIT_TESTS=OFF \
        -DCPUINFO_BUILD_MOCK_TESTS=OFF \
        -DCPUINFO_BUILD_BENCHMARKS=OFF \
        -DCPUINFO_LOG_TO_STDIO=ON \
        -DUSE_SYSTEM_LIBS=ON || return 1
    sanitize_sysroot_libs libcpuinfo || return 1
}

build_libsvtav1() {
    meta_cmake_build \
        -DENABLE_AVX512=ON \
        -DCOVERAGE=OFF || return 1
    sanitize_sysroot_libs libSvtAv1Enc || return 1
}

build_libsvtav1_psy() {
    meta_cmake_build \
        -DENABLE_AVX512=ON \
        -DCOVERAGE=OFF \
        -DLIBDOVI_FOUND=1 \
        -DLIBHDR10PLUS_RS_FOUND=1 || return 1
    sanitize_sysroot_libs libSvtAv1Enc || return 1
}

build_libaom() {
    meta_cmake_build \
        -DENABLE_TESTS=OFF || return 1
    sanitize_sysroot_libs libaom || return 1
}

build_libopus() {
    meta_cmake_build || return 1
    sanitize_sysroot_libs libopus || return 1
}

build_libvorbis() {
    local modPath
    if ! using_cmake3; then
        modPath="${LOCAL_PREFIX}/bin:"
    fi

    PATH="${modPath}${PATH}" meta_cmake_build || return 1
    sanitize_sysroot_libs \
        libvorbis libvorbisenc libvorbisfile || return 1
}

build_libogg() {
    meta_cmake_build || return 1
    sanitize_sysroot_libs libogg || return 1
}

build_libwebp() {
    if is_android; then
        replace_line CMakeLists.txt \
            "if(ANDROID)" \
            "if(FALSE)\n"
    fi

    meta_cmake_build || return 1
    sanitize_sysroot_libs libwebp libsharpyuv || return 1
}

build_libjpeg() {
    meta_cmake_build || return 1
    sanitize_sysroot_libs libjpeg libturbojpeg || return 1
}

build_libpng() {
    meta_cmake_build \
        -DPNG_TESTS=OFF \
        -DPNG_TOOLS=OFF || return 1
    sanitize_sysroot_libs libpng || return 1
}

build_libdeflate() {
    meta_cmake_build \
        -DLIBDEFLATE_BUILD_GZIP=OFF || return 1
    sanitize_sysroot_libs libdeflate || return 1
}

build_zstd() {
    meta_cmake_build \
        -S build/cmake || return 1
    sanitize_sysroot_libs libzstd || return 1
}

build_zlib() {
    meta_cmake_build \
        -DZLIB_BUILD_EXAMPLES=OFF || return 1
    sanitize_sysroot_libs libz || return 1
}

build_glslang() {
    meta_cmake_build \
        -DALLOW_EXTERNAL_SPIRV_TOOLS=ON || return 1
    sanitize_sysroot_libs libglslang || return 1
}

build_spirv_tools() {
    meta_cmake_build \
        -DSPIRV-Headers_SOURCE_DIR="${PREFIX}" \
        -DSPIRV_WERROR=OFF \
        -DSPIRV_SKIP_TESTS=ON || return 1
}

build_spirv_headers() {
    meta_cmake_build || return 1
}

build_libopenjpeg() {
    meta_cmake_build || return 1
    sanitize_sysroot_libs libopenjp2 || return 1
}

build_libtiff() {
    meta_cmake_build \
        -Dtiff-tools=OFF \
        -Dtiff-tests=OFF \
        -Dtiff-contrib=OFF || return 1
    sanitize_sysroot_libs libtiff || return 1
}

build_supmover() (
    # clean build environment
    unset "${BUILD_ENV_NAMES[@]}"

    # manual install to sysroot
    make || return 1
    cp supmover "${LOCAL_PREFIX}/bin/supmover" || return 1
)

build_cmake3() (
    # clean build environment
    unset "${BUILD_ENV_NAMES[@]}"

    # don't need to rebuild if already using cmake3
    if using_cmake3; then
        return 0
    fi

    # don't need to rebuild if already built
    if PATH="${LOCAL_PREFIX}/bin:${PATH}" using_cmake3; then
        return 0
    fi

    CMAKE_FLAGS+=(
        "-DCMAKE_PREFIX_PATH=${LOCAL_PREFIX}"
        "-DCMAKE_INSTALL_PREFIX=${LOCAL_PREFIX}"
        "-DCMAKE_INSTALL_LIBDIR=lib"
        "-DCMAKE_BUILD_TYPE=Release"
        "-DCMAKE_C_COMPILER_LAUNCHER=ccache"
        "-DCMAKE_CXX_COMPILER_LAUNCHER=ccache"
        "-DCMAKE_VERBOSE_MAKEFILE=ON"
        "-G" "Ninja"
        "-DENABLE_STATIC=ON"
        "-DENABLE_SHARED=OFF"
        "-DBUILD_SHARED_LIBS=OFF"
    )
    meta_cmake_build || return 1
)

build_libx265() {
    local modPath
    if ! using_cmake3; then
        modPath="${LOCAL_PREFIX}/bin:"
    fi

    PATH="${modPath}${PATH}" meta_cmake_build \
        -DHIGH_BIT_DEPTH=ON \
        -DENABLE_HDR10_PLUS=OFF \
        -S source || return 1
    sanitize_sysroot_libs libx265 || return 1
    del_pkgconfig_gcc_s x265.pc || return 1
}

build_brotli() {
    meta_cmake_build || return 1
    sanitize_sysroot_libs \
        libbrotlicommon libbrotlidec libbrotlienc || return 1
}

build_libxml2() {
    meta_cmake_build || return 1
    sanitize_sysroot_libs libxml2 || return 1
}

build_xz() {
    meta_cmake_build || return 1
    sanitize_sysroot_libs liblzma || return 1
}

build_expat() {
    meta_cmake_build || return 1
    sanitize_sysroot_libs libexpat || return 1
}

### MESON ###
meta_meson_build() {
    local addFlags=("$@")
    meson setup \
        "${MESON_FLAGS[@]}" \
        "${addFlags[@]}" \
        . fb-build || return 1
    meson compile \
        -C fb-build \
        -j "${JOBS}" || return 1
    ${SUDO_MODIFY} meson install \
        -C fb-build || return 1
}

build_libdav1d() {
    local enableAsm=true
    # arm64 will fail the build at 0 optimization
    if [[ "${HOSTTYPE}:${OPT}" == "aarch64:0" ]]; then
        enableAsm=false
    fi
    meta_meson_build \
        -D enable_asm=${enableAsm} || return 1
    sanitize_sysroot_libs libdav1d || return 1
}

build_libplacebo() {
    # copy downloaded glad release as "submodule"
    (
        installDir="${PWD}/3rdparty/glad"
        get_build_conf glad || exit 1
        CLEAN=OFF download_release || exit 1
        cd "${extractedDir}" || exit 1
        cp -r ./* "${installDir}"
    ) || return 1

    meta_meson_build \
        -D tests=false \
        -D demos=false || return 1
    sanitize_sysroot_libs libplacebo || return 1
}

build_libvmaf() {
    cd libvmaf || return 1
    virtualenv .venv
    (
        source .venv/bin/activate
        meta_meson_build \
            -D enable_float=true || exit 1
    ) || return 1
    sanitize_sysroot_libs libvmaf || return 1

    # HACK PATCH
    # add '-lstdc++' to pkgconfig for static builds
    if [[ ${STATIC} == 'ON' ]]; then
        local fname='libvmaf.pc'
        local cfg="${PKG_CONFIG_PATH}/${fname}"
        local newCfg="${TMP_DIR}/${fname}"
        test -f "${cfg}" || return 1
        local search='Libs: '

        test -f "${newCfg}" && rm "${newCfg}"
        while read -r line; do
            if line_contains "${line}" "${search}"; then
                line+=" -lstdc++"
            fi
            echo "${line}" >>"${newCfg}"
        done <"${cfg}"
        # overwrite the pkgconfig
        ${SUDO_MODIFY} cp "${newCfg}" "${cfg}"
    fi
}

build_libfreetype() {
    meta_meson_build \
        -D tests=disabled || return 1
    sanitize_sysroot_libs libfreetype || return 1
}

build_bzip() {
    meta_meson_build || return 1
    sanitize_sysroot_libs libbz2 || return 1
}

build_libfontconfig() {
    meta_meson_build || return 1
    sanitize_sysroot_libs libfontconfig || return 1
}

# harfbuzz No FreeType
build_libharfbuzzNFTP() {
    DISABLE_FREETYPE=1 build_libharfbuzz
}

build_libharfbuzz() {
    local addFlag
    test "${DISABLE_FREETYPE}" -eq 1 && addFlag="-Dfreetype=disabled"

    meta_meson_build ${addFlag} \
        -D tests=disabled \
        -D docs=disabled \
        -D utilities=disabled \
        -D doc_tests=false || return 1
    sanitize_sysroot_libs libharfbuzz || return 1
}

build_libfribidi() {
    meta_meson_build \
        -D tests=false || return 1
    sanitize_sysroot_libs libfribidi || return 1
}

build_lcms2() {
    meta_meson_build || return 1
    sanitize_sysroot_libs liblcms2 || return 1
}

### PYTHON ###
build_glad() {
    true
}

### AUTOTOOLS ###
meta_configure_build() {
    local addFlags=("$@")
    local configureFlags=()
    # backup global variable for re-setting
    # after build is complete
    local cflagsBackup="${CFLAGS}"
    local ldflagsBackup="${LDFLAGS}"

    # some builds break with LTO
    if [[ ${LTO} == 'OFF' ]]; then
        for flag in "${CONFIGURE_FLAGS[@]}"; do
            test "${flag}" == '--enable-lto' && continue
            configureFlags+=("${flag}")
        done
        CFLAGS="${CFLAGS//${LTO_FLAG}/}"
        LDFLAGS="${LDFLAGS//${LTO_FLAG}/}"
    else
        configureFlags+=("${CONFIGURE_FLAGS[@]}")
    fi

    # configure
    ./configure \
        "${configureFlags[@]}" \
        "${addFlags[@]}" || return 1
    # build
    # attempt to build twice since build can fail due to OOM
    ccache make -j"${JOBS}" ||
        ccache make -j"${JOBS}" || return 1
    # install
    local destdir="${PWD}/fb-local-install"
    make -j"${JOBS}" DESTDIR="${destdir}" install || return 1
    install_local_destdir "${destdir}" || return 1

    # reset global variables
    CFLAGS="${cflagsBackup}"
    LDFLAGS="${ldflagsBackup}"
}

build_libvpx() {
    # remove preprocessor flags to not break the build
    # when including old pre-built headers
    CFLAGS="${CFLAGS//${CPPFLAGS}/}" meta_configure_build \
        --disable-examples \
        --disable-tools \
        --disable-docs \
        --disable-unit-tests \
        --disable-decode-perf-tests \
        --disable-encode-perf-tests \
        --enable-vp8 \
        --enable-vp9 \
        --enable-vp9-highbitdepth \
        --enable-better-hw-compatibility \
        --enable-runtime-cpu-detect \
        --enable-webm-io \
        --enable-libyuv || return 1
    sanitize_sysroot_libs libvpx || return 1
}

build_libx264() {
    # libx264 breaks with LTO
    LTO=OFF meta_configure_build \
        --disable-cli \
        --disable-avs \
        --disable-swscale \
        --disable-lavf \
        --disable-ffms \
        --disable-gpac || return 1
    sanitize_sysroot_libs libx264 || return 1
}

build_libmp3lame() {
    meta_configure_build \
        --enable-nasm \
        --disable-frontend || return 1
    sanitize_sysroot_libs libmp3lame || return 1
}

build_libnuma() {
    if ! is_linux; then return 0; fi

    ./autogen.sh || return 1
    meta_configure_build || return 1
    sanitize_sysroot_libs libnuma || return 1
}

build_libunibreak() {
    meta_configure_build || return 1
    sanitize_sysroot_libs libunibreak || return 1
}

build_libass() {
    meta_configure_build || return 1
    sanitize_sysroot_libs libass || return 1
}

add_project_versioning_to_ffmpeg() {
    # embed this project's enables/versions
    # into ffmpeg with FFMPEG_BUILDER_INFO
    local FFMPEG_BUILDER_INFO=(
        '' # pad with empty line
        "ffmpeg-builder=$(git -C "${REPO_DIR}" rev-parse HEAD)"
    )
    for build in ${ENABLE}; do
        get_build_conf "${build}" || return 1
        # add build configuration info
        FFMPEG_BUILDER_INFO+=("${build}=${ver}")
    done
    # and finally for ffmpeg itself
    get_build_conf ffmpeg || return 1
    FFMPEG_BUILDER_INFO+=("${build}=${ver}")

    local fname='opt_common.c'
    local optFile="fftools/${fname}"
    if [[ ! -f ${optFile} ]]; then
        echo_fail "could not find ${fname} to add project versioning"
    fi

    local printLibLine='print_all_libs_info(SHOW_VERSION, AV_LOG_INFO);'
    local newPrintLibLine="${printLibLine} "
    newPrintLibLine+="$(printf 'av_log(NULL, AV_LOG_INFO, "%s\\\\n"); ' "${FFMPEG_BUILDER_INFO[@]}")"
    replace_line "${optFile}" "${printLibLine}" "${newPrintLibLine}" || return 1

    return 0
}
build_ffmpeg() {
    add_project_versioning_to_ffmpeg || return 1

    # libsvtav1_psy real name is libsvtav1
    for enable in ${ENABLE}; do
        test "${enable}" == 'libsvtav1_psy' && enable='libsvtav1'
        CONFIGURE_FLAGS+=("--enable-${enable}")
    done

    local ffmpegFlags=(
        "--enable-gpl"
        "--enable-version3"
        "--disable-htmlpages"
        "--disable-podpages"
        "--disable-txtpages"
        "--disable-ffplay"
        "--disable-autodetect"
        "--extra-version=${ver}"
        "--enable-runtime-cpudetect"
    )

    # lto is broken on darwin for ffmpeg only
    # https://trac.ffmpeg.org/ticket/11479
    local ltoBackup="${LTO}"
    if is_darwin; then
        LTO=OFF
        for flag in "${FFMPEG_EXTRA_FLAGS[@]}"; do
            if line_contains "${flag}" "${LTO_FLAG}"; then
                # get rid of potential space on either side
                flag="${flag//${LTO_FLAG} /}"
                flag="${flag// ${LTO_FLAG}/}"
            fi
            ffmpegFlags+=("${flag}")
        done
    else
        ffmpegFlags+=("${FFMPEG_EXTRA_FLAGS[@]}")
    fi

    meta_configure_build \
        "${ffmpegFlags[@]}" || return 1
    LTO="${ltoBackup}"
    ${SUDO_MODIFY} cp ff*_g "${PREFIX}/bin"
    sanitize_sysroot_libs \
        libavcodec libavdevice libavfilter libswscale \
        libavformat libavutil libswresample || return 1
}
