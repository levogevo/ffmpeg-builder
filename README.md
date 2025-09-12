
A collection of scripts for building ffmpeg and encoding content with the built ffmpeg

Tested on:
- linux x86_64/aarch64 on:
  - ubuntu
  - fedora
  - debian
  - archlinux
- darwin aarch64

```bash
~~~ Usable Commands ~~~

print_cmds:
	 print usable commands
do_build:
	 build a specific project
build:
	 build ffmpeg with desired configuration
docker_build_image:
	 build docker image with required dependencies pre-installed
docker_save_image:
	 save docker image into tar.zst
docker_load_image:
	 load docker image from tar.zst
docker_run_image:
	 run docker image with given flags
build_with_docker:
	 run docker image with given flags
docker_build_multiarch_image:
	 build multiarch docker image
efg:
	 estimate the film grain of a given file
encode:
	 encode a file using libsvtav1_psy and libopus
print_pkg_mgr:
	 print out evaluated package manager commands and required packages
install_deps:
	 install required dependencies
gen_readme:
	 generate project README.md
```


