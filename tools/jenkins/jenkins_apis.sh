#!/bin/bash -e
######## common handler
#### common env
line="-----------------------------------------------------------------------------------------------"
bar() { printf "\e[1;36m%s%s \e[0m\n" "${1:+$1 }" "${line:(${1:+3}+${#1})}" ;}

#### common env
## this variable must be defined before calling, by "export variable"
JENKINS_URL=${JENKINS_URL:=http://vjenkins.lge.com/jenkins03/}
ACCOUNTnAPIKEY=${ACCOUNTnAPIKEY:=joongkeun.kim:REMOVE_KEY}

## default sample value
NAME_JOB=_SProject-MJ_DebugJenkins
NAME_NODE=_SNode_Private-10.159.44.211d
BUILD_ID=400

## user input
CMD=( $@ )
bar "INPUT: [${CMD[@]}]" ======================================================================

if [ "${CMD[1]}" = "help" ]; then
    case ${CMD[0]} in 
       comment)                     echo "jenkins api call example"
    ;; list-jobs| who-am-i|help)    SAMPLE="${CMD[0]}" 
    ;; get-job)                     SAMPLE="${CMD[0]} ${NAME_JOB} > config.xml"
    ;; update-job)                  SAMPLE="${CMD[0]} ${NAME_JOB} < config.xml"
    ;; build)                       SAMPLE="${CMD[0]} ${NAME_JOB}" 
    ;; set-build-display-name)      SAMPLE="${CMD[0]} ${NAME_JOB} ${BUILD_ID} title"
    ;; set-build-description)       SAMPLE="${CMD[0]} ${NAME_JOB} ${BUILD_ID} description" 
    ;; console)                     SAMPLE="${CMD[0]} ${NAME_JOB} ${BUILD_ID} > result.log"
    ;; delete-builds)               SAMPLE="${CMD[0]} ${NAME_JOB} 391-393"
    ;; get-node)                    SAMPLE="${CMD[0]} ${NAME_NODE} > config.xml"
    ;; create-node)                 SAMPLE="${CMD[0]} ${NAME_NODE} < config.xml"
    ;; connect-node)                SAMPLE="${CMD[0]} ${NAME_NODE}"
    ;; groovy| mail)                SAMPLE="${CMD[0]} sample.groovy"
    ;; *)                           SAMPLE="not supported, please see help" && exit 1; 
    ;;
    esac
    java -jar jenkins-cli.jar -s ${JENKINS_URL} -auth ${ACCOUNTnAPIKEY} help ${CMD[0]}
    bar "SAMPLE: [$0 ${SAMPLE}]"
    exit 1
fi

if [ ! -f jenkins-cli.jar ]; then wget -q ${JENKINS_URL}/jnlpJars/jenkins-cli.jar; fi 
eval "set -x; java -jar jenkins-cli.jar -s ${JENKINS_URL} -auth ${ACCOUNTnAPIKEY} ${CMD[@]}"