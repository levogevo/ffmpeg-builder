#!/usr/bin/env bash

# variables used externally
# shellcheck disable=SC2034

# compile option descriptions
unset FB_COMP_OPTS_DESC
declare -Ag FB_COMP_OPTS_DESC

# default build options
FB_COMP_OPTS_DESC['CLEAN']='clean build directories before building (ON/OFF)'
DEFAULT_CLEAN=ON

FB_COMP_OPTS_DESC['LTO']='enable link time optimization (ON/OFF)'
DEFAULT_LTO=ON

FB_COMP_OPTS_DESC['PGO']='enable profile guided optimization (ON/OFF)'
DEFAULT_PGO=OFF

FB_COMP_OPTS_DESC['OPT']='optimization level (0-3)'
DEFAULT_OPT=3

FB_COMP_OPTS_DESC['STATIC']='static (ON) or shared (OFF) build'
DEFAULT_STATIC=ON

FB_COMP_OPTS_DESC['ARCH']='architecture type (x86-64-v{1,2,3,4}, armv8-a, etc)'
DEFAULT_ARCH=native

FB_COMP_OPTS_DESC['PREFIX']='path to install to, local install is in ./gitignore/sysroot'
DEFAULT_PREFIX='local'

FB_COMP_OPTS_DESC['PACKAGE']='package ffmpeg binaries to tarball in ./gitignore/package (ON/OFF)'
DEFAULT_PACKAGE=OFF

FB_COMP_OPTS_DESC['ENABLE']='configure what ffmpeg enables'
DEFAULT_ENABLE="
lcms2
libaom
libass
libvpx
libjxl
libxml2
libvmaf
libx264
libx265
libwebp
libopus
librav1e
libdav1d
libbluray
libsnappy
libvorbis
libmp3lame
libfribidi
libfreetype
libharfbuzz
libopenjpeg
libsvtav1_hdr
libfontconfig
"

# user-overridable compile option variable names
FB_COMP_OPTS=("${!FB_COMP_OPTS_DESC[@]}")

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
