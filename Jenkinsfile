pipeline {
    agent none
    environment { DEBUG = "1" }
    stages {
        stage('Build in Docker') {
            matrix {
                axes {
                    axis {
                        name 'DISTRO'
                        values 'ubuntu-22.04', 'ubuntu-24.04', 
                            'debian-12', 'fedora-42'
                            // 'archlinux-latest'
                    }
                    axis {
                        name 'ARCH'
                        values 'amd64', 'arm64'
                    }
                }
                stages {
                    stage('Build/Run') {
                        agent { label "linux && ${ARCH}" }
                        steps {
                            sh "./scripts/docker_build_image.sh ${DISTRO}"
                            sh "./scripts/docker_run_image.sh ${DISTRO}"
                        }
                    }
                }
            }
        }
    }
}
