
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
3. encode a file using libsvtav1_psy and libopus using `./scripts/encode.sh`
4. estimate the film grain of a given file using `./scripts/efg.sh`

# Building
This project supports multiple ways to build.

## Configuration
Configuration is done through environment variables.
By default, this project will build a static `ffmpeg` binary in `./gitignore/sysroot/bin/ffmpeg`.
The default enabled libraries included in the `ffmpeg` build are:
- libsvtav1_psy
- libopus
- libdav1d
- libaom
- librav1e
- libvmaf
- libx264
- libx265
- libwebp
- libmp3lame

The user-overridable compile options are:
- `CLEAN`: clean build directories before building (default: ON)
- `LTO`: enable link time optimization (default: ON)
- `OPT`: optimization level (0-3) (default: 3)
- `STATIC`: static or shared build (default: ON)
- `ARCH`: architecture type (x86-64-v{1,2,3,4}, armv8-a, etc) (default: native)
- `PREFIX`: prefix to install to, default is local install in ./gitignore/sysroot (default: local)
- `ENABLE`: configure what ffmpeg enables (default: libsvtav1_psy libopus libdav1d libaom librav1e libvmaf libx264 libx265 libwebp libmp3lame)

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

## Encoding with svtav1-psy and opus
```bash
encode -i input [options] output
	[-P NUM] set preset (default: 3)
	[-C NUM] set CRF (default: 25)
	[-g NUM] set film grain for encode
	[-p] print the command instead of executing it (default: false)
	[-c] use cropdetect (default: false)
	[-d] enable dolby vision (default: false)
	[-v] print relevant version info
	[-s] use same container as input, default is convert to mkv

	[output] if unset, defaults to ${HOME}/av1-input-file-name.mkv

	[-u] update script (git pull ffmpeg-builder)
	[-I] system install at /usr/local/bin/encode
	[-U] uninstall from /usr/local/bin/encode
```
- Uses svtav1-psy for the video encoder.
- Uses libopus for the audio encoder.
- Skips re-encoding av1/opus streams.
- Only maps audio streams that match the video stream language if the video stream has a defined language.
- Only maps english subtitle streams.
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
	[-l NUM] low value (default: 0)
	[-s NUM] step value (default: 1)
	[-h NUM] high value (default: 30)
	[-p] plot bitrates using gnuplot

	[-I] system install at /usr/local/bin/efg
	[-U] uninstall from /usr/local/bin/efg
```
- Provides a way to estimate the ideal film-grain amount by encoding from low-high given values and the step amount.
- Observing the point of diminishing returns, one can make an informed decision for a given film-grain value to choose.

Example usage:
- `efg -i input.mkv -p`
```
     1 +------------------------------------------------------------------------------------------------------+
       |    *****G*****          +                         +                        +                         |
       |               *****G**                                                       '/tmp/plot.dat' ***G*** |
  0.95 |-+                     *****                                                                        +-|
       |                            **G*                                                                      |
       |                                ***                                                                   |
       |                                   ****                                                               |
   0.9 |-+                                     *G*                                                          +-|
       |                                          ****                                                        |
       |                                              ****                                                    |
  0.85 |-+                                                *G*                                               +-|
       |                                                     ***                                              |
       |                                                        ****                                          |
   0.8 |-+                                                          *G*                                     +-|
       |                                                               ***                                    |
       |                                                                  ****                                |
       |                                                                      *G*                             |
  0.75 |-+                                                                       ***                        +-|
       |                                                                            ****                      |
       |                                                                                *G*                   |
   0.7 |-+                                                                                 ***              +-|
       |                                                                                      **              |
       |                                                                                        ***           |
       |                                                                                           *G*        |
  0.65 |-+                                                                                            ***   +-|
       |                                                                                                 **** |
       |                         +                         +                        +                        *|
   0.6 +------------------------------------------------------------------------------------------------------+
```

