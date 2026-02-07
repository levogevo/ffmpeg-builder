#!/usr/bin/env bash

# shellcheck disable=SC2034

# ANSI colors
RED='\e[0;31m'
CYAN='\e[0;36m'
GREEN='\e[0;32m'
YELLOW='\e[0;33m'
NC='\e[0m'

# echo wrappers
echo_wrapper() {
    local args
    if [[ $1 == '-n' ]]; then
        args=("$1")
        shift
    fi
    # COLOR is override for using ${color}
    # shellcheck disable=SC2153
    if [[ ${COLOR} == 'OFF' ]]; then
        color=''
        endColor=''
    else
        endColor="${NC}"
    fi

    echo -e "${args[@]}" "${color}${word:-''}${endColor}" "$@"
}
echo_fail() { color="${RED}" word="FAIL" echo_wrapper "$@"; }
echo_info() { color="${CYAN}" word="INFO" echo_wrapper "$@"; }
echo_pass() { color="${GREEN}" word="PASS" echo_wrapper "$@"; }
echo_warn() { color="${YELLOW}" word="WARN" echo_wrapper "$@"; }
echo_exit() {
    echo_fail "$@"
    exit 1
}
void() { echo "$@" >/dev/null; }

trace_cmd_to_file() {
    local cmd=("$@")
    test -n "${OUT}" && test -n "${ERR}" && test -n "${TRACE}" || return 1
    local out="${OUT}"
    local err="${ERR}"
    local trace="${TRACE}"
    local fd=6

    # get current trace status
    local set
    if [[ $- == *x* ]]; then
        set='-x'
    else
        set='+x'
    fi

    # stop tracing before new trace file
    set +x

    # set trace to the cmdEvalTrace and open file descriptor
    eval "exec ${fd}>\"${trace}\""
    export BASH_XTRACEFD=${fd}

    set -x
    "${cmd[@]}" >"${out}" 2>"${err}"
    local retval=$?

    # unset and close file descriptor
    # unset BASH_XTRACEFD first
    set +x
    unset BASH_XTRACEFD
    eval "exec ${fd}>&-"

    # reset previous state
    set ${set}

    return ${retval}
}

echo_if_fail() {
    local cmd=("$@")
    local logName="${LOGNAME:-${RANDOM}}-"
    local out="${TMP_DIR}/${logName}stdout"
    local err="${TMP_DIR}/${logName}stderr"
    local trace="${TMP_DIR}/${logName}trace"

    OUT="${out}" ERR="${err}" TRACE="${trace}" trace_cmd_to_file \
        "${cmd[@]}"
    local retval=$?

    # parse out relevant part of the trace
    local cmdEvalLines=()
    while IFS= read -r line; do
        line="${line/${PS4}/}"
        test "${line}" == 'set +x' && continue
        test "${line}" == '' && continue
        cmdEvalLines+=("${line}")
    done <"${trace}"

    if ! test ${retval} -eq 0; then
        echo
        echo_fail "command failed with ${retval}:"
        printf "%s\n" "${cmdEvalLines[@]}"
        echo_warn "command stdout:"
        tail -n 32 "${out}"
        echo_warn "command stderr:"
        tail -n 32 "${err}"
        echo
    fi
    if [[ -z ${LOGNAME} ]]; then
        rm "${out}" "${err}" "${trace}"
    fi
    return ${retval}
}

is_root_owned() {
    local path=$1
    local uid

    if stat --version &>/dev/null; then
        # GNU coreutils (Linux)
        uid=$(stat -c '%u' "$path")
    else
        # BSD/macOS
        uid=$(stat -f '%u' "$path")
    fi

    test "$uid" -eq 0
}

dump_arr() {
    local arrayNames=("$@")
    for arrayName in "${arrayNames[@]}"; do
        declare -n array="${arrayName}"
        arrayExpanded=("${array[@]}")

        # skip showing single element arrays by default
        if [[ ! ${#arrayExpanded[@]} -gt 1 ]]; then
            if [[ ${SHOW_SINGLE} == true ]]; then
                echo_info "${arrayName}='${arrayExpanded[*]}'"
            else
                continue
            fi
        fi

        echo
        # don't care that the variable has "ARR"
        echo_info "${arrayName//"_ARR"/}"
        printf "\t%s\n" "${arrayExpanded[@]}"
    done
}

has_cmd() {
    local cmds=("$@")
    local rv=0
    for cmd in "${cmds[@]}"; do
        command -v "${cmd}" &>/dev/null || rv=1
    done

    return ${rv}
}

missing_cmd() {
    local cmds=("$@")
    local rv=1
    for cmd in "${cmds[@]}"; do
        if ! has_cmd "${cmd}"; then
            echo_warn "missing ${cmd}"
            rv=0
        fi
    done

    return ${rv}
}

bash_dirname() {
    local tmp=${1:-.}

    [[ $tmp != *[!/]* ]] && {
        printf '/\n'
        return
    }

    tmp=${tmp%%"${tmp##*[!/]}"}

    [[ $tmp != */* ]] && {
        printf '.\n'
        return
    }

    tmp=${tmp%/*}
    tmp=${tmp%%"${tmp##*[!/]}"}

    printf '%s\n' "${tmp:-/}"
}

bash_basename() {
    local tmp
    path="$1"
    suffix="${2:-''}"

    tmp=${path%"${path##*[!/]}"}
    tmp=${tmp##*/}
    tmp=${tmp%"${suffix/"$tmp"/}"}

    printf '%s\n' "${tmp:-/}"
}

bash_realpath() {
    local file=$1
    local dir

    # If the file is already absolute
    [[ $file == /* ]] && {
        printf '%s\n' "$file"
        return
    }

    # Otherwise: split into directory + basename
    dir="$(bash_dirname "${file}")"
    file="$(bash_basename "${file}")"

    # If no directory component, use current directory
    if [[ $dir == "$file" ]]; then
        dir="$PWD"
    else
        # Save current dir, move into target dir, capture $PWD, then return
        local oldpwd="$PWD"
        cd "$dir" || return 1
        dir="$PWD"
        cd "$oldpwd" || return 1
    fi

    printf '%s/%s\n' "$dir" "$file"
}

line_contains() {
    local line="$1"
    local substr="$2"
    if [[ $line == *"${substr}"* ]]; then
        return 0
    else
        return 1
    fi
}

line_starts_with() {
    local line="$1"
    local substr="$2"
    if [[ $line == "${substr}"* ]]; then
        return 0
    else
        return 1
    fi
}

is_linux() {
    line_contains "${OSTYPE}" 'linux'
}

is_darwin() {
    line_contains "$(print_os)" darwin
}

is_windows() {
    line_contains "$(print_os)" windows
}

is_android() {
    line_contains "$(print_os)" android
}

print_os() {
    # cached response
    if [[ -n ${FB_OS} ]]; then
        echo "${FB_OS}"
        return 0
    fi

    unset FB_OS
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        FB_OS="${ID}"
        if [[ ${VERSION_ID} != '' ]]; then
            FB_OS+="-${VERSION_ID}"
        fi
        if line_starts_with "${FB_OS}" 'arch'; then
            FB_OS='archlinux'
        fi
    else
        FB_OS="$(uname -o)"
    fi

    # lowercase
    FB_OS="${FB_OS,,}"

    # special treatment for windows
    if line_contains "${FB_OS}" 'windows' || line_contains "${FB_OS}" 'msys'; then
        FB_OS='windows'
    fi

    echo "${FB_OS}"
}

is_positive_integer() {
    local input="$1"
    if [[ ${input} != ?(-)+([[:digit:]]) || ${input} -lt 0 ]]; then
        echo_fail "${input} is not a positive integer"
        return 1
    fi
    return 0
}

print_line_indent() {
    local line="$1"
    if [[ ${line} =~ ^( +) ]]; then
        echo -n "${BASH_REMATCH[1]}"
    fi
}

replace_line() {
    local file="$1"
    local search="$2"
    local newLine="$3"
    local newFile="${TMP_DIR}/$(bash_basename "${file}")"

    test -f "${newFile}" && rm "${newFile}"
    while IFS= read -r line; do
        if line_contains "${line}" "${search}"; then
            print_line_indent "${line}" >>"${newFile}"
            echo -en "${newLine}" >>"${newFile}"
            continue
        fi
        echo "${line}" >>"${newFile}"
    done <"${file}"

    cp "${newFile}" "${file}"
}

remove_line() {
    local file="$1"
    local search="$2"
    replace_line "${file}" "${search}" ''
}

bash_sort() {
    local arr=("$@")
    local n=${#arr[@]}
    local i j val1 val2

    # Bubble sort, numeric comparison
    for ((i = 0; i < n; i++)); do
        for ((j = 0; j < n - i - 1; j++)); do
            read -r val1 _ <<<"${arr[j]}"
            read -r val2 _ <<<"${arr[j + 1]}"
            if (("${val1}" > "${val2}")); then
                local tmp=${arr[j]}
                arr[j]=${arr[j + 1]}
                arr[j + 1]=$tmp
            fi
        done
    done

    printf '%s\n' "${arr[@]}"
}

_start_spinner() {
    local spinChars=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")

    sleep 1

    while true; do
        for ((ind = 0; ind < "${#spinChars[@]}"; ind++)); do
            echo -ne "${spinChars[${ind}]}" '\b\b'
            sleep .125
        done
    done
}

spinner() {
    local action="$1"
    local spinPidFile="${TMP_DIR}/.spinner-pid"
    case "${action}" in
    start)
        # if there is already a pidfile, we're spinning
        test -f "${spinPidFile}" && return

        # don't want to clutter logs if running headless
        test "${HEADLESS}" == '1' && return

        _start_spinner &
        echo $! >"${spinPidFile}"
        ;;
    stop)
        if [[ -f ${spinPidFile} ]]; then
            local pid="$(<"${spinPidFile}")"
            kill -0 "${pid}" &>/dev/null && kill "${pid}"
            rm "${spinPidFile}"
        fi
        echo -ne ' \n'
        ;;
    esac
}

get_pkgconfig_version() {
    local pkg="$1"
    pkg-config --modversion "${pkg}"
}

using_cmake_4() {
    local cmakeVersion
    IFS=$' \t' read -r _ _ cmakeVersion <<<"$(command cmake --version)"
    line_starts_with "${cmakeVersion}" 4
}

have_req_meson_version() {
    local min=1.6.1
    have_required_version "$(meson --version)" "${min}"
}

have_required_version() {
    local have="$1"
    local min="$2"
    local hMaj hMin hPatch mMaj mMin mPatch
    IFS=. read -r hMaj hMin hPatch <<<"${have}"
    IFS=. read -r mMaj mMin mPatch <<<"${min}"
    test "${hMaj}" -ge "${mMaj}" &&
        test "${hMin}" -ge "${mMin}" &&
        test "${hPatch}" -ge "${mPatch}"
}

recreate_dir() {
    local dirs=("$@")
    for dir in "${dirs[@]}"; do
        test -d "${dir}" && rm -rf "${dir}"
        mkdir -p "${dir}" || return 1
    done
}

ensure_dir() {
    local dirs=("$@")
    for dir in "${dirs[@]}"; do
        test -d "${dir}" || mkdir -p "${dir}" || return 1
    done
}

get_date() {
    printf '%(%Y-%m-%d)T\n' -1
}

get_remote_head() {
    local url="$1"
    # ${build} is magically populated from get_build_conf
    local remoteCommitFile="${TMP_DIR}/${build}-remote-head.txt"
    local date="$(get_date)"
    # want to cache the remote head for faster retrieval
    # and only get it once per day
    local remoteHEAD
    if [[ -f ${remoteCommitFile} ]]; then
        IFS=' ' read -r prevDate prevBuild prevCommit <"${remoteCommitFile}"
    fi

    if [[ "${date}:${build}" == "${prevDate}:${prevBuild}" ]]; then
        remoteHEAD="${prevCommit}"
    else
        IFS=$' \t' read -r remoteHEAD _ <<< \
            "$(git ls-remote "${url}" HEAD)"
        echo "${date} ${build} ${remoteHEAD}" >"${remoteCommitFile}"
    fi
    echo "${remoteHEAD}"
}

fb_max() {
    local a="$1"
    local b="$2"
    test "${a}" -gt "${b}" &&
        echo "${a}" ||
        echo "${b}"
}

print_padded() {
    local str="$1"
    local padding="$2"
    echo -n "${str}"
    for ((i = 0; i < padding - ${#str}; i++)); do
        echo -n ' '
    done
}

benchmark_command() {
    local cmd=("$@")
    local out='/dev/null'
    local err='/dev/null'
    local trace="${TMP_DIR}/benchmark-trace.txt"

    # note this marker around the awk parsing
    local traceMarker='TRACEOUTPUT ; '

    echo_warn "tracing ${cmd[*]}"
    PS4='$EPOCHREALTIME TRACEOUTPUT ; ' OUT="${out}" ERR="${err}" TRACE="${trace}" trace_cmd_to_file \
        "${cmd[@]}" || return 1
    echo_pass "done tracing ${cmd[*]}"

    awk '
    BEGIN { 
        # Use a regex for the marker to handle leading/trailing whitespace cleanly
        marker = "TRACEOUTPUT ; " 
    }
    
    # Match lines starting with a timestamp followed by the marker
    $0 ~ /^[0-9.]+[ ]+TRACEOUTPUT ; / {
        # 1. Calculate duration for the PREVIOUS command now that we have a new timestamp
        if (prev_time != "") {
            duration = $1 - prev_time
            # Output for the system sort: [duration] | [command]
            printf "%012.6f | %s\n", duration, prev_cmd
        }
        
        # 2. Start tracking the NEW command
        prev_time = $1
        
        # Extract everything after "TRACEOUTPUT ; "
        # match() finds the position, substr() grabs the rest
        match($0, /TRACEOUTPUT ; /)
        prev_cmd = substr($0, RSTART + RLENGTH)
        next
    }

    # If the line does not match the timestamp pattern, it is a newline in a variable
    {
        if (prev_time != "") {
            prev_cmd = prev_cmd "\n" $0
        }
    }
    ' "${trace}" | sort -rn | head -n 20
}
