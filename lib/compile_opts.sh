#!/usr/bin/env bash

# variables used externally
# shellcheck disable=SC2034

# default compile options

# clean build directories before building
DEFAULT_CLEAN=true
# enable link time optimization
DEFAULT_LTO=true
# optimization level (0-3)
DEFAULT_OPT=3
# static or shared build
DEFAULT_STATIC=true
# architecture type (x86-64-v{1,2,3,4}, armv8-a, etc)
DEFAULT_ARCH=native
# prefix to install to, default is local install
DEFAULT_PREFIX='local'
# configure what ffmpeg enables
DEFAULT_ENABLE="\
libsvtav1_psy \
libopus \
libdav1d \
libaom \
librav1e \
libvmaf \
"

# user-overridable compile option variable names
FB_COMP_OPTS=(
	CLEAN LTO OPT STATIC ARCH PREFIX ENABLE
)

# sets FB_COMP_OPTS to allow for user-overriding
check_compile_opts_override() {
	for opt in "${FB_COMP_OPTS[@]}"; do
		declare -n defOptVal="DEFAULT_${opt}"
		declare -n optVal="${opt}"
		# use given value if not overridden
		if [[ -v optVal && ${optVal} != "${defOptVal}" ]]; then
			echo_info "setting given value for ${opt}=${optVal}"
			declare -g "${opt}=${optVal}"
		else
			declare -g "${opt}=${defOptVal}"
		fi
	done
}
