#!/usr/bin/env bash

# shellcheck disable=SC2034

# ANSI colors
RED='\e[0;31m'
CYAN='\e[0;36m'
GREEN='\e[0;32m'
YELLOW='\e[0;33m'
NC='\e[0m'

# echo wrappers
echo_fail() { echo -e "${RED}FAIL${NC}:" "$@" ; }
echo_info() { echo -e "${CYAN}INFO${NC}:" "$@" ; }
echo_pass() { echo -e "${GREEN}PASS${NC}:" "$@" ; }
echo_warn() { echo -e "${YELLOW}WARN${NC}:" "$@" ; }
echo_exit() { echo_fail "$@" ; exit 1 ; }
void() { echo "$@" >/dev/null ; }

echo_if_fail() {
    local cmd=("$@")
    local out="${TMP_DIR}/.stdout-${RANDOM}"
    local err="${TMP_DIR}/.stderr-${RANDOM}"
    test -d "${TMP_DIR}" || mkdir -p "${TMP_DIR}"

    # set trace to the cmdEvalTrace and open file descriptor
    local cmdEvalTrace="${TMP_DIR}/.cmdEvalTrace-${RANDOM}"
    exec 5> "${cmdEvalTrace}"
    export BASH_XTRACEFD=5

    set -x
    "${cmd[@]}" >"${out}" 2>"${err}"
    local retval=$?

    # unset and close file descriptor
    set +x
    exec 5>&-
    
    # parse out relevant part of the trace
    local cmdEvalLines=()
    cmd=()
    while IFS= read -r line; do
        cmdEvalLines+=("${line}")
    done < "${cmdEvalTrace}"
    local cmdEvalLineNum=${#cmdEvalLines[@]}
    for ((i=1; i < cmdEvalLineNum-2; i++)); do
        local trimmedCmd="${cmdEvalLines[${i}]}"
        trimmedCmd="${trimmedCmd/+ /}"
        cmd+=("${trimmedCmd}")
    done

    if ! test ${retval} -eq 0; then
        echo
        echo_fail "command failed:" 
        printf "%s\n" "${cmd[@]}"
        echo_warn "command output:"
        tail -n 10 "${out}"
        tail -n 10 "${err}"
        echo
    fi
    rm "${out}" "${err}" "${cmdEvalTrace}"
    return ${retval}
}

dump_arr() {
    arr_name="$1"
    declare -n arr
    arr="${arr_name}"
    arr_exp=("${arr[@]}")
    test "${#arr_exp}" -gt 0 || return 0
    echo_info "${arr_name}"
    printf "\t%s\n" "${arr_exp[@]}"
}