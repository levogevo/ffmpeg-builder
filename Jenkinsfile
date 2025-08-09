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
                            'debian-12', 'fedora-42',
                            'ogarcia/archlinux-latest'
                    }
                    axis {
                        name 'ARCH'
                        values 'amd64', 'arm64'
                    }
                }
                stages {
                    stage('Build Multiarch Image') {
                        agent { label "linux && amd64" }
                        steps {
                            withCredentials([string(
                                    credentialsId: 'DOCKER_REGISTRY',
                                    variable: 'DOCKER_REGISTRY'),
                                    usernamePassword(credentialsId: 'DOCKER_REGISTRY_CRED',
                                    passwordVariable: 'DOCKER_REGISTRY_PASS',
                                    usernameVariable: 'DOCKER_REGISTRY_USER'
                                    )]) {
                                sh "./scripts/docker_build_multiarch_image.sh ${DISTRO}"
                            }
                        }
                    }
                    stage('Run Multiarch Image') {
                        agent { label "linux && ${ARCH}" }
                        steps {
                            withCredentials([string(
                                    credentialsId: 'DOCKER_REGISTRY',
                                    variable: 'DOCKER_REGISTRY'),
                                    usernamePassword(credentialsId: 'DOCKER_REGISTRY_CRED',
                                    passwordVariable: 'DOCKER_REGISTRY_PASS',
                                    usernameVariable: 'DOCKER_REGISTRY_USER'
                                    )]) {
                                sh "./scripts/docker_run_image.sh ${DISTRO}"
                            }
                        }
                    }
                }
            }
        }
    }
}
