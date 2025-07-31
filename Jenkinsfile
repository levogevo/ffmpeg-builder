pipeline {
    agent none
    stages {
        stage('Build Matrix') {
            matrix {
                agent { label "linux" }
                axes {
                    axis {
                        name 'DISTRO'
                        values 'debian:bookworm', 'ubuntu:24.04', 'ubuntu:22.04',
                             'archlinux:latest', 'fedora:42'
                    }
                }
                stages {
                    stage('Build') {
                        steps {
                            sh "./scripts/docker_run_amd64_image_on_arm64.sh ${DISTRO}"
                        }
                    }
                }
            }
        }
    }
}
