#!/bin/bash
# Jenkins Build History에서 _CMScript_FAIL 패턴을 build name과 description에서 찾는 스크립트

JOB_URL="$1"
SEARCH_PATTERN="$2"

# JOB_NAME 추출
JOB_NAME=$(echo "$JOB_URL" | grep -oP 'job/\K[^/]+$' | head -1)
PATH_OUTPUT="$HOME/workspace/searchJobName/${JOB_NAME}"

# 3일 지난 디렉토리 삭제
find "$HOME/workspace/searchJobName" -maxdepth 1 -type d -mtime +3 ! -path "$HOME/workspace/searchJobName" -exec rm -rf {} \; 2>/dev/null

# 출력 디렉토리 생성
mkdir -p "$PATH_OUTPUT"

# MAX_BUILDS가 지정되지 않으면 전체 빌드 수를 동적으로 가져오기
MAX_BUILDS=$(wget --no-check-certificate -q -O - "${JOB_URL}/api/json?tree=lastBuild[number]" | jq -r '.lastBuild.number // 1000')

echo "==================================================="
echo "Jenkins Build Search (Name & Description)"
echo "==================================================="
echo "Job: ${JOB_NAME}"
echo "Job URL: ${JOB_URL}"
echo "Search Pattern: ${SEARCH_PATTERN}"
echo "Max Builds to Check: ${MAX_BUILDS}"
echo "Output Dir: ${PATH_OUTPUT}"
echo ""

# Jenkins API로 빌드 목록 가져오기 (displayName과 description 포함) - allBuilds 사용
echo "Fetching build list with displayName and description..."
wget --no-check-certificate -q -O "${PATH_OUTPUT}/jenkins_builds.json" "${JOB_URL}/api/json?tree=allBuilds[number,displayName,description,result]{0,${MAX_BUILDS}}"

if [ ! -s "${PATH_OUTPUT}/jenkins_builds.json" ]; then
    echo "Failed to fetch builds"
    exit 1
fi

total=$(jq '.allBuilds | length' "${PATH_OUTPUT}/jenkins_builds.json")
echo "Total builds fetched: ${total}"
echo ""
echo "Searching for '${SEARCH_PATTERN}' in build names and descriptions..."
echo "---------------------------------------------------"

# jq로 displayName 또는 description에 패턴이 포함된 빌드 필터링 (모든 상태 포함, URL만 출력)
jq -r --arg pattern "${SEARCH_PATTERN}" --arg job_url "${JOB_URL}" '
  .allBuilds[] |
  select(
    (.displayName // "" | contains($pattern)) or
    (.description // "" | contains($pattern))
  ) |
  "\($job_url)/\(.number)/"
' "${PATH_OUTPUT}/jenkins_builds.json" > "${PATH_OUTPUT}/matched_build_urls.txt"

matched=$(wc -l < "${PATH_OUTPUT}/matched_build_urls.txt")

if [ "$matched" -gt 0 ]; then
    echo "✓ Found ${matched} matching builds:"
    echo ""
    cat "${PATH_OUTPUT}/matched_build_urls.txt"
else
    echo "No matching builds found."
fi

echo ""
echo "---------------------------------------------------"
echo "Search complete. Total matches: ${matched}"
echo "Results saved to: ${PATH_OUTPUT}/matched_build_urls.txt"
