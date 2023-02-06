######## common handler
#### common env
#VGIT_PORT=${VGIT_PORT:?must_set_port}

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
     "description":"@@ is building now @@" }
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

