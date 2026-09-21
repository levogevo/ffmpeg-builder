#!/usr/bin/env bash

efg_usage() {
    echo "efg -i input [options]"
    print_opt_map "${EFG_OPT_MAP[@]}" || return 1
    return 0
}

set_efg_opts() {
    # default values
    PRESET=10
    LOW=0
    STEP=1
    HIGH=30
    PLOT=false
    ENCODE_SEGMENTS=5
    EFG_INSTALL_PATH='/usr/local/bin/efg'
    DENOISE_VS=false

    local EFG_OPT_MAP=(
        "-i --input input file"
        "-P --preset set preset (default: ${PRESET})"
        "-l --low set low end value for grain range (default: ${LOW})"
        "-s --step set step value for grain range (default: ${STEP})"
        "-h --high set high end value for grain range (default: ${HIGH})"
        "-d --denoise denoise with vapoursynth (default: disabled)"
        "-n --segments number of segments to analyze from input (default: ${ENCODE_SEGMENTS})"
        "-p --plot plot bitrates using gnuplot"
        "-I --install system install at ${EFG_INSTALL_PATH}"
        "-U --uninstall uninstall from ${EFG_INSTALL_PATH}"
    )

    # only using -I or -U
    local minOpt=1
    test $# -lt ${minOpt} && efg_usage && return 1

    local arg value
    while [[ $# -gt 0 ]]; do
        arg="$1"
        value="${2:-}"
        case "${arg}" in
        -i | --input)
            INPUT="$(readlink -f ${value})"
            shift
            ;;
        -P | --preset)
            if ! is_positive_integer "${value}"; then
                efg_usage
                return 1
            fi
            PRESET="${value}"
            shift
            ;;
        -l | --low)
            if ! is_positive_integer "${value}"; then
                efg_usage
                return 1
            fi
            LOW="${value}"
            shift
            ;;
        -s | --step)
            if ! is_positive_integer "${value}"; then
                efg_usage
                return 1
            fi
            STEP="${value}"
            shift
            ;;
        -h | --high)
            if ! is_positive_integer "${value}"; then
                efg_usage
                return 1
            fi
            HIGH="${value}"
            shift
            ;;
        -d | --denoise)
            DENOISE_VS=true
            ;;
        -n | --num-segments)
            if ! is_positive_integer "${value}"; then
                efg_usage
                return 1
            fi
            ENCODE_SEGMENTS="${value}"
            shift
            ;;
        -p | --plot)
            missing_cmd gnuplot && return 1
            PLOT=true
            ;;
        -I | --install)
            echo_warn "attempting install"
            sudo ln -sf "${SCRIPT_DIR}/efg.sh" \
                "${EFG_INSTALL_PATH}" || return 1
            echo_pass "succesfull install"
            return "${FUNC_EXIT_SUCCESS}"
            ;;
        -U | --uninstall)
            echo_warn "attempting uninstall"
            sudo rm "${EFG_INSTALL_PATH}" || return 1
            echo_pass "succesfull uninstall"
            return "${FUNC_EXIT_SUCCESS}"
            ;;
        *)
            echo_fail "unsupported option: [${arg}]"
            efg_usage
            return 1
            ;;
        esac
        shift
    done

    # validate input
    if [[ -z ${INPUT} || ! -f ${INPUT} ]]; then
        echo_fail "input undefined or does not exist"
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
    echo_info "range: ${LOW}-${HIGH} with ${STEP} step increments"
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
    recreate_dir "${EFG_DIR}" || return 1

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
    local grainLogWIP="${GRAIN_LOG}.wip"
    local encodeArgs=(
        -P "${PRESET}"
    )
    [[ ${DENOISE_VS} == true ]] && encodeArgs+=(--denoise)

    echo -n >"${grainLogWIP}"
    for vid in "${EFG_DIR}/"*.mkv; do
        echo "file: ${vid}" >>"${grainLogWIP}"
        for ((grain = LOW; grain <= HIGH; grain += STEP)); do
            local file="$(bash_basename "${vid}")"
            local out="${EFG_DIR}/grain-${grain}-${file}"

            echo_info "encoding ${file} with grain ${grain}"
            echo_if_fail encode "${encodeArgs[@]}" -g ${grain} -i "${vid}" "${out}" || return 1

            echo -e "\tgrain: ${grain}, bitrate: $(get_avg_bitrate "${out}")" >>"${grainLogWIP}"
            rm "${out}" || return 1
        done
        # remove segment once complete
        rm "${vid}" || return 1
    done

    # atomic move of grain log
    mv "${grainLogWIP}" "${GRAIN_LOG}" || return 1

    echo "$(<"${GRAIN_LOG}")"
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
    # localize variables used by child functions
    local PRESET LOW STEP HIGH PLOT \
        DENOISE_VS EFG_INSTALL_PATH EFG_DIR ENCODE_SEGMENTS \
        GRAIN_LOG

    EFG_DIR="${TMP_DIR}/efg"
    # encode N highest-bitrate segments

    set_efg_opts "$@"
    local ret=$?
    if [[ ${ret} -eq ${FUNC_EXIT_SUCCESS} ]]; then
        return 0
    elif [[ ${ret} -ne 0 ]]; then
        return ${ret}
    fi
    ensure_dir "${EFG_DIR}"

    GRAIN_LOG="${EFG_DIR}/${LOW}-${STEP}-${HIGH}-${DENOISE_VS}-grains.txt"

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
