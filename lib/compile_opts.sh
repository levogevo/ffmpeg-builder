#!/usr/bin/env bash

# variables used externally
# shellcheck disable=SC2034

# compile option descriptions
unset FB_COMP_OPTS_DESC
declare -Ag FB_COMP_OPTS_DESC

# default compile options
FB_COMP_OPTS_DESC['CLEAN']='clean build directories before building'
DEFAULT_CLEAN=true

FB_COMP_OPTS_DESC['LTO']='enable link time optimization'
DEFAULT_LTO=ON

FB_COMP_OPTS_DESC['OPT']='optimization level (0-3)'
DEFAULT_OPT=3

FB_COMP_OPTS_DESC['STATIC']='static or shared build'
DEFAULT_STATIC=ON

FB_COMP_OPTS_DESC['ARCH']='architecture type (x86-64-v{1,2,3,4}, armv8-a, etc)'
DEFAULT_ARCH=native

FB_COMP_OPTS_DESC['PREFIX']='prefix to install to, default is local install in ./gitignore/sysroot'
DEFAULT_PREFIX='local'

FB_COMP_OPTS_DESC['ENABLE']='configure what ffmpeg enables'
DEFAULT_ENABLE="\
libsvtav1_psy \
libopus \
libdav1d \
libaom \
librav1e \
libvmaf \
libx264 \
libx265 \
libwebp \
libmp3lame \
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
