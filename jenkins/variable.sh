#!/bin/bash
#
# 변수 관리 유틸리티 스크립트
# - 다중 변수를 파일로 export/import 및 출력하는 기능 제공
# - defineVariable_export: ARR 배열에 정의된 변수들을 파일에 저장
# - defineVariable_import: 파일에서 변수들을 읽어와 현재 환경에 로드
# - defineVariable_print: 파일에 저장된 변수들을 포맷팅하여 출력
# - Jenkins와 같이 shell이 별도로 실행되는 환경에서 변수를 /tmp dir아래나 

# jenkins에서 호출될때
if [[ -n "${JOB_URL}" ]]; then
    BUILTIN_JOB_NAME=$(echo "${JOB_URL##*job/}" | cut -d'/' -f1)
else #jenkins가 아닌곳 호출될때
    BUILTIN_JOB_NAME="sharevar"
fi
BUILTIN_BACKUP_FILE="/tmp/${BUILTIN_JOB_NAME}"
BUILTIN_WORKSP_FILE="${HOME}/workspace/${JOB_BASE_NAME}_${BUILTIN_JOB_NAME}"


function download_from_jenkins(){
#----------------------------------------------------------------------------------------------------------
# Jenkins workspace에서 파일을 wget으로 다운로드
# 입력: $1 - 저장할 로컬 파일 경로
# 출력: 다운로드 성공 시 0, 실패 시 1 반환
    local dest_file="$1"
    
    if [[ -z "${JOB_URL}" ]]; then
        return 1
    fi
    
    local jenkins_server=$(echo "${JOB_URL}" | grep -oP 'jenkins\d+')
    # local auth_key=""

    # case "$jenkins_server" in
    #     jenkins01) auth_key="118d9b5fb8fd571a0b710e7121152a4c41" ;;
    #     jenkins02) auth_key="11cec21c35fb88f5d9abc591d844e22532" ;;
    #     jenkins03) auth_key="1115aa9663a20801980e2ab969028d3b46" ;;
    #     jenkins06) auth_key="11cec21c35fb88f5d9abc591d844e22532" ;;
    #     *) return 1 ;;
    # esac

    local job_name="${BUILTIN_JOB_NAME}"
    local url="http://vjenkins.lge.com/${jenkins_server}/job/${job_name}/ws/${BUILTIN_JOB_NAME}"
    
    #wget -q -O "$dest_file" --user=vc.integrator --password="$auth_key" "$url" 2>/dev/null
    wget -q -O "$dest_file" --user=vc.integrator --password="$auth_key" "$url" 2>/dev/null
    return $?
}

function defineVariable_export(){
#----------------------------------------------------------------------------------------------------------
# 선언된 ARR 배열의 변수들을 key=value 형식으로 BUILTIN_BACKUP_FILE과 BUILTIN_WORKSP_FILE 두 곳에 무조건 저장
# 입력: 저장 파일명 (없어도 됨)
# 출력: 파일에 변수 저장 (각 줄은 "변수명=이스케이프된값" 형식)
    local content=$(for var in "${ARR[@]%%=*}"; do printf "%s=%q\n" "$var" "${!var}"; done)
    mkdir -p "$(dirname "$BUILTIN_WORKSP_FILE")" 2>/dev/null
    echo "$content" > "$BUILTIN_BACKUP_FILE"
    echo "$content" > "$BUILTIN_WORKSP_FILE"
}

function defineVariable_import(){
#----------------------------------------------------------------------------------------------------------
# 파일에서 변수를 불러와 현재 환경에 로드
# - local server /tmp dir (BUILTIN_BACKUP_FILE) 우선, 없으면 Jenkins에서 wget으로 다운로드 (즉 workspace에서 download)
# 입력: 변수를 가져올 파일 (default: BUILTIN_BACKUP_FILE 또는 Jenkins에서 다운로드)
# 출력: 파일의 모든 변수 로드
    local src="$1"
    local tmp=$(mktemp)
    
    if [[ -z "$src" ]]; then
        src="$BUILTIN_BACKUP_FILE"
        [[ -f "$src" ]] || { local downloaded=$(mktemp); download_from_jenkins "$downloaded" && src="$downloaded"; }
    fi
    
    [[ -f "$src" ]] && { sed '/"/!s/#.*//' "$src" > "$tmp"; source "$tmp"; }
    rm -f "$tmp"
}

function defineVariable_print(){
#----------------------------------------------------------------------------------------------------------
# 파일에 저장된 변수들을 포맷팅하여 출력
# - 파일이 없거나 비어있으면 "No variables found in file" 메시지 출력
# - 변수명은 15자 고정폭으로 좌측 정렬하여 깔끔하게 출력
# - BUILTIN_BACKUP_FILE 우선, 없으면 Jenkins에서 wget으로 다운로드
# 입력: $1 - 파일 경로 (기본값: BUILTIN_BACKUP_FILE 또는 Jenkins에서 다운로드)
# 출력: 변수명과 값을 "변수명          = 값" 형식으로 표준 출력
    local infile="$1"
    
    if [[ -z "$infile" ]]; then
        infile="$BUILTIN_BACKUP_FILE"
        [[ -f "$infile" ]] || { local downloaded=$(mktemp); download_from_jenkins "$downloaded" && infile="$downloaded"; }
    fi
    
    if [[ -f "$infile" ]] && [[ -s "$infile" ]]; then
        echo "=== Defined Variables from $infile ==="
        while IFS='=' read -r var value; do
            [[ -z "$var" || "$var" =~ ^[[:space:]]*# ]] && continue
            printf "%-15s = %s\n" "$var" "$value"
        done < "$infile"
    else
        echo "No variables found in file: $infile"
    fi
}
