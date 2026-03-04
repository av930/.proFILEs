#!/bin/bash
set -euo pipefail

# URL 접속 테스트 스크립트
# 사용법: test_url_access.sh <URL 1> <URL 2> ... <URL N>

# 색상 정의
readonly COLOR_GREEN="\033[92m\033[1m"
readonly COLOR_RED="\033[91m\033[1m"
readonly COLOR_YELLOW="\033[93m\033[1m"
readonly COLOR_RESET="\033[0m"

# 결과 출력 함수
printr() {
    local status="$1"
    local message="$2"

    case "${status}" in
        OK)   echo -e "${COLOR_GREEN}[OKAY]${COLOR_RESET} ${message}"
     ;; FAIL) echo -e "${COLOR_RED}[FAIL]${COLOR_RESET} ${message}"
     ;; WARN) echo -e "${COLOR_YELLOW}[WARN]${COLOR_RESET} ${message}"
    esac
}

# URL에서 호스트 추출
extract_host() {
    local url="$1"
    echo "${url}" | sed -e 's|^https\?://||' -e 's|/.*$||'
}

# URL 프로토콜 확인
is_https() {
    local url="$1"
    [[ "${url}" =~ ^https:// ]] && return 0 || return 1
}

# DNS 조회 테스트
test_dns() {
    local host="$1"

    printf "\n=== 1. DNS 조회 테스트 ===\n"

    local dns_result
    dns_result=$(nslookup "${host}" 2>&1) || true

    if echo "${dns_result}" | grep -q "Address:";
    then local ip=$(echo "${dns_result}" | grep -A1 "Name:" | grep "Address:" | head -1 | awk '{print $2}' || echo "N/A")
         printr "OK" "DNS 조회 성공: ${host} → ${ip}";  return 0
    else printr "FAIL" "DNS 조회 실패: ${host}";         return 1
    fi
}

# Ping 테스트
test_ping() {
    local host="$1"

    printf "\n=== 2. Ping 테스트 ===\n"

    local ping_result
    ping_result=$(ping -c 2 -W 3 "${host}" 2>&1) || true

    if echo "${ping_result}" | grep -q "bytes from";
    then local avg_time=$(echo "${ping_result}" | tail -1 | awk -F'/' '{print $5}' || echo "N/A")
         printr "OK" "Ping 성공: ${avg_time}ms";      return 0
    else printr "WARN" "Ping 실패 (ICMP 차단 가능)"; return 0
    fi
}

# SSL Handshake 테스트
test_ssl() {
    local host="$1"
    local url="$2"
    local port="${3:-443}"

    printf "\n=== 3. SSL/TLS Handshake 테스트 ===\n"

    # HTTP URL은 SSL 테스트 스킵
    if ! is_https "${url}";
    then printr "WARN" "HTTP URL - SSL 테스트 불필요"; return 0
    fi

    local result
    result=$(timeout 5 openssl s_client -connect "${host}:${port}" -servername "${host}" </dev/null 2>&1) || true

    if echo "${result}" | grep -q "Verify return code: 0 (ok)";
    then if echo "${result}" | grep -q "Cipher is (NONE)";
         then printr "FAIL" "SSL Handshake 실패: Cipher가 협상되지 않음";  return 1
         else local cipher=$(echo "${result}" | grep "Cipher" | head -1 | sed 's/.*Cipher is //' || echo "N/A")
              printr "OK" "SSL Handshake 성공: ${cipher}";                  return 0
         fi
    elif echo "${result}" | grep -qE "Verify return code: (19|20|21|27)";
    then printr "WARN" "SSL 인증서 검증 실패 (사설 인증서 또는 자체 서명)";  return 0
    else printr "FAIL" "SSL 인증서 검증 실패 또는 연결 실패";                  return 1
    fi
}

# HTTP 연결 테스트
test_http() {
    local url="$1"

    printf "\n=== 4. HTTP/HTTPS 연결 테스트 ===\n"

    local curl_output
    curl_output=$(curl -s -S -I -k --max-time 10 "${url}" 2>&1)
    local curl_exit=$?

    if [ ${curl_exit} -eq 0 ];
    then local http_code=$(echo "${curl_output}" | head -1 | awk '{print $2}' || echo "N/A")
         printr "OK" "HTTP 연결 성공: ${http_code}"
         echo "${curl_output}" | head -5 | grep -E "HTTP|Server|Date" | sed 's/^/    /' || true; return 0
    else case ${curl_exit} in
             6) printr "FAIL" "DNS 조회 실패 (Could not resolve host)"
                return 1
          ;; 7) printr "FAIL" "연결 실패 (Failed to connect)"
                return 1
          ;; 28) printr "FAIL" "연결 시간 초과 (Connection timeout)"
                return 1
          ;; 35) printr "FAIL" "SSL Handshake 중단 (방화벽/프록시 차단 가능성)"
                echo "${curl_output}" | grep "error:" | sed 's/^/    /' || true
                return 1
          ;; 60) printr "WARN" "SSL 인증서 검증 실패 (사설 인증서 - 연결은 성공)"
                local http_code=$(echo "${curl_output}" | grep "HTTP" | head -1 | awk '{print $2}' || echo "확인불가")
                echo "    HTTP 코드: ${http_code}"
                return 0
          ;; *) printr "FAIL" "HTTP 연결 실패 (curl exit code: ${curl_exit})"
                echo "${curl_output}" | tail -3 | sed 's/^/    /' || true
                return 1
         esac
    fi
}

# 상세 진단 정보
test_detailed() {
    local url="$1"
    local host="$2"

    local tls_ver
    tls_ver=$(timeout 5 curl -s -v --max-time 5 "${url}" 2>&1 | grep "SSL connection" | sed 's/.*SSL connection using //' | head -1 || echo "N/A")

    local http_proto
    http_proto=$(timeout 5 curl -s -I --max-time 5 "${url}" 2>&1 | head -1 | awk '{print $1}' || echo "N/A")

    local redirect
    redirect=$(timeout 5 curl -s -I -L --max-time 5 "${url}" 2>&1 | grep "HTTP" | wc -l | tr -d ' \n' || echo "0")
    redirect=${redirect:-0}

    local redirect_msg="없음"
    [ ${redirect} -gt 1 ] && redirect_msg="있음 (${redirect}번)"

    printf "\n=== 5. 상세 진단 정보 ===\n"
    printf "  - TLS 버전 확인: %s\n  - HTTP 프로토콜: %s\n  - 리다이렉션: %s\n" \
           "${tls_ver}" "${http_proto}" "${redirect_msg}"
}

# 단일 URL 테스트 함수
test_single_url() {
    local url="$1"
    local host=$(extract_host "${url}")

    printf "========================================\nURL 접속 테스트\n========================================\n대상 URL: %s\n대상 호스트: %s\n" \
           "${url}" "${host}"

    local test_pass=0
    local test_fail=0

    test_dns "${host}" && test_pass=$((test_pass + 1)) || test_fail=$((test_fail + 1))
    test_ping "${host}" && test_pass=$((test_pass + 1)) || test_fail=$((test_fail + 1))
    test_ssl "${host}" "${url}" && test_pass=$((test_pass + 1)) || test_fail=$((test_fail + 1))
    test_http "${url}" && test_pass=$((test_pass + 1)) || test_fail=$((test_fail + 1))
    test_detailed "${url}" "${host}"

    printf "\n========================================\n테스트 결과 요약\n========================================\n"
    printf "성공: ${COLOR_GREEN}%d${COLOR_RESET} / 실패: ${COLOR_RED}%d${COLOR_RESET}\n" "${test_pass}" "${test_fail}"

    if [ ${test_fail} -eq 0 ];
    then echo ""
         printr "OK" "모든 테스트 통과 - URL 접속 가능"; return 0
    elif [ ${test_pass} -ge 2 ] && [ ${test_fail} -le 2 ];
    then printr "WARN" "일부 테스트 실패 - 방화벽/프록시 차단 가능성"
         printf "\n권장 조치:\n  1. TeraTerm SSH Port Forwarding 사용\n  2. VPN 연결 시도\n  3. 네트워크 관리자에게 문의\n"; return 1
    else echo ""
         printr "FAIL" "대부분 테스트 실패 - 네트워크 문제";               return 1
    fi
}

# 메인 함수
main() {
    if [ $# -eq 0 ];
    then printf "사용법: %s <URL1> [URL2] [URL3] ...\n예제: %s https://keep.google.com/u/0/#home\n      %s https://www.google.com https://gmail.com\n" \
              "$0" "$0" "$0"
         exit 1
    fi

    local total_urls=$#
    local current=0
    local fail_count=0

    for url in "$@"; do
        current=$((current + 1))

        if [ ${total_urls} -gt 1 ];
        then printf "\n[%d/%d] URL 테스트\n###############################################################\n" \
                  "${current}" "${total_urls}"
        fi

        test_single_url "${url}" || fail_count=$((fail_count + 1))
    done

    printf "\n"
    exit ${fail_count}
}

main "$@"
