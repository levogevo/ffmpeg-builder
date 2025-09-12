#!/usr/bin/env bash

FB_FUNC_NAMES+=('gen_readme')
FB_FUNC_DESCS['gen_readme']='generate project README.md'
gen_readme() {
	local readme="${REPO_DIR}/README.md"

	echo "
A collection of scripts for building ffmpeg and encoding content with the built ffmpeg

Tested on:
- linux x86_64/aarch64 on:
$(printf '  - %s\n' "${VALID_DOCKER_IMAGES[@]}")
- darwin aarch64

\`\`\`bash
$(print_cmds false)
\`\`\`

" >"${readme}"

}
