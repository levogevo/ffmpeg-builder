pipeline {
    agent none
    stages {
        stage('Build Matrix') {
            matrix {
                agent { label "linux" }
                axes {
                    axis {
                        name 'DISTRO'
                        values 'debian:bookworm', 'ubuntu:24.04', 'archlinuxarm:latest', 'fedora:42'
                    }
                }
                stages {
                    stage('Build') {
                        steps {
                            sh "./scripts/docker_run_image.sh ${DISTRO}"
                        }
                    }
                }
            }
        }
    }
}
