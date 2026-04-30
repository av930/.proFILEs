#!/bin/bash -e

: ' #구조설명
호출방법 AnalyzeGit <jenkins buildlog url>
exit 0:분석완료, 1:분석불가, 2:분석필요없음, 3:분석필요하나 분석못함

먼저, 빌드로그 다운로드 (타임스탬프 포함)
Step 0: 빌드 최종 상태 출력 (SUCCESS/FAILURE/ABORTED/UNSTABLE)
  SUCCESS면 분석 종료
  ABORTED인 경우 중단 원인 추가 확인
Step 1: 에러명령에 대한 카테고리 분류
  Python(sc-infra/script/)경우 (세부 error 카테고리 분류):
    GERRIT_ABANDONED, GERRIT_WIP, GERRIT_NEGATIVE_REVIEW, GERRIT_CONFLICT, GERRIT_OUTDATED, GERRIT_PATCHSET_NOT_FOUND
    SSH_CONNECTION_FAILED, SSH_PERMISSION, INCORRECT_GIT_ADDRESS, GIT_REPO_ERROR, TIMEOUT, UNKNOWN
  Non-Python 경우:
    GIT_REPO_ERROR, SSH_PERMISSION, TIMEOUT, UNKNOWN
Step 2: Commit 정보 추출
  Gerrit change URL 추출 (http://vgit.lge.com/.../+/[번호])
  Commit Status(ABANDONED 여부), Project, Branch 정보획득
Step 3: 실제 error가 난 line 출력
  에러 메시지 상세 내용 표시 (최대 15줄)
Step 4: 주변 error log 출력
  ERROR발생주변 컨텍스트 표시 (전 5줄, 후 10줄)
  실패 지점을 빨간색으로 하이라이트
후처리
  미검출 에러는 별도 로그 파일에 기록
  빌드로그 파일 삭제
'

# 터미널 색상 정의, URL 파라미터 정리 (공백제거, 마지막 / 제거)
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' BLUE='\033[0;34m' NC='\033[0m'
line="------------------------------------------------------------------------------------------------------"
bar() { printf "\n\n${!1}%s%s ${NC}\n" "${2:+[$2] }" "${line:(${2:+3}+${#2})}" ;}
log() { echo -e "${!1} $2 ${NC}"; }

PARAM1="${1}"
PARAM1="${PARAM1%/}"


# Jenkins 서버 URL 검증
[ -z "${PARAM1}" ] && { log RED "Error: URL required"; exit 1; }
[[ "${PARAM1}" =~ ^https?://[^/]+/(jenkins[0-9]+)/.*job/.*/[0-9]+$ ]] || log RED "Invalid URL format"


# 빌드 번호 추출
[[ ${PARAM1} =~ /([0-9]+)/?$ ]] && BUILD_NUMBER="${BASH_REMATCH[1]}" || { log RED "Cannot extract build number"; exit 1; }

## 빌드 로그 다운로드 (타임스탬프 포함)
LOG_FILE="/tmp/console_${BUILD_NUMBER}.txt"
log BLUE "Processing: ${PARAM1}/console"
wget --no-check-certificate -q -O "${LOG_FILE}" "${PARAM1}/timestamps/?time=HH:mm:ss&timeZone=GMT+9&appendLog" || { bar RED "Download failed"; exit 1; }
[ -s "${LOG_FILE}" ] || { bar RED "Empty log"; exit 1; }
log GREEN "Downloaded $(wc -l < "${LOG_FILE}" | tr -d ' ') lines"

log BLUE "========================================\nGit/Gerrit/Repo Build Error Analysis\n========================================"


## Step 0: 빌드 결과 출력 (SUCCESS면 분석 불필요)
bar YELLOW "Step 0: Build result"
# Jenkins API를 통해 빌드 결과 가져오기
BUILD_RESULT=$(curl -s -k "${PARAM1}/api/json" | grep -oP '"result":\s*"\K[^"]+' || echo "UNKNOWN")
echo "Status: ${BUILD_RESULT}"

# SUCCESS면 분석 종료
[[ "${BUILD_RESULT}" =~ SUCCESS ]] && { bar GREEN "Success - no analysis"; rm -f "${LOG_FILE}"; exit 2; }

# ABORTED 원인 확인 및 조기 종료
if [[ "${BUILD_RESULT}" =~ ABORTED ]]; then
    ABORT_REASON=$(grep -E "(timed out|Aborted by user|Terminated|Killed)" "${LOG_FILE}" | tail -1)
    [ -n "${ABORT_REASON}" ] && log YELLOW "Abort reason: ${ABORT_REASON}"
    bar YELLOW "Build was aborted - no error analysis needed"
    rm -f "${LOG_FILE}"
    exit 2
fi

log RED "Failed"


## Step 1: Error Classification
bar YELLOW "Step 1: Root Cause Analysis"

# 근본 원인 판별: Python 스크립트 실패 여부 확인
PYTHON_SCRIPT=$(grep -oE "sc-infra/script/[^/]+\.py" "${LOG_FILE}" | head -1)
UNDETECTED_FLAG=0

if [ -n "${PYTHON_SCRIPT}" ]; then
    # 대분류: Python Script Error
    log YELLOW "Root Cause: Python Script Failure"
    echo "  Script: ${PYTHON_SCRIPT}"

    # 소분류: 에러 메시지 기반 카테고리
    ERROR_CATEGORY="UNKNOWN"
    if grep -q "status.*abandoned" "${LOG_FILE}"; then
        ERROR_CATEGORY="GERRIT_ABANDONED"
    elif grep -q "It does not need to verify" "${LOG_FILE}"; then
        ERROR_CATEGORY="GERRIT_MERGED"
    elif grep -q "work in progress" "${LOG_FILE}"; then
        ERROR_CATEGORY="GERRIT_WIP"
    elif grep -q "negative reviews" "${LOG_FILE}"; then
        ERROR_CATEGORY="GERRIT_NEGATIVE_REVIEW"
    elif grep -q "Conflict.*commit" "${LOG_FILE}"; then
        ERROR_CATEGORY="GERRIT_CONFLICT"
    elif grep -iq "outdated.*rebase\|rebase.*outdated" "${LOG_FILE}"; then
        ERROR_CATEGORY="GERRIT_OUTDATED"
    elif grep -q -iE "no such patch set|patch set.*not found" "${LOG_FILE}"; then
        ERROR_CATEGORY="GERRIT_PATCHSET_NOT_FOUND"
    elif grep -q -iE "Could not read from remote repository" "${LOG_FILE}"; then
        ERROR_CATEGORY="SSH_CONNECTION_FAILED"
    elif grep -q "Permission denied\|Host key verification" "${LOG_FILE}"; then
        ERROR_CATEGORY="SSH_PERMISSION"
    elif grep -q -iE "unable to access.*git.*(503|504|404|500)" "${LOG_FILE}"; then
        ERROR_CATEGORY="INCORRECT_GIT_ADDRESS"
    elif grep -q -iE "(git clone|git fetch|repo init|repo sync).*(error|fatal)" "${LOG_FILE}"; then
        ERROR_CATEGORY="GIT_REPO_ERROR"
    elif grep -iq "timeout" "${LOG_FILE}"; then
        ERROR_CATEGORY="TIMEOUT"
    fi

    echo "  Error Type: ${ERROR_CATEGORY}"
    echo ""
else
    # Python 스크립트 실패가 아닌 경우 기존 분류
    log YELLOW "Root Cause: Non-Python Error"

    if grep -q -iE "(git clone|git fetch|repo sync|repo init).*(error|fatal|failed)" "${LOG_FILE}"; then
        ERROR_CATEGORY="GIT_REPO_ERROR"
    elif grep -q -iE "(Could not read from remote repository|Permission denied|Host key verification|Connection refused)" "${LOG_FILE}"; then
        ERROR_CATEGORY="SSH_PERMISSION"
    elif grep -q -iE "(timed out|timeout|TIMEOUT)" "${LOG_FILE}"; then
        ERROR_CATEGORY="TIMEOUT"
    else
        ERROR_CATEGORY="UNKNOWN"
        UNDETECTED_FLAG=1
    fi

    echo "  Error Type: ${ERROR_CATEGORY}"
    echo ""
fi


## Step 2: Gerrit Change 정보
bar YELLOW "Step 2: Gerrit change information"

# Gerrit change URL 추출 (http://vgit.lge.com/.../.../+/[번호] 형태)
GERRIT_URL=$(grep -oE "http://vgit.lge.com/[^/]+/c/.+/\+/[0-9]+" "${LOG_FILE}" | head -1)
if [ -n "${GERRIT_URL}" ]; then
    echo "Change URL: ${GERRIT_URL}"

    # Abandoned 상태 확인
    ABANDONED_MSG=$(grep -A 2 "\[Error\].*Permalink" "${LOG_FILE}" | grep "status.*abandoned" || true)
    if [ -n "${ABANDONED_MSG}" ]; then
        log RED "  Status: ABANDONED (verify build does not operate)"
        echo ""
    fi

    # Project, Branch 정보
    PROJECT=$(grep -oP 'git project: \K[^\s]+' "${LOG_FILE}" | head -1 || true)
    BRANCH=$(grep -oP 'git branch: \K[^\s]+' "${LOG_FILE}" | head -1 || true)
    [ -n "${PROJECT}" ] && echo "  Project: ${PROJECT}"
    [ -n "${BRANCH}" ] && echo "  Branch: ${BRANCH}"
    echo ""
else
    echo "No Gerrit change found\n"
fi


## Step 3: Error Details
bar YELLOW "Step 3: Error Details"

if [ -n "${PYTHON_SCRIPT}" ]; then
    # Python 스크립트 에러 상세 정보
    EXIT_CODE=$(grep -oP "exit code: \K[0-9]+" "${LOG_FILE}" | tail -1)
    [ -n "${EXIT_CODE}" ] && log RED "Exit Code: ${EXIT_CODE}"

    # Gerrit 관련 에러인 경우 Change URL 출력
    if [[ "${ERROR_CATEGORY}" =~ ^GERRIT ]]; then
        GERRIT_CHANGE=$(grep -oE "http://vgit.lge.com/.*/\+/[0-9]+" "${LOG_FILE}" | head -1)
        [ -n "${GERRIT_CHANGE}" ] && echo "Gerrit Change: ${GERRIT_CHANGE}"
    fi

    # 에러 메시지 출력 (GERRIT 관련 에러는 항상 표시)
    if [[ "${ERROR_CATEGORY}" =~ ^GERRIT ]]; then
        ERROR_MSG=$(grep -A 3 "\[Error\]" "${LOG_FILE}" | head -10)
        if [ -n "${ERROR_MSG}" ]; then
            echo -e "\n${RED}Error Message:${NC}"
            echo "${ERROR_MSG}"
        fi
    elif ERROR_MSG=$(grep -A 5 "\[Error\]" "${LOG_FILE}" | head -15); [ -n "${ERROR_MSG}" ]; then
        echo -e "\n${RED}Error Message:${NC}"
        echo "${ERROR_MSG}"
    fi
    echo ""

else
    # Non-Python 에러 상세 정보
    case "${ERROR_CATEGORY}" in
        GIT_REPO_ERROR)
            GIT_ERROR=$(grep -iE "(git clone|git fetch|repo sync).*(error|fatal|failed)" "${LOG_FILE}" | head -5)
            log RED "Git/Repo Error Details:"
            echo "${GIT_ERROR}"
            ;;
        SSH_PERMISSION)
            SSH_ERROR=$(grep -iE "(Permission denied|Host key verification|Connection refused)" "${LOG_FILE}" | head -5)
            log RED "SSH/Permission Error Details:"
            echo "${SSH_ERROR}"
            ;;
        TIMEOUT)
            TIMEOUT_ERROR=$(grep -iE "(timed out|timeout|TIMEOUT)" "${LOG_FILE}" | head -5)
            log RED "Timeout Error Details:"
            echo "${TIMEOUT_ERROR}"
            ;;
        *)
            log YELLOW "No specific error pattern detected"
            ;;
    esac
    echo ""
fi

# 미검출 에러 로깅
if [ "$UNDETECTED_FLAG" -eq 1 ]; then
    UNDETECTED_LOG="/tmp/undetected_errors.log"
    BUILD_NUM=$(echo "${PARAM1}" | grep -oE "[0-9]+/?$" | tr -d '/')

    {
        echo "========================================"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Undetected Error Case"
        echo "Build: #${BUILD_NUM}"
        echo "URL: ${PARAM1}"
        echo "Result: ${BUILD_RESULT}"
        echo ""
        echo "Error counts - GIT:${ERRORS[GIT]} GERRIT:${ERRORS[GERRIT]} PYTHON:${ERRORS[PYTHON]} SSH:${ERRORS[SSH]} TIMEOUT:${ERRORS[TIMEOUT]} BUILDSTEP:${ERRORS[BUILDSTEP]}"
        echo ""
        echo "Sample errors (first 20 lines with 'error' keyword):"
        grep -i "error\|fatal\|failed" "${LOG_FILE}" | head -20
        echo "========================================"
        echo ""
    } >> "${UNDETECTED_LOG}"

    log YELLOW "Undetected error logged to: ${UNDETECTED_LOG}"
    exit 3
fi

## Step 4: 실패 지점 컨텍스트
bar YELLOW "Step 4: Failure context"

# exception_handler 호출 지점 찾기
# 우선순위: [Error] in python 메시지 > ERROR/FATAL 키워드 in git/repo
ERROR_LINE=$(grep -n "\[Error\]" "${LOG_FILE}" | tail -1)
[ -z "${ERROR_LINE}" ] && ERROR_LINE=$(grep -n -Ei "ERROR|FATAL" "${LOG_FILE}" | grep -v "jenkins" | tail -1)

if [ -n "${ERROR_LINE}" ]; then
    line_num=$(echo "${ERROR_LINE}" | cut -d: -f1)
    log YELLOW "=== Error at line ${line_num} ==="
    start=$((line_num-5))
    end=$((line_num+10))

    # 각 라인을 순회하면서 JSON이면 jq로 포맷팅, 아니면 그대로 출력
    line_count=0
    while IFS= read -r line; do
        line_count=$((line_count+1))

        # 타임스탬프 제거 후 JSON 데이터 추출
        json_content=$(echo "$line" | grep -oP '^\d{2}:\d{2}:\d{2}\s+\K\{.*' || true)

        # JSON 데이터 포맷팅
        if [ -z "$json_content" ] || echo "$json_content" | grep -q '"type":"stats"'; then
            echo "$line"
        else
            # Gerrit change JSON 포맷팅
            printf "owner:\n"
            echo "$json_content" | jq -cC '.owner'

            echo "commitMessage:"
            commit_msg=$(echo "$json_content" | jq -r '.commitMessage // ""')
            echo -e "${GREEN}${commit_msg}${NC}"

            echo "$json_content" | jq -C '{
              project, branch, id, number, subject, url, open, status,
              createdOn: (.createdOn | strftime("%Y-%m-%d %H:%M:%S")),
              lastUpdated: (.lastUpdated | strftime("%Y-%m-%d %H:%M:%S"))
            }'

           # 2. 상세 정보 (각 항목을 1줄씩 출력)
            printf "currentPatchSet:\n"
            echo "$json_content" | jq -cC '.currentPatchSet | {number, revision, ref, createdOn, kind}'
            echo "$json_content" | jq -cC '.currentPatchSet.uploader'
            echo "$json_content" | jq -cC '.currentPatchSet.author'
            printf "currentPatchSet> approvals[]:\n"
            echo "$json_content" | jq -cC '.currentPatchSet.approvals[]?'

            printf "dependsOn:\n"
            echo "$json_content" | jq -cC '.dependsOn[]?'

            printf "submitRecords> status: "
            echo "$json_content" | jq -cC '.submitRecords[].status'
            printf "submitRecords> labels[]:\n"
            echo "$json_content" | jq -cC '.submitRecords[].labels[]?'

            printf "allReviewers:\n"
            echo "$json_content" | jq -cC '.allReviewers[]?'
        fi
    done < <(sed -n "${start},${end}p" "${LOG_FILE}")

    echo ""
fi


rm -f "${LOG_FILE}"
log BLUE "Analysis complete!"
exit 0