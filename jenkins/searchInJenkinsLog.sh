#!/bin/bash
# searchInJenkinsLog.sh - Download Jenkins build logs and optionally search for patterns
# Usage: MATCH_COUNT=0 RANGE="1-24" searchInJenkinsLog.sh [job_url] [search_string]

# ==================== 설정 ====================
PARAM1="$1";
# URL에서 빌드 번호 제거하고 https를 http로 변환(인증 불필요)
[[ $PARAM1 =~ ^(http.*jenkins\.lge\.com.*/job/[^/]+) ]] && JOB_URL="${BASH_REMATCH[1]}" || JOB_URL="${PARAM1%/}"
JOB_URL="${JOB_URL/https:\/\/vjenkins/http:\/\/vjenkins}"

# 검색 문자열
SEARCH_STRING="$2"

JOB_NAME=$(echo "$JOB_URL" | grep -oP 'job/\K[^/]+$' | head -1)
OUTPUT_DIR="~/workspace/searchJobLog/${JOB_NAME}"

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

# 3일 지난 디렉토리 삭제
find /tmp/searchJobLog -maxdepth 1 -type d -mtime +3 ! -path /tmp/searchJobLog -exec rm -rf {} \; 2>/dev/null

# 출력 디렉토리 생성 (기존 파일은 유지)
mkdir -p "$OUTPUT_DIR"

# 빌드 번호 가져오기 (RANGE 변수 또는 API)
if [[ -n "$RANGE" ]]; then
    # RANGE 변수가 설정된 경우 (예: RANGE="1-24" 또는 RANGE="24")
    echo "Using RANGE: $RANGE"
    if [[ "$RANGE" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        # 범위 형식 (예: "1-24")
        start_build="${BASH_REMATCH[1]}"
        end_build="${BASH_REMATCH[2]}"
        BUILD_NUMBERS=$(seq "$start_build" "$end_build")
    elif [[ "$RANGE" =~ ^[0-9]+$ ]]; then
        # 단일 숫자 형식 (예: "24")
        BUILD_NUMBERS="$RANGE"
    else
        echo "Error: Invalid RANGE format. Use 'start-end' or 'number' (e.g., RANGE=\"1-24\" or RANGE=\"24\")" >&2
        exit 1
    fi
else
    # RANGE가 없으면 API에서 가져오기
    echo "Fetching build list from API..."
    BUILD_LIST=$(wget --no-check-certificate -q -O - "${JOB_URL%/}/api/json")
    [[ -z "$BUILD_LIST" ]] && { echo "Error: Failed to fetch build list. Check URL." >&2; exit 1; }

    # 빌드 번호들을 추출 (builds 배열에서 number 필드만 추출, 중복 제거)
    BUILD_NUMBERS=$(echo "$BUILD_LIST" | grep -oP '"number":\s*\K[0-9]+' | sort -n | uniq)
    [[ -z "$BUILD_NUMBERS" ]] && { echo "Error: No builds found" >&2; exit 1; }

    # RANGE가 설정되지 않은 경우 실제 빌드 번호 범위로 설정
    FIRST_BUILD=$(echo "$BUILD_NUMBERS" | head -1)
    LAST_BUILD=$(echo "$BUILD_NUMBERS" | tail -1)
    [[ "$FIRST_BUILD" == "$LAST_BUILD" ]] && RANGE="$FIRST_BUILD" || RANGE="$FIRST_BUILD-$LAST_BUILD"

fi

TOTAL_BUILDS=$(echo "$BUILD_NUMBERS" | wc -l)
printf "Found $TOTAL_BUILDS builds\n"



# 각 빌드 로그 다운로드
success=0 failed=0 skipped=0 MATCH_COUNT=0
while read -r build_num; do
    output_file="$OUTPUT_DIR/build_${build_num}.log"
    # 이미 다운로드된 빌드는 건너뛰기
    if [ -s "$output_file" ]; then
        echo "  Build #${build_num}: ⊙ Skip (already exists)"
        ((success++))
        ((skipped++))
        continue
    fi
    download_build_log "$build_num" "$output_file" && ((success++)) || ((failed++))
done <<< "$BUILD_NUMBERS"

# 검색 기능
if [ -n "$SEARCH_STRING" ] && [ "$success" -gt 0 ]; then
    echo ""
    echo "Searching for '$SEARCH_STRING' in downloaded logs..."
    SEARCH_RESULT="$OUTPUT_DIR/search_results.txt"

    # RANGE가 설정된 경우 해당 범위의 파일만 검색
    if [[ -n "$RANGE" ]]; then
        SEARCH_FILES=""
        while read -r build_num; do
            log_file="$OUTPUT_DIR/build_${build_num}.log"
            [[ -f "$log_file" ]] && SEARCH_FILES="$SEARCH_FILES $log_file"
        done <<< "$BUILD_NUMBERS"
    else
        SEARCH_FILES="$OUTPUT_DIR/*.log"
    fi

    # 먼저 고정 문자열로 검색 (특수문자 그대로)
    grep -F -n --color=always "$SEARCH_STRING" $SEARCH_FILES 2>/dev/null | sed "s|$OUTPUT_DIR/||g" > "$SEARCH_RESULT"
    MATCH_COUNT=$(wc -l < "$SEARCH_RESULT")
    if (( $MATCH_COUNT > 1 )); then
        echo "  ✓ Found $MATCH_COUNT matches (fixed string)"
        echo "  Results saved: $SEARCH_RESULT"
    else
        echo "  ✗ Matches is under 10 ($MATCH_COUNT found), retry with REGEXP"
        echo "---------------------------- retry with REGEXP -----------------------" >> $SEARCH_RESULT
        # 정규식으로 재검색 (결과 추가)
        grep -n --color=always "$SEARCH_STRING" $SEARCH_FILES 2>/dev/null | sed "s|$OUTPUT_DIR/||g" >> "$SEARCH_RESULT"
        MATCH_COUNT=$(wc -l < "$SEARCH_RESULT")
        echo "  ✓ Total $MATCH_COUNT matches (with regex)"
    fi
fi

printf "\n\n\n=== Jenkins Build Log Result ==="
echo "  Job: $JOB_NAME"
echo "  URL: $JOB_URL"
echo "  RANGE: $RANGE"
echo "  Keyword: '$SEARCH_STRING'"
echo "  Total log: $TOTAL_BUILDS (Downloaded: $success, reused: $skipped, Failed: $failed)"
echo "  Logs saved in: $OUTPUT_DIR"
echo ""
echo "=== search result: Match count: $MATCH_COUNT==="
cat $OUTPUT_DIR/search_results.txt 2>/dev/null