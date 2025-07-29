#!/usr/bin/env bash

# set top dir
relativeRepoRoot="${BASH_SOURCE[0]//'main.sh'/}"
if [[ -d ${relativeRepoRoot} ]]; then
	preloadCmd="cd ${relativeRepoRoot} &&"
fi
REPO_DIR="$(${preloadCmd} echo "$PWD")"
unset relativeRepoRoot preloadCmd

IGN_DIR="${REPO_DIR}/gitignore"
TMP_DIR="${IGN_DIR}/tmp"
DL_DIR="${IGN_DIR}/downloads"
BUILD_DIR="${IGN_DIR}/builds"
CCACHE_DIR="${IGN_DIR}/ccache"
export REPO_DIR IGN_DIR TMP_DIR DL_DIR BUILD_DIR CCACHE_DIR

# function names, descriptions, completions
unset FB_FUNC_NAMES FB_FUNC_DESCS FB_FUNC_COMPLETION
FB_FUNC_NAMES=()
declare -A FB_FUNC_DESCS FB_FUNC_COMPLETION

# can't have recursive generation
FB_RUNNING_AS_SCRIPT=${FB_RUNNING_AS_SCRIPT:-0}

# shellcheck disable=SC2034
FB_COMPILE_OPTS_SET=0

SCRIPT_DIR="${REPO_DIR}/scripts"
ENTRY_SCRIPT="${SCRIPT_DIR}/entry.sh"
src_scripts() {
	local SCRIPT_DIR="${REPO_DIR}/scripts"

	if [[ $FB_RUNNING_AS_SCRIPT -eq 0 ]]; then
		rm "${SCRIPT_DIR}"/*.sh
		# shellcheck disable=SC2016
		echo '#!/usr/bin/env bash
cd "$(dirname "$(readlink -f $0)")/.."
export FB_RUNNING_AS_SCRIPT=1
. main.sh
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
		if [[ $FB_RUNNING_AS_SCRIPT -eq 0 ]]; then
			(cd "$SCRIPT_DIR" && ln -sf entry.sh "${funcname}.sh")
		fi
	done
	echo -e "~~~~~~~~~~~~~~~~~~~~~~~\n"
}

set_completions() {
	for funcname in "${FB_FUNC_NAMES[@]}"; do
		complete -W "${FB_FUNC_COMPLETION[${funcname}]}" "${funcname}"
	done
}

# shellcheck disable=SC1091
test -f "${HOME}/.bashrc" && source "${HOME}/.bashrc"
src_scripts || return 1
determine_pkg_mgr || return 1

# pkg_mgr initialized in determine_pkg_mgr
# shellcheck disable=SC2154
test "${PREFIX}" == '' && PREFIX="${IGN_DIR}/${pkg_mgr}_sysroot"

if [[ $FB_RUNNING_AS_SCRIPT -eq 0 ]]; then
	print_cmds || return 1
fi
set_completions || return 1
