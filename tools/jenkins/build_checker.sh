######## common handler
#### common env
TARGET_PROJECT=${TARGET_PROJECT:?must_set_project}
MASTER_BRANCH=${MASTER_BRANCH:?must_set_branch}

line="-----------------------------------------------------------------------------------------------"
echobar() { printf "\e[1;36m%s%s \e[0m\n\n" "${1:+[$1] }" "${line:(${1:+3}+${#1})}" ;}

## APIKEY for $USER
APIKEY=REMOVE_KEY

function updateinfo_beforebuild(){
## make build info to json 
    cat <<EOL >temp.json
    {"displayName":"##[${BUILD_ID}] ${GERRIT_PATCHSET_UPLOADER} \n\
        [${NODE_NAME}]                                          \n\
        ${PATH_SRC}                                             \n\
        [${GERRIT_BRANCH}]                                      \n\
        ${GERRIT_PROJECT}",
     "description":"@@ ${TARGET_PROJECT} is building now @@" }
EOL

## change build name & description with encoding
    curl -u $USER:$APIKEY --silent ${JOB_URL}${BUILD_ID}/configSubmit --data-urlencode json@temp.json
}


function updateinfo_afterbuild(){
## make build info to json 
    case $1 in
        HUP|INT|QUIT|TERM) echo "[ERROR: sig=%1] reason of error must be defined" && ret="[FATAL]_check_SIGNAL";;
        ERR | EXIT) echo "[signal: sig=%1] is happened";;
        *) echo "[ERROR: sig=%1] severe error occurred" && ret="[FATAL]_check_SIGNAL";;
    esac

    cat <<EOL >temp.json
    {"displayName":"###[${BUILD_ID}] ${GERRIT_PATCHSET_UPLOADER}                           \n\
        [${GERRIT_BRANCH}]                                                                 \n\
        ${GERRIT_PROJECT}",
    "description":"<PRE>      @@@ build info [$(date +"%y%m%d:%H:%M")] finished @@@        \n\
        server node: ${NODE_NAME}                                                          \n\
        server path: ${PATH_SRC}                                                           \n\
        commit owner: ${GERRIT_PATCHSET_UPLOADER_EMAIL}                                    \n\
        git branch: ${GERRIT_BRANCH}                                                       \n\
        git project: ${GERRIT_PROJECT}                                                     \n\
        source path: ${PATH_BUILD:-NotApplicable}                                          \n\
        commit patchset: ${GERRIT_PATCHSET_REVISION::7}                                    \n\
        exit command: [line $2]${ECMD}                                                     \n\
        build result: [sig=$1:exit=$3] ${ret}                                              \n\
        </PRE>                                                                             \n\
        <H3><a href=\"${JOB_URL}/${BUILD_ID}/consoleText\"    >>>  open build log</a><BR>  \n\
        <a href=\"${JOB_URL}/${BUILD_ID}/checkResult\"    >>>  check build error</a></H3>"
    }
EOL
    curl -u $USER:$APIKEY --silent ${JOB_URL}${BUILD_ID}/configSubmit --data-urlencode json@temp.json
}


function exit_handler(){
## exit handler for build name/description
if [ "$func_called" = "true" ]; then echo "already called" && exit 1; else export func_called=true;  fi

    local sig=$1 && local line=$2 && local exitcode=$3
    ECMD=$(eval echo ${BASH_COMMAND})
    BUILD_ID=${BUILD_JENKINS_ID:=${BUILD_ID}}

    #set +x
    case $exitcode in
          0)  echobar ${ret:="[success]_build_PASS"} ;;
          *)  if [[ "${ECMD}" =~ "sc-infra/script" ]];
              then echobar ${ret:="[failed]_CheckGerrit_FAIL"}
              else echobar ${ret:="[failed]_CheckBuild_FAIL"}
              fi
              echo "[ERROR]: file: $BASH_SOURCE line: $BASH_LINENO calls $FUNCNAME: [$line: ${ECMD}]"
              ;;
    esac

    ## make build info to json
    updateinfo_afterbuild $sig $line $exitcode

    if [ "$exitcode" -ne 0 ]; then echo "$exitcode" && exitcode=1; fi
    exit $exitcode
}


######## common build checker
function makedir_downscript(){
#### preproces before build
    updateinfo_beforebuild &
    
# create build root
    mkdir -p ${PATH_JOB} > /dev/null && cd $PATH_JOB 
# Kill all process using PATH_SRC
    eval sudo fuser -kuv "${PATH_JOB}/${DIR_PREFIX}*" || true
# remove legacy directories
    rm -rf "${PATH_JOB}/${DIR_PREFIX}"* || true

## get integration script and update every 12 hours
    local diff=1
    if [ -f ${PATH_SCRIPT}/.git/FETCH_HEAD ]; then diff=$(( (($(date +%s) - $(stat -c %Y ${PATH_SCRIPT}/.git/FETCH_HEAD) )) / ((12 * 3600)) ));fi
    if (( $diff > 0 )); then ## older than 12 hours 
        curl --silent ${SCINFRA_GIT_DEPLOY_SERVER}:8124/app/${SCINFRA_GIT_SETUP_PY} > ${SCINFRA_GIT_SETUP_PY} && chmod 755 ${SCINFRA_GIT_SETUP_PY}
        python3 ${SCINFRA_GIT_SETUP_PY} --git-path ${PATH_SCRIPT} --branch ${SC_INFRA_BRANCH} --host ${SCINFRA_GIT_HOST} --port ${SCINFRA_GIT_PORT} --mirror-path ${PATH_MIRROR}/sc-infra
    fi
}


function downrepo_applycommit(){
#### repo init get manifests & check validation
    echobar "$(pwd): download src and apply patches"
    mkdir -p "${PATH_SRC}" 

    if [ "$1" = "repo" ]; then 
        echo "\$ $@"; time "$@" ;
    else
        cd ${PATH_MIRROR}
        time pax -rwl src ${PATH_SRC%/*}
    fi
    cd ${PATH_SRC}

## check commit whether included in manifests by project 
    repo list -p ${GERRIT_PROJECT} 2>&1 |sed 's/.*(\(.*\)).*/\1/'
    PATH_BUILD=$(repo list -p ${GERRIT_PROJECT} 2>&1 |sed 's/.*(\(.*\)).*/\1/') ||true
    if [[ "${PATH_BUILD}" =~ "error:" ]]; then ret="[FATAL]_checktrigger_JENKINS" && exit 0; fi
    if ! [[ "${PATH_BUILD}" =~ "nad" || "${PATH_BUILD}" =~ "mcu" ]]; then ret="[FATAL]_checksrc_GIT" && exit 0; fi

## check commit whether included in manifests both by project and branch
    BUILD_JUDGE=$(python3 -u ${PATH_SCRIPT}/script/pre_check_git_in_manifest.py -m default.xml -n ${GERRIT_PROJECT} -b ${GERRIT_BRANCH})
    if [ "${BUILD_JUDGE}" == "SKIP" ]; then
        echo "${GERRIT_BRANCH} branch of ${GERRIT_PROJECT} is not in the repo!!"
        echo "[FATAL] must not be here!"
        ret="[FATAL]_checksrc_BRANCH"
        exit 
    fi
    
#### get source from mirror
    time repo sync -qcj4 --no-tags
    repo start ${MASTER_BRANCH} --all
    
    
#### apply commit 
#python ${PATH_SCRIPT}/script/apply_change.py -d F -p ${TARGET_PROJECT}
    if [ "$BUILD_CAUSE" != "MANUALTRIGGER" ]; then 
        python3 ${PATH_SCRIPT}/script/apply_change_mg.py -p ${TARGET_PROJECT} -l ${GERRIT_CHANGE_URL} -n ${GERRIT_PATCHSET_NUMBER} -r ${GERRIT_PATCHSET_REVISION} -s $(pwd) -d True
    fi
}


#### set exit trap
trap 'exit_handler ERR $LINENO $?' ERR
trap 'exit_handler HUP $LINENO $?' HUP
trap 'exit_handler INT $LINENO $?' INT
trap 'exit_handler QUIT $LINENO $?' QUIT
trap 'exit_handler TERM $LINENO $?' TERM
trap 'exit_handler EXIT $LINENO $?' EXIT

## error, xtrace, TRAP, pipe
set -exEo pipefail

