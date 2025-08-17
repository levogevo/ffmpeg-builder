pipeline {
    agent none
    environment { DEBUG = "1" }
    stages {
        stage('Build Docker Image') {
            matrix {
                axes {
                    axis {
                        name 'DISTRO'
                        values 'ubuntu-24.04',
                                'fedora-42',
                                'fedora-41',
                                'debian-13',
                                'archlinux-latest'
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
                }
            }
        }
    }
    stages {
        stage('Run Docker Image') {
            matrix {
                axes {
                    axis {
                        name 'DISTRO'
                        values 'ubuntu-24.04',
                                'fedora-42',
                                'fedora-41',
                                'debian-13',
                                'archlinux-latest'
                    }
                    axis {
                        name 'ARCH'
                        values 'arm64', 'amd64'
                    }
                    axis {
                        name 'STATIC'
                        values 'true', 'false'
                    }
                    axis {
                        name 'OPT_AND_LTO'
                        values 'OPT_LVL=0 LTO=false',
                                'OPT_LVL=2 LTO=false',
                                'OPT_LVL=3 LTO=true' 
                    }
                }
                stages {
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
                                sh "STATIC=${STATIC} ${OPT_AND_LTO} ./scripts/docker_run_image.sh ${DISTRO}"
                            }
                        }
                    }
                }
            }
        }
    }
}
