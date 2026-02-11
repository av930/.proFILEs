#!/bin/bash -e

[ -z "$1" ] && { echo "Usage: $0 <jenkins_build_url>" >&2; exit 1; }

BUILD_URL="$1"
JENKINS_CLI_JAR="${JENKINS_CLI_JAR:-$HOME/jenkins-cli.jar}"
USERNAME="${JENKINS_USER:-vc.integrator}"
PASSWORD="${JENKINS_PASSWORD:-UUmF3ZYZofW1JqRwEFe4g1tHbs1hLoVuVVKrxpvG0g}"

# jenkins-cli.jar 존재 확인 및 다운로드
if [ ! -f "$JENKINS_CLI_JAR" ]; then
    echo "Downloading jenkins-cli.jar..." >&2
    wget -qO "$JENKINS_CLI_JAR" http://vjenkins.lge.com/jenkins03/jnlpJars/jenkins-cli.jar || {
        echo "Error: Failed to download jenkins-cli.jar" >&2
        exit 1
    }
    echo "Downloaded to $JENKINS_CLI_JAR" >&2
fi

# URL 파싱: Jenkins 서버 URL 추출
JENKINS_SERVER=$(echo "$BUILD_URL" | grep -oP '^https?://[^/]+/[^/]+')

# Job 경로 추출 (view 및 /job/ 처리)
JOB_PATH=$(echo "$BUILD_URL" | sed -E 's|^https?://[^/]+/[^/]+/||; s|/buildWithParameters.*||; s|view/[^/]+/||; s|/job/|/|g; s|^job/||')

# Parameters 추출
PARAMS=$(echo "$BUILD_URL" | grep -oP 'buildWithParameters\?\K.*' | tr '&' '\n' | grep -v '^token=' | sed 's/^/-p /')

# Jenkins CLI 실행
BUILD_OUTPUT=$(java -jar "$JENKINS_CLI_JAR" \
    -s "$JENKINS_SERVER" \
    -auth "$USERNAME:$PASSWORD" \
    build "$JOB_PATH" $PARAMS -s -v 2>&1)

# 빌드 URL 추출
BUILD_NUMBER=$(echo "$BUILD_OUTPUT" | grep -oP 'Started.*#\K[0-9]+' || echo "$BUILD_OUTPUT" | grep -oP '#\K[0-9]+' | head -1)

if [ -n "$BUILD_NUMBER" ]; then
    echo "${JENKINS_SERVER}/job/${JOB_PATH//\//%2F}/${BUILD_NUMBER}/"
    exit 0
else
    echo "Error: Failed to get build number" >&2
    echo "$BUILD_OUTPUT" >&2
    exit 1
fi
