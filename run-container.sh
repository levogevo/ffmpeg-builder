#!/usr/bin/env bash

THIS_DIR="$(dirname "${BASH_SOURCE[0]}")"
IMAGE_NAME='ffmpeg_builder'
DISTROS=( debian ubuntu archlinux fedora )
DISTROS=( debian )

for DISTRO in "${DISTROS[@]}"; do
    docker run \
    --rm -it \
    -v "${THIS_DIR}":/workdir \
    -w /workdir \
    "${IMAGE_NAME}-${DISTRO}" bash main.sh
done