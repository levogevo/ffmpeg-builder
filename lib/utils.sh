#!/usr/bin/env bash

# shellcheck disable=SC2034

# ANSI colors
RED='\e[0;31m'
CYAN='\e[0;36m'
GREEN='\e[0;32m'
YELLOW='\e[0;33m'
NC='\e[0m'

# echo wrappers
echo_fail() { echo -e "${RED}FAIL${NC}:" "$@"; }
echo_info() { echo -e "${CYAN}INFO${NC}:" "$@"; }
echo_pass() { echo -e "${GREEN}PASS${NC}:" "$@"; }
echo_warn() { echo -e "${YELLOW}WARN${NC}:" "$@"; }
echo_exit() {
	echo_fail "$@"
	exit 1
}
void() { echo "$@" >/dev/null; }

echo_if_fail() {
	local cmd=("$@")
	local logName="${LOGNAME:-${RANDOM}}"
	local out="${TMP_DIR}/.stdout-${logName}"
	local err="${TMP_DIR}/.stderr-${logName}"

	# set trace to the cmdEvalTrace and open file descriptor
	local cmdEvalTrace="${TMP_DIR}/.cmdEvalTrace-${logName}"
	test -d "${TMP_DIR}" || mkdir -p "${TMP_DIR}"
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
	cmd=()
	while IFS= read -r line; do
		cmdEvalLines+=("${line}")
	done <"${cmdEvalTrace}"
	local cmdEvalLineNum=${#cmdEvalLines[@]}
	for ((i = 1; i < cmdEvalLineNum - 2; i++)); do
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
	arr_name="$1"
	declare -n arr
	arr="${arr_name}"
	arr_exp=("${arr[@]}")
	test "${#arr_exp}" -gt 0 || return 0
	echo
	echo_info "${arr_name}"
	printf "\t%s\n" "${arr_exp[@]}"
}

has_cmd() {
	local cmd="$1"
	command -v "${cmd}" >/dev/null 2>&1
}

missing_cmd() {
	local cmd="$1"
	rv=1
	if ! has_cmd "${cmd}"; then
		echo_warn "missing ${cmd}"
		rv=0
	fi
	return $rv
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

is_darwin() {
	line_contains "$(print_os)" darwin
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
