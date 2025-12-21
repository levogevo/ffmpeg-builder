#!/usr/bin/env bash

check_for_package_cfg() {
	local requiredCfg='ON:ON:ON:3'
	local currentCfg="${STATIC}:${LTO}:${PGO}:${OPT}"
	if [[ ${currentCfg} == "${requiredCfg}" ]]; then
		return 0
	else
		return 1
	fi
}

FB_FUNC_NAMES+=('package')
FB_FUNC_DESCS['package']='package ffmpeg build'
package() {
	local pkgDir="${IGN_DIR}/package"
	recreate_dir "${pkgDir}" || return 1
	check_for_package_cfg || return 0

	echo_info "packaging"
	set_compile_opts || return 1
	cp "${PREFIX}/bin/ff"* "${pkgDir}/"

	cd "${pkgDir}" || return 1
	local tarball="ffmpeg-build-${HOSTTYPE}-$(print_os).tar"
	tar -cf "${tarball}" ff* || return 1
	xz -e -9 "${tarball}" || return 1
	echo_pass "finished packaging ${tarball}.xz"
}
