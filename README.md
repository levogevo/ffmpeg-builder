
# ffmpeg-builder
A collection of scripts for building `ffmpeg` and encoding content with the built `ffmpeg`.

Tested on:
- linux x86_64/aarch64 on:
  - ubuntu
  - fedora
  - debian
  - archlinux
- darwin aarch64

With these scripts you can:
1. install required dependencies using `./scripts/install_deps.sh`
2. build ffmpeg with the desired configuration using `./scripts/build.sh`
3. encode a file using libsvtav1 and libopus using `./scripts/encode.sh`
4. estimate the film grain of a given file using `./scripts/efg.sh`

# Building
This project supports multiple ways to build.

## Configuration
Configuration is done through environment variables.
By default, this project will build a static `ffmpeg` binary in `./gitignore/sysroot/bin/ffmpeg`.

The user-overridable compile options are:
- `ENABLE`: configure what ffmpeg enables. default: 
lcms2
libaom
libass
libvpx
libjxl
libxml2
libvmaf
libx264
libx265
libwebp
libopus
librav1e
libdav1d
libbluray
libsnappy
libvorbis
libmp3lame
libfribidi
vapoursynth
libfreetype
libharfbuzz
libopenjpeg
libsvtav1_hdr
libfontconfig

- `PREFIX`: path to install to, local install is in ./gitignore/sysroot. default: local
- `STATIC`: static (ON) or shared (OFF) build. default: ON
- `LTO`: enable link time optimization (ON/OFF). default: ON
- `CLEAN`: clean build directories before building (ON/OFF). default: ON
- `PGO`: enable profile guided optimization (ON/OFF). default: OFF
- `PACKAGE`: package ffmpeg binaries to tarball in ./gitignore/package (ON/OFF). default: OFF
- `ARCH`: architecture type (x86-64-v{1,2,3,4}, armv8-a, etc). default: native
- `OPT`: optimization level (0-3). default: 3

Examples:
- only build libsvtav1_psy and libopus: `ENABLE='libsvtav1_psy libopus' ./scripts/build.sh`
- build shared libraries in custom path: `PREFIX=/usr/local STATIC=OFF ./scripts/build.sh` 
- build without LTO at O1: `LTO=OFF OPT=1 ./scripts/build.sh`

### Native build
Make sure to install required dependencies using `./scripts/install_deps.sh`. Then build ffmpeg with the desired configuration using `./scripts/build.sh`.

### Docker build
1. choose a given distro from: `ubuntu fedora debian archlinux`.
2. build a docker image with the required dependencies pre-installed using `./scripts/docker_build_image.sh` `<distro>`.
3. run a docker image with the given arguments using `./scripts/docker_run_image.sh` `<distro>` `./scripts/build.sh`

Docker builds support the same configuration options as native builds. For example to build `ffmpeg` on ubuntu with only `libdav1d` enabled:
```bash
./scripts/docker_build_image.sh ubuntu
ENABLE='libdav1d' ./scripts/docker_run_image.sh ubuntu ./scripts/build.sh
```

# Encoding scripts
The encoding scripts are designed to be installed to system paths for re-use via symbolic links back to this repo using the `-I` flag.

## Encoding with svtav1 and opus
```bash
encode -i input [options] [output]

OPTIONS:
  -i, --input         		input file
  -P, --preset        		set preset (default: 3)
  -C, --crf           		set CRF (default: 25)
  -g, --grain         		set film grain (default: disabled)
  -d, --denoise       		denoise with vapoursynth (default: disabled)
  -p, --print         		print the script instead of executing it
  -c, --crop          		use crop detect to auto-crop
  -z, --dv            		enable dolby vision
  -v, --version       		print version info
  -s, --same-container		use same container as input (default: mkv)
  -u, --update        		update script (git pull ffmpeg-builder)
  -I, --install       		system install at /usr/local/bin/encode
  -U, --uninstall     		uninstall from /usr/local/bin/encode


  [output] output filename (default: ${PWD}/av1-input-file-name.mkv)
```
- Uses svtav1 for the video encoder.
- Uses libopus for the audio encoder.
- Skips re-encoding av1/opus streams.
- Only maps audio streams that match the video stream language if the video stream has a defined language.
- Only maps english subtitle streams.
- Crop PGS subtitles to match video dimensions.
- Adds track statistics to the output mkv file and embeds the encoder versions to the output metadata. For example:
```
ENCODE : aa4d7e6
FFMPEG : 8.0
LIBOPUS : 1.5.2
LIBSVTAV1_PSY : 3.0.2-B
SVTAV1_PARAMS : film-grain=8:film-grain-denoise=1:tune=0:...
VIDEO_PARAMS : -crf 25 -preset 3 -g 240
```

Example usage:
- standard usage: `encode -i input.mkv output.mkv`
- print out what will be executed without starting encoding: `encode -i input.mkv -p`
- encode with film-grain synthesis value of 20 with denoising: `encode -g 20 -i input.mkv` 

## Estimate film-grain
```bash
efg -i input [options]

OPTIONS:
  -i, --input    		input file
  -P, --preset   		set preset (default: 10)
  -l, --low      		set low end value for grain range (default: 0)
  -s, --step     		set step value for grain range (default: 1)
  -h, --high     		set high end value for grain range (default: 30)
  -d, --denoise  		denoise with vapoursynth (default: disabled)
  -n, --segments 		number of segments to analyze from input (default: 5)
  -p, --plot     		plot bitrates using gnuplot
  -I, --install  		system install at /usr/local/bin/efg
  -U, --uninstall		uninstall from /usr/local/bin/efg
```
- Provides a way to estimate the ideal film-grain amount by encoding from low-high given values and the step amount.
- Observing the point of diminishing returns, one can make an informed decision for a given film-grain value to choose.

Example usage:
- `efg -i input.mkv -p`
```
  10000 +------------------------------------------------------------------------------------------------------------------------------------------+
        |      **G*            +                      +                       +                      +                      +                      |
        |          **                                    /Volumes/External/ffmpeg-builder/gitignore/tmp/efg-matrix-reloaded.mkv/plot.dat ***G*** |
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
```

