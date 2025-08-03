pipeline {
    agent none
    stages {
        stage('Build Docker Image Matrix') {
            matrix {
                axes {
                    axis {
                        name 'DISTRO'
                        values 'debian-bookworm', 'ubuntu-24.04', 'ubuntu-22.04',
                             'archlinux-latest', 'fedora-42'
                    }
                }
                stages {
                    stage('Build Docker Image') {
                        agent { label "linux && amd64" }
                        steps {
                            sh "./scripts/docker_build_image.sh ${DISTRO}"
                            sh "./scripts/docker_save_image.sh ${DISTRO}"
                            stash includes: "gitignore/docker/*${DISTRO}.tar.zst", name: "${DISTRO}-stash"
                        }
                    }

                    stage('Run Docker Image') {
                        agent { label "linux && arm64" }
                        steps {
                            unstash "${DISTRO}-stash"
                            sh "./scripts/docker_load_image.sh ${DISTRO}"
                            sh "./scripts/docker_run_amd64_image_on_arm64.sh ${DISTRO}"
                        }
                    }
                }
            }
        }
    }
}
