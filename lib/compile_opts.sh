#!/usr/bin/env bash

# variables used externally
# shellcheck disable=SC2034

# complete clean before building
CLEAN=true
# enable link time optimization
LTO=false
# optimization level (0-3)
OPT_LVL=0
# static or shared build
STATIC=true
# CPU type (x86_v{1,2,3}...)
CPU=native
# architecture type
ARCH=native
# prefix to install, leave empty for non-system install (local)
PREFIX=''
# configure what ffmpeg enables
FFMPEG_ENABLES=(
	libopus
	libdav1d
	libsvtav1_psy
	libaom
	librav1e
	libvmaf
)
