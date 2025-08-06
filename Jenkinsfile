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
                            withCredentials([string(
                                    credentialsId: 'DOCKER_REGISTRY',
                                    variable: 'DOCKER_REGISTRY'),
                                    usernamePassword(credentialsId: 'DOCKER_REGISTRY_CRED',
                                    passwordVariable: 'DOCKER_REGISTRY_PASS',
                                    usernameVariable: 'DOCKER_REGISTRY_USER'
                                    )]) {
                                sh "./scripts/docker_build_image.sh ${DISTRO}"
                                sh "./scripts/docker_run_image.sh ${DISTRO}"
                            }
                        }
                    }
                }
            }
        }
    }
}
