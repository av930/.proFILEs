#!/bin/bash
# Jenkins 서버에서 job의 Shell 스크립트를 다운로드해 기존 파일과 비교한 후
# 필요시 로컬 파일을 업데이트한다.
set -euo pipefail

# Jenkins XML에서 추출한 Shell 스크립트를 검증해 복사 필요 여부를 반환한다.
getscript_fromXML() {
    local job=$1 jenkins=$2

    # Jenkins 서버 이름에 따라 인증 키를 선택한다.
    case ${jenkins} in
    *jenkins01*) _JENKINS_KEY=${JENKINS01_VCINTEGRATOR_KEY};;
    *jenkins02*) _JENKINS_KEY=${JENKINS02_VCINTEGRATOR_KEY};;
    *jenkins03*) _JENKINS_KEY=${JENKINS03_VCINTEGRATOR_KEY};;
    *jenkins04*) _JENKINS_KEY=${JENKINS04_VCINTEGRATOR_KEY};;
    *jenkins05*) _JENKINS_KEY=${JENKINS05_VCINTEGRATOR_KEY};;
    *jenkins06*) _JENKINS_KEY=${JENKINS06_VCINTEGRATOR_KEY};;
              *) echo "error: you need to put jenkins-server" && exit 1;;
    esac
    _JENKINS_URL=http://vjenkins.lge.com/${jenkins}/

    # Jenkins CLI로 job XML을 가져와 Shell 스크립트만 추출한다.
    [[ ! -f jenkins-cli.jar ]] && wget -q ${_JENKINS_URL}/jnlpJars/jenkins-cli.jar
    java -jar jenkins-cli.jar -s ${_JENKINS_URL} -auth vc.integrator:${_JENKINS_KEY} \
        get-job ${job} | xmllint --nowarning --xpath string\("//hudson.tasks.Shell"\) - > ${SRC_FILE}

    # 추출 스크립트 검증: 문법 오류, 최소 라인 수, 기존 파일 동일성 확인
    bash -n ${SRC_FILE} || { echo "[no-copy] script has a error"; return 1; }
    (( $(cat ${SRC_FILE} | wc -l) >= 10 )) || { echo "[no-copy] new script is too small, ignore"; return 1; }
    diff -s ${SRC_FILE} ${DST_FILE} > /dev/null && { echo "[no-copy] file is same"; return 1; }

    # 모든 검증 통과 - 복사 준비
    echo "ok.must copy";   return 0
}

# URL에서 스크립트를 내려받아 임시 파일 경로를 반환한다.
getscript_fromURL() {
    local url=$1 output
    output=$(mktemp)
    wget -q ${url} -O $output
    echo ${output}
}

# 메인: Jenkins에서 새 스크립트를 다운로드하고 필요시 로컬 파일 업데이트
readonly BASE_SCRIPT=${JOB_BASE_NAME}
SRC_FILE=$(mktemp)
DST_FILE=${BASE_SCRIPT}.sh

if get_script ${BASE_SCRIPT} jenkins06; then
    echo "copy"; cp -vf ${SRC_FILE} ${DST_FILE}
else
    echo "use legacy file"
fi

[[ $? -eq 0 ]] && return 0 || { echo "ERROR"; exit 1; }


