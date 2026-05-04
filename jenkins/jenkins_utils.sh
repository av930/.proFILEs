######## common handler
#### common env
#VGIT_PORT=${VGIT_PORT:?must_set_port}
#ARR_APIKEY for $USER must be defined in caller
DEBUG=#
#DEBUG="printf ${RED}%s${NCOL}\n"


line="-----------------------------------------------------------------------------------------------"
bar() { printf "\e[1;36m%s%s \e[0m\n\n" "${1:+[$1] }" "${line:(${1:+3}+${#1})}" ;}
exeTIME=0 && SECONDS=0
BUILD_JENKINS_ID=${BUILD_JENKINS_ID:=${BUILD_ID}}
BUILTIN_JOB_NAME=$(echo ${JOB_URL##*job/} |cut -d'/' -f1)
BUILTIN_BACKUP_FILE=/tmp/${BUILTIN_JOB_NAME}
BUILTIN_FILE_VARIABLE=/tmp/${BUILTIN_JOB_NAME}.var
BUILTIN_FILE_JOBINFO=/tmp/${BUILTIN_JOB_NAME}.job

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
    local SEP='='
    local i c 
    
    local input_data
    if [ -f "$1" ]; then 
        # 파일에서 모든 내용을 읽어옴
        input_data=$(cat "${1}")
    else
        # 변수에서 가져옴
        input_data="${!1}"
    fi
    
    # 공백으로 구분된 KEY=VALUE 형태를 줄바꿈으로 변환
    input_data=$(echo "$input_data" | sed 's/ \([A-Z_][A-Z_0-9]*=\)/\n\1/g')
    readarray -t ARR <<< "$input_data"
    
    ##print front|behind 
    i=0; for var in ${ARR[@]}; do printf "DEBUG_element[$((i++))] [${var}]\n";done

    #define variable with value (remove leading & trailing space)
    c=0; for var in ${ARR[@]%$SEP*}; do
        echo [var:${var}] [value:${ARR[$c]#*$SEP}]

        #declare $(echo ${var})="$(echo ${ARR[0]#*$SEP})"
	declare -g ${var}="$(eval echo ${ARR[$c]#*$SEP})"

        #echo "$var=$(echo ${ARR[$c]#*$SEP})"
        echo "## $var=${!var}"    
        ((c=c+1))
    done
}


function defineVariable_export(){
#----------------------------------------------------------------------------------------------------------
## ARR array로 부터 여러변수들을 file과 변수로 export한다
## VAR="value" 형태로 저장한다.
## usage: defineVariable_export <file-name>

    local outfile=${1:=${BUILTIN_FILE_VARIABLE}}

    #인자가 파일이면 해당파일에 '변수=값' 형식를 저장하고 출력해준다.
    if [ -f "$outfile" ]; then cat <<EOL >$outfile
$(for var in ${ARR[@]%%=*}; do printf "${var}=${!var}\n"; done)
EOL
    echo '##'; cat ${outfile}
    #변수이면 변수에 '변수=값' 형식으로 저장하고 출력해준다.
    else cat <<EOL
export $1="
$(echo $outfile)
"
EOL
    echo "##[${outfile}]"
    fi
}



function updateJob_makeText(){
#----------------------------------------------------------------------------------------------------------
## jenkins job을 update할 default json 파일을 만든다.
## $1: display name
## $2: description

    local display_name=$1
    local description=$2

    ## make build info to json
    cat <<EOL >${BUILTIN_FILE_JOBINFO}
    {"displayName":"##[${BUILD_JENKINS_ID}]                          \n\
        [${NODE_NAME}]                                          \n\
        [${exeTIME} sec]"                                       \n\
        ${display_name},
     "description":"<PRE>@@@ build info [$(date +"%y%m%d:%H:%M")] @@@    \n\
        </PRE>                                                           \n\
        ${description}                                                          \n\
        <H4><a href=\"${JOB_URL}/${BUILD_JENKINS_ID}/consoleText\"> >>>  open build log</a></H4>"
     }
EOL
        #/timestamps/?time=HH:mm:ss&timeZone=GMT+9&appendLog
}



function updateJob_updateInfo(){
#----------------------------------------------------------------------------------------------------------
## jenkins job의 build name과 description을 update한다.
## $1: API_KEY
## $3: timeflag (true/false)

    local API_KEY=$1
    local timeflag=$2

    if $timeflag ; then
        exeTIME=$(( exeTIME + SECONDS ))
        text=$( printf "${text} [%06d sec/%05d s] <BR>" "${exeTIME}" "${SECONDS}"  )
        SECONDS=0
    fi
    ## change build name & description with encoding
    if [ -s "$BUILTIN_FILE_JOBINFO" ] && [ -n ${BUILD_JENKINS_ID} ]; then
        curl -u $USER:$API_KEY --silent ${JOB_URL}${BUILD_JENKINS_ID}/configSubmit --data-urlencode json@$BUILTIN_FILE_JOBINFO
    fi
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
    ECMD=$(eval "echo ${BASH_COMMAND}")
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
