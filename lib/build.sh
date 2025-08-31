#!/usr/bin/env bash

set_compile_opts() {
	test "$FB_COMPILE_OPTS_SET" == 1 && return 0

	unset LDFLAGS C_FLAGS CXX_FLAGS CPP_FLAGS \
		CONFIGURE_FLAGS MESON_FLAGS \
		RUSTFLAGS CMAKE_FLAGS \
		FFMPEG_EXTRA_FLAGS \
		CARGO_FLAGS CARGO_CINSTALL_FLAGS
	export LDFLAGS C_FLAGS CXX_FLAGS CPP_FLAGS \
		CONFIGURE_FLAGS MESON_FLAGS \
		RUSTFLAGS CMAKE_FLAGS \
		FFMPEG_EXTRA_FLAGS PATH

	# set job count for all builds
	JOBS="$(nproc)"
	# local vs system prefix
	test "${PREFIX}" == 'local' && PREFIX="${IGN_DIR}/$(print_os)_sysroot"
	# set library/pkgconfig directory
	LIBDIR="${PREFIX}/lib"

	# set prefix flags
	CONFIGURE_FLAGS+=(
		"--prefix=${PREFIX}"
		"--libdir=${LIBDIR}"
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
	CARGO_BUILD_TYPE=release
	CARGO_FLAGS+=("--${CARGO_BUILD_TYPE}")
	CARGO_CINSTALL_FLAGS=(
		"--${CARGO_BUILD_TYPE}"
		"--prefix" "${PREFIX}"
		"--libdir" "${LIBDIR}"
	)
	PKG_CONFIG_PATH="${LIBDIR}/pkgconfig"
	export PKG_CONFIG_PATH

	# add prefix include
	C_FLAGS+=("-I${PREFIX}/include")

	# enabling link-time optimization
	# shellcheck disable=SC2034
	unset LTO_SWITCH LTO_FLAG LTO_BOOL
	export LTO_SWITCH LTO_FLAG LTO_BOOL
	if [[ ${LTO} == 'true' ]]; then
		echo_info "building with LTO"
		LTO_SWITCH='ON'
		LTO_FLAG='-flto'
		C_FLAGS+=("${LTO_FLAG}")
		if ! is_darwin; then
			CONFIGURE_FLAGS+=('--enable-lto')
		fi
		MESON_FLAGS+=("-Db_lto=true")
		RUSTFLAGS+=("-C lto=yes" "-C inline-threshold=1000" "-C codegen-units=1")
	else
		echo_info "building without LTO"
		LTO_SWITCH='OFF'
		LTO_FLAG=''
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
	echo_info "building with optimization: ${OPT}"

	STATIC_LIB_SUFF='a'
	# darwin has different suffix for dynamic libraries
	if is_darwin; then
		SHARED_LIB_SUFF='dylib'
	else
		SHARED_LIB_SUFF='so'
	fi

	# static/shared linking
	unset PKG_CFG_FLAGS LIB_SUFF
	export PKG_CFG_FLAGS LIB_SUFF
	if [[ ${STATIC} == true ]]; then
		LDFLAGS+=('-static')
		CONFIGURE_FLAGS+=('--enable-static')
		MESON_FLAGS+=('--default-library=static')
		CMAKE_FLAGS+=("-DBUILD_SHARED_LIBS=OFF")
		RUSTFLAGS+=("-C target-feature=+crt-static")
		PKG_CFG_FLAGS='--static'
		# darwin does not support static linkage
		if ! is_darwin; then
			CMAKE_FLAGS+=("-DCMAKE_EXE_LINKER_FLAGS=-static")
			FFMPEG_EXTRA_FLAGS+=(--extra-ldflags="${LDFLAGS[*]}")
		fi
		# remove shared libraries for static builds
		USE_LIB_SUFF="${STATIC_LIB_SUFF}"
		DEL_LIB_SUFF="${SHARED_LIB_SUFF}"
	else
		LDFLAGS+=("-Wl,-rpath,${LIBDIR}" "-Wl,-rpath-link,${LIBDIR}")
		CONFIGURE_FLAGS+=('--enable-shared')
		CMAKE_FLAGS+=(
			"-DBUILD_SHARED_LIBS=ON"
			"-DCMAKE_INSTALL_RPATH=${LIBDIR}"
		)
		FFMPEG_EXTRA_FLAGS+=('--enable-rpath')
		# remove static libraries for shared builds
		USE_LIB_SUFF="${SHARED_LIB_SUFF}"
		DEL_LIB_SUFF="${STATIC_LIB_SUFF}"
	fi

	# architecture/cpu compile flags
	# arm prefers -mcpu over -march
	# https://community.arm.com/arm-community-blogs/b/tools-software-ides-blog/posts/compiler-flags-across-architectures-march-mtune-and-mcpu
	# and can fail static builds with -fpic
	# warning: too many GOT entries for -fpic, please recompile with -fPIC
	local arch_flags=()
	if [[ ${HOSTTYPE} == "x86_64" ]]; then
		arch_flags+=("-march=${CPU}")
	elif [[ ${HOSTTYPE} == "aarch64" ]]; then
		arch_flags+=("-mcpu=${CPU}")
	fi

	C_FLAGS+=("${arch_flags[@]}" "-fPIC")
	CXX_FLAGS=("${C_FLAGS[@]}")
	CPP_FLAGS=("${C_FLAGS[@]}")
	RUSTFLAGS+=("-C target-cpu=${CPU}")
	CMAKE_FLAGS+=("-DCMAKE_C_FLAGS=${C_FLAGS[*]}")
	CMAKE_FLAGS+=("-DCMAKE_CXX_FLAGS=${CXX_FLAGS[*]}")
	MESON_FLAGS+=("-Dc_args=${C_FLAGS[*]}" "-Dcpp_args=${CPP_FLAGS[*]}")
	echo_info "CLEAN: $CLEAN"
	dump_arr CONFIGURE_FLAGS
	dump_arr C_FLAGS
	dump_arr RUSTFLAGS
	dump_arr CARGO_CINSTALL_FLAGS
	dump_arr CMAKE_FLAGS
	dump_arr MESON_FLAGS
	dump_arr PKG_CFG_FLAGS

	# extra ffmpeg flags
	FFMPEG_EXTRA_FLAGS+=(
		--extra-cflags="${C_FLAGS[*]}"
		--extra-cxxflags="${CXX_FLAGS[*]}"
	)
	dump_arr FFMPEG_EXTRA_FLAGS

	# shellcheck disable=SC2178
	RUSTFLAGS="${RUSTFLAGS[*]}"

	# make sure RUSTUP_HOME and CARGO_HOME are defined
	RUSTUP_HOME="${RUSTUP_HOME:-"${HOME}/.rustup"}"
	CARGO_HOME="${CARGO_HOME:-"${HOME}/.cargo"}"
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

get_build_conf() {
	local getBuild="${1}"

	# name version file-extension url dep1,dep2
	# shellcheck disable=SC2016
	local BUILDS_CONF='
ffmpeg           8.0      tar.gz    https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n${ver}.${ext}
hdr10plus_tool   1.7.1    tar.gz    https://github.com/quietvoid/hdr10plus_tool/archive/refs/tags/${ver}.${ext}
dovi_tool        2.3.0    tar.gz    https://github.com/quietvoid/dovi_tool/archive/refs/tags/${ver}.${ext}
libsvtav1        3.1.2    tar.gz    https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v${ver}/SVT-AV1-v${ver}.${ext}
libsvtav1_psy    3.0.2-A  tar.gz    https://github.com/BlueSwordM/svt-av1-psyex/archive/refs/tags/v${ver}.${ext} dovi_tool,hdr10plus_tool,cpuinfo
librav1e         0.8.1    tar.gz    https://github.com/xiph/rav1e/archive/refs/tags/v${ver}.${ext}
libaom           3.12.1   tar.gz    https://storage.googleapis.com/aom-releases/libaom-${ver}.${ext}
libvmaf          3.0.0    tar.gz    https://github.com/Netflix/vmaf/archive/refs/tags/v${ver}.${ext}
libopus          1.5.2    tar.gz    https://github.com/xiph/opus/releases/download/v${ver}/opus-${ver}.${ext}
libdav1d         1.5.1    tar.xz    http://downloads.videolan.org/videolan/dav1d/${ver}/dav1d-${ver}.${ext}
cpuinfo          latest   git       https://github.com/pytorch/cpuinfo/
'

	local supported_builds=()
	unset ver ext url deps extracted_dir
	while read -r line; do
		test "${line}" == '' && continue
		IFS=' ' read -r build ver ext url deps <<<"${line}"
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
	# set extracted directory
	extracted_dir="${BUILD_DIR}/${build}-v${ver}"

	return 0
}

download_release() {
	local build="${1}"
	# set env for wget download
	get_build_conf "${build}" || return 1
	local base_path="${build}-v${ver}"
	local base_dl_path="${DL_DIR}/${base_path}"

	# remove other versions of a download
	for wrong_ver_dl in "${DL_DIR}/${build}-v"*; do
		if [[ ${wrong_ver_dl} =~ ${base_path} ]]; then
			continue
		fi
		test -f "${wrong_ver_dl}" || continue
		echo_warn "removing wrong version: ${wrong_ver_dl}"
		rm -rf "${wrong_ver_dl}"
	done
	# remove other versions of a build
	for wrong_ver_build in "${BUILD_DIR}/${build}-v"*; do
		if [[ ${wrong_ver_build} =~ ${base_path} ]]; then
			continue
		fi
		test -d "${wrong_ver_build}" || continue
		echo_warn "removing wrong version: ${extracted_dir}"
		rm -rf "${wrong_ver_build}"
	done

	# enabling a clean build
	if [[ ${CLEAN} == 'true' ]]; then
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
			git clone "${url}" "${base_dl_path}" || return 1

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
	download_release "${build}" || return 1
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

	return 0
}

# make sure the sysroot has the appropriate library type
# darwin will always link dynamically if a dylib is present
# so they must be remove for static builds
sanitize_sysroot_libs() {
	local lib="$1"
	local libPath="${LIBDIR}/${lib}"
	local useLib="${libPath}.${USE_LIB_SUFF}"
	local delLib="${libPath}.${DEL_LIB_SUFF}"

	if [[ ! -f ${useLib} ]]; then
		echo_fail "could not find ${useLib}, something is wrong"
		return 1
	fi
	${SUDO_MODIFY} rm "${delLib}"*
	return 0
}

### RUST ###
build_hdr10plus_tool() {
	cargo build "${CARGO_FLAGS[@]}" || return 1
	${SUDO_MODIFY} cp \
		"target/${CARGO_BUILD_TYPE}/hdr10plus_tool" \
		"${PREFIX}/bin/" || return 1

	# build libhdr10plus
	cd hdr10plus || return 1
	cargo cbuild "${CARGO_FLAGS[@]}" || return 1
	${SUDO_CARGO} bash -lc "PATH=\"${PATH}\" cargo cinstall ${CARGO_CINSTALL_FLAGS[*]}" || return 1
	sanitize_sysroot_libs 'libhdr10plus-rs' || return 1
}
build_dovi_tool() {
	cargo build "${CARGO_FLAGS[@]}" || return 1
	${SUDO_MODIFY} cp \
		"target/${CARGO_BUILD_TYPE}/dovi_tool" \
		"${PREFIX}/bin/" || return 1

	# build libdovi
	cd dolby_vision || return 1
	cargo cbuild "${CARGO_FLAGS[@]}" || return 1
	${SUDO_CARGO} bash -lc "PATH=\"${PATH}\" cargo cinstall ${CARGO_CINSTALL_FLAGS[*]}" || return 1
	sanitize_sysroot_libs 'libdovi' || return 1
}
build_librav1e() {
	cargo build "${CARGO_FLAGS[@]}" || return 1
	${SUDO_MODIFY} cp \
		"target/${CARGO_BUILD_TYPE}/rav1e" \
		"${PREFIX}/bin/" || return 1

	# build librav1e
	cargo cbuild "${CARGO_FLAGS[@]}" || return 1
	${SUDO_CARGO} bash -lc "PATH=\"${PATH}\" cargo cinstall ${CARGO_CINSTALL_FLAGS[*]}" || return 1
	sanitize_sysroot_libs 'librav1e' || return 1

	# HACK PATCH
	# remove '-lgcc_s' from pkgconfig for static builds
	if [[ ${STATIC} == 'true' ]]; then
		local fname='rav1e.pc'
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
	sanitize_sysroot_libs 'libcpuinfo' || return 1
}
build_libsvtav1() {
	cmake \
		"${CMAKE_FLAGS[@]}" \
		-DENABLE_AVX512=ON \
		-DBUILD_TESTING=OFF \
		-DCOVERAGE=OFF || return 1
	ccache make -j"${JOBS}" || return 1
	${SUDO_MODIFY} make -j"${JOBS}" install || return 1
	sanitize_sysroot_libs 'libSvtAv1Enc' || return 1
}
build_libsvtav1_psy() {
	local hdr10pluslib="$(find -L "${PREFIX}" -type f -name "libhdr10plus-rs.${USE_LIB_SUFF}")"
	local dovilib="$(find -L "${PREFIX}" -type f -name "libdovi.${USE_LIB_SUFF}")"
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
	sanitize_sysroot_libs 'libSvtAv1Enc' || return 1
}
build_libaom() {
	cmake \
		"${CMAKE_FLAGS[@]}" \
		-B build.user \
		-DENABLE_TESTS=OFF || return 1
	cd build.user || return 1
	ccache make -j"${JOBS}" || return 1
	${SUDO_MODIFY} make -j"${JOBS}" install || return 1
	sanitize_sysroot_libs 'libaom' || return 1
}
build_libopus() {
	cmake \
		"${CMAKE_FLAGS[@]}" || return 1
	ccache make -j"${JOBS}" || return 1
	${SUDO_MODIFY} make -j"${JOBS}" install || return 1
	sanitize_sysroot_libs 'libopus' || return 1
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
	sanitize_sysroot_libs 'libdav1d' || return 1
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
	sanitize_sysroot_libs 'libvmaf' || return 1

	# HACK PATCH
	# add '-lstdc++' to pkgconfig for static builds
	if [[ ${STATIC} == 'true' ]]; then
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
add_project_versioning_to_ffmpeg() {
	local optFile
	local fname='ffmpeg_opt.c'
	optFile="$(command ls ./**/"${fname}")"
	if [[ ! $? -eq 0 || ${optFile} == '' || ! -f ${optFile} ]]; then
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
		--pkg-config='pkg-config' \
		--pkg-config-flags="${PKG_CFG_FLAGS}" \
		--arch="${ARCH}" \
		--cpu="${CPU}" \
		--enable-gpl \
		--enable-version3 \
		--enable-nonfree \
		--disable-htmlpages \
		--disable-podpages \
		--disable-txtpages || return 1
	ccache make -j"${JOBS}" || return 1
	${SUDO_MODIFY} make -j"${JOBS}" install || return 1
}
# check that ffmpeg was built correctly
sanity_check_ffmpeg() {
	local ffmpeg="${PREFIX}/bin/ffmpeg"
	if has_cmd ldd; then
		while read -r line; do
			echo "${line}"
			if [[ ${STATIC} == 'true' ]]; then
				echo static
			else
				echo hi
			fi
		done
	fi
}
