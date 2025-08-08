#!/usr/bin/env bash

set_compile_opts() {
	test "$FB_COMPILE_OPTS_SET" == 1 && return 0

	unset LDFLAGS C_FLAGS CXX_FLAGS CPP_FLAGS \
		CONFIGURE_FLAGS MESON_FLAGS \
		RUSTFLAGS CMAKE_FLAGS \
		FFMPEG_EXTRA_FLAGS
	export LDFLAGS C_FLAGS CXX_FLAGS CPP_FLAGS \
		CONFIGURE_FLAGS MESON_FLAGS \
		RUSTFLAGS CMAKE_FLAGS \
		FFMPEG_EXTRA_FLAGS

	# set job count for all builds
	JOBS="$(nproc)"

	mapfile -t pkgconfigDirs < <(find "${PREFIX}" -type d -name pkgconfig)
	for d in "${pkgconfigDirs[@]}"; do
		if [[ ${d} =~ '64' ]]; then
			MACHINE_LIB="${d}"
		fi
	done
	test "${MACHINE_LIB}" == '' && return 1
	pkgconfigString="${pkgconfigDirs[*]}"
	PKG_CONFIG_PATH="${pkgconfigString// /:}"

	# set prefix flags
	CONFIGURE_FLAGS+=("--prefix=${PREFIX}")
	MESON_FLAGS+=("--prefix" "${PREFIX}")
	CMAKE_FLAGS+=("-DCMAKE_PREFIX_PATH=${PREFIX}")
	CMAKE_FLAGS+=("-DCMAKE_INSTALL_PREFIX=${PREFIX}")
	export PKG_CONFIG_PATH
	export PKG_CONFIG_DEBUG_SPEW=1

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
		CONFIGURE_FLAGS+=('--enable-lto')
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
	if [[ ${OPT_LVL} == '' ]]; then
		OPT_LVL='0'
	fi
	C_FLAGS+=("-O${OPT_LVL}")
	RUSTFLAGS+=("-C opt-level=${OPT_LVL}")
	MESON_FLAGS+=("--optimization=${OPT_LVL}")
	echo_info "building with optimization: ${OPT_LVL}"

	# static/shared linking
	unset PKG_CFG_FLAGS LIB_SUFF
	export PKG_CFG_FLAGS LIB_SUFF
	if [[ ${STATIC} == true ]]; then
		LDFLAGS+=('-static')
		CONFIGURE_FLAGS+=('--enable-static')
		CMAKE_FLAGS+=("-DBUILD_SHARED_LIBS=OFF")
		MESON_FLAGS+=('--default-library=static')
		CMAKE_FLAGS+=("-DCMAKE_EXE_LINKER_FLAGS=-static")
		PKG_CFG_FLAGS='--static'
		LIB_SUFF='a'
	else
		LDFLAGS+=("-Wl,-rpath,${MACHINE_LIB}")
		CONFIGURE_FLAGS+=('--enable-shared')
		CMAKE_FLAGS+=("-DBUILD_SHARED_LIBS=ON")
		CMAKE_FLAGS+=("-DCMAKE_INSTALL_RPATH=${PREFIX}/lib;${MACHINE_LIB}")
		FFMPEG_EXTRA_FLAGS+=('--enable-rpath')
		LIB_SUFF='so'
	fi

	# architecture/cpu compile flags
	# arm prefers -mcpu over -march
	# https://community.arm.com/arm-community-blogs/b/tools-software-ides-blog/posts/compiler-flags-across-architectures-march-mtune-and-mcpu
	arch_flags=""
	test_arch="$(uname -m)"
	if [[ ${test_arch} == "x86_64" ]]; then
		arch_flags="-march=${CPU}"
	elif [[ ${test_arch} == "aarch64" ||
		${test_arch} == "arm64" ]]; then
		arch_flags="-mcpu=${CPU}"
	fi

	C_FLAGS+=("${arch_flags}")
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
	dump_arr CMAKE_FLAGS
	dump_arr MESON_FLAGS
	dump_arr PKG_CFG_FLAGS

	# extra ffmpeg flags
	FFMPEG_EXTRA_FLAGS+=(
		--extra-cflags="${C_FLAGS[*]}"
		--extra-cxxflags="${CXX_FLAGS[*]}"
		--extra-ldflags="${LDFLAGS[*]}"
	)
	# dump_arr FFMPEG_EXTRA_FLAGS

	# shellcheck disable=SC2178
	RUSTFLAGS="${RUSTFLAGS[*]}"

	# make sure RUSTUP_HOME and CARGO_HOME are defined
	RUSTUP_HOME="${RUSTUP_HOME:-"${HOME}/.rustup"}"
	CARGO_HOME="${CARGO_HOME:-"${HOME}/.rustup"}"
	test -d "${RUSTUP_HOME}" || echo_exit "RUSTUP_HOME does not exist"
	test -d "${CARGO_HOME}" || echo_exit "CARGO_HOME does not exist"
	export RUSTUP_HOME CARGO_HOME

	# cargo does not have an easy way to install into system directories
	unset SUDO_CARGO
	if [[ ${SUDO} != '' ]]; then
		export SUDO_CARGO="${SUDO} --preserve-env=PATH,RUSTUP_HOME,CARGO_HOME"
	fi
	echo

	FB_COMPILE_OPTS_SET=1
}

get_build_conf() {
	local getBuild="${1}"

	# name version file-extension url dep1,dep2
	# shellcheck disable=SC2016
	local BUILDS_CONF='
ffmpeg          7cd1edeaa410d977a9f1ff8436f480cb45b80178 git https://github.com/FFmpeg/FFmpeg/
hdr10plus_tool  1.7.0   tar.gz    https://github.com/quietvoid/hdr10plus_tool/archive/refs/tags/${ver}.${ext}
dovi_tool       2.2.0   tar.gz    https://github.com/quietvoid/dovi_tool/archive/refs/tags/${ver}.${ext}
libsvtav1       3.0.2   tar.gz    https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v${ver}/SVT-AV1-v${ver}.${ext}
libsvtav1_psy   3.0.2   tar.gz    https://github.com/psy-ex/svt-av1-psy/archive/refs/tags/v${ver}.${ext} dovi_tool,hdr10plus_tool
librav1e        0.7.1   tar.gz    https://github.com/xiph/rav1e/archive/refs/tags/v${ver}.${ext}
libaom          3.12.1  tar.gz    https://storage.googleapis.com/aom-releases/libaom-${ver}.${ext}
libvmaf         3.0.0   tar.gz    https://github.com/Netflix/vmaf/archive/refs/tags/v${ver}.${ext}
libopus         1.5.2   tar.gz    https://github.com/xiph/opus/releases/download/v${ver}/opus-${ver}.${ext}
libdav1d        1.5.0   tar.xz    http://downloads.videolan.org/videolan/dav1d/${ver}/dav1d-${ver}.${ext}
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
	set_compile_opts || return 1
	for dep in "${deps[@]}"; do
		do_build "${dep}" || return 1
	done
	get_build_conf "${build}" || return 1
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
	test -d "${DL_DIR}" || mkdir -p "${DL_DIR}"
	test -d "${CCACHE_DIR}" || mkdir -p "${CCACHE_DIR}"
	test -d "${BUILD_DIR}" || mkdir -p "${BUILD_DIR}"
	test -d "${PREFIX}/bin/" || mkdir -p "${PREFIX}/bin/"

	testfile="${PREFIX}/ffmpeg-build-testfile"
	if ! touch "${testfile}" 2>/dev/null; then
		# we cannot modify the install prefix
		# so we need to use sudo
		${SUDO} mkdir -p "${PREFIX}/bin/"
	fi
	test -f "${testfile}" && ${SUDO} rm "${testfile}"

	for build in "${FFMPEG_ENABLES[@]}"; do
		do_build "${build}" || return 1
	done
	do_build "ffmpeg" || return 1

	return 0
}

build_hdr10plus_tool() {
	cargo build --release || return 1
	${SUDO} cp target/release/hdr10plus_tool "${PREFIX}/bin/" || return 1

	# build libhdr10plus
	cd hdr10plus || return 1
	cargo cbuild --release || return 1
	${SUDO_CARGO} bash -lc "cargo cinstall --prefix=${PREFIX} --release" || return 1
}

build_dovi_tool() {
	cargo build --release || return 1
	${SUDO} cp target/release/dovi_tool "${PREFIX}/bin/" || return 1

	# build libdovi
	cd dolby_vision || return 1
	cargo cbuild --release || return 1
	${SUDO_CARGO} bash -lc "cargo cinstall --prefix=${PREFIX} --release" || return 1
}

build_libsvtav1() {
	cmake \
		"${CMAKE_FLAGS[@]}" \
		-DSVT_AV1_LTO="${LTO_SWITCH}" \
		-DENABLE_AVX512=ON \
		-DBUILD_TESTING=OFF \
		-DCOVERAGE=OFF || return 1
	ccache make -j"${JOBS}" || return 1
	${SUDO} make -j"${JOBS}" install || return 1
}

build_libsvtav1_psy() {
	local hdr10pluslib="$(find "${PREFIX}" -type f -name "libhdr10plus-rs.${LIB_SUFF}")"
	local dovilib="$(find "${PREFIX}" -type f -name "libdovi.${LIB_SUFF}")"
	cmake \
		"${CMAKE_FLAGS[@]}" \
		-DSVT_AV1_LTO="${LTO_SWITCH}" \
		-DBUILD_TESTING=OFF \
		-DENABLE_AVX512=ON \
		-DCOVERAGE=OFF \
		-DLIBDOVI_FOUND=1 \
		-DLIBHDR10PLUS_RS_FOUND=1 \
		-DLIBHDR10PLUS_RS_LIBRARY="${hdr10pluslib}" \
		-DLIBDOVI_LIBRARY="${dovilib}" \
		. || return 1
	ccache make -j"${JOBS}" || return 1
	${SUDO} make -j"${JOBS}" install || return 1
}

build_librav1e() {
	cargo build --release || return 1
	${SUDO} cp target/release/rav1e "${PREFIX}/bin/" || return 1

	cargo cbuild --release || return 1
	${SUDO_CARGO} bash -lc "cargo cinstall --prefix=${PREFIX} --release" || return 1
}

build_libaom() {
	cmake \
		"${CMAKE_FLAGS[@]}" \
		-B build.user \
		-DENABLE_TESTS=OFF || return 1
	cd build.user || return 1
	ccache make -j"${JOBS}" || return 1
	${SUDO} make -j"${JOBS}" install || return 1
}

build_libopus() {
	./configure \
		"${CONFIGURE_FLAGS[@]}" \
		--disable-doc || return 1
	ccache make -j"${JOBS}" || return 1
	${SUDO} make -j"${JOBS}" install || return 1
	return 0
}

build_libdav1d() {
	meson \
		setup . build.user \
		"${MESON_FLAGS[@]}" || return 1
	ccache ninja -vC build.user || return 1
	${SUDO} ninja -vC build.user install || return 1
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
		${SUDO} ninja -vC build.user install || exit 1
	) || return 1
}

build_ffmpeg() {
	for enable in "${FFMPEG_ENABLES[@]}"; do
		test "${enable}" == 'libsvtav1_psy' && enable='libsvtav1'
		CONFIGURE_FLAGS+=("--enable-${enable}")
	done
	./configure \
		"${CONFIGURE_FLAGS[@]}" \
		"${FFMPEG_EXTRA_FLAGS[@]}" \
		--pkg-config='pkg-config' \
		--pkg-config-flags="${PKG_CFG_FLAGS}" \
		--cpu="${CPU}" --arch="${ARCH}" \
		--enable-gpl --enable-version3 \
		--enable-nonfree \
		--disable-htmlpages \
		--disable-podpages \
		--disable-txtpages \
		--disable-autodetect || return 1
	ccache make -j"${JOBS}" || return 1
	${SUDO} make -j"${JOBS}" install || return 1
	return 0
}
