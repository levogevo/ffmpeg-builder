#!/usr/bin/env bash

set_compile_opts() {
	test "$FB_COMPILE_OPTS_SET" == 1 && return 0

	unset LDFLAGS C_FLAGS CXX_FLAGS CPP_FLAGS \
		CONFIGURE_FLAGS MESON_FLAGS \
		RUSTFLAGS CMAKE_FLAGS \
		FFMPEG_EXTRA_FLAGS \
		CARGO_CINSTALL_FLAGS
	export LDFLAGS C_FLAGS CXX_FLAGS CPP_FLAGS \
		RUSTFLAGS PATH

	# set job count for all builds
	JOBS="$(nproc)"
	# local vs system prefix
	test "${PREFIX}" == 'local' && PREFIX="${IGN_DIR}/$(print_os)_sysroot"
	# set library/pkgconfig directory
	LIBDIR="${PREFIX}/lib"
	LDFLAGS=("-L${LIBDIR}")

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
	)
	CMAKE_FLAGS+=(
		"-DCMAKE_PREFIX_PATH=${PREFIX}"
		"-DCMAKE_INSTALL_PREFIX=${PREFIX}"
		"-DCMAKE_INSTALL_LIBDIR=lib"
		"-DCMAKE_BUILD_TYPE=Release"
	)
	CARGO_CINSTALL_FLAGS=(
		"--release"
		"--prefix" "${PREFIX}"
		"--libdir" "${LIBDIR}"
	)
	PKG_CONFIG_PATH="${LIBDIR}/pkgconfig"
	export PKG_CONFIG_PATH

	# add prefix include
	C_FLAGS+=("-I${PREFIX}/include")

	# enabling link-time optimization
	# shellcheck disable=SC2034
	unset LTO_FLAG
	export LTO_FLAG
	if [[ ${LTO} == 'ON' ]]; then
		LTO_FLAG='-flto'
		C_FLAGS+=("${LTO_FLAG}")
		if ! is_darwin; then
			CONFIGURE_FLAGS+=('--enable-lto')
		fi
		MESON_FLAGS+=("-Db_lto=true")
		RUSTFLAGS+=("-C lto=yes" "-C inline-threshold=1000" "-C codegen-units=1")
	else
		LTO_FLAG=' '
		MESON_FLAGS+=("-Db_lto=false")
		RUSTFLAGS+=("-C lto=no")
	fi

	# setting optimization level
	if [[ ${OPT} == '' ]]; then
		OPT='0'
	fi
	C_FLAGS+=("-O${OPT}")
	RUSTFLAGS+=("-C opt-level=${OPT}")
	MESON_FLAGS+=("--optimization=${OPT}")

	STATIC_LIB_SUFF='a'
	# darwin has different suffix for dynamic libraries
	if is_darwin; then
		SHARED_LIB_SUFF='dylib'
	else
		SHARED_LIB_SUFF='so'
	fi

	# static/shared linking
	unset LIB_SUFF
	export LIB_SUFF
	if [[ ${STATIC} == 'ON' ]]; then
		CONFIGURE_FLAGS+=(
			'--enable-static'
			'--disable-shared'
		)
		MESON_FLAGS+=('--default-library=static')
		CMAKE_FLAGS+=(
			"-DENABLE_STATIC=${STATIC}"
			"-DENABLE_SHARED=OFF"
			"-DBUILD_SHARED_LIBS=OFF"
		)
		RUSTFLAGS+=("-C target-feature=+crt-static")
		FFMPEG_EXTRA_FLAGS+=("--pkg-config-flags=--static")
		# darwin does not support static linkage
		if ! is_darwin; then
			LDFLAGS+=('-static')
			CMAKE_FLAGS+=("-DCMAKE_EXE_LINKER_FLAGS=-static")
		fi
		FFMPEG_EXTRA_FLAGS+=(--extra-ldflags="${LDFLAGS[*]}")
		# remove shared libraries for static builds
		USE_LIB_SUFF="${STATIC_LIB_SUFF}"
		DEL_LIB_SUFF="${SHARED_LIB_SUFF}"
	else
		FFMPEG_EXTRA_FLAGS+=(--extra-ldflags="${LDFLAGS[*]}")
		LDFLAGS+=("-Wl,-rpath,${LIBDIR}" "-Wl,-rpath-link,${LIBDIR}")
		CONFIGURE_FLAGS+=(
			'--enable-shared'
			'--disable-static'
		)
		CMAKE_FLAGS+=(
			"-DENABLE_STATIC=${STATIC}"
			"-DENABLE_SHARED=ON"
			"-DBUILD_SHARED_LIBS=ON"
			"-DCMAKE_INSTALL_RPATH=${LIBDIR}"
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

	# can fail static builds with -fpic
	# warning: too many GOT entries for -fpic, please recompile with -fPIC
	C_FLAGS+=("${arch_flags[@]}" "-fPIC")
	CXX_FLAGS=("${C_FLAGS[@]}")
	CPP_FLAGS=("${C_FLAGS[@]}")
	RUSTFLAGS+=("-C target-cpu=${ARCH}")
	CMAKE_FLAGS+=("-DCMAKE_C_FLAGS=${C_FLAGS[*]}")
	CMAKE_FLAGS+=("-DCMAKE_CXX_FLAGS=${CXX_FLAGS[*]}")
	MESON_FLAGS+=("-Dc_args=${C_FLAGS[*]}" "-Dcpp_args=${CPP_FLAGS[*]}")
	dump_arr CONFIGURE_FLAGS
	dump_arr C_FLAGS
	dump_arr RUSTFLAGS
	dump_arr CARGO_CINSTALL_FLAGS
	dump_arr CMAKE_FLAGS
	dump_arr MESON_FLAGS
	echo_info "PKG_CONFIG_PATH=${PKG_CONFIG_PATH}"

	# extra ffmpeg flags
	FFMPEG_EXTRA_FLAGS+=(
		--extra-cflags="${C_FLAGS[*]}"
		--extra-cxxflags="${CXX_FLAGS[*]}"
		--pkg-config='pkg-config'
	)
	dump_arr FFMPEG_EXTRA_FLAGS

	# shellcheck disable=SC2178
	RUSTFLAGS="${RUSTFLAGS[*]}"

	# make sure RUSTUP_HOME and CARGO_HOME are defined for SUDO builds
	# set fallback values
	local rustupHome cargoHome
	if has_cmd rustup; then
		rustupHome="$(bash_dirname "$(command -v rustup)")"
		# move out of bin/ dir
		rustupHome="$(cd "${rustupHome}/../" && echo "$PWD")"
	fi
	if has_cmd cargo; then
		cargoHome="$(bash_dirname "$(command -v cargo)")"
		# move out of bin/ dir
		cargoHome="$(cd "${cargoHome}/../" && echo "$PWD")"
	fi

	RUSTUP_HOME="${RUSTUP_HOME:-"${rustupHome}"}"
	CARGO_HOME="${CARGO_HOME:-"${cargoHome}"}"
	test -d "${RUSTUP_HOME}" || echo_exit "RUSTUP_HOME does not exist"
	test -d "${CARGO_HOME}" || echo_exit "CARGO_HOME does not exist"
	export RUSTUP_HOME CARGO_HOME

	unset SUDO_CARGO
	if [[ ${SUDO_MODIFY} == '' ]]; then
		SUDO_CARGO=''
	else
		SUDO_CARGO="${SUDO} --preserve-env=PATH,RUSTUP_HOME,CARGO_HOME"
	fi

	FB_COMPILE_OPTS_SET=1
	echo
}

get_remote_head() {
	local url="$1"
	local remoteHEAD=''
	IFS=$' \t' read -r remoteHEAD _ <<< \
		"$(git ls-remote "${url}" HEAD)"
	echo "${remoteHEAD}"
}

get_build_conf() {
	local getBuild="${1}"

	# name version file-extension url dep1,dep2
	# shellcheck disable=SC2016
	local BUILDS_CONF='
ffmpeg			8.0			tar.gz		https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n${ver}.${ext}

libsvtav1_psy	3.0.2-A		tar.gz		https://github.com/BlueSwordM/svt-av1-psyex/archive/refs/tags/v${ver}.${ext} dovi_tool,hdr10plus_tool,cpuinfo
hdr10plus_tool	1.7.1		tar.gz		https://github.com/quietvoid/hdr10plus_tool/archive/refs/tags/${ver}.${ext}
dovi_tool		2.3.0		tar.gz		https://github.com/quietvoid/dovi_tool/archive/refs/tags/${ver}.${ext}
cpuinfo			latest   	git   		https://github.com/pytorch/cpuinfo/

libsvtav1		3.1.2		tar.gz		https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v${ver}/SVT-AV1-v${ver}.${ext}
librav1e		0.8.1		tar.gz		https://github.com/xiph/rav1e/archive/refs/tags/v${ver}.${ext}
libaom			3.12.1		tar.gz		https://storage.googleapis.com/aom-releases/libaom-${ver}.${ext}
libvmaf			3.0.0		tar.gz		https://github.com/Netflix/vmaf/archive/refs/tags/v${ver}.${ext}
libopus			1.5.2		tar.gz		https://github.com/xiph/opus/releases/download/v${ver}/opus-${ver}.${ext}
libdav1d		1.5.1		tar.xz		http://downloads.videolan.org/videolan/dav1d/${ver}/dav1d-${ver}.${ext}
libx264			latest   	git   		https://code.videolan.org/videolan/x264.git
libmp3lame		3.100		tar.gz		https://pilotfiber.dl.sourceforge.net/project/lame/lame/${ver}/lame-${ver}.${ext}

libwebp			1.6.0		tar.gz		https://github.com/webmproject/libwebp/archive/refs/tags/v${ver}.${ext} libpng,libjpeg
libjpeg			3.0.3		tar.gz		https://github.com/winlibs/libjpeg/archive/refs/tags/libjpeg-turbo-${ver}.${ext}
libpng			1.6.50		tar.gz		https://github.com/pnggroup/libpng/archive/refs/tags/v${ver}.${ext}	zlib
zlib			1.3.1		tar.gz		https://github.com/madler/zlib/archive/refs/tags/v${ver}.${ext}

libplacebo		7.351.0		tar.gz		https://github.com/haasn/libplacebo/archive/refs/tags/v${ver}.${ext} glslang
glslang			15.4.0		tar.gz		https://github.com/KhronosGroup/glslang/archive/refs/tags/${ver}.${ext} spirv_tools
spirv_tools		2024.4		tar.gz		https://github.com/KhronosGroup/SPIRV-Tools/archive/refs/tags/v${ver}.${ext} spirv_headers
spirv_headers	1.4.304.0	tar.gz		https://github.com/KhronosGroup/SPIRV-Headers/archive/refs/tags/vulkan-sdk-${ver}.${ext}

libx265			4.1			tar.gz		https://bitbucket.org/multicoreware/x265_git/downloads/x265_${ver}.${ext} libnuma,cmake
libnuma			2.0.19		tar.gz		https://github.com/numactl/numactl/archive/refs/tags/v${ver}.${ext}
cmake			3.31.8		tar.gz		https://github.com/Kitware/CMake/archive/refs/tags/v${ver}.${ext}
'

	local supported_builds=()
	unset ver ext url deps extracted_dir
	while read -r line; do
		test "${line}" == '' && continue
		IFS=$' \t' read -r build ver ext url deps <<<"${line}"
		supported_builds+=("${build}")
		if [[ ${getBuild} != "${build}" ]]; then
			build=''
			continue
		fi
		break
	done <<<"${BUILDS_CONF}"

	if [[ ${getBuild} == 'supported' ]]; then
		echo "${supported_builds[@]}"
		return 0
	fi

	if [[ ${build} == '' ]]; then
		echo_fail "build ${getBuild} is not supported"
		return 1
	fi

	# url uses ver and extension
	eval "url=\"$url\""
	# set dependencies array
	# shellcheck disable=SC2206
	deps=(${deps//,/ })
	# set version based off of remote head
	# and set extracted directory
	if [[ ${ext} == 'git' ]]; then
		ver="$(get_remote_head "${url}")"
		extracted_dir="${BUILD_DIR}/${build}-${ext}"
	else
		extracted_dir="${BUILD_DIR}/${build}-v${ver}"
	fi
	# download the release
	download_release || return 1

	return 0
}

download_release() {
	local base_path="$(bash_basename "${extracted_dir}")"
	local base_dl_path="${DL_DIR}/${base_path}"

	# remove other versions of a download
	for wrong_ver_dl in "${DL_DIR}/${build}-"*; do
		if line_contains "${wrong_ver_dl}" "${base_path}"; then
			continue
		fi
		if [[ ! -d ${wrong_ver_dl} && ! -f ${wrong_ver_dl} ]]; then
			continue
		fi
		echo_warn "removing wrong version: ${wrong_ver_dl}"
		rm -rf "${wrong_ver_dl}"
	done
	# remove other versions of a build
	for wrong_ver_build in "${BUILD_DIR}/${build}-"*; do
		if line_contains "${wrong_ver_build}" "${base_path}"; then
			continue
		fi
		test -d "${wrong_ver_build}" || continue
		echo_warn "removing wrong version: ${extracted_dir}"
		rm -rf "${wrong_ver_build}"
	done

	# enabling a clean build
	if [[ ${CLEAN} == true ]]; then
		DO_CLEAN="rm -rf"
	else
		DO_CLEAN='void'
	fi

	# create new build dir for clean builds
	test -d "${extracted_dir}" &&
		{ ${DO_CLEAN} "${extracted_dir}" || return 1; }

	if test "${ext}" != "git"; then
		wget_out="${base_dl_path}.${ext}"

		# download archive if not present
		if ! test -f "${wget_out}"; then
			echo_info "downloading ${build}"
			echo_if_fail wget "${url}" -O "${wget_out}"
		fi

		# create new build directory
		test -d "${extracted_dir}" ||
			{
				mkdir "${extracted_dir}"
				tar -xf "${wget_out}" \
					--strip-components=1 \
					--no-same-permissions \
					-C "${extracted_dir}"
			}
	else
		# for git downloads
		test -d "${base_dl_path}" ||
			git clone --recursive "${url}" "${base_dl_path}" || return 1
		(
			cd "${base_dl_path}" || exit 1
			local localHEAD remoteHEAD
			localHEAD="$(git rev-parse HEAD)"
			remoteHEAD="$(get_remote_head "$(git config --get remote.origin.url)")"
			if [[ ${localHEAD} != "${remoteHEAD}" ]]; then
				git pull --ff-only
				git submodule update --init --recursive
			fi
			localHEAD="$(git rev-parse HEAD)"
			if [[ ${localHEAD} != "${remoteHEAD}" ]]; then
				echo_exit "could not update git for ${build}"
			fi
		) || return 1

		# create new build directory
		test -d "${extracted_dir}" ||
			cp -r "${base_dl_path}" "${extracted_dir}" || return 1
	fi
}

FB_FUNC_NAMES+=('do_build')
# shellcheck disable=SC2034
FB_FUNC_DESCS['do_build']='build a specific project'
# shellcheck disable=SC2034
FB_FUNC_COMPLETION['do_build']="$(get_build_conf supported)"
do_build() {
	local build="${1:-''}"
	get_build_conf "${build}" || return 1

	# add build configuration to FFMPEG_BUILDER_INFO
	FFMPEG_BUILDER_INFO+=("${build}=${ver}")

	set_compile_opts || return 1
	for dep in "${deps[@]}"; do
		do_build "${dep}" || return 1
	done
	get_build_conf "${build}" || return 1
	echo_info "building ${build}"
	pushd "$extracted_dir" >/dev/null || return 1
	# check for any patches
	for patch in "${PATCHES_DIR}/${build}"/*.patch; do
		test -f "${patch}" || continue
		echo_if_fail patch -p1 -i "${patch}" || return 1
	done
	export LOGNAME="${build}"
	local timeBefore=$EPOCHSECONDS
	echo_if_fail build_"${build}"
	retval=$?
	popd >/dev/null || return 1
	test ${retval} -eq 0 || return ${retval}
	echo_pass "built ${build} in $((EPOCHSECONDS - timeBefore)) seconds"
}

FB_FUNC_NAMES+=('build')
# shellcheck disable=SC2034
FB_FUNC_DESCS['build']='build ffmpeg with desired configuration'
build() {
	test -d "${DL_DIR}" || { mkdir -p "${DL_DIR}" || return 1; }
	test -d "${CCACHE_DIR}" || { mkdir -p "${CCACHE_DIR}" || return 1; }
	test -d "${BUILD_DIR}" || { mkdir -p "${BUILD_DIR}" || return 1; }

	set_compile_opts || return 1
	# check if we need to install with sudo
	test -d "${PREFIX}" || mkdir -p "${PREFIX}"
	unset SUDO_MODIFY
	testfile="${PREFIX}/ffmpeg-build-testfile"
	if touch "${testfile}" 2>/dev/null; then
		SUDO_MODIFY=''
	else
		SUDO_MODIFY="${SUDO}"
		${SUDO_MODIFY} mkdir -p "${PREFIX}/bin/" || return 1
	fi
	test -f "${testfile}" && ${SUDO_MODIFY} rm "${testfile}"
	test -d "${PREFIX}/bin/" || { ${SUDO_MODIFY} mkdir -p "${PREFIX}/bin/" || return 1; }

	# embed this project's enables/versions
	# into ffmpeg with this variable
	FFMPEG_BUILDER_INFO=("ffmpeg-builder=$(cd "${REPO_DIR}" && git rev-parse HEAD)")
	for build in ${ENABLE}; do
		do_build "${build}" || return 1
	done
	do_build "ffmpeg" || return 1
	# run ffmpeg to show completion
	"${PREFIX}/bin/ffmpeg"

	# suggestion for path
	hash -r
	local ffmpeg="$(command -v ffmpeg 2>/dev/null)"
	if [[ ${ffmpeg} != "${PREFIX}/bin/ffmpeg" ]]; then
		echo
		echo_warn "ffmpeg in path (${ffmpeg}) is not the built one (${PREFIX}/bin/ffmpeg)"
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
	local libs=("$@")

	for lib in "${libs[@]}"; do
		local libPath="${LIBDIR}/${lib}"
		local useLib="${libPath}.${USE_LIB_SUFF}"

		if [[ ! -f ${useLib} ]]; then
			echo_fail "could not find ${useLib}, something is wrong"
			return 1
		fi

		${SUDO_MODIFY} rm "${libPath}"*".${DEL_LIB_SUFF}"*
	done

	return 0
}

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
build_hdr10plus_tool() {
	${SUDO_CARGO} bash -c "cargo install --path . --root ${PREFIX}" || return 1

	# build libhdr10plus
	cd hdr10plus || return 1
	${SUDO_CARGO} bash -c "cargo cinstall ${CARGO_CINSTALL_FLAGS[*]}" || return 1
	sanitize_sysroot_libs libhdr10plus-rs || return 1
}

build_dovi_tool() {
	${SUDO_CARGO} bash -c "cargo install --path . --root ${PREFIX}" || return 1

	# build libdovi
	cd dolby_vision || return 1
	${SUDO_CARGO} bash -c "cargo cinstall ${CARGO_CINSTALL_FLAGS[*]}" || return 1
	sanitize_sysroot_libs libdovi || return 1
}

build_librav1e() {
	${SUDO_CARGO} bash -c "cargo install --path . --root ${PREFIX}" || return 1

	# build librav1e
	${SUDO_CARGO} bash -c "cargo cinstall ${CARGO_CINSTALL_FLAGS[*]}" || return 1
	sanitize_sysroot_libs librav1e || return 1
	del_pkgconfig_gcc_s rav1e.pc || return 1
}

### CMAKE ###
build_cpuinfo() {
	cmake \
		"${CMAKE_FLAGS[@]}" \
		-DCPUINFO_BUILD_UNIT_TESTS=OFF \
		-DCPUINFO_BUILD_MOCK_TESTS=OFF \
		-DCPUINFO_BUILD_BENCHMARKS=OFF \
		-DUSE_SYSTEM_LIBS=ON || return 1
	ccache make -j"${JOBS}" || return 1
	${SUDO_MODIFY} make -j"${JOBS}" install || return 1
	sanitize_sysroot_libs libcpuinfo || return 1
}

build_libsvtav1() {
	cmake \
		"${CMAKE_FLAGS[@]}" \
		-DENABLE_AVX512=ON \
		-DBUILD_TESTING=OFF \
		-DCOVERAGE=OFF || return 1
	ccache make -j"${JOBS}" || return 1
	${SUDO_MODIFY} make -j"${JOBS}" install || return 1
	sanitize_sysroot_libs libSvtAv1Enc || return 1
}

build_libsvtav1_psy() {
	local hdr10pluslib="${LIBDIR}/libhdr10plus-rs.${USE_LIB_SUFF}"
	local dovilib="${LIBDIR}/libdovi.${USE_LIB_SUFF}"
	cmake \
		"${CMAKE_FLAGS[@]}" \
		-DBUILD_TESTING=OFF \
		-DENABLE_AVX512=ON \
		-DCOVERAGE=OFF \
		-DLIBDOVI_FOUND=1 \
		-DLIBHDR10PLUS_RS_FOUND=1 \
		-DLIBHDR10PLUS_RS_LIBRARY="${hdr10pluslib}" \
		-DLIBDOVI_LIBRARY="${dovilib}" \
		. || return 1
	ccache make -j"${JOBS}" || return 1
	${SUDO_MODIFY} make -j"${JOBS}" install || return 1
	sanitize_sysroot_libs libSvtAv1Enc || return 1
}

build_libaom() {
	cmake \
		"${CMAKE_FLAGS[@]}" \
		-B build.user \
		-DENABLE_TESTS=OFF || return 1
	cd build.user || return 1
	ccache make -j"${JOBS}" || return 1
	${SUDO_MODIFY} make -j"${JOBS}" install || return 1
	sanitize_sysroot_libs libaom || return 1
}

build_libopus() {
	cmake \
		"${CMAKE_FLAGS[@]}" || return 1
	ccache make -j"${JOBS}" || return 1
	${SUDO_MODIFY} make -j"${JOBS}" install || return 1
	sanitize_sysroot_libs libopus || return 1
}

build_libwebp() {
	cmake \
		"${CMAKE_FLAGS[@]}" || return 1
	ccache make -j"${JOBS}" || return 1
	${SUDO_MODIFY} make -j"${JOBS}" install || return 1
	sanitize_sysroot_libs libwebp libsharpyuv || return 1
}

build_libjpeg() {
	cmake \
		"${CMAKE_FLAGS[@]}" || return 1
	ccache make -j"${JOBS}" || return 1
	${SUDO_MODIFY} make -j"${JOBS}" install || return 1
	sanitize_sysroot_libs libjpeg || return 1
}

build_libpng() {
	cmake \
		"${CMAKE_FLAGS[@]}" \
		-DPNG_TESTS=OFF \
		-DPNG_TOOLS=OFF || return 1
	ccache make -j"${JOBS}" || return 1
	${SUDO_MODIFY} make -j"${JOBS}" install || return 1
	sanitize_sysroot_libs libpng || return 1
}

build_zlib() {
	cmake \
		"${CMAKE_FLAGS[@]}" \
		-DZLIB_BUILD_EXAMPLES=OFF || return 1
	ccache make -j"${JOBS}" || return 1
	${SUDO_MODIFY} make -j"${JOBS}" install || return 1
	sanitize_sysroot_libs libz || return 1
}

build_glslang() {
	cmake \
		"${CMAKE_FLAGS[@]}" \
		-DALLOW_EXTERNAL_SPIRV_TOOLS=ON || return 1
	ccache make -j"${JOBS}" || return 1
	${SUDO_MODIFY} make -j"${JOBS}" install || return 1
	sanitize_sysroot_libs glslang || return 1
}

build_spirv_tools() {
	cmake \
		"${CMAKE_FLAGS[@]}" \
		-DSPIRV-Headers_SOURCE_DIR="${PREFIX}" \
		-DSPIRV_WERROR=OFF \
		-DSPIRV_SKIP_TESTS=ON \
		-G Ninja || return 1
	ccache ninja || return 1
	${SUDO_MODIFY} ninja install || return 1
}

build_spirv_headers() {
	cmake \
		"${CMAKE_FLAGS[@]}" \
		-G Ninja || return 1
	ccache ninja || return 1
	${SUDO_MODIFY} ninja install || return 1
}

# libx265 does not support cmake >= 4
build_cmake() {
	local cmakeVersion verMajor
	# don't need to build if system version is below 4
	IFS=$' \t' read -r _ _ cmakeVersion <<<"$(cmake --version)"
	IFS='.' read -r verMajor _ _ <<<"${cmakeVersion}"
	if [[ ${verMajor} -lt 4 ]]; then
		return 0
	fi

	# don't need to rebuild if already built
	local cmake="${PREFIX}/bin/cmake"
	if [[ -f ${cmake} ]]; then
		IFS=$' \t' read -r _ _ cmakeVersion <<<"$("${cmake}" --version)"
		IFS='.' read -r verMajor _ _ <<<"${cmakeVersion}"
		if [[ ${verMajor} -lt 4 ]]; then
			return 0
		fi
	fi

	cmake \
		-DCMAKE_PREFIX_PATH="${PREFIX}" \
		-DCMAKE_INSTALL_PREFIX="${PREFIX}" \
		-DCMAKE_INSTALL_LIBDIR=lib \
		-DCMAKE_BUILD_TYPE=Release || return 1
	ccache make -j"${JOBS}" || return 1
	${SUDO_MODIFY} make -j"${JOBS}" install || return 1
}

build_libx265() {
	PATH="${PREFIX}/bin:$PATH" cmake \
		"${CMAKE_FLAGS[@]}" \
		-G "Unix Makefiles" \
		-DHIGH_BIT_DEPTH=ON \
		-DENABLE_HDR10_PLUS=OFF \
		./source || return 1
	ccache make -j"${JOBS}" || return 1
	${SUDO_MODIFY} make -j"${JOBS}" install || return 1
	sanitize_sysroot_libs libx265 || return 1
	del_pkgconfig_gcc_s x265.pc || return 1
}

### MESON ###
build_libdav1d() {
	local enableAsm=true
	# arm64 will fail the build at 0 optimization
	if [[ "${HOSTTYPE}:${OPT}" == "aarch64:0" ]]; then
		enableAsm="false"
	fi
	meson \
		setup . build.user \
		-Denable_asm=${enableAsm} \
		"${MESON_FLAGS[@]}" || return 1
	ccache ninja -vC build.user || return 1
	${SUDO_MODIFY} ninja -vC build.user install || return 1
	sanitize_sysroot_libs libdav1d || return 1
}

build_libplacebo() {
	meson \
		setup . build.user \
		"${MESON_FLAGS[@]}" || return 1
	ccache ninja -vC build.user || return 1
	${SUDO_MODIFY} ninja -vC build.user install || return 1
	sanitize_sysroot_libs libplacebo || return 1
}

build_libvmaf() {
	cd libvmaf || return 1
	python3 -m virtualenv .venv
	(
		source .venv/bin/activate
		meson \
			setup . build.user \
			"${MESON_FLAGS[@]}" \
			-Denable_float=true || exit 1
		ccache ninja -vC build.user || exit 1
		${SUDO_MODIFY} ninja -vC build.user install || exit 1
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

### AUTOTOOLS ###
build_libx264() {
	./configure \
		"${CONFIGURE_FLAGS[@]}" \
		--disable-cli || return 1
	ccache make -j"${JOBS}" || return 1
	${SUDO_MODIFY} make -j"${JOBS}" install || return 1
	sanitize_sysroot_libs libx264 || return 1
}

build_libmp3lame() {
	# https://sourceforge.net/p/lame/mailman/message/36081038/
	if is_darwin; then
		remove_line \
			'include/libmp3lame.sym' \
			'lame_init_old' || return 1
	fi

	./configure \
		"${CONFIGURE_FLAGS[@]}" \
		--enable-nasm || return 1
	ccache make -j"${JOBS}" || return 1
	${SUDO_MODIFY} make -j"${JOBS}" install || return 1
	sanitize_sysroot_libs libmp3lame || return 1
}

build_libnuma() {
	# darwin does not have numa
	if is_darwin; then return 0; fi

	./autogen.sh || return 1
	./configure \
		"${CONFIGURE_FLAGS[@]}" || return 1
	ccache make -j"${JOBS}" || return 1
	${SUDO_MODIFY} make -j"${JOBS}" install || return 1
	sanitize_sysroot_libs libnuma || return 1
}

add_project_versioning_to_ffmpeg() {
	local fname='ffmpeg_opt.c'
	local optFile="fftools/${fname}"
	if [[ ! -f ${optFile} ]]; then
		echo_fail "could not find ${fname} to add project versioning"
	fi

	local searchFor='Universal media converter\n'
	local foundUsageStart=0
	local newOptFile="${TMP_DIR}/${fname}"
	test -f "${newOptFile}" && rm "${newOptFile}"
	while read -r line; do
		# if we found the line previously, add the versioning
		if [[ ${foundUsageStart} -eq 1 ]]; then
			if line_starts_with "${line}" '}'; then
				echo_info "found ${line} on ${lineNum}"
				for info in "${FFMPEG_BUILDER_INFO[@]}"; do
					local newline="av_log(NULL, AV_LOG_INFO, \"${info}\n\");"
					echo "${newline}" >>"${newOptFile}"
					lineNum=$((lineNum + 1))
				done
				newline="av_log(NULL, AV_LOG_INFO, \"\n\");"
				echo "${newline}" >>"${newOptFile}"
				foundUsageStart=0
			fi
		fi
		# find the line we are searching for
		if line_contains "${line}" "${searchFor}"; then
			foundUsageStart=1
		fi
		# start building the new file
		echo "${line}" >>"${newOptFile}"
	done <"${optFile}"

	cp "${newOptFile}" "${optFile}" || return 1

	return 0
}
build_ffmpeg() {
	for enable in ${ENABLE}; do
		test "${enable}" == 'libsvtav1_psy' && enable='libsvtav1'
		CONFIGURE_FLAGS+=("--enable-${enable}")
	done
	add_project_versioning_to_ffmpeg || return 1

	# lto is broken on darwin for ffmpeg only
	# https://trac.ffmpeg.org/ticket/11479
	local ffmpegFlags=()
	if is_darwin; then
		for flag in "${CONFIGURE_FLAGS[@]}"; do
			test "${flag}" == '--enable-lto' && continue
			ffmpegFlags+=("${flag}")
		done
		for flag in "${FFMPEG_EXTRA_FLAGS[@]}"; do
			ffmpegFlags+=("${flag// ${LTO_FLAG}/}")
		done
	else
		ffmpegFlags=("${CONFIGURE_FLAGS[@]}" "${FFMPEG_EXTRA_FLAGS[@]}")
	fi

	./configure \
		"${ffmpegFlags[@]}" \
		--enable-gpl \
		--enable-version3 \
		--disable-htmlpages \
		--disable-podpages \
		--disable-txtpages \
		--disable-autodetect || return 1
	ccache make -j"${JOBS}" || return 1
	${SUDO_MODIFY} make -j"${JOBS}" install || return 1
	sanitize_sysroot_libs \
		libavcodec libavdevice libavfilter libswscale \
		libavformat libavutil libswresample || return 1
}
