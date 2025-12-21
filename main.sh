#!/usr/bin/env bash

# set top dir
if [[ -z ${REPO_DIR} ]]; then
	thisFile="$(readlink -f "${BASH_SOURCE[0]}")"
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

# some functions need a way to signal early
# returns instead of failures, so if a function
# returns ${FUNC_EXIT_SUCCESS}, stop processing
test -v FUNC_EXIT_SUCCESS || readonly FUNC_EXIT_SUCCESS=9

# make paths if needed
IGN_DIRS=(
	"${TMP_DIR}"
	"${DL_DIR}"
	"${BUILD_DIR}"
	"${CCACHE_DIR}"
	"${DOCKER_DIR}"
)
for dir in "${IGN_DIRS[@]}"; do
	test -d "${dir}" || mkdir -p "${dir}"
done
unset IGN_DIRS

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
source "${REPO_DIR}/main.sh" || exit 1
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
	echo -e "~~~ Usable Commands ~~~\n"
	for funcName in "${FB_FUNC_NAMES[@]}"; do
		color="${CYAN}" word="${funcName}:" echo_wrapper "\n\t${FB_FUNC_DESCS[${funcName}]}"
		if [[ $FB_RUNNING_AS_SCRIPT -eq 0 ]]; then
			(cd "$SCRIPT_DIR" && ln -sf entry.sh "${funcName}.sh")
		fi
	done
	echo -e "\n"
}

set_completions() {
	for funcName in "${FB_FUNC_NAMES[@]}"; do
		complete -W "${FB_FUNC_COMPLETION[${funcName}]}" "${funcName}"
	done
}

src_scripts || return 1
determine_pkg_mgr || return 1
check_compile_opts_override || return 1

# set local prefix since some functions need it
# as opposed to user-defined PREFIX
LOCAL_PREFIX="${IGN_DIR}/$(print_os)_sysroot"

if [[ ${FB_RUNNING_AS_SCRIPT} -eq 0 ]]; then
	print_cmds || return 1
fi
set_completions || return 1
