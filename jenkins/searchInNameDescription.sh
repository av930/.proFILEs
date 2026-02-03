#!/bin/bash
# Jenkins Build History에서 _CMScript_FAIL 패턴을 build name과 description에서 찾는 스크립트

JOB_URL="$1"
SEARCH_PATTERN="$2"

# MAX_BUILDS가 지정되지 않으면 전체 빌드 수를 동적으로 가져오기
MAX_BUILDS=$(wget --no-check-certificate -q -O - "${JOB_URL}/api/json?tree=lastBuild[number]" | jq -r '.lastBuild.number // 1000')

echo "==================================================="
echo "Jenkins Build Search (Name & Description)"
echo "==================================================="
echo "Job URL: ${JOB_URL}"
echo "Search Pattern: ${SEARCH_PATTERN}"
echo "Max Builds to Check: ${MAX_BUILDS}"
echo ""

# Jenkins API로 빌드 목록 가져오기 (displayName과 description 포함) - allBuilds 사용
echo "Fetching build list with displayName and description..."
wget --no-check-certificate -q -O /tmp/jenkins_builds.json "${JOB_URL}/api/json?tree=allBuilds[number,displayName,description,result]{0,${MAX_BUILDS}}"

if [ ! -s /tmp/jenkins_builds.json ]; then
    echo "Failed to fetch builds"
    exit 1
fi

total=$(jq '.allBuilds | length' /tmp/jenkins_builds.json)
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
' /tmp/jenkins_builds.json > /tmp/matched_build_urls.txt

matched=$(wc -l < /tmp/matched_build_urls.txt)

if [ "$matched" -gt 0 ]; then
    echo "✓ Found ${matched} matching builds:"
    echo ""
    cat /tmp/matched_build_urls.txt
else
    echo "No matching builds found."
fi

echo ""
echo "---------------------------------------------------"
echo "Search complete. Total matches: ${matched}"
echo "URLs saved to: /tmp/matched_build_urls.txt"
