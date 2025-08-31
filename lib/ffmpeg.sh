#!/usr/bin/env bash

get_duration() {
	local file="$1"
	ffprobe \
		-v error \
		-show_entries format=duration \
		-of default=noprint_wrappers=1:nokey=1 \
		"${file}"
}

get_avg_bitrate() {
	local file="$1"
	ffprobe \
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
