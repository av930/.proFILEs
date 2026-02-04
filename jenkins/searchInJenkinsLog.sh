#!/bin/bash
# searchInJenkinsLog.sh - Download Jenkins build logs and optionally search for patterns
# Usage: searchInJenkinsLog.sh [job_url] [search_string]

# ==================== 설정 ====================
PARAM1="$1"
# URL에서 빌드 번호 제거하고 https를 http로 변환(인증 불필요)
[[ $PARAM1 =~ ^(http.*jenkins\.lge\.com.*/job/[^/]+) ]] && JOB_URL="${BASH_REMATCH[1]}" || JOB_URL="${PARAM1%/}"
JOB_URL="${JOB_URL/https:\/\/vjenkins/http:\/\/vjenkins}"

# 검색 문자열
SEARCH_STRING="$2"

JOB_NAME=$(echo "$JOB_URL" | grep -oP 'job/\K[^/]+$' | head -1)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="/tmp/jenkins_logs_${JOB_NAME}_${TIMESTAMP}"

# ==================== 함수 ====================
download_build_log() {
    local build_number=$1
    local output_file=$2
    local log_url="${JOB_URL%/}/${build_number}/consoleText"

    echo "  Downloading build #${build_number}..."
    # wget으로 다운로드
    wget --no-check-certificate -q -O "$output_file" "$log_url"
    local exit_code=$?

    # 다운로드 성공 및 파일이 비어있지 않은지 확인
    if [ $exit_code -eq 0 ] && [ -s "$output_file" ];
    then printf "✓ Saved ($(du -h "$output_file" | cut -f1))"; return 0
    else rm -f "$output_file"; printf "✗ Failed(build may not available)"; return 1;
    fi
}

# ==================== 메인 로직 ====================

# 출력 디렉토리 생성
mkdir -p "$OUTPUT_DIR"

# 현재존재하는 빌드번호 가져오기 (Jenkins 환경변수 or API)
echo "Fetching build list from API..."
BUILD_LIST=$(wget --no-check-certificate -q -O - "${JOB_URL%/}/api/json")
if [ -z "$BUILD_LIST" ]; then echo "Error: Failed to fetch build list. Check URL." >&2; exit 1; fi

# 빌드 번호들을 추출 (builds 배열에서 number 필드만 추출, 중복 제거)
BUILD_NUMBERS=$(echo "$BUILD_LIST" | grep -oP '"number":\s*\K[0-9]+' | sort -n | uniq)
if [ -z "$BUILD_NUMBERS" ]; then echo "Error: No builds found" >&2; exit 1; fi

TOTAL_BUILDS=$(echo "$BUILD_NUMBERS" | wc -l)
printf "Found $TOTAL_BUILDS builds\n"

# 각 빌드 로그 다운로드
success=0 failed=0
while read -r build_num; do
    output_file="$OUTPUT_DIR/build_${build_num}.log"
    download_build_log "$build_num" "$output_file" && ((success++)) || ((failed++))
done <<< "$BUILD_NUMBERS"

# 검색 기능
if [ -n "$SEARCH_STRING" ] && [ "$success" -gt 0 ]; then
    echo ""
    echo "Searching for '$SEARCH_STRING' in downloaded logs..."
    SEARCH_RESULT="$OUTPUT_DIR/search_results.txt"
    grep -n "$SEARCH_STRING" "$OUTPUT_DIR"/*.log > "$SEARCH_RESULT" 2>/dev/null

    if [ -s "$SEARCH_RESULT" ]; then
        MATCH_COUNT=$(wc -l < "$SEARCH_RESULT")
        echo "  ✓ Found $MATCH_COUNT matches"
        echo "  Results saved: $SEARCH_RESULT"
    else
        echo "  ✗ No matches found"
        rm -f "$SEARCH_RESULT"
    fi
fi

echo "=== Jenkins Build Log Downloader ==="
echo "  Job: $JOB_NAME"
echo "  URL: $JOB_URL"
echo "  Search: '$SEARCH_STRING'"
echo "  Total builds: $TOTAL_BUILDS, Downloaded: $success, Failed: $failed"
echo "  Logs saved in: $OUTPUT_DIR"
echo ""
echo "=== search result ==="
cat $OUTPUT_DIR/search_results.txt
