#!/bin/bash
# jenkins-download-logs.sh - Download all build logs from Jenkins job
# Usage: jenkins-download-logs.sh [job_url] [output_dir] [username] [api_token]

# ==================== 설정 ====================
JOB_URL="$1"
OUTPUT_DIR="${2:-./jenkins_logs}"
JENKINS_USER="${3:-${USER}}"
JENKINS_TOKEN="${4:-${JENKINS_TOKEN}}"

# 인증 설정
if [ -n "$JENKINS_USER" ] && [ -n "$JENKINS_TOKEN" ]; then AUTH_OPTS="-u ${JENKINS_USER}:${JENKINS_TOKEN}"; fi

# ==================== 함수 ====================
get_job_name() { echo "$JOB_URL" | grep -oP 'job/[^/]+' | cut -d'/' -f2; }
download_build_log() {
    local build_number=$1 output_file=$2 log_url="${JOB_URL%/}/${build_number}/consoleText"
    echo "  Downloading build #${build_number}..."
    if curl -f -s ${AUTH_OPTS} "$log_url" -o "$output_file" 2>/dev/null;
    then echo "    ✓ Saved ($(du -h "$output_file" | cut -f1))"; return 0;
    else rm -f "$output_file"; echo "    ✗ Failed (log may not exist)"; return 1;
    fi
}

# ==================== 메인 로직 ====================
JOB_NAME=$(get_job_name)
API_URL="${JOB_URL%/}/api/json"

echo "=== Jenkins Build Log Downloader ==="
echo "  Job: $JOB_NAME"
echo "  URL: $JOB_URL"
echo "  Output: $OUTPUT_DIR"
echo ""

# 출력 디렉토리 생성
mkdir -p "$OUTPUT_DIR"

# 빌드 리스트 가져오기
echo "Fetching build list..."
BUILD_LIST=$(curl -s ${AUTH_OPTS} "$API_URL")
if [ -z "$BUILD_LIST" ]; then echo "Error: Failed to fetch build list. Check URL and credentials." >&2; exit 1; fi

# 빌드 번호 추출 (builds 배열에서 number 필드만 추출)
BUILD_NUMBERS=$(echo "$BUILD_LIST" | grep -oP '"number":\s*\K[0-9]+' | sort -n)
if [ -z "$BUILD_NUMBERS" ]; then echo "Error: No builds found" >&2; exit 1; fi

TOTAL_BUILDS=$(echo "$BUILD_NUMBERS" | wc -l)
echo "Found $TOTAL_BUILDS builds"
echo ""

# 각 빌드 로그 다운로드
success=0 failed=0 skipped=0
while read -r build_num; do
    output_file="$OUTPUT_DIR/build_${build_num}.log"
    download_build_log "$build_num" "$output_file" && ((success++)) || ((failed++))
done <<< "$BUILD_NUMBERS"

echo ""
echo "=== Summary ==="
echo "  Total builds: $TOTAL_BUILDS"
echo "  Downloaded: $success"
echo "  Skipped: $skipped"
echo "  Failed: $failed"
echo ""
echo "Logs saved in: $(realpath "$OUTPUT_DIR")"
