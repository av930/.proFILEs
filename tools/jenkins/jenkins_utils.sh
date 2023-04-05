######## common handler
#### common env
#VGIT_PORT=${VGIT_PORT:?must_set_port}
#ARR_APIKEY for $USER must be defined in caller


line="-----------------------------------------------------------------------------------------------"
bar() { printf "\e[1;36m%s%s \e[0m\n\n" "${1:+[$1] }" "${line:(${1:+3}+${#1})}" ;}
exeTIME=0 && SECONDS=0


######## export & import variable
# Multi-line String Parameter
# ARR_FILE=/tmp/__reference__bench_aosp_build
# ARR_STEP=1.DOWNLOAD
# ARR_REMOVE=false
# ARR_APIKEY=REMOVE_KEY


function defineVariable_import(){
#----------------------------------------------------------------------------------------------------------
# 1.import multi-line string from file or variable
# 2.define variable 
   ## define variables
    declare -g BUILTIN_JOB_NAME=$(echo ${JOB_URL##*job/} |cut -d'/' -f1)
    declare -g BUILTIN_BACKUP_FILE=/tmp/${BUILTIN_JOB_NAME}
    local SEP='='
    local i c 
    
    if [ -f "$1" ]; then 
        readarray -t ARR < "${1}"
    else
        readarray -t ARR <<< "${!1}"
    fi 
    
    ##print front|behind 
    i=0; for var in ${ARR[@]}; do printf "DEBUG_element[$((i++))] [${var}]\n";done

    #define variable with value (remove leading & trailing space)
    c=0; for var in ${ARR[@]%$SEP*}; do
        echo [var:${var}] [value:${ARR[$c]##*$SEP}]

        #declare $(echo ${var})="$(echo ${ARR[0]##*$SEP})"
	declare -g ${var}="$(eval echo ${ARR[$c]##*$SEP})"

        #echo "$var=$(echo ${ARR[$c]##*$SEP})"
        echo "## $var=${!var}"    
        ((c=c+1))
    done
}


function defineVariable_export(){
#----------------------------------------------------------------------------------------------------------
# 1.export multi variables in file 

    local outfile=${1:=${BUILTIN_BACKUP_FILE}}

    cat <<EOL >$outfile
$(for var in ${ARR[@]%%=*}; do printf "${var}=${!var}\n"; done)
EOL

    cat <<EOL >${outfile}.param
$1="
$(cat $outfile)
"
EOL
    echo DEBUG_outfile[${outfile}]
}



function updateInfo_job(){
#----------------------------------------------------------------------------------------------------------
#$1: API_KEY
#$2: SUBJECT

    declare -g text
    
    exeTIME=$(( exeTIME + SECONDS ))
    #text="${text}>>${exeTIME}s:${2}<BR>"
    text=$( printf "${text} [%06d sec/%05d s] %s<BR>" "${exeTIME}" "${SECONDS}" "$2" )

    ## make build info to json 

    if ! [ -f "$2" ]; then 
    cat <<EOL >temp.json
    {"displayName":"##[${BUILD_JENKINS_ID} $2]                          \n\
        [${NODE_NAME}]                                          \n\
        ${PATH_SRC}                                             \n\
        [${exeTIME} sec]",
     "description":"<PRE>    @@@ build info [$(date +"%y%m%d:%H:%M")] @@@    \n\
        </PRE>                                                               \n\
        ${text}                                                              \n\
        <H3><a href=\"${JOB_URL}/${BUILD_JENKINS_ID}/consoleText\"> >>>  open build log</a></H3>"
     }
EOL
    fi

    ## change build name & description with encoding
    if [ -s temp.json ] || [ -n ${BUILD_JENKINS_ID} ]; then 
        curl -u $USER:$1 --silent ${JOB_URL}${BUILD_JENKINS_ID}/configSubmit --data-urlencode json@temp.json
    fi 
    SECONDS=0
}


function updateInfo_result(){
#----------------------------------------------------------------------------------------------------------
    exeTIME=$(( exeTIME + SECONDS ))
## make build info to json 
    cat <<EOL >temp.json
    {"displayName":"##[${BUILD_JENKINS_ID} $2]                          \n\
        [${NODE_NAME}]                                          \n\
        ${PATH_SRC}                                             \n\
        [${exeTIME} sec]",
     "description":"<PRE>    @@@ build info [$(date +"%y%m%d:%H:%M")] finished @@@       \n\
        server node: ${NODE_NAME}                                                          \n\
        server path: ${PATH_SRC}                                                           \n\
        command: [line $2]${ECMD}                                                     \n\
        build result: [sig=$1:exit=$3] ${ret}                                              \n\
        </PRE>                                                                             \n\
        <H3><a href=\"${JOB_URL}/${BUILD_JENKINS_ID}/consoleText\"> >>>  open build log</a><BR>  \n\
        <a href=\"${JOB_URL}/${BUILD_JENKINS_ID}/checkResult\"> >>>  check build error</a></H3>"
     }
EOL

## change build name & description with encoding
    if [ -s temp.json ] || [ -n ${BUILD_JENKINS_ID} ]; then 
        curl -u $USER:$ARR_APIKEY --silent ${JOB_URL}${BUILD_JENKINS_ID}/configSubmit --data-urlencode json@temp.json
    fi
    SECONDS=0
}



######## register exit_handler
# example call
# register_trap updateInfo_result ERR HUP INT QUIT TERM EXIT
# updateInfo_job 

function updateInfo_commit(){
#----------------------------------------------------------------------------------------------------------
    cat <<EOL >temp.json
    {"displayName":"###[${BUILD_JENKINS_ID}] ${GERRIT_PATCHSET_UPLOADER}                           \n\
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
        <H3><a href=\"${JOB_URL}/${BUILD_JENKINS_ID}/consoleText\"> >>>  open build log</a><BR>  \n\
        <a href=\"${JOB_URL}/${BUILD_JENKINS_ID}/checkResult\"> >>>  check build error</a></H3>"
    }
EOL
    
    if [ -s temp.json ] || [ -n ${BUILD_JENKINS_ID} ]; then 
        curl -u $USER:$ARR_APIKEY --silent ${JOB_URL}${BUILD_JENKINS_ID}/configSubmit --data-urlencode json@temp.json
    fi
    SECONDS=0
}


function exit_handler(){
#----------------------------------------------------------------------------------------------------------
## exit handler for build name/description
echo "exit_handler @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@"
if [ "$func_called" = "true" ]; then echo "already called" && exit 1; else export func_called=true;  fi

    local func=$1 && local sig=$2 && local line=$3 && local exitcode=$4
    echo "[sig=$sig, line="$line", exitcode=$exitcode ]"    
    ECMD=$(eval echo ${BASH_COMMAND})
    BUILD_JENKINS_ID=${BUILD_JENKINS_ID:=${BUILD_JENKINS_ID}}

    #set +x
    case $exitcode in
          0)  bar ${ret:="[success]_PASS_all"} ;;
          *)  if [[ "${ECMD}" =~ "sc-infra/script" ]];
              then bar ${ret:="[failed]_FAIL_infra"}
              else bar ${ret:="[failed]_FAIL_process"}
              fi
              echo "[ERROR]: file: $BASH_SOURCE line: $BASH_LINENO calls $FUNCNAME: [$line: ${ECMD}]"
              ;;
    esac

    
    ## make build info to json 
    case $sig in
        ERR|HUP|INT|QUIT|TERM) echo "non-normal err" && ret="[FATAL]_check_SIGNAL";;
        EXIT) echo "normal exit is happened";;
        *) echo "severe error occurred" && ret="[FATAL]_check_SIGNAL";;
    esac
    #replace function to printout
    $func ${@:2}

    if [ "$exitcode" -ne 0 ]; then echo "$exitcode" && exitcode=1; fi
    exit $exitcode
}



function register_trap(){
#----------------------------------------------------------------------------------------------------------
    for sig in ${@:2}; do
    #### set exit trap
        trap "exit_handler $1 $sig $LINENO $?" $sig
    done


    ## error, xtrace, TRAP, pipe
    set -exEo pipefail
}
