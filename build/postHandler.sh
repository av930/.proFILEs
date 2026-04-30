#!/bin/bash
##############################################################################
# build checker가 구동된후 그 결과로 post job을 구동합니다.
# 1. pass/fail에 대한 collect db
# 2. build log에 대한 error분석
# 3. success시 image 업로드및 삭제
# 4. 최종결과에 대한 reporting (gerrit comment, email전송)


##############################################################################
## 필수 환경 검사 (환경변수 및 파일 존재)
##############################################################################
if [ !  -f "/tmp/${BUILD_TAG}" ]; then
    cat <<-ADD_FILE >>/tmp/${BUILD_TAG}
    RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' BLUE='\033[0;34m' NC='\033[0m'
    line="------------------------------------------------------------------------------------------------------"
    bar() { printf "\n\n${!1}%s%s ${NC}\n" "${2:+[$2] }" "${line:(${2:+3}+${#2})}" ;}
    log() { echo -e "${!1} $2 ${NC}"; }
ADD_FILE
else
    echo -e "\033[0;31m [ERROR:STEP1] There is no build history info \033[0m"
    exit 1
fi
cat "/tmp/${BUILD_TAG}"



if grep -E "^(JOB_NAME=|BUILD_NUMBER=|GERRIT_BRANCH=|JOB_URL=)" "/tmp/${BUILD_TAG}";
then source "/tmp/${BUILD_TAG}"
else echo -e "\033[0;31m [ERROR:STEP2] There is not proper info \033[0m" "Variables not found" ; exit 1;
fi

