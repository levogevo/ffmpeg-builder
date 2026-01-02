#!/usr/bin/env bash

make_bullet_points() {
    for arg in "$@"; do
        echo "- ${arg}"
    done
}

gen_function_info() {
    local funcName="$1"
    echo "${FB_FUNC_DESCS[${funcName}]} using \`./scripts/${funcName}.sh\`"
}

gen_compile_opts_info() {
    for opt in "${FB_COMP_OPTS[@]}"; do
        declare -n defOptVal="DEFAULT_${opt}"
        echo "- \`${opt}\`: ${FB_COMP_OPTS_DESC[${opt}]} (default: ${defOptVal})"
    done
}

FB_FUNC_NAMES+=('gen_readme')
FB_FUNC_DESCS['gen_readme']='generate project README.md'
gen_readme() {
    local readme="${REPO_DIR}/README.md"

    echo "
# ffmpeg-builder
A collection of scripts for building \`ffmpeg\` and encoding content with the built \`ffmpeg\`.

Tested on:
- linux x86_64/aarch64 on:
$(printf '  - %s\n' "${VALID_DOCKER_IMAGES[@]}")
- darwin aarch64

With these scripts you can:
1. $(gen_function_info install_deps)
2. $(gen_function_info build)
3. $(gen_function_info encode)
4. $(gen_function_info efg)

# Building
This project supports multiple ways to build.

## Configuration
Configuration is done through environment variables.
By default, this project will build a static \`ffmpeg\` binary in \`./gitignore/sysroot/bin/ffmpeg\`.
The default enabled libraries included in the \`ffmpeg\` build are:
$(make_bullet_points ${DEFAULT_ENABLE})

The user-overridable compile options are:
$(gen_compile_opts_info)

Examples:
- only build libsvtav1_psy and libopus: \`ENABLE='libsvtav1_psy libopus' ./scripts/build.sh\`
- build shared libraries in custom path: \`PREFIX=/usr/local STATIC=OFF ./scripts/build.sh\` 
- build without LTO at O1: \`LTO=OFF OPT=1 ./scripts/build.sh\`

### Native build
Make sure to $(gen_function_info install_deps). Then $(gen_function_info build).

### Docker build
1. choose a given distro from: \`${VALID_DOCKER_IMAGES[*]}\`.
2. $(gen_function_info docker_build_image) \`<distro>\`.
3. $(gen_function_info docker_run_image) \`<distro>\` \`./scripts/build.sh\`

Docker builds support the same configuration options as native builds. For example to build \`ffmpeg\` on ubuntu with only \`libdav1d\` enabled:
\`\`\`bash
./scripts/docker_build_image.sh ubuntu
ENABLE='libdav1d' ./scripts/docker_run_image.sh ubuntu ./scripts/build.sh
\`\`\`

# Encoding scripts
The encoding scripts are designed to be installed to system paths for re-use via symbolic links back to this repo using the \`-I\` flag.

## Encoding with svtav1-psy and opus
\`\`\`bash
$(encode)
\`\`\`
- Uses svtav1-psy for the video encoder.
- Uses libopus for the audio encoder.
- Skips re-encoding av1/opus streams.
- Only maps audio streams that match the video stream language if the video stream has a defined language.
- Only maps english subtitle streams.
- Adds track statistics to the output mkv file and embeds the encoder versions to the output metadata. For example:
\`\`\`
ENCODE : aa4d7e6
FFMPEG : 8.0
LIBOPUS : 1.5.2
LIBSVTAV1_PSY : 3.0.2-B
SVTAV1_PARAMS : film-grain=8:film-grain-denoise=1:tune=0:...
VIDEO_PARAMS : -crf 25 -preset 3 -g 240
\`\`\`

Example usage:
- standard usage: \`encode -i input.mkv output.mkv\`
- print out what will be executed without starting encoding: \`encode -i input.mkv -p\`
- encode with film-grain synthesis value of 20 with denoising: \`encode -g 20 -i input.mkv\` 

## Estimate film-grain
\`\`\`bash
$(efg)
\`\`\`
- Provides a way to estimate the ideal film-grain amount by encoding from low-high given values and the step amount.
- Observing the point of diminishing returns, one can make an informed decision for a given film-grain value to choose.

Example usage:
- \`efg -i input.mkv -p\`
\`\`\`
  10000 +------------------------------------------------------------------------------------------------------------------------------------------+
        |      **G*            +                      +                       +                      +                      +                      |
        |          **                                    "/Volumes/External/ffmpeg-builder/gitignore/tmp/efg-matrix-reloaded.mkv/plot.dat" ***G*** |
        |            *G**                                                                                                                          |
        |                **G                                                                                                                       |
   9000 |-+                 **                                                                                                                   +-|
        |                     *G**                                                                                                                 |
        |                         **G                                                                                                              |
        |                            **                                                                                                            |
        |                              *G*                                                                                                         |
   8000 |-+                               **                                                                                                     +-|
        |                                   *G**                                                                                                   |
        |                                       **G                                                                                                |
        |                                          **                                                                                              |
        |                                            *G**                                                                                          |
   7000 |-+                                              **G*                                                                                    +-|
        |                                                    **                                                                                    |
        |                                                      *G*                                                                                 |
        |                                                         **G**                                                                            |
   6000 |-+                                                            **G*                                                                      +-|
        |                                                                  **                                                                      |
        |                                                                    *G*                                                                   |
        |                                                                       **G**                                                              |
        |                                                                            **G*                                                          |
   5000 |-+                                                                              **G**                                                   +-|
        |                                                                                     **G****G*                                            |
        |                                                                                              **G**                                       |
        |                                                                                                   **G****G*                              |
        |                                                                                                            **G****G*                     |
   4000 |-+                                                                                                                   **G****G****G*     +-|
        |                                                                                                                                   **G****|
        |                                                                                                                                          |
        |                                                                                                                                          |
        |                      +                      +                       +                      +                      +                      |
   3000 +------------------------------------------------------------------------------------------------------------------------------------------+
        0                      5                      10                      15                     20                     25                     30
\`\`\`
" >"${readme}"

}
