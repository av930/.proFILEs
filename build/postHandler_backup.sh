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
curl -X POST \
    -su "${USER}:${JENKINS06_KEY}" \
    -d "PARENT_JOB_NAME=${JOB_NAME}&PARENT_BUILD_NO=${BUILD_NUMBER}&BUILD_TYPE=C&PROJECT_ID=11091&BRANCH=${GERRIT_BRANCH}&PARENT_JOB_URL=${JOB_URL}" \
    "${JENKINS_URL}/job/dashboard_commit_build_data_collector/buildWithParameters" || true



##############################################################################
## 결과물 업로드 및 삭제
##############################################################################

## 업로드 (Artifactory)
##############################################################################
if grep -E "^(PATH_SRC=|PATH_OUT=|PATH_UPLOAD=|FILE_OUT=|RESULT=|URL_SERVER=)" "/tmp/${BUILD_TAG}";
then source "/tmp/${BUILD_TAG}"
else echo -e "\033[0;31m [ERROR:STEP3] There is not proper info \033[0m" "Variables not found" ; exit 1;
fi

mkdir -p ${PATH_OUT} > /dev/null
cd ${PATH_SRC}
zip -qr ${PATH_OUT}/${FILE_OUT} ${RESULT}
CI=true
timeout 120s jfrog rt upload --flat --threads=8 --user $USER --password ${PW_ARTI_118} --url=${URL_SERVER} ${PATH_OUT}/${FILE_OUT} ${PATH_UPLOAD} > /dev/null
[ $? -eq 124 ] && echo "The command timed out." || echo "The command completed."

#static trigger일때는 구동안함
msg="[Download] Commit Result from ${PATH_OUTIMG}/${PATH_UPLOAD}/${FILE_OUT} "
ssh -p ${GERRIT_PORT} vgit.lge.com gerrit review ${GERRIT_PATCHSET_REVISION} --message \'"$msg"\'



## 파일삭제 (5일마다 오전 8~9시 사이에 구동)
##############################################################################
[ "$(date +%H)" != "08" ] && exit 0
OLD=$(ls /tmp/${JOB_BASE_NAME}_* 2>/dev/null | head -1)
[ -n "$OLD" ] && [ $(( $(date +%s) - ${OLD##*_} )) -lt $((3600*24*5)) ] && exit 0
rm -f /tmp/${JOB_BASE_NAME}_*; touch "/tmp/${JOB_BASE_NAME}_$(date +%s)"

# 실행할 명령
CI=true
timeout 10s jfrog rt delete --quiet --user 'vc.integrator' --password ${PW_ARTI_118} --url=${URL_SERVER} honda-26my/$(sed 's/.$/*/' <<< $(date +%y%m%d -d "$TODAY -10 days"))





##############################################################################
## 에러 분석
##############################################################################


## python, git, repo, ssh등의 error검사
##############################################################################
set +xe  # 에러 무시 모드로 시작
mkdir -p /tmp/${JOB_BASE_NAME:=tmp} && cd "/tmp/${JOB_BASE_NAME}"

## 다운로드 스크립트 저장
script=AnalyzeGit ; tmp="$(mktemp)"
PATH_L=/data001/vc.integrator/.proFILEs/findError
PATH_R=https://raw.githubusercontent.com/av930/.proFILEs/master/findError
if [ ! -f "${PATH_L}/${script}" ];then
  wget -q ${PATH_R}/${script} -O $tmp && chmod 755 $tmp
  lines="$(wc -l < "$tmp" || echo 0)"
## 5줄이상이고 변경이 있을때만
  if [ "$lines" -gt 5 ]; then
    if [ ! -f "$script" ] || ! cmp -s "$tmp" "$script"; then mv $tmp $script ;fi
  fi
  PATH_SCRIPT=.
else
  PATH_SCRIPT=${PATH_L}
fi


## PARAM1 획득및 정보출력
PARAM1="${PARAM1:-${1}}"
# 앞뒤 공백/개행 제거 및 배열 변환
mapfile -t URL_LIST < <(echo "$PARAM1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr ' ' '\n' | grep -v '^$')

# URL 처리 결과 저장 (초기화 필수)
NUMOF_URLS=${#URL_LIST[@]}
SUCCESS_COUNT=0
ABORT_COUNT=0
FAILURE_COUNT=0

echo "Total URLs to process: ${NUMOF_URLS}"
echo "========================================"

# URL이 없으면 종료
[ "$NUMOF_URLS" -eq 0 ] && { echo "No valid URLs found in PARAM1"; exit 1; }

## 각 URL 처리
for index in "${!URL_LIST[@]}"; do
  URL="${URL_LIST[$index]%/}"  # 마지막 / 제거

  [ -z "$URL" ] && continue
  echo -e "\n[$((index+1))/${NUMOF_URLS}] ################################"

  # jenkins build url 검증 및 정규화 (view 경로 포함)
  if [[ $URL =~ ^(https?://[^/]+/jenkins[0-9]+/.*job/[^/]+/([0-9]+))(/.*)?$ ]]; then
    NORMALIZED_URL="${BASH_REMATCH[1]}"
  else
    echo "⚠️  Invalid Jenkins URL"
    echo "    Expected format: http://vjenkins.lge.com/jenkins##/.../job/JOB_NAME/BUILD_NUMBER"
    echo "    Received: $URL"
    ((FAILURE_COUNT++))
    continue
  fi

  # AnalyzeGit 실행 및 결과 처리 (서브쉘에서 실행하여 에러 격리)
  ( ${PATH_SCRIPT}/$script "$NORMALIZED_URL"  )
  EXIT_CODE=$?

  case $EXIT_CODE in
     0) result=SUCCESS; echo "✓ Analysis $result (FAILED job) ";              ((SUCCESS_COUNT++))
  ;; 2) result=NO_NEED; echo "✓ Analysis $result (SUCESS or ABORT job)";      ((ABORT_COUNT++))
  ;; 3) result=CONTINE; echo "✓ Analysis $result (Pass to next step)";        ((FAILURE_COUNT++))
  ;; *) result=FAILED;  echo "✗ Analysis $result (NeedTo Check: $EXIT_CODE)"; ((FAILURE_COUNT++))
  esac
  echo "----------------------------------------"
done

## 최종 결과 요약
echo ""
echo "========================================"
echo "Summary:"
echo "  Total:   ${NUMOF_URLS}"
echo "  Success: ${SUCCESS_COUNT}"
echo "  Aborted: ${ABORT_COUNT}"
echo "  Failed:  ${FAILURE_COUNT}"
echo "========================================"

## build description 변경
curl -sX POST -u $USER:$API_KEY ${JOB_URL}/$BUILD_NUMBER/configSubmit -F   \
   'json={"displayName":"'"${BUILD_NUMBER} ${result}"'", "description":"'"<A href=${JOB_URL}${BUILD_NUMBER}/console> >>>  open build log</A><BR><BR><A HREF=${PARAM1}> >>>  ${PARAM1} </A>"'"}' > /dev/null


#분석할 필요가 없거나 제대로 된경우 성공
if (( "$EXIT_CODE" == 0 )); then exit 0 ;
elif (( "$EXIT_CODE" == 2 )); then exit 0 ;
else exit 1 ;fi




##############################################################################
## RESULT REPORT
##############################################################################


## python, git, repo, ssh등의 error검사
##############################################################################

set -xeEo pipefail
line="---------------------------------------------------------------------------------------------------------------------------------"
bar() { printf "\e[1;36m%s%s \e[0m\n\n" "${1:+[$1] }" "${line:(${1:+3}+${#1})}" ;}
export LC_ALL=C.UTF-8

function gerrit_add_comment() {
curl -sS -u vc.integrator:$GERRIT_KEY -X POST --header 'Content-Type: application/json' \
           http://vgit.lge.com:${GERRIT_PORT}/a/changes/$GERRIT_CHANGE_ID/revisions/$GERRIT_PATCHSET_REVISION/review
           --data-raw '{ "message": "'"$1"'" }'
}

function send_warning_mail() {
    RECIPIENT="luan2.vo@lge.com"
    PROJECT="Honda_26my"
    curl -s -L http://vjenkins.lge.com/jenkins06/job/honda_26my__ci_buildchecker_prepare/ws/send_mail_warning_CM_script_failed.py | \
        python3 - "$RECIPIENT" "$PROJECT" "$JOB_NAME" "$BUILD_URL" "$ECMD"
}

bar "POSTBUILD error information"
echo "ECMD: ${ECMD}"
echo "EXITCODE: ${EXITCODE}"

case $ECMD in
*sc-infra/script*)
    echo "[SKIP] Check Gerrit Fail [SKIP]"
    ;;

*./build.sh*)
    bar "Check Build Fail from ./build.sh"
    mkdir -p ${PATH_OUT} >/dev/null

    CONSOLE_LOG_FILE="${PATH_OUT}/jenkins_console.log"
    curl -s "${BUILD_URL}consoleText" -o "${PATH_OUT}/jenkins_console.log"

    ERROR_LOG_FILES=$(grep -oP 'ERROR: Logfile of failure stored in: \K/.+' "${CONSOLE_LOG_FILE}" | sort -u)
    if [ -n "$ERROR_LOG_FILES" ]; then
        for filepath in ${ERROR_LOG_FILES}; do
            if [ -f "$filepath" ]; then
                subpath=$(echo "${filepath%/*}" | sed 's|^/||; s|/|_|g')
                mkdir -p "${PATH_OUT}/$subpath"
                cp "$filepath" "${PATH_OUT}/$subpath"
            else
                echo "[WARN] Missing: $filepath"
            fi
        done

        # Upload
        FILE_OUT=faillog_${GERRIT_CHANGE_NUMBER}_${GERRIT_PATCHSET_NUMBER}.zip
        cd "${PATH_OUT}"
        zip -qr "${PATH_OUT}/${FILE_OUT}" .
        timeout 120s jfrog rt upload --flat --threads=8 \
                --user 'vc.integrator' --password "${PW_ARTI_118}" \
                --url="${URL_SERVER}" \
                "${PATH_OUT}/${FILE_OUT}" "${PATH_UPLOAD}" || echo "[WARN] Upload failed or timed out."

        # Comment on open change
        MSG="[Download] Build-checker Failure logs from: ${PATH_OUTIMG}/${PATH_UPLOAD}${FILE_OUT}"
        #ssh -p "${GERRIT_PORT}" vgit.lge.com gerrit review "${GERRIT_PATCHSET_REVISION}" --message \'"$MSG"\'
        gerrit_add_comment "$MSG"
    else
        echo "[INFO] No Yocto error log files found."
    fi
    ;;
*)
    bar "CM script failed, send email warning to CM"
    send_warning_mail