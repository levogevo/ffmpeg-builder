#!/usr/bin/env bash

# variables used externally
# shellcheck disable=SC2034

# default compile options

# clean build directories before building
DEFAULT_CLEAN=true
# enable link time optimization
DEFAULT_LTO=true
# optimization level (0-3)
DEFAULT_OPT_LVL=3
# static or shared build
DEFAULT_STATIC=true
# CPU type (amd64/v{1,2,3}...)
DEFAULT_CPU=native
# architecture type
DEFAULT_ARCH=native
# prefix to install to, default is local install
DEFAULT_PREFIX='local'
# configure what ffmpeg enables
DEFAULT_FFMPEG_ENABLES="\
libsvtav1_psy \
libopus \
libdav1d \
libaom \
librav1e \
libvmaf \
"

# user-overridable compile option variable names
FB_COMP_OPTS=(
	CLEAN LTO OPT_LVL STATIC CPU ARCH PREFIX FFMPEG_ENABLES
)

# sets FB_COMP_OPTS to allow for user-overriding
check_compile_opts_override() {
	for opt in "${FB_COMP_OPTS[@]}"; do
		declare -n defOptVal="DEFAULT_${opt}"
		declare -n optVal="${opt}"
		# use given value if not overridden
		if [[ -n ${optVal} && ${optVal} != "${defOptVal}" ]]; then
			echo_warn "setting given value for ${opt}=${optVal[*]}"
			declare -g "${opt}=${optVal}"
		else
			echo_info "setting default value for ${opt}=${defOptVal[*]}"
			declare -g "${opt}=${defOptVal}"
		fi
	done
}
