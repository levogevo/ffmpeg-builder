#!/usr/bin/env bash

DESIRED_SUB_LANG=eng

# sets UNMAP_STREAMS
set_unmap_streams() {
    local file="$1"
    local unmapFilter='bin_data|jpeg|png'
    local streamsStr
    UNMAP_STREAMS=()
    streamsStr="$(get_num_streams "${file}")" || return 1
    mapfile -t streams <<<"${streamsStr}" || return 1
    for stream in "${streams[@]}"; do
        if [[ "$(get_stream_codec "${file}" "${stream}")" =~ ${unmapFilter} ]]; then
            UNMAP_STREAMS+=("-map" "-0:${stream}")
        fi
    done
}

# sets AUDIO_PARAMS
set_audio_params() {
    local file="$1"
    local videoLang
    AUDIO_PARAMS=()
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
            AUDIO_PARAMS+=(
                '-map'
                "-0:${stream}"
            )
        elif [[ ${codec} == 'opus' ]]; then
            AUDIO_PARAMS+=(
                "-c:${OUTPUT_INDEX}"
                "copy"
            )
            OUTPUT_INDEX=$((OUTPUT_INDEX + 1))
        else
            AUDIO_PARAMS+=(
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

# sets SUBTITLE_PARAMS
set_subtitle_params() {
    local file="$1"
    local convertCodec='eia_608'

    local defaultTextCodec
    if [[ ${SAME_CONTAINER} == false && ${FILE_EXT} == 'mkv' ]]; then
        defaultTextCodec='srt'
        convertCodec+='|mov_text'
    else
        defaultTextCodec='mov_text'
        convertCodec+='|srt'
    fi

    SUBTITLE_PARAMS=()
    for stream in $(get_num_streams "${file}" 's'); do
        local codec lang
        codec="$(get_stream_codec "${file}" "${stream}")" || return 1
        lang="$(get_stream_lang "${file}" "${stream}")" || return 1
        if [[ ${lang} != '' && ${DESIRED_SUB_LANG} != "${lang}" ]]; then
            SUBTITLE_PARAMS+=(
                '-map'
                "-0:${stream}"
            )
        elif [[ ${codec} =~ ${convertCodec} ]]; then
            SUBTITLE_PARAMS+=("-c:${OUTPUT_INDEX}" "${defaultTextCodec}")
            OUTPUT_INDEX=$((OUTPUT_INDEX + 1))
        elif [[ ${codec} == 'hdmv_pgs_subtitle' ]]; then
            PGS_SUB_STREAMS+=("${stream}")
            SUBTITLE_PARAMS+=(
                '-map'
                "-0:${stream}"
            )
        else
            # map -0 covers the stream but still want to increment the index
            OUTPUT_INDEX=$((OUTPUT_INDEX + 1))
        fi
    done
}

get_encode_versions() {
    action="${1:-}"

    ENCODE_VERSION="encode=$(git -C "${REPO_DIR}" rev-parse --short HEAD)"
    FFMPEG_VERSION=''
    VIDEO_ENC_VERSION=''
    AUDIO_ENC_VERSION=''

    # shellcheck disable=SC2155
    local output="$(ffmpeg -version 2>&1)"
    while read -r line; do
        if line_starts_with "${line}" 'ffmpeg='; then
            FFMPEG_VERSION="${line}"
        elif line_starts_with "${line}" 'libsvtav1'; then
            VIDEO_ENC_VERSION="${line}"
        elif line_starts_with "${line}" 'libopus='; then
            AUDIO_ENC_VERSION="${line}"
        fi
    done <<<"${output}"

    local version
    if [[ ${FFMPEG_VERSION} == '' ]]; then
        while read -r line; do
            if line_starts_with "${line}" 'ffmpeg version '; then
                read -r _ _ version _ <<<"${line}"
                FFMPEG_VERSION="ffmpeg=${version}"
                break
            fi
        done <<<"${output}"
    fi

    if [[ ${VIDEO_ENC_VERSION} == '' ]]; then
        version="$(get_pkgconfig_version SvtAv1Enc)"
        test "${version}" == '' && return 1
        VIDEO_ENC_VERSION="libsvtav1=${version}"
    fi

    if [[ ${AUDIO_ENC_VERSION} == '' ]]; then
        version="$(get_pkgconfig_version opus)"
        test "${version}" == '' && return 1
        AUDIO_ENC_VERSION="libopus=${version}"
    fi

    test "${FFMPEG_VERSION}" == '' && return 1
    test "${VIDEO_ENC_VERSION}" == '' && return 1
    test "${AUDIO_ENC_VERSION}" == '' && return 1

    if [[ ${action} == 'print' ]]; then
        echo "${ENCODE_VERSION}"
        echo "${FFMPEG_VERSION}"
        echo "${VIDEO_ENC_VERSION}"
        echo "${AUDIO_ENC_VERSION}"
    fi
    return 0
}

# given an input mkv/sup file,
# output a new mkv file with
# input metadata preserved
replace_mkv_sup() {
    local mkvIn="$1"
    local supIn="$2"
    local mkvOut="$3"
    local stream="${4:-0}"

    local json
    json="$(get_stream_json "${mkvIn}" "${stream}")" || return 1

    # x:y
    # x = stream json variable name
    # y = mkvmerge option name
    local optionMap=(
        disposition.default:--default-track-flag
        disposition.original:--original-flag
        disposition.comment:--commentary-flag
        disposition.forced:--forced-display-flag
        disposition.hearing_impaired:--hearing-impaired-flag
        tags.language:--language
        tags.title:--track-name
    )

    # start building mkvmerge command
    local mergeCmd=(
        mkvmerge
        -o "${mkvOut}"
    )
    for line in "${optionMap[@]}"; do
        IFS=: read -r key option <<<"${line}"
        local val
        val="$(jq -r ".streams[].${key}" <<<"${json}")" || return 1
        # skip undefined values
        test "${val}" == null && continue
        # always track 0 for single track
        mergeCmd+=("${option}" "0:${val}")
    done
    mergeCmd+=("${supIn}")

    "${mergeCmd[@]}"
}

crop_sup() {
    local inSup="$1"
    local outSup="$2"
    local left="$3"
    local top="$4"
    local right="$5"
    local bottom="$6"
    local warnMsg='Window is outside new screen area'
    local maxAcceptableWarn=5
    local offset=5

    # skip cropping if not needed
    if [[ "${left}${top}${right}${bottom}" == "0000" ]]; then
        cp "${inSup}" "${outSup}" || return 1
        return 0
    fi

    for ((try = 0; try < 30; try++)); do
        echo_info "cropping sup with ${left} ${top} ${right} ${bottom}"
        "${SUPMOVER}" \
            "${inSup}" \
            "${outSup}" \
            --crop \
            "${left}" "${top}" "${right}" "${bottom}" &>"${outSup}.out" || return 1
        # supmover does not error for out-of-bounds subtitles
        # so adjust crop value until there is most certainly no issue
        if [[ "$(grep -c "${warnMsg}" "${cropSup}.out")" -gt ${maxAcceptableWarn} ]]; then
            echo_warn "${warnMsg}, retrying... (try ${try})"
            test "${left}" -gt ${offset} && left=$((left - offset))
            test "${top}" -gt ${offset} && top=$((top - offset))
            test "${right}" -gt ${offset} && right=$((right - offset))
            test "${bottom}" -gt ${offset} && bottom=$((bottom - offset))
        else
            return 0
        fi
    done
    # if we got here, all tries were had, so indicate failure
    return 1
}

# extract PGS_SUB_STREAMS from INPUT
# and crop using CROP_VALUE
setup_pgs_mkv() {
    local pgsMkvOut="$1"

    if [[ ${#PGS_SUB_STREAMS[@]} -eq 0 ]]; then
        return
    fi

    check_for_supmover || return 1

    # setup tempdir
    local ogSup cropSup cropMkv tmpdir
    tmpdir="${pgsMkvOut}-dir"
    recreate_dir "${tmpdir}" || return 1

    # get video resolution
    local vidRes vidWidth vidHeight
    vidRes="$(get_resolution "${INPUT}")"
    IFS=x read -r vidWidth vidHeight <<<"${vidRes}"

    for stream in "${PGS_SUB_STREAMS[@]}"; do
        # extract sup from input
        ogSup="${tmpdir}/${stream}.sup"
        cropSup="${tmpdir}/${stream}-cropped.sup"
        cropMkv="${tmpdir}/${stream}.mkv"
        mkvextract "${INPUT}" tracks "${stream}:${ogSup}" || return 1

        # check sup resolution
        local supRes
        supRes="$(get_sup_resolution "${ogSup}")" || return 1
        local supWidth supHeight
        IFS=x read -r supWidth supHeight <<<"${supRes}"
        local left top right bottom
        # determine crop values
        # if the supfile is smaller than the video stream
        # crop using aspect ratio instead of resolution
        if [[ ${vidWidth} -gt ${supWidth} || ${vidHeight} -gt ${supHeight} ]]; then
            echo_warn "PGS sup (stream=${stream}) is somehow smaller than initial video stream"
            echo_warn "cropping based off of aspect ratio instead of resolution"
            left=0
            # (supHeight - ((vidHeight/vidWidth) * supWidth)) / 2
            top="$(awk '{ print int(($1 - ($2 / $3 * $4)) / 2) }' <<<"${supHeight} ${vidHeight} ${vidWidth} ${supWidth}")"
            right=${left}
            bottom=${top}
        # otherwise crop using the crop value
        elif [[ ${CROP_VALUE} != '' ]]; then
            # determine supmover crop based off of crop
            local res w h x y
            # extract ffmpeg crop value ("crop=w:h:x:y")
            IFS='=' read -r _ res <<<"${CROP_VALUE}"
            IFS=':' read -r w h x y <<<"${res}"

            # ffmpeg crop value
            # is different than supmover crop inputs
            left=${x}
            top=${y}
            right=$((supWidth - w - left))
            bottom=$((supHeight - h - top))
        # fallback to just the video resolution
        else
            left=$(((supWidth - vidWidth) / 2))
            top=$(((supHeight - vidHeight) / 2))
            right=${left}
            bottom=${top}
        fi

        if ! crop_sup "${ogSup}" "${cropSup}" "${left}" "${top}" "${right}" "${bottom}"; then
            rm -r "${tmpdir}" || return 1
            return 1
        fi

        if ! replace_mkv_sup "${INPUT}" "${cropSup}" "${cropMkv}" "${stream}"; then
            echo_fail "could not replace mkv sup for ${stream}"
            rm -r "${tmpdir}" || return 1
        fi
    done

    # merge all single mkv into one
    mkvmerge -o "${pgsMkvOut}" "${tmpdir}/"*.mkv
    local mergeRet=$?
    rm -r "${tmpdir}" || return 1
    return ${mergeRet}
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
    echo -e "\n\t[output] if unset, defaults to \${PWD}/av1-input-file-name.mkv"
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
        OUTPUT="${PWD}/av1-${basename}"
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

    if [[ ${PRINT_OUT} == false ]]; then
        echo
        echo_info "INPUT: ${INPUT}"
        echo_info "GRAIN: ${GRAIN}"
        echo_info "OUTPUT: ${OUTPUT}"
        echo
    fi
}

# shellcheck disable=SC2034
# shellcheck disable=SC2155
# shellcheck disable=SC2016
gen_encode_script() {
    if missing_cmd mkvpropedit; then
        echo_fail "use: ${REPO_DIR}/scripts/install_deps.sh"
        return 1
    fi

    local outputBasename="$(bash_basename "${OUTPUT}")"
    local genScript="${TMP_DIR}/${outputBasename}.sh"

    # global output index number to increment
    OUTPUT_INDEX=0

    # single string params
    local params=(
        INPUT
        OUTPUT
        PRESET
        CRF
        CROP_VALUE
        ENCODE_VERSION
        FFMPEG_VERSION
        VIDEO_ENC_VERSION
        AUDIO_ENC_VERSION
        svtAv1Params
        pgsMkv
        muxxedPgsMkv
    )

    svtAv1ParamsArr=(
        "tune=0"
        "complex-hvs=1"
        "spy-rd=1"
        "psy-rd=1"
        "sharpness=3"
        "enable-overlays=0"
        "hbd-mds=1"
        "scd=1"
        "fast-decode=1"
        "enable-variance-boost=1"
        "enable-qm=1"
        "chroma-qm-min=10"
        "qm-min=4"
        "qm-max=15"
    )
    IFS=':'
    local svtAv1Params="${GRAIN}${svtAv1ParamsArr[*]}"
    unset IFS

    # arrays
    local arrays=(
        UNMAP_STREAMS
        AUDIO_PARAMS
        SUBTITLE_PARAMS
        videoParams
        metadata
        ffmpegParams
        PGS_SUB_STREAMS
    )
    local "${arrays[@]}"

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
    get_encode_versions || return 1
    local inputVideoCodec="$(get_stream_codec "${INPUT}" 'v:0')"
    if [[ ${inputVideoCodec} == 'av1' ]]; then
        ffmpegParams+=(
            "-c:v:${OUTPUT_INDEX}" 'copy'
        )
        # can't crop if copying codec
        CROP=false
    else
        ffmpegParams+=(
            '-pix_fmt' 'yuv420p10le'
            "-c:v:${OUTPUT_INDEX}" 'libsvtav1' '${videoParams[@]}'
            '-svtav1-params' '${svtAv1Params}'
        )
        metadata+=(
            '-metadata' '${VIDEO_ENC_VERSION}'
            '-metadata' 'svtav1_params=${svtAv1Params}'
            '-metadata' 'video_params=${videoParams[*]}'
        )
    fi
    OUTPUT_INDEX=$((OUTPUT_INDEX + 1))

    # these values may be empty
    set_unmap_streams "${INPUT}" || return 1
    set_audio_params "${INPUT}" || return 1
    set_subtitle_params "${INPUT}" || return 1

    if [[ ${UNMAP_STREAMS[*]} != '' ]]; then
        ffmpegParams+=('${UNMAP_STREAMS[@]}')
    fi

    if [[ ${AUDIO_PARAMS[*]} != '' ]]; then
        ffmpegParams+=('${AUDIO_PARAMS[@]}')
    fi

    if [[ ${SUBTITLE_PARAMS[*]} != '' ]]; then
        ffmpegParams+=('${SUBTITLE_PARAMS[@]}')
    fi

    metadata+=(
        '-metadata' '${ENCODE_VERSION}'
        '-metadata' '${FFMPEG_VERSION}'
    )

    # in the case all audio streams are copied,
    # don't add libopus metadata
    if line_contains "${AUDIO_PARAMS[*]}" 'libopus'; then
        metadata+=(
            '-metadata' '${AUDIO_ENC_VERSION}')
    fi

    local CROP_VALUE
    if [[ ${CROP} == true ]]; then
        CROP_VALUE="$(get_crop "${INPUT}")" || return 1
        ffmpegParams+=('-vf' '${CROP_VALUE}')
        metadata+=(
            '-metadata' '${CROP_VALUE}'
            '-metadata' "og_res=$(get_resolution "${INPUT}")"
        )
    fi

    # separate processing step for pkg subs
    local pgsMkv="${TMP_DIR}/pgs-${outputBasename// /.}.mkv"
    local muxxedPgsMkv='${OUTPUT}.muxxed'
    setup_pgs_mkv "${pgsMkv}" 1>&2 || return 1

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
                # ffmpeg does not copy PGS subtitles without breaking them
                # use mkvmerge to extract and supmover to crop
                if [[ ${#PGS_SUB_STREAMS[@]} -gt 0 ]]; then
                    echo
                    echo 'mkvmerge -o "${muxxedPgsMkv}" "${pgsMkv}" "${OUTPUT}" || exit 1'
                    echo 'rm "${pgsMkv}" || exit 1'
                    echo 'mv "${muxxedPgsMkv}" "${OUTPUT}" || exit 1'
                fi

                echo 'mkvpropedit "${OUTPUT}" --add-track-statistics-tags || exit 1'
                echo 'mkvpropedit "${OUTPUT}" --edit info --set "title=" || exit 1'
            }
        fi

        echo
    } >"${genScript}"

    if [[ ${PRINT_OUT} == true ]]; then
        echo_info "${genScript} contents:" 1>&2
        echo "$(<"${genScript}")"
    else
        bash -x "${genScript}" || return 1
        rm "${genScript}"
    fi
}

FB_FUNC_NAMES+=('encode')
# shellcheck disable=SC2034
FB_FUNC_DESCS['encode']='encode a file using libsvtav1 and libopus'
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
