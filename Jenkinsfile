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
    environment {
        DEBUG = "1"
        HEADLESS = "1"    
    }
    options { buildDiscarder logRotator(numToKeepStr: '4') }
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
                    axis { 
                        name 'COMP_OPTS'; 
                        values 'OPT=0 LTO=OFF STATIC=OFF', 'OPT=2 LTO=OFF STATIC=ON', 'OPT=3 LTO=ON STATIC=ON PGO=ON'
                    }
                }
                stages {
                    stage('build on darwin ') {
                        agent { label "darwin" }
                        steps {
                            sh "${COMP_OPTS} ./scripts/build.sh"
                            archiveArtifacts allowEmptyArchive: true, artifacts: 'gitignore/package/*.tar.xz', defaultExcludes: false
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
                    axis { 
                        name 'COMP_OPTS'; 
                        values 'OPT=0 LTO=OFF STATIC=OFF', 'OPT=2 LTO=OFF STATIC=ON', 'OPT=3 LTO=ON STATIC=ON PGO=ON'
                    }
                }
                stages {
                    stage('build ffmpeg on linux using docker') {
                        agent { label "linux && ${ARCH}" }
                        steps {
                            withDockerCreds {
                                sh "${COMP_OPTS} ./scripts/build_with_docker.sh ${DISTRO}"
                                archiveArtifacts allowEmptyArchive: true, artifacts: 'gitignore/package/*.tar.xz', defaultExcludes: false
                            }
                        }
                    }
                }
            }
        }
    }
}
