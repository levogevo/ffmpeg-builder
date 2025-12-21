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

echo_if_fail() {
	local cmd=("$@")
	local logName="${LOGNAME:-${RANDOM}}-"
	local out="${TMP_DIR}/${logName}stdout"
	local err="${TMP_DIR}/${logName}stderr"

	# set trace to the cmdEvalTrace and open file descriptor
	local cmdEvalTrace="${TMP_DIR}/${logName}cmdEvalTrace"
	exec 5>"${cmdEvalTrace}"
	export BASH_XTRACEFD=5

	set -x
	"${cmd[@]}" >"${out}" 2>"${err}"
	local retval=$?

	# unset and close file descriptor
	set +x
	exec 5>&-

	# parse out relevant part of the trace
	local cmdEvalLines=()
	while IFS= read -r line; do
		line="${line/${PS4}/}"
		test "${line}" == 'set +x' && continue
		test "${line}" == '' && continue
		cmdEvalLines+=("${line}")
	done <"${cmdEvalTrace}"

	if ! test ${retval} -eq 0; then
		echo
		echo_fail "command failed:"
		printf "%s\n" "${cmdEvalLines[@]}"
		echo_warn "command stdout:"
		tail -n 32 "${out}"
		echo_warn "command stderr:"
		tail -n 32 "${err}"
		echo
	fi
	if [[ -z ${LOGNAME} ]]; then
		rm "${out}" "${err}" "${cmdEvalTrace}"
	fi
	return ${retval}
}

is_root_owned() {
	local path=$1
	local uid

	if stat --version >/dev/null 2>&1; then
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
		command -v "${cmd}" >/dev/null 2>&1 || rv=1
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

replace_line() {
	local file="$1"
	local search="$2"
	local newLine="$3"
	local newFile="${TMP_DIR}/$(bash_basename "${file}")"

	test -f "${newFile}" && rm "${newFile}"
	while read -r line; do
		if line_contains "${line}" "${search}"; then
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
	local spinChars=(
		"-"
		'\'
		"|"
		"/"
	)

	sleep 1

	while true; do
		for ((ind = 0; ind < "${#spinChars[@]}"; ind++)); do
			echo -ne "${spinChars[${ind}]}" '\b\b'
			sleep .25
		done
	done
}

spinner() {
	local action="$1"
	local spinPidFile="${TMP_DIR}/.spinner-pid"
	case "${action}" in
	start)
		test -f "${spinPidFile}" && rm "${spinPidFile}"

		# don't want to clutter logs if running headless
		test "${HEADLESS}" == '1' && return

		_start_spinner &
		echo $! >"${spinPidFile}"
		;;
	stop)
		test -f "${spinPidFile}" && kill "$(<"${spinPidFile}")"
		echo -ne ' \n'
		;;
	esac
}

get_pkgconfig_version() {
	local pkg="$1"
	pkg-config --modversion "${pkg}"
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
