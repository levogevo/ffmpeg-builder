#!/usr/bin/env bash

REPO_DIR="$(cd "${BASH_SOURCE[0]//'main.sh'/}" && echo "$PWD")"
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

# can't have recursive generation
FB_RUNNING_AS_SCRIPT=${FB_RUNNING_AS_SCRIPT:-0}

# no undefined variables
set -u

SCRIPT_DIR="${REPO_DIR}/scripts"
ENTRY_SCRIPT="${SCRIPT_DIR}/entry.sh"
src_scripts() {
	local SCRIPT_DIR="${REPO_DIR}/scripts"
	rm "${SCRIPT_DIR}"*.sh

	if [[ $FB_RUNNING_AS_SCRIPT -eq 0 ]]; then
		# shellcheck disable=SC2016
		echo '#!/usr/bin/env bash
cd "$(dirname "$(readlink -f $0)")/.."
. main.sh
FB_RUNNING_AS_SCRIPT=1
scr_name="$(bash_basename $0)"
cmd="${scr_name//.sh}"
$cmd $@' >"${ENTRY_SCRIPT}"
		chmod +x "${ENTRY_SCRIPT}"
	fi

	for script in "${REPO_DIR}/lib/"*.sh; do
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
		fb_running_as_script || (cd "$SCRIPT_DIR" && ln -sf entry.sh "${funcname}.sh")
	done
	echo -e "~~~~~~~~~~~~~~~~~~~~~~~\n"
}

set_completions() {
	set +u
	for funcname in "${FB_FUNC_NAMES[@]}"; do
		complete -W "${FB_FUNC_COMPLETION[${funcname}]}" "${funcname}"
	done
	set -u
}

# shellcheck disable=SC1091
source "${HOME}/.bashrc"
src_scripts || return 1
determine_pkg_mgr || return 1

# pkg_mgr initialized in determine_pkg_mgr
# shellcheck disable=SC2154
test "${PREFIX}" == '' && PREFIX="${IGN_DIR}/${pkg_mgr}_sysroot"

set_compile_opts || return 1
fb_running_as_script || print_cmds || return 1
set_completions || return 1
