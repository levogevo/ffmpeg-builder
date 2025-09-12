def withDockerCreds(body) {
    withCredentials([
        string(credentialsId: 'DOCKER_REGISTRY', variable: 'DOCKER_REGISTRY'),
        usernamePassword(
            credentialsId: 'DOCKER_REGISTRY_CRED',
            passwordVariable: 'DOCKER_REGISTRY_PASS',
            usernameVariable: 'DOCKER_REGISTRY_USER'
        )
    ]) {
        body()
    }
}

pipeline {
    agent none
    environment { DEBUG = "1" }
    stages {
        stage('build docker image') {
            matrix {
                axes {
                    axis { name 'DISTRO'; values 'ubuntu', 'fedora', 'debian', 'archlinux' }
                }
                stages {
                    stage('build multiarch image') {
                        agent { label "linux && amd64" }
                        steps {
                            withDockerCreds {
                                sh "./scripts/docker_build_multiarch_image.sh ${DISTRO}"
                            }
                        }
                    }
                }
            }
        }
        stage('build ffmpeg on darwin') {
            matrix {
                axes {
                    axis { name 'OPT_LTO'; values 'OPT=0 LTO=OFF', 'OPT=3 LTO=ON' }
                    axis { name 'STATIC'; values 'ON', 'OFF' }
                }
                stages {
                    stage('build on darwin ') {
                        agent { label "darwin" }
                        steps {
                            sh "${OPT_LTO} ./scripts/build.sh"
                        }
                    }
                }
            }
        }
        stage('build ffmpeg on linux') {
            matrix {
                axes {
                    axis { name 'ARCH'; values 'armv8-a', 'x86-64-v3' }
                    axis { name 'DISTRO'; values 'ubuntu', 'fedora', 'debian', 'archlinux' }
                    axis { name 'OPT_LTO'; values 'OPT=0 LTO=OFF', 'OPT=3 LTO=ON' }
                    axis { name 'STATIC'; values 'ON', 'OFF' }
                }
                stages {
                    stage('build ffmpeg on linux using docker') {
                        agent { label "linux && ${ARCH}" }
                        steps {
                            withDockerCreds {
                                sh "${OPT_LTO} ./scripts/build_with_docker.sh ${DISTRO}"
                            }
                        }
                    }
                }
            }
        }
    }
}
