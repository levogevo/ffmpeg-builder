#!/usr/bin/env bash

# sets unmapStreams
set_unmap_streams() {
	local file="$1"
	local unmapFilter='bin_data|jpeg|png'
	local streamsStr
	unmapStreams=()
	streamsStr="$(get_num_streams "${file}")" || return 1
	mapfile -t streams <<<"${streamsStr}" || return 1
	for stream in "${streams[@]}"; do
		if [[ "$(get_stream_codec "${file}" "${stream}")" =~ ${unmapFilter} ]]; then
			unmapStreams+=("-map" "-0:${stream}")
		fi
	done
}

# sets audioParams
set_audio_params() {
	local file="$1"
	local videoLang
	audioParams=()
	videoLang="$(get_stream_lang "${file}" 'v:0')" || return 1
	for stream in $(get_num_streams "${file}" 'a'); do
		local numChannels codec lang
		numChannels="$(get_num_audio_channels "${file}" "${stream}")" || return 1
		if [[ ${numChannels} == '' ]]; then
			echo_fail "could not obtain channel count for stream ${stream}"
			return 1
		fi
		local channelBitrate=$((numChannels * 64))
		codec="$(get_stream_codec "${file}" "${stream}")" || return 1
		lang="$(get_stream_lang "${file}" "${stream}")" || return 1
		if [[ ${videoLang} != '' && ${videoLang} != "${lang}" ]]; then
			audioParams+=(
				'-map'
				"-0:${stream}"
			)
		elif [[ ${codec} == 'opus' ]]; then
			audioParams+=(
				"-c:${OUTPUT_INDEX}"
				"copy"
			)
			OUTPUT_INDEX=$((OUTPUT_INDEX + 1))
		else
			audioParams+=(
				"-filter:${OUTPUT_INDEX}"
				"aformat=channel_layouts=7.1|5.1|stereo|mono"
				"-c:${OUTPUT_INDEX}"
				"libopus"
				"-b:${OUTPUT_INDEX}"
				"${channelBitrate}k"
			)
			OUTPUT_INDEX=$((OUTPUT_INDEX + 1))
		fi
	done
}

# sets subtitleParams
set_subtitle_params() {
	local file="$1"
	local convertCodec='eia_608'
	local keepLang='eng'

	local defaultTextCodec
	if [[ ${SAME_CONTAINER} == false && ${FILE_EXT} == 'mkv' ]]; then
		defaultTextCodec='srt'
		convertCodec+='|mov_text'
	else
		defaultTextCodec='mov_text'
		convertCodec+='|srt'
	fi

	subtitleParams=()
	for stream in $(get_num_streams "${file}" 's'); do
		local codec lang
		codec="$(get_stream_codec "${file}" "${stream}")" || return 1
		lang="$(get_stream_lang "${file}" "${stream}")" || return 1
		if [[ ${lang} != '' && ${keepLang} != "${lang}" ]]; then
			subtitleParams+=(
				'-map'
				"-0:${stream}"
			)
		elif [[ ${codec} =~ ${convertCodec} ]]; then
			subtitleParams+=("-c:${OUTPUT_INDEX}" "${defaultTextCodec}")
			OUTPUT_INDEX=$((OUTPUT_INDEX + 1))
		fi
	done
}

get_encode_versions() {
	action="${1:-}"

	encodeVersion="encode=$(git -C "${REPO_DIR}" rev-parse --short HEAD)"
	ffmpegVersion=''
	videoEncVersion=''
	audioEncVersion=''

	# shellcheck disable=SC2155
	local output="$(ffmpeg -version 2>&1)"
	while read -r line; do
		if line_starts_with "${line}" 'ffmpeg='; then
			ffmpegVersion="${line}"
		elif line_starts_with "${line}" 'libsvtav1'; then
			videoEncVersion="${line}"
		elif line_starts_with "${line}" 'libopus='; then
			audioEncVersion="${line}"
		fi
	done <<<"${output}"

	local version
	if [[ ${ffmpegVersion} == '' ]]; then
		while read -r line; do
			if line_starts_with "${line}" 'ffmpeg version '; then
				read -r _ _ version _ <<<"${line}"
				ffmpegVersion="ffmpeg=${version}"
				break
			fi
		done <<<"${output}"
	fi

	if [[ ${videoEncVersion} == '' ]]; then
		version="$(get_pkgconfig_version SvtAv1Enc)"
		test "${version}" == '' && return 1
		videoEncVersion="libsvtav1=${version}"
	fi

	if [[ ${audioEncVersion} == '' ]]; then
		version="$(get_pkgconfig_version opus)"
		test "${version}" == '' && return 1
		audioEncVersion="libopus=${version}"
	fi

	test "${ffmpegVersion}" == '' && return 1
	test "${videoEncVersion}" == '' && return 1
	test "${audioEncVersion}" == '' && return 1

	if [[ ${action} == 'print' ]]; then
		echo "${encodeVersion}"
		echo "${ffmpegVersion}"
		echo "${videoEncVersion}"
		echo "${audioEncVersion}"
	fi
	return 0
}

encode_usage() {
	echo "encode -i input [options] output"
	echo -e "\t[-P NUM] set preset (default: ${PRESET})"
	echo -e "\t[-C NUM] set CRF (default: ${CRF})"
	echo -e "\t[-g NUM] set film grain for encode"
	echo -e "\t[-p] print the command instead of executing it (default: ${PRINT_OUT})"
	echo -e "\t[-c] use cropdetect (default: ${CROP})"
	echo -e "\t[-d] enable dolby vision (default: ${DV_TOGGLE})"
	echo -e "\t[-v] print relevant version info"
	echo -e "\t[-s] use same container as input, default is convert to mkv"
	echo -e "\n\t[output] if unset, defaults to \${HOME}/av1-input-file-name.mkv"
	echo -e "\n\t[-u] update script (git pull ffmpeg-builder)"
	echo -e "\t[-I] system install at ${ENCODE_INSTALL_PATH}"
	echo -e "\t[-U] uninstall from ${ENCODE_INSTALL_PATH}"
	return 0
}

encode_update() {
	git -C "${REPO_DIR}" pull
}

set_encode_opts() {
	local opts='vi:pcsdg:P:C:uIU'
	local numOpts=${#opts}
	# default values
	PRESET=3
	CRF=25
	GRAIN=""
	CROP=false
	PRINT_OUT=false
	DV_TOGGLE=false
	ENCODE_INSTALL_PATH='/usr/local/bin/encode'
	SAME_CONTAINER="false"
	# only using -I/U
	local minOpt=1
	# using all + output name
	local maxOpt=$((numOpts + 1))
	test $# -lt ${minOpt} && encode_usage && return 1
	test $# -gt ${maxOpt} && encode_usage && return 1
	local optsUsed=0
	local OPTARG OPTIND
	while getopts "${opts}" flag; do
		case "${flag}" in
		u)
			encode_update || return 1
			return ${FUNC_EXIT_SUCCESS}
			;;
		I)
			echo_warn "attempting install"
			sudo ln -sf "${SCRIPT_DIR}/encode.sh" \
				"${ENCODE_INSTALL_PATH}" || return 1
			echo_pass "succesfull install"
			return ${FUNC_EXIT_SUCCESS}
			;;
		U)
			echo_warn "attempting uninstall"
			sudo rm "${ENCODE_INSTALL_PATH}" || return 1
			echo_pass "succesfull uninstall"
			return ${FUNC_EXIT_SUCCESS}
			;;
		v)
			get_encode_versions print || return 1
			return ${FUNC_EXIT_SUCCESS}
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
			PRINT_OUT=true
			optsUsed=$((optsUsed + 1))
			;;
		c)
			CROP=true
			optsUsed=$((optsUsed + 1))
			;;
		d)
			DV_TOGGLE=true
			optsUsed=$((optsUsed + 1))
			;;
		s)
			SAME_CONTAINER=true
			optsUsed=$((optsUsed + 1))
			;;
		g)
			if ! is_positive_integer "${OPTARG}"; then
				encode_usage
				return 1
			fi
			GRAIN="film-grain=${OPTARG}:film-grain-denoise=1:"
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
				encode_usage
				return 1
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

	if [[ ! -f ${INPUT} ]]; then
		echo "${INPUT} does not exist"
		encode_usage
		return 1
	fi

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
	local genScript="${TMP_DIR}/$(bash_basename "${OUTPUT}").sh"

	# global output index number to increment
	OUTPUT_INDEX=0

	# single string params
	local params=(
		INPUT
		OUTPUT
		PRESET
		CRF
		crop
		encodeVersion
		ffmpegVersion
		videoEncVersion
		audioEncVersion
		svtAv1Params
	)
	local crop=''
	if [[ $CROP == "true" ]]; then
		crop="$(get_crop "${INPUT}")" || return 1
	fi

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

	# arrays
	local arrays=(
		unmapStreams
		audioParams
		videoParams
		metadata
		subtitleParams
		ffmpegParams
	)
	local videoParams=(
		"-crf" '${CRF}' "-preset" '${PRESET}' "-g" "240"
	)
	local ffmpegParams=(
		'-hide_banner'
		'-i' '${INPUT}'
		'-y'
		'-map' '0'
		'-c:s' 'copy'
	)

	# set video params
	local inputVideoCodec="$(get_stream_codec "${INPUT}" 'v:0')"
	if [[ ${inputVideoCodec} == 'av1' ]]; then
		ffmpegParams+=(
			"-c:v:${OUTPUT_INDEX}" 'copy'
		)
	else
		ffmpegParams+=(
			'-pix_fmt' 'yuv420p10le'
			"-c:v:${OUTPUT_INDEX}" 'libsvtav1' '${videoParams[@]}'
			'-svtav1-params' '${svtAv1Params}'
		)
	fi
	OUTPUT_INDEX=$((OUTPUT_INDEX + 1))

	# these values may be empty
	local unmapStr audioParamsStr subtitleParamsStr
	set_unmap_streams "${INPUT}" || return 1
	set_audio_params "${INPUT}" || return 1
	set_subtitle_params "${INPUT}" || return 1

	if [[ ${unmapStreams[*]} != '' ]]; then
		ffmpegParams+=('${unmapStreams[@]}')
	fi

	if [[ ${audioParams[*]} != '' ]]; then
		ffmpegParams+=('${audioParams[@]}')
	fi

	if [[ ${subtitleParams[*]} != '' ]]; then
		ffmpegParams+=('${subtitleParams[@]}')
	fi

	if [[ ${crop} != '' ]]; then
		ffmpegParams+=('-vf' '${crop}')
	fi

	get_encode_versions || return 1
	local metadata=(
		'-metadata' '${encodeVersion}'
		'-metadata' '${ffmpegVersion}'
		'-metadata' '${videoEncVersion}'
		'-metadata' '${audioEncVersion}'
		'-metadata' 'svtav1_params=${svtAv1Params}'
		'-metadata' 'video_params=${videoParams[*]}'
	)
	ffmpegParams+=('${metadata[@]}')

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
		if [[ ${DV_TOGGLE} == true ]]; then
			echo 'ffmpeg "${ffmpegParams[@]}" -dolbyvision 1 "${OUTPUT}" || \'
		fi
		echo 'ffmpeg "${ffmpegParams[@]}" -dolbyvision 0 "${OUTPUT}" || exit 1'

		# track-stats and clear title
		if [[ ${FILE_EXT} == 'mkv' ]]; then
			{
				echo
				echo 'mkvpropedit "${OUTPUT}" --add-track-statistics-tags'
				echo 'mkvpropedit "${OUTPUT}" --edit info --set "title="'
			}
		fi

		echo
	} >"${genScript}"

	if [[ ${PRINT_OUT} == true ]]; then
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
	set_encode_opts "$@"
	local ret=$?
	if [[ ${ret} -eq ${FUNC_EXIT_SUCCESS} ]]; then
		return 0
	elif [[ ${ret} -ne 0 ]]; then
		return ${ret}
	fi
	gen_encode_script || return 1
}
