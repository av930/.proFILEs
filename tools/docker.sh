#!/bin/bash

function generate_dockerfile(){
cat <<-'EOF' > Dockerfile
#syntax=docker/dockerfile:1
############################################## This file is run as ROOT
#### Baseline Ubuntu 22.04
FROM ubuntu:22.04 AS base_ubuntu
LABEL maintainer="joongkeun.kim@lge.com"
LABEL version="v2.chm1"


#### no more use debconf from here
#### ban message "delaying package configuration ~~~"
ENV DEBCONF_NOWARNINGS=yes
## C.UTF-8: korean input is valid, but msg is printed by ENG
## initially only C.UTF-8 is available
ENV LC_ALL=C.UTF-8 \
    TERM=xterm-256color \
    TZ=Asia/Seoul
## compiler memory & encoding
ENV _JAVA_OPTIONS="-Xms16g -Xmx32g -XX:MetaspaceSize=512m -XX:MaxMetaspaceSize=512m -Dfile.encoding=UTF-8"

############################################## This file is run as ROOT
## /bin, /sbin, /usr/bin is private, /usr/local/bin shared
############################################## Package Installer Update
## for condition usage:
## EXTRA="--build-arg arg=20" DOC=Dockerfile run.sh start proj.cntr 7000 proj.img
ARG arg
############################################## clean & update apt-repository

#echo "---------------------- This code run $arg"
RUN <<EOT bash
if [ -z "$arg" ]; then
    PS4='\n\e[32m\h:\s:\u[\w]>>>>\e[0m \$ '; set -ex
    echo "#### set repository for package installation"
    apt-get update -y
    apt-get upgrade -y
    apt-get install software-properties-common -y
    add-apt-repository -y ppa:openjdk-r/ppa
##
############################################## Basic tool for development
############################################## Language & Locale setting
    DEBIAN_FRONTEND=noninteractive \
    apt-get -y install tzdata locales-all language-pack-en language-pack-ko
    ln -snf /usr/share/zoneinfo/$TZ /etc/localtime
    echo $TZ > /etc/timezone
##
############################################## Basic utilities
    echo "#### basic utilites"
    apt-get install -y sudo ssh wget make vim git curl cpio unzip psmisc sshpass zip rsync      \
        htop tree net-tools bash-completion gawk pigz screen pax ncftp repo autoconf automake   \
        bc bison bsdiff build-essential diffstat file flex gperf help2man iputils-ping socat    \
        srecord subversion sudo swig tar texi2html texinfo tig udev uuid-dev xterm xxd xz-utils \
        zlib1g-dev zstd g++ cmake cppcheck gcc gcc-multilib jq
##
############################################## JAVA for jenkins interface
    apt-get install -y openjdk-8-jdk
##
############################################## DevOps Tools
    apt-get install -y python3.10 python3-pip
    pip3 install requests pymysql xlwt xlsxwriter plotly pygerrit2 pexpect
    curl -fL https://getcli.jfrog.io | bash -s v2
    sudo mv ./jfrog /usr/bin/jfrog
##
############################################## Install git LFS
    curl -s https://packagecloud.io/install/repositories/github/git-lfs/script.deb.sh | bash
    apt-get install git-lfs && git lfs install
    git init --bare /tmp/tmp-git && cd /tmp/tmp-git && git lfs env && cd && rm -rf /tmp/tmp-git
##
############################################## Android Essentials
############################################## android build
#    apt-get -y install git-core gnupg flex bison build-essential zip curl                \
#       zlib1g-dev libc6-dev-i386 libncurses5 lib32ncurses5-dev                           \
#       x11proto-core-dev libx11-dev lib32z1-dev libgl1-mesa-dev libxml2-utils            \
#       xsltproc unzip fontconfig
##
############################################## Kernel build
    apt-get -y install libssl-dev bc kmod
##
############################################## Yocto build
    apt-get -y install build-essential chrpath cpio debianutils diffstat file gawk gcc git \
        iputils-ping libacl1 liblz4-tool locales python3 python3-git python3-jinja2        \
        python3-pexpect python3-pip python3-subunit socat texinfo unzip wget xz-utils zstd
##
else echo "------------------------------- This code is not run [$arg]";fi
EOT

############################################## Project Specific
##
############################################## Chipset Compiler
#Install python & chipset compiler
RUN <<EOT bash
    PS4='\n\e[32m\h:\s:\u>>>>>>>>[\w]\e[0m \$ '; set -ex

##
############################################## Cleaning download files
    echo "#### Dispose apt-repository"
    apt-get autoremove
    apt-get clean
    rm -rf /var/lib/apt/lists/*
    echo "#### [Warning] Must not install package after this line[condition]"
EOT


FROM base_ubuntu AS env_docker
##
############################################## Account Setting for managing
## this values are input from docker build
ARG UID
ARG GID
ARG UNAME
ARG HOME
##
############################################## vc.integrator
RUN <<EOT bash
    PS4='\n\e[32m\h:\s:\u>>>>>>>>[\w]\e[0m \$ '; set -ex
    mkdir -p $(dirname $HOME)
    groupadd -g $GID -o $UNAME
    useradd -m -u $UID -g $GID -o -s /bin/bash -d $HOME $UNAME
    usermod -aG sudo $UNAME
    echo "${UNAME} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
    ln -sf bash /bin/sh
##
############################################## Change prompt
#leading tab must be used from here
    cat <<-'SCRIPT' >$HOME/.bash_aliases
        PS1='\e[33;1m\u@\h:\e[31m\$PWD\e[0m \n$ '
        PS1SC='\e[33;1m\u@docker_d:\e[31m\$PWD\e[0m \n$ '
        export LC_ALL=en_US.UTF-8
        cd
SCRIPT
    chown ${UID}:${GID} $HOME/.bash_aliases
    echo "End of Docker Run"
##
############################################## run as vc.integrator after boot
############################################## DevOps RuntimeConfig
#leading tab must be used from here
    cat <<-'SCRIPT' >$HOME/post_handler.sh
        ## PREMIRROR and SSTATE CACHE setting
        #!/bin/bash -x
        sudo sysctl fs.inotify.max_user_watches=1000000
        ulimit -u unlimited
        [ -z "\$(git config --global --get-regexp user.name)" ] && { echo "run in HOST: git config --global user.name $UNAME"; exit 1; }
        [ -z "\$(git config --global --get-regexp color.ui)" ] && { echo "run in HOST: git config --global color.ui false"; exit 1; }

SCRIPT
    chown ${UID}:${GID} $HOME/post_handler.sh && chmod 755 $HOME/post_handler.sh
EOT
##
# account setting
#ENTRYPOINT service ssh restart && bash for openSSH

EOF
}


PATH_ARTI=10.158.4.241:8082
#$1: command, #$2: conatainer name, #$3: container port, #$4: image name
cntr_cmd=$1
cntr_name=$2
cntr_port=$3
cntr_img="${4:-${PATH_ARTI}/devops-docker/honda/30my/30my:latest}"

#user setting
if [ "${account}" == "" ]; then account=$USER && account_id=$(id -u ${account}); fi
home_dir="/data001/${account}"

function docker_run(){
    local cntr_img=$1
    local cntr_port=$2

    set -ex
    sudo -u ${account} mkdir -p ${home_dir}/Docker_MountDIR ${home_dir}/mirror ${home_dir}/.jfrog
    touch ${home_dir}/.ssh ${home_dir}/.profile ${home_dir}/.bashrc ${home_dir}/.gitconfig

    docker run                                                                  \
        -dit --init --privileged --cap-add=ALL --restart="always"               \
        --name ${cntr_img}_cntr                                                 \
        -u ${account_id}:${account_id}                                          \
        -p ${cntr_port}:22                                                      \
        -v /etc/group:/etc/group:ro                                             \
        -v /etc/passwd:/etc/passwd:ro                                           \
        -v /etc/shadow:/etc/shadow:ro                                           \
        -v /etc/timezone:/etc/timezone:ro                                       \
        -v /etc/localtime:/etc/localtime:ro                                     \
        -v /etc/ssh:/etc/ssh:ro                                                 \
        -v /usr/local/bin:/usr/local/bin:ro                                     \
        -v /usr/bin/git-lfs:/usr/bin/git-lfs:ro                                 \
        -v /lib/modules:/lib/modules:ro                                         \
        -v ${home_dir}/.profile:${home_dir}/.profile:rw                         \
        -v ${home_dir}/.bashrc:${home_dir}/.bashrc:rw                           \
        -v ${home_dir}/.gitconfig:${home_dir}/.gitconfig:rw                     \
        -v ${home_dir}/.ssh:${home_dir}/.ssh:rw                                 \
        -v ${home_dir}/.jfrog:${home_dir}/.jfrog:rw                             \
        -v ${home_dir}/mirror:${home_dir}/mirror:rw                             \
        -v ${home_dir}/Docker_MountDIR:${home_dir}/Docker_MountDIR:rw           \
        ${cntr_img} /bin/bash -c 'sudo service ssh start && /bin/bash'
    set +ex
    return 0
}

##  main command handler ##
set +ex
case ${cntr_cmd} in
        gen)    if [ -f Dockerfile ];then read -p "Dockerfile already existed [break:Ctrl+c | overwrite:Enter]: "; fi
                echo "Generate Dockerfile with current host account..."
                echo "If you want to modify it, edit "$(readlink -f "$0")":generate_dockerfile()"
                generate_dockerfile
    ;; build )  DOCKER_BUILDKIT=1 docker build --network=host --progress=plain \
                --build-arg UID=$(id -u) \
                --build-arg GID=$(id -g) \
                --build-arg UNAME=$(whoami) \
                --build-arg HOME=$(eval echo ~$(whoami)) \
                -f Dockerfile -t ${2,,} . "${@:3}" |& tee -a log.docker
                printf "docker build log is saved to ./log.docker\n"
    ;; start)   docker_run ${2,,} $3
    ;; pull)    docker login ${PATH_ARTI}/artifactory-devops-docker.jfrog.io
                echo "${PATH_ARTI}/devops-docker/honda/30my/30my:latest"
                docker pull ${PATH_ARTI}/devops-docker/honda/30my/30my:latest
    ;; stop)    docker ps; read -p "input container name to attach: "
                docker stop ${REPLY} ; docker rm -f ${REPLY}
    ;; exec)    docker ps; read -p "input container name to attach: "
                docker exec -w ${home_dir} -it ${REPLY} /bin/bash
    ;; *)   echo "./docker.sh gen                                   #generate Dockerfile"
            echo "./docker.sh build <image name>                    #build with Dockerfile <image name ex: $(date +%y%m%d)_Honda30my >"
            echo "./docker.sh start <image name> <container port>   #container name automatically be 'imagename_cntr'"
            echo "        ex: ./docker.sh start 30my 7100"
            echo "./docker.sh exec|stop                             #attach container"
            echo "./docker.sh pull  #get prebuilt image"
esac
