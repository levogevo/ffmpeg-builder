#!/usr/bin/env bash

efg_usage() {
	echo "efg -i input [options]"
	echo -e "\t[-l NUM] low value (default: ${LOW})"
	echo -e "\t[-s NUM] step value (default: ${STEP})"
	echo -e "\t[-h NUM] high value (default: ${HIGH})"
	echo -e "\t[-p] plot bitrates using gnuplot"
	echo -e "\n\t[-I] system install at ${EFG_INSTALL_PATH}"
	echo -e "\t[-U] uninstall from ${EFG_INSTALL_PATH}"
	return 0
}

set_efg_opts() {
	local opts='pl:s:h:i:IU'
	local numOpts=${#opts}
	# default values
	unset INPUT
	LOW=0
	STEP=1
	HIGH=30
	PLOT=false
	EFG_INSTALL_PATH='/usr/local/bin/efg'
	# only using -I or -U
	local minOpt=1
	# using all
	local maxOpt=${numOpts}
	test $# -lt ${minOpt} && echo_fail "not enough arguments" && efg_usage && return 1
	test $# -gt ${maxOpt} && echo_fail "too many arguments" && efg_usage && return 1
	local OPTARG OPTIND
	while getopts "${opts}" flag; do
		case "${flag}" in
		I)
			echo_warn "attempting install"
			sudo ln -sf "${SCRIPT_DIR}/efg.sh" \
				"${EFG_INSTALL_PATH}" || return 1
			echo_pass "succesfull install"
			exit 0
			;;
		U)
			echo_warn "attempting uninstall"
			sudo rm "${EFG_INSTALL_PATH}" || return 1
			echo_pass "succesfull uninstall"
			exit 0
			;;
		i)
			if [[ $# -lt 2 ]]; then
				echo_fail "wrong arguments given"
				efg_usage
				return 1
			fi
			INPUT="${OPTARG}"
			;;
		p)
			PLOT=true
			;;
		l)
			if ! is_positive_integer "${OPTARG}"; then
				efg_usage
				return 1
			fi
			LOW="${OPTARG}"
			;;
		s)
			if ! is_positive_integer "${OPTARG}"; then
				efg_usage
				return 1
			fi
			STEP="${OPTARG}"
			;;
		h)
			if ! is_positive_integer "${OPTARG}"; then
				efg_usage
				return 1
			fi
			HIGH="${OPTARG}"
			;;
		*)
			echo "wrong flags given"
			efg_usage
			return 1
			;;
		esac
	done

	if [[ ! -f ${INPUT} ]]; then
		echo "${INPUT} does not exist"
		efg_usage
		return 1
	fi

	# set custom EFG_DIR based off of sanitized inputfile
	local sanitizedInput="$(bash_basename "${INPUT}")"
	local sanitizeChars=(' ' '@' ':')
	for char in "${sanitizeChars[@]}"; do
		sanitizedInput="${sanitizedInput//${char}/}"
	done
	EFG_DIR+="-${sanitizedInput}"

	echo_info "estimating film grain for ${INPUT}"
	echo_info "range: $LOW-$HIGH with $STEP step increments"
}

efg_segment() {
	# number of segments to split video
	local segments=30
	# duration of each segment
	local segmentTime=3

	# get times to split the input based
	# off of number of segments
	local duration
	duration="$(get_duration "${INPUT}")" || return 1
	# trim decimal points if any
	IFS=. read -r duration _ <<<"${duration}"
	# number of seconds that equal 1 percent of the video
	local percentTime=$((duration / 100))
	# percent that each segment takes
	local percentSegment=$((100 / segments))
	# number of seconds to increment between segments
	local timeBetweenSegments=$((percentTime * percentSegment))
	if [[ ${timeBetweenSegments} -lt ${segmentTime} ]]; then
		timeBetweenSegments=${segmentTime}
	fi
	local segmentBitrates=()

	# clean workspace
	test -d "${EFG_DIR}" && rm -rf "${EFG_DIR}"
	mkdir -p "${EFG_DIR}"

	# split up video into segments based on start times
	for ((time = 0; time < duration; time += timeBetweenSegments)); do
		local outSegment="${EFG_DIR}/segment-${#segmentBitrates[@]}.mkv"
		split_video "${INPUT}" "${time}" "${segmentTime}" "${outSegment}" || return 1
		local segmentBitrate
		segmentBitrate="$(get_avg_bitrate "${outSegment}")" || return 1
		segmentBitrates+=("${segmentBitrate}:${outSegment}")
	done
	local numSegments="${#segmentBitrates[@]}"

	local removeSegments
	if [[ ${numSegments} -lt ${ENCODE_SEGMENTS} ]]; then
		removeSegments=0
	else
		removeSegments=$((numSegments - ENCODE_SEGMENTS))
	fi

	# sort the segments
	mapfile -t sortedSegments < <(IFS=: bash_sort "${segmentBitrates[@]}")
	# make sure bitrate for each file is actually increasing
	local prevBitrate=0
	# remove all but the highest bitrate segments
	for segment in "${sortedSegments[@]}"; do
		test ${removeSegments} -eq 0 && break
		local file currBitrate
		IFS=: read -r _ file <<<"${segment}"
		currBitrate="$(get_avg_bitrate "${file}")" || return 1

		if [[ ${currBitrate} -lt ${prevBitrate} ]]; then
			echo_fail "${file} is not a higher bitrate than previous"
			return 1
		fi
		prevBitrate=${currBitrate}

		rm "${file}" || return 1
		removeSegments=$((removeSegments - 1))
	done

}

efg_encode() {
	echo -n >"${GRAIN_LOG}"
	for vid in "${EFG_DIR}/"*.mkv; do
		echo "file: ${vid}" >>"${GRAIN_LOG}"
		for ((grain = LOW; grain <= HIGH; grain += STEP)); do
			local file="$(bash_basename "${vid}")"
			local out="${EFG_DIR}/grain-${grain}-${file}"
			echo_info "encoding ${file} with grain ${grain}"
			echo_if_fail encode -P 10 -g ${grain} -i "${vid}" "${out}"
			echo -e "\tgrain: ${grain}, bitrate: $(get_avg_bitrate "${out}")" >>"${GRAIN_LOG}"
			rm "${out}"
		done
	done

	less "${GRAIN_LOG}"
}

efg_plot() {
	declare -A normalizedBitrateSums=()
	local referenceBitrate=''
	local setNewReference=''

	while read -r line; do
		local noWhite="${line// /}"
		# new file, reset logic
		if line_starts_with "${noWhite}" 'file:'; then
			setNewReference=true
			continue
		fi

		IFS=',' read -r grainText bitrateText <<<"${noWhite}"
		IFS=':' read -r _ grain <<<"${grainText}"
		IFS=':' read -r _ bitrate <<<"${bitrateText}"
		if [[ ${setNewReference} == true ]]; then
			referenceBitrate="${bitrate}"
			setNewReference=false
		fi
		# bash doesn't support floats, so scale up by 10000
		local normBitrate=$((bitrate * 10000 / referenceBitrate))
		local currSumBitrate=${normalizedBitrateSums[${grain}]}
		normalizedBitrateSums[${grain}]=$((normBitrate + currSumBitrate))
		setNewReference=false
	done <"${GRAIN_LOG}"

	# create grain:average plot file
	local plotFile="${EFG_DIR}/plot.dat"
	echo -n >"${plotFile}"
	for ((grain = LOW; grain <= HIGH; grain += STEP)); do
		local sum=${normalizedBitrateSums[${grain}]}
		local avg=$((sum / ENCODE_SEGMENTS))
		echo -e "${grain}\t${avg}" >>"${plotFile}"
	done

	# plot data
	# run subprocess for bash COLUMNS/LINES
	shopt -s checkwinsize
	(true)
	gnuplot -p -e "\
set terminal dumb size ${COLUMNS}, ${LINES}; \
set autoscale; \
set style line 1 \
linecolor rgb '#0060ad' \
linetype 1 linewidth 2 \
pointtype 7 pointsize 1.5; \
plot \"${plotFile}\" with linespoints linestyle 1" | less
	echo_info "grain log: ${GRAIN_LOG}"
}

FB_FUNC_NAMES+=('efg')
# shellcheck disable=SC2034
FB_FUNC_DESCS['efg']='estimate the film grain of a given file'
efg() {
	EFG_DIR="${TMP_DIR}/efg"
	# encode N highest-bitrate segments
	ENCODE_SEGMENTS=5

	set_efg_opts "$@" || return 1
	test -d "${EFG_DIR}" || mkdir "${EFG_DIR}"

	GRAIN_LOG="${EFG_DIR}/${LOW}-${STEP}-${HIGH}-grains.txt"

	if [[ ${PLOT} == true && -f ${GRAIN_LOG} ]]; then
		efg_plot
		return $?
	fi

	efg_segment || return 1
	efg_encode || return 1

	if [[ ${PLOT} == true && -f ${GRAIN_LOG} ]]; then
		efg_plot || return 1
	fi
}
