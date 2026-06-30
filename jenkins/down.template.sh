#!/bin/bash
set +xe  # 에러 무시 모드로 시작

format_display_ip() {
    local input_value="$1" old_ifs="$IFS" octets=()

    [[ "$input_value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "$input_value"; return; }
    IFS='.' read -r -a octets <<< "$input_value"
    IFS="$old_ifs"
    printf '%3s.%3s.%3s.%3s\n' "${octets[0]}" "${octets[1]}" "${octets[2]}" "${octets[3]}"
}
## getIP
display_ip=$(format_display_ip "10.159.30.66")



readonly C_YELLOW='\033[1;33m' C_GREEN='\033[1;32m' C_RED='\033[1;31m' C_RESET='\033[0m'

## 다운로드 스크립트 저장
download_file() { 
    local file="${1##*/}"
    
    if   wget -O "$file" "http://10.159.30.66:8000/$1"; then
         printf "${C_YELLOW}%s${C_RESET}\n" "Downloaded from http://10.159.30.66:8000"
    elif wget -O "$file" "https://raw.githubusercontent.com/av930/.proFILEs/master/$1"; then
         printf "${C_GREEN}%s${C_RESET}\n" "Downloaded from github"
    else printf "${C_RED}%s${C_RESET}\n" "Error: Download failed from both 10.159.30.66 and github"
         return 1
    fi
    [ -s "$file" ] && chmod 755 "$file" || { echo "Error: File is empty."; return 1; }
    [ "$(wc -l < "$file")" -lt 10 ] && { echo "Error: File is too small Less than 10 lines."; return 1; }
    return 0
}

#####################################
## 여기서 부터 main script 실행
SCRIPT=build/analyzeBuildTime.sh
download_file "${SCRIPT}" || exit 1

## prameter 체크
[ -z "$PARAM1" ] && { echo "need to jenkins build url as parameter" ; exit 1; }

# script실행 및 결과 처리 (자식 process에서 실행처리)
./${SCRIPT##*/} "$PARAM1" 
##결과값에 따른 처리
#에러시  if [ $? -ne 0 ]; then   ~; fi
#성공시  if [ $? -eq 0 ]; then   ~; fi


## build description 변경(기본 log를 보여주도록 설정)
# displayName에 적당한 변수추가 필요
# description에 build log url과 PARAM1의 결과값을 보여주도록 설정함
# log종류: console, consoleFull, consoleText, /timestamps/?time=HH:mm:ss&timeZone=GMT+9&appendLog
curl -sX POST -u $USER:$API_KEY ${JOB_URL}/$BUILD_NUMBER/configSubmit -F   \
   'json={"displayName":"'"${BUILD_NUMBER} "'", "description":"'"<A href=${JOB_URL}${BUILD_NUMBER}/console> >>>  open build log</A><BR>${PARAM1}"'"}' > /dev/null
