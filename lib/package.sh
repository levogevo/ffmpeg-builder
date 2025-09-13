#!/usr/bin/env bash

check_for_package_cfg() {
	local requiredCfg='ON:ON:3'
	local currentCfg="${STATIC}:${LTO}:${OPT}"
	if [[ ${currentCfg} == "${requiredCfg}" ]]; then
		return 0
	else
		return 1
	fi
}

FB_FUNC_NAMES+=('package')
FB_FUNC_DESCS['package']='package ffmpeg build'
package() {
	check_for_package_cfg || return 0

	echo_info "packaging"
	local pkgDir="${IGN_DIR}/package"
	test -d "${pkgDir}" && rm -rf "${pkgDir}"
	mkdir "${pkgDir}" || return 1

	set_compile_opts || return 1
	cp "${PREFIX}/bin/ff"* "${pkgDir}/"

	cd "${pkgDir}" || return 1
	local tarball="ffmpeg-build-${HOSTTYPE}-$(print_os).tar"
	tar -cf "${tarball}" ff* || return 1
	xz -e -9 "${tarball}" || return 1
	echo_pass "finished packaging ${tarball}.xz"
}
