pipeline {
    agent none
    stages {
        stage('Build Matrix') {
            matrix {
                agent { label "linux" }
                axes {
                    axis {
                        name 'DISTRO'
                        values 'debian', 'ubuntu', 'archlinux', 'fedora'
                    }
                }
                stages {
                    stage('Build') {
                        steps {
                            echo "Do Build for ${DISTRO}"
                        }
                    }
                }
            }
        }
    }
}
