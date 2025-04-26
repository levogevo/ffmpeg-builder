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

echo_if_fail() {
    local cmd=("$@")
    local out="/tmp/.stdout-${RANDOM}"
    local err="/tmp/.stderr-${RANDOM}"
    "${cmd[@]}" > ${out} 2> ${err}
    local retval=$?
    if ! test ${retval} -eq 0; then
        echo
        echo_fail "command [" "${cmd[@]}" "] failed"
        echo_warn "command output:"
        tail -n 10 ${out}
        tail -n 10 ${err}
        echo
    fi
    rm ${out} ${err}
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