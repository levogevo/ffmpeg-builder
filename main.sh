#!/usr/bin/env bash

# set top dir
if [[ -z ${REPO_DIR} ]]; then
	thisFile="${BASH_SOURCE[0]}"
	REPO_DIR="$(dirname "${thisFile}")"
fi

IGN_DIR="${REPO_DIR}/gitignore"
TMP_DIR="${IGN_DIR}/tmp"
DL_DIR="${IGN_DIR}/downloads"
BUILD_DIR="${IGN_DIR}/builds"
CCACHE_DIR="${IGN_DIR}/ccache"
DOCKER_DIR="${IGN_DIR}/docker"
PATCHES_DIR="${REPO_DIR}/patches"
export REPO_DIR IGN_DIR TMP_DIR DL_DIR BUILD_DIR CCACHE_DIR DOCKER_DIR PATCHES_DIR

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
export FB_RUNNING_AS_SCRIPT=1
thisFile="$(readlink -f "$0")"
export REPO_DIR="$(cd "$(dirname "${thisFile}")/.." && echo "$PWD")"
source "${REPO_DIR}/main.sh" || return 1
scr_name="$(bash_basename $0)"
cmd="${scr_name//.sh/}"
if [[ $DEBUG == 1 ]]; then set -x; fi
$cmd "$@"' >"${ENTRY_SCRIPT}"
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
check_compile_opts_override || return 1

if [[ $FB_RUNNING_AS_SCRIPT -eq 0 ]]; then
	print_cmds || return 1
fi
set_completions || return 1
