#!/usr/bin/env bash

_ffprobe_wrapper() {
    local stderr="${TMP_DIR}/ffprobe-stderr"
    if ! ffprobe "$@" 2>"${TMP_DIR}/ffprobe-stderr"; then
        cat "${stderr}"
        return 1
    fi
    return 0
}

get_duration() {
    local file="$1"
    _ffprobe_wrapper \
        -v error \
        -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 \
        "${file}"
}

get_avg_bitrate() {
    local file="$1"
    _ffprobe_wrapper \
        -v error \
        -select_streams v:0 \
        -show_entries format=bit_rate \
        -of default=noprint_wrappers=1:nokey=1 \
        "${file}"
}

split_video() {
    local file="$1"
    local start="$2"
    local time="$3"
    local out="$4"
    ffmpeg \
        -ss "${start}" \
        -i "${file}" \
        -hide_banner \
        -loglevel error \
        -t "${time}" \
        -map 0:v \
        -reset_timestamps 1 \
        -c copy \
        "${out}"
}

get_crop() {
    local file="$1"
    local duration
    duration="$(get_duration "${file}")" || return 1
    # don't care about decimal points
    IFS='.' read -r duration _ <<<"${duration}"
    # get crop value for first tenth of input
    local timeEnc=$((duration / 10))
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
        grep -o 'crop=.*' |
        sort -bh |
        uniq -c |
        sort -bh |
        tail -n1 |
        grep -o "crop=.*"
}

# output '1920x1080'
get_resolution() {
    local file="$1"
    get_stream_json "${file}" 0 |
        jq -r '.streams[0] | "\(.width)x\(.height)"'
}

# same as get_resolution
get_sup_resolution() {
    local supfile="$1"
    check_for_supmover || return 1
    if [[ "$(get_file_format "${supfile}")" != 'sup' ]]; then
        echo_fail "${supfile} is not a sup file"
        return 1
    fi
    local trace res
    trace="$("${SUPMOVER}" "${supfile}" --trace)" || return 1
    res="$(grep 'Video size' <<<"${trace}" | sort -u | awk '{print $NF}')" || return 1
    echo "${res}"
}

get_stream_codec() {
    local file="$1"
    local stream="$2"
    _ffprobe_wrapper \
        -v error \
        -select_streams "${stream}" \
        -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 \
        "${file}"
}

get_stream_json() {
    local file="$1"
    local stream="$2"
    _ffprobe_wrapper \
        -v error \
        -select_streams "${stream}" \
        -read_intervals "%+#1" \
        -show_entries stream:frames \
        -of json \
        "${file}"
}

get_file_format() {
    local file="$1"
    local probe
    probe="$(_ffprobe_wrapper \
        -v error \
        -show_entries format=format_name \
        -of default=noprint_wrappers=1:nokey=1 \
        "${file}")" || return 1
    if line_contains "${probe}" 'matroska'; then
        echo mkv
    elif line_contains "${probe}" 'mp4'; then
        echo mp4
    else
        echo "${probe}"
    fi
}

get_num_streams() {
    local file="$1"
    local type="${2:-}"
    local select=()

    if [[ ${type} != '' ]]; then
        select=("-select_streams" "${type}")
    fi

    _ffprobe_wrapper \
        -v error "${select[@]}" \
        -show_entries stream=index \
        -of default=noprint_wrappers=1:nokey=1 \
        "${file}"
}

get_num_audio_channels() {
    local file="$1"
    local stream="$2"
    _ffprobe_wrapper \
        -v error \
        -select_streams "${stream}" \
        -show_entries stream=channels \
        -of default=noprint_wrappers=1:nokey=1 \
        "${file}"
}

get_stream_lang() {
    local file="$1"
    local stream="$2"
    _ffprobe_wrapper \
        -v error \
        -select_streams "${stream}" \
        -show_entries stream_tags=language \
        -of default=noprint_wrappers=1:nokey=1 \
        "${file}"
}

gen_video() {
    local outFile="$1"
    local addFlags=()
    shift

    local vf="format=yuv420p10le"
    for arg in "$@"; do
        case "${arg}" in
        '1080p') resolution='1920x1080' ;;
        '2160p') resolution='3840x2160' ;;
        'grain=yes') vf+=",noise=alls=15:allf=t+u" ;;
        'hdr=yes')
            local colorPrimaries='bt2020'
            local colorTrc='smpte2084'
            local colorspace='bt2020nc'
            vf+=",setparams=color_primaries=${colorPrimaries}:color_trc=${colorTrc}:colorspace=${colorspace}"
            addFlags+=(
                -color_primaries "${colorPrimaries}"
                -color_trc "${colorTrc}"
                -colorspace "${colorspace}"
                -metadata:s:v:0 "mastering_display_metadata=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1)"
                -metadata:s:v:0 "content_light_level=1000,400"
            )
            ;;
        *) echo_fail "bad arg ${arg}" && return 1 ;;
        esac
    done

    echo_if_fail ffmpeg -y \
        -hide_banner \
        -f lavfi \
        -i "testsrc2=size=${resolution}:rate=24:duration=5" \
        -vf "${vf}" \
        -c:v ffv1 \
        -level 3 \
        -g 1 \
        -color_range tv \
        "${addFlags[@]}" \
        "${outFile}"
}

build_svtav1_color_params() {
    local file="$1"
    local json
    json="$(get_stream_json "${file}" | jq -er '.frames[0]')"

    local params=()

    local range space primaries transfer location
    range="$(jq -r '.color_range' <<<"${json}")"
    space="$(jq -r '.color_space' <<<"${json}")"
    primaries="$(jq -r '.color_primaries' <<<"${json}")"
    transfer="$(jq -r '.color_transfer' <<<"${json}")"
    location="$(jq -r '.chroma_location' <<<"${json}")"

    # map ffmpeg color values to svtav1
    local value

    # color_primaries -> --color-primaries
    case "${primaries}" in
    bt709) value=1 ;;
    unknown | unspecified | null) value=2 ;;
    bt470m) value=4 ;;
    bt470bg) value=5 ;;
    smpte170m) value=6 ;;
    smpte240m) value=7 ;;
    film) value=8 ;;
    bt2020) value=9 ;;
    smpte428 | smpte428_1) value=10 ;;
    smpte431) value=11 ;;
    smpte432) value=12 ;;
    jedec-p22 | ebu3213) value=22 ;;
    *) echo_fail "unsupported color primaries ${primaries}" && return 1 ;;
    esac
    params+=("color-primaries=${value}")

    # color_trc -> --transfer-characteristics
    case "${transfer}" in
    bt709) value=1 ;;
    unknown | unspecified | null) value=2 ;;
    gamma22 | bt470m) value=4 ;;
    gamma28 | bt470bg) value=5 ;;
    smpte170m) value=6 ;;
    smpte240m) value=7 ;;
    linear) value=8 ;;
    log100 | log) value=9 ;;
    log316 | log_sqrt) value=10 ;;
    iec61966-2-4 | iec61966_2_4) value=11 ;;
    bt1361e | bt1361) value=12 ;;
    iec61966-2-1 | iec61966_2_1) value=13 ;;
    bt2020-10 | bt2020_10bit) value=14 ;;
    bt2020-12 | bt2020_12bit) value=15 ;;
    smpte2084) value=16 ;;
    smpte428 | smpte428_1) value=17 ;;
    arib-std-b67) value=18 ;;
    *) echo_fail "unsupported transfer characteristics ${transfer}" && return 1 ;;
    esac
    params+=("transfer-characteristics=${value}")

    # colorspace / matrix_coefficients -> --matrix-coefficients
    case "${space}" in
    rgb) value=0 ;;
    bt709) value=1 ;;
    unknown | unspecified | null) value=2 ;;
    fcc) value=4 ;;
    bt470bg) value=5 ;;
    smpte170m) value=6 ;;
    smpte240m) value=7 ;;
    ycgco | ycocg) value=8 ;;
    bt2020nc | bt2020_ncl) value=9 ;;
    bt2020c | bt2020_cl) value=10 ;;
    smpte2085) value=11 ;;
    chroma-derived-nc) value=12 ;;
    chroma-derived-c) value=13 ;;
    ictcp) value=14 ;;
    *) echo_fail "unsupported matrix coefficients ${space}" && return 1 ;;
    esac
    params+=("matrix-coefficients=${value}")

    # color_range -> --color-range
    case "${range}" in
    unknown | unspecified | null) value=0 ;;
    tv | mpeg | limited) value=0 ;;
    pc | jpeg | full) value=1 ;;
    *) echo_fail "unsupported color range ${range}" && return 1 ;;
    esac
    params+=("color-range=${value}")

    # chroma_sample_location -> --chroma-sample-position
    case "${location}" in
    unknown | unspecified | null) value=0 ;;
    left) value=1 ;;
    topleft) value=2 ;;
    *) echo_fail "unsupported chroma sample location ${location}" && return 1 ;;
    esac
    params+=("chroma-sample-position=${value}")

    local masteringDisplay
    masteringDisplay="$(
        jq -r '
        def rat:
            if type == "string" and contains("/") then
                split("/") | (.[0] | tonumber) / (.[1] | tonumber)
            else
                tonumber
            end;

        first(
            .side_data_list[]?
            | select(.side_data_type == "Mastering display metadata")
        ) as $m
        |
        "G(\($m.green_x | rat),\($m.green_y | rat))" +
        "B(\($m.blue_x | rat),\($m.blue_y | rat))" +
        "R(\($m.red_x | rat),\($m.red_y | rat))" +
        "WP(\($m.white_point_x | rat),\($m.white_point_y | rat))" +
        "L(\($m.max_luminance | rat),\($m.min_luminance | rat))"
    ' <<<"${json}"
    )"
    [[ -n ${masteringDisplay} ]] && params+=("mastering-display=${masteringDisplay}")

    local cll
    cll="$(
        jq -r '
        first(
            .side_data_list[]?
            | select(.side_data_type == "Content light level metadata")
        )
        | "\(.max_content),\(.max_average)"
    ' <<<"${json}"
    )"
    [[ -n ${cll} ]] && params+=("content-light=${cll}")

    local IFS=':'
    echo "${params[*]}"
}
