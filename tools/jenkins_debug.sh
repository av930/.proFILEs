#!/bin/bash -ex
echo "[$0]: PID[$$] PPID[$PPID] UID[$UID]"

echo "########### DEBUG information ###################

this project is executed in : NODE_LABELS[$NODE_LABELS] NODE_NAME[$NODE_NAME]
project environment variable: ${JOB_URL}$BUILD_ID/injectedEnvVars
system environment info: ${JENKINS_URL}systemInfo
system environment configure: ${JENKINS_URL}configure
"
cp $1 $(pwd)/${JOB_NAME%%/*}_${BUILD_CAUSE}.sh

