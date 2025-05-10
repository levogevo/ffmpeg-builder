#!/usr/bin/env bash

REPO_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
IGN_DIR="${REPO_DIR}/gitignore"
TMP_DIR="${IGN_DIR}/tmp"
DL_DIR="${IGN_DIR}/downloads"
BUILD_DIR="${IGN_DIR}/builds"
CCACHE_DIR="${IGN_DIR}/ccache"
export REPO_DIR IGN_DIR TMP_DIR DL_DIR BUILD_DIR CCACHE_DIR

# function names, descriptions, completions
FB_FUNC_NAMES=()
declare -A FB_FUNC_DESCS
declare -A FB_FUNC_COMPLETION

BUILD_CFG="${REPO_DIR}/"cfgs/builds.json
COMPILE_CFG="${REPO_DIR}/"cfgs/compile_opts.json
mapfile -t BUILDS < <(jq -r 'keys[]' "$BUILD_CFG")
export BUILD_CFG COMPILE_CFG BUILDS

# enable what ffmpeg builds
unset FFMPEG_ENABLES
export FFMPEG_ENABLES
for enable in $(jq -r '.ffmpeg_enable[]' "$COMPILE_CFG"); do
    FFMPEG_ENABLES+=("${enable}")
done

src_scripts() {
    for script in "${REPO_DIR}/scripts/"*.sh; do
        # shellcheck disable=SC1090
        source "${script}"
    done
}

FB_FUNC_NAMES+=('print_cmds')
FB_FUNC_DESCS['print_cmds']='print usable commands'
print_cmds() {
    echo -e "\n~~~ Usable Commands ~~~"
    for funcname in "${FB_FUNC_NAMES[@]}"; do
        echo -e "${CYAN}${funcname}${NC}:\n\t" "${FB_FUNC_DESCS[${funcname}]}"
    done
    echo -e "~~~~~~~~~~~~~~~~~~~~~~~\n"
}

set_completions() {
    for funcname in "${FB_FUNC_NAMES[@]}"; do
        complete -W "${FB_FUNC_COMPLETION[${funcname}]}" "${funcname}"
    done
}

# shellcheck disable=SC1091
source "${HOME}/.bashrc"
src_scripts || return 1
determine_os || return 1

unset PREFIX
PREFIX="$(jq -r '.prefix' "${COMPILE_CFG}")"
test "${PREFIX}" == 'null' && PREFIX="${IGN_DIR}/${OS}_sysroot"
export PREFIX

set_compile_opts || return 1
print_cmds || return 1
set_completions || return 1
