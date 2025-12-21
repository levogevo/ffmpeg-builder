#!/usr/bin/env bash

PGO_DIR="${IGN_DIR}/pgo"
PGO_PROFDATA="${PGO_DIR}/prof.profdata"
gen_profdata() {
	recreate_dir "${PGO_DIR}" || return 1
	cd "${PGO_DIR}" || return 1
	setup_pgo_clips || return 1
	for vid in *.mkv; do
		local args=()
		# add precalculated grain amount based off of filename
		line_contains "${vid}" 'grain' && args+=(-g 16)
		# make fhd preset 2
		line_contains "${vid}" 'fhd' && args+=(-P 2)

		echo_info "encoding pgo vid: ${vid}"
		LLVM_PROFILE_FILE="${PGO_DIR}/default_%p.profraw" \
			echo_if_fail encode -i "${vid}" "${args[@]}" "encoded-${vid}" || return 1
	done

	# merge profraw into profdata
	local mergeCmd=()
	# darwin needs special invoke
	if is_darwin; then
		mergeCmd+=(xcrun)
	fi

	mergeCmd+=(
		llvm-profdata
		merge
		"--output=${PGO_PROFDATA}"
	)
	"${mergeCmd[@]}" default*.profraw || return 1

	return 0
}

setup_pgo_clips() {
	local clips=(
		"fhd-grainy.mkv 1080p,grain=yes"
		"uhd.mkv 2160p"
		"uhd-hdr.mkv 2160p,hdr=yes"
	)
	for clip in "${clips[@]}"; do
		local genVid genVidArgs pgoFile genVidArgsArr
		IFS=' ' read -r genVid genVidArgs <<<"${clip}"
		# pgo path is separate
		pgoFile="${PGO_DIR}/${genVid}"
		genVid="${TMP_DIR}/${genVid}"
		# create array of args split with ,
		genVidArgsArr=(${genVidArgs//,/ })
		# create generated vid without any profiling if needed
		test -f "${genVid}" ||
			LLVM_PROFILE_FILE='/dev/null' gen_video "${genVid}" "${genVidArgsArr[@]}" || return 1
		# and move to the pgo directory
		test -f "${pgoFile}" ||
			cp "${genVid}" "${pgoFile}" || return 1

	done
}
