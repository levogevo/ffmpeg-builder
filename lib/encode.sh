#!/usr/bin/env bash

get_duration() {
	local file="$1"
	ffprobe \
		-v error \
		-show_entries format=duration \
		-of default=noprint_wrappers=1:nokey=1 \
		"${file}"
}

get_crop() {
	local file="$1"
	local duration
	duration="$(get_duration "${file}")" || return 1
	# don't care about decimal points
	IFS='.' read -r duration _ <<<"${duration}"
	# get crop value for first half of input
	local timeEnc=$((duration / 2))
	ffmpeg \
		-y \
		-hide_banner \
		-ss 0 \
		-discard 'nokey' \
		-i "${file}" \
		-t "${timeEnc}" \
		-map '0:v:0' \
		-filter:v:0 'cropdetect=limit=100:round=16:skip=2:reset_count=0' \
		-codec:v 'wrapped_avframe' \
		-f 'null' '/dev/null' 2>&1 |
		grep -o crop=.* |
		sort -bh |
		uniq -c |
		sort -bh |
		tail -n1 |
		grep -o "crop=.*"
}

get_stream_codec() {
	local file="$1"
	local stream="$2"
	ffprobe \
		-v error \
		-select_streams "${stream}" \
		-show_entries stream=codec_name \
		-of default=noprint_wrappers=1:nokey=1 \
		"${file}"
}

get_file_format() {
	local file="$1"
	local probe
	probe="$(ffprobe \
		-v error \
		-show_entries format=format_name \
		-of default=noprint_wrappers=1:nokey=1 \
		"${file}")" || return 1
	if line_contains "${probe}" 'matroska'; then
		echo mkv
	else
		echo mp4
	fi
}

get_num_streams() {
	local file="$1"
	ffprobe \
		-v error \
		-show_entries stream=index \
		-of default=noprint_wrappers=1:nokey=1 \
		"${file}"
}

get_num_audio_streams() {
	local file="$1"
	ffprobe \
		-v error \
		-select_streams a \
		-show_entries stream=index \
		-of default=noprint_wrappers=1:nokey=1 \
		"${file}"
}

get_num_audio_channels() {
	local file="$1"
	local stream="$2"
	ffprobe \
		-v error \
		-select_streams "${stream}" \
		-show_entries stream=channels \
		-of default=noprint_wrappers=1:nokey=1 \
		"${file}"
}

unmap_streams() {
	local file="$1"
	local unmapFilter='bin_data|jpeg|png'
	local unmap=()
	local streamsStr
	streamsStr="$(get_num_streams "${file}")" || return 1
	mapfile -t streams <<<"${streamsStr}" || return 1
	for stream in "${streams[@]}"; do
		if [[ "$(get_stream_codec "${file}" "${stream}")" =~ ${unmapFilter} ]]; then
			unmap+=("-map" "-0:${stream}")
		fi
	done
	echo "${unmap[@]}"
}

set_audio_bitrate() {
	local file="$1"
	local bitrate=()
	for stream in $(get_num_audio_streams "${file}"); do
		local numChannels codec
		numChannels="$(get_num_audio_channels "${file}" "${stream}")" || return 1
		local channelBitrate=$((numChannels * 64))
		codec="$(get_stream_codec "${file}" "a:${stream}")" || return 1
		if [[ ${codec} == 'opus' ]]; then
			bitrate+=(
				"-c:a:${stream}"
				"copy"
			)
		else
			bitrate+=(
				"-filter:a:${stream}"
				"aformat=channel_layouts=7.1|5.1|stereo|mono"
				"-c:a:${stream}"
				"libopus"
				"-b:a:${stream}"
				"${channelBitrate}k"
			)
		fi
	done
	echo "${bitrate[@]}"
}

convert_subs() {
	local file="$1"
	local convertCodec='eia_608'
	local convert=()
	for stream in $(get_num_streams "${file}"); do
		if [[ "$(get_stream_codec "${file}" "${stream}")" == "${convertCodec}" ]]; then
			convert+=("-c:${stream}" "srt")
		fi
	done
	echo "${convert[@]}"
}

encode_version() (
	cd "${REPO_DIR}" || exit 1
	echo "encode=$(git rev-parse --short HEAD)"
)

ffmpeg_version() {
	local output="$(ffmpeg 2>&1)"
	local commit=''
	local version=''
	while read -r line; do
		if line_contains "${line}" 'ffmpeg version'; then
			read -r _ _ commit _ <<<"${line}"
		fi
		if line_contains "${line}" 'ffmpeg='; then
			IFS='=' read -r _ version <<<"${line}"
		fi
	done <<<"${output}"
	echo "ffmpeg=${version}-${commit}"
}

video_enc_version() {
	local output="$(ffmpeg -hide_banner 2>&1)"
	while read -r line; do
		if line_contains "${line}" 'libsvtav1_psy='; then
			echo "${line}"
			break
		fi
	done <<<"${output}"
}

audio_enc_version() {
	local output="$(ffmpeg -hide_banner 2>&1)"
	while read -r line; do
		if line_contains "${line}" 'libopus='; then
			echo "${line}"
			break
		fi
	done <<<"${output}"
}

encode_usage() {
	echo "$(bash_basename "$0") -i input_file [options] "
	echo -e "\t[-P NUM] set preset (default: ${PRESET})"
	echo -e "\t[-C NUM] set CRF (default: ${CRF})"
	echo -e "\t[-p] print the command instead of executing it (default: ${PRINT_OUT})"
	echo -e "\t[-c] use cropdetect (default: ${CROP})"
	echo -e "\t[-d] disable dolby vision (default: ${DISABLE_DV})"
	echo -e "\t[-v] Print relevant version info"
	echo -e "\t[-g NUM] set film grain for encode"
	echo -e "\t[-s] use same container as input, default is mkv"
	echo -e "\n\t[output_file] if unset, defaults to ${HOME}/"
	echo -e "\n\t[-I] Install this as /usr/local/bin/encode"
	echo -e "\t[-U] Uninstall this from /usr/local/bin/encode"
	return 0
}

set_encode_opts() {
	local opts='vi:pcsdg:P:C:IU'
	local numOpts="${#opts}"
	# default values
	PRESET=3
	CRF=25
	GRAIN=""
	CROP='false'
	PRINT_OUT='false'
	DISABLE_DV='false'
	local SAME_CONTAINER="false"
	# only using -I/U
	local minOpt=1
	# using all + output name
	local maxOpt=$((numOpts + 1))
	test $# -lt ${minOpt} && echo_fail "not enough arguments" && encode_usage && return 1
	test $# -gt ${maxOpt} && echo_fail "too many arguments" && encode_usage && return 1
	local optsUsed=0
	while getopts "${opts}" flag; do
		case "${flag}" in
		I)
			echo_warn "attempting install"
			sudo ln -sf "${SCRIPT_DIR}/encode.sh" \
				/usr/local/bin/encode || return 1
			echo_pass "succesfull install"
			exit 0
			;;
		U)
			echo_warn "attempting uninstall"
			sudo rm /usr/local/bin/encode || return 1
			echo_pass "succesfull uninstall"
			exit 0
			;;
		v)
			encode_version
			ffmpeg_version
			video_enc_version
			audio_enc_version
			exit 0
			;;
		i)
			if [[ $# -lt 2 ]]; then
				echo_fail "wrong arguments given"
				encode_usage
				return 1
			fi
			INPUT="${OPTARG}"
			optsUsed=$((optsUsed + 2))
			;;
		p)
			PRINT_OUT='true'
			optsUsed=$((optsUsed + 1))
			;;
		c)
			CROP='true'
			optsUsed=$((optsUsed + 1))
			;;
		d)
			DISABLE_DV='enable'
			optsUsed=$((optsUsed + 1))
			;;
		s)
			SAME_CONTAINER='true'
			optsUsed=$((optsUsed + 1))
			;;
		g)
			if ! is_positive_integer "${OPTARG}"; then
				encode_usage
				return 1
			fi
			GRAIN="film-grain=${OPTARG}:film-grain-denoise=1:adaptive-film-grain=1:"
			optsUsed=$((optsUsed + 2))
			;;
		P)
			if ! is_positive_integer "${OPTARG}"; then
				encode_usage
				return 1
			fi
			PRESET="${OPTARG}"
			optsUsed=$((optsUsed + 2))
			;;
		C)
			if ! is_positive_integer "${OPTARG}" || test ${OPTARG} -gt 63; then
				echo_fail "${OPTARG} is not a valid CRF value (0-63)"
				usage
				exit 1
			fi
			CRF="${OPTARG}"
			OPTS_USED=$((OPTS_USED + 2))
			;;
		*)
			echo_fail "wrong flags given"
			encode_usage
			return 1
			;;
		esac
	done

	# allow optional output filename
	if [[ $(($# - optsUsed)) == 1 ]]; then
		OUTPUT="${*: -1}"
	else
		local basename="$(bash_basename "${INPUT}")"
		OUTPUT="${HOME}/av1-${basename}"
	fi

	# use same container for output
	if [[ $SAME_CONTAINER == "true" ]]; then
		local fileFormat
		fileFormat="$(get_file_format "${INPUT}")" || return 1
		FILE_EXT=''
		if [[ ${fileFormat} == 'MPEG-4' ]]; then
			FILE_EXT='mp4'
		elif [[ ${fileFormat} == 'Matroska' ]]; then
			FILE_EXT='mkv'
		else
			echo "unrecognized input format"
			return 1
		fi
	else
		FILE_EXT="mkv"
	fi
	OUTPUT="${OUTPUT%.*}"
	OUTPUT+=".${FILE_EXT}"

	echo
	echo_info "INPUT: ${INPUT}"
	echo_info "GRAIN: ${GRAIN}"
	echo_info "OUTPUT: ${OUTPUT}"
	echo
}

# shellcheck disable=SC2034
# shellcheck disable=SC2155
# shellcheck disable=SC2016
gen_encode_script() {
	test -d "${TMP_DIR}" || mkdir -p "${TMP_DIR}"
	local genScript="${TMP_DIR}/$(bash_basename "${OUTPUT}").sh"

	# single string params
	local params=(
		INPUT
		OUTPUT
		PRESET
		CRF
		crop
		videoEncoder
		ffmpegVersion
		videoEncVersion
		audioEncVersion
		svtAv1Params
		svtAv1ParamsMetadata
	)
	local crop=''
	if [[ $CROP == "true" ]]; then
		crop="$(get_crop "${INPUT}")" || return 1
	fi
	local videoEncoder='libsvtav1'
	local ffmpegVersion="$(ffmpeg_version)"
	local videoEncVersion="$(video_enc_version)"
	local audioEncVersion="$(audio_enc_version)"

	svtAv1ParamsArr=(
		"tune=0"
		"complex-hvs=1"
		"spy-rd=1"
		"psy-rd=1"
		"sharpness=3"
		"enable-overlays=1"
		"scd=1"
		"fast-decode=1"
		"enable-variance-boost=1"
		"enable-qm=1"
		"qm-min=4"
		"qm-max=15"
	)
	IFS=':'
	local svtAv1Params="${GRAIN}${svtAv1ParamsArr[*]}"
	unset IFS

	local svtAv1ParamsMetadata='svtav1_params=${svtAv1Params}'

	# arrays
	local arrays=(
		unmap
		audioBitrate
		videoParams
		videoParamsMetadata
		metadata
		convertSubs
		ffmpegParams
	)
	local videoParams=(
		"-crf" '${CRF}' "-preset" '${PRESET}' "-g" "240"
	)
	local ffmpegParams=(
		'-i' '${INPUT}'
		'-y' '-map' '0'
		'-c:s' 'copy'
	)

	# these values may be empty
	local unmapStr audioBitrateStr convertSubsStr
	unmapStr="$(unmap_streams "${INPUT}")" || return 1
	audioBitrateStr="$(set_audio_bitrate "${INPUT}")" || return 1
	convertSubsStr="$(convert_subs "${INPUT}")" || return 1

	unmap=(${unmapStr})
	if [[ ${unmap[*]} != '' ]]; then
		ffmpegParams+=('${unmap[@]}')
	fi

	audioBitrate=(${audioBitrateStr})
	if [[ ${audioBitrate[*]} != '' ]]; then
		ffmpegParams+=('${audioBitrate[@]}')
	fi

	convertSubs=(${convertSubsStr})
	if [[ ${convertSubs[*]} != '' ]]; then
		ffmpegParams+=('${convertSubs[@]}')
	fi

	if [[ ${crop} != '' ]]; then
		ffmpegParams+=('-vf' '${crop}')
	fi

	ffmpegParams+=(
		'-pix_fmt' 'yuv420p10le' '-c:V' '${videoEncoder}' '${videoParams[@]}'
		'-svtav1-params' '${svtAv1Params}'
		'${metadata[@]}'
	)

	local videoParamsMetadata='video_params=${videoParams[*]}'
	local metadata=(
		'-metadata' '${ffmpegVersion}'
		'-metadata' '${videoEncVersion}'
		'-metadata' '${audioEncVersion}'
		'-metadata' '${svtAv1ParamsMetadata}'
		'-metadata' '${videoParamsMetadata[@]}'
	)

	{
		echo '#!/usr/bin/env bash'
		echo

		# add normal params
		for param in "${params[@]}"; do
			declare -n value="${param}"
			if [[ ${value} != '' ]]; then
				echo "${param}=\"${value[*]}\""
			fi
		done
		for arrName in "${arrays[@]}"; do
			declare -n arr="${arrName}"
			if [[ -v arr ]]; then
				echo "${arrName}=("
				printf '\t"%s"\n' "${arr[@]}"
				echo ')'
			fi
		done

		# actually do ffmpeg commmand
		echo
		if [[ ${DISABLE_DV} == 'false' ]]; then
			echo 'ffmpeg "${ffmpegParams[@]}" -dolbyvision 1 "${OUTPUT}" || \'
		fi
		echo 'ffmpeg "${ffmpegParams[@]}" -dolbyvision 0 "${OUTPUT}" || exit 1'

		# track-stats and clear title
		if [[ ${FILE_EXT} == 'mkv' ]]; then
			{
				echo
				echo "mkvpropedit \"${OUTPUT}\" --add-track-statistics-tags"
				echo "mkvpropedit \"${OUTPUT}\" --edit info --set \"title=\""
			}
		fi

		echo
	} >"${genScript}"

	if [[ ${PRINT_OUT} == 'true' ]]; then
		echo_info "${genScript} contents:"
		echo "$(<"${genScript}")"
	else
		bash -x "${genScript}" || return 1
		rm "${genScript}"
	fi
}

FB_FUNC_NAMES+=('encode')
# shellcheck disable=SC2034
FB_FUNC_DESCS['encode']='encode a file using libsvtav1_psy and libopus'
encode() {
	set_encode_opts "$@" || return 1
	gen_encode_script || return 1
}
