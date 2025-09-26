#!/bin/bash

# 서버 설정
HOST="0.0.0.0"
PORT="8000"
HANDLER_SCRIPT="$(dirname "$0")/mcp_handler.sh"
LOG_FILE="$(dirname "$0")/mcp.log"

# 로그 파일 생성 (truncate 하지 않음)
touch "$LOG_FILE"

echo "[$(date '+%F %T')] Starting MCP server on $HOST:$PORT..." | tee -a "$LOG_FILE"

# socat을 사용하여 들어오는 연결을 수신하고 핸들러 스크립트로 전달합니다.
# TCP-LISTEN: TCP 포트에서 수신 대기합니다.
# fork: 각 연결에 대해 새 프로세스를 생성합니다.
# reuseaddr: 주소를 즉시 재사용할 수 있도록 합니다.
# EXEC: 핸들러 스크립트를 실행합니다.
while true; do
  socat -T300 TCP-LISTEN:${PORT},reuseaddr,fork EXEC:"bash ${HANDLER_SCRIPT}" 2>> "$LOG_FILE"
  echo "[$(date '+%F %T')] socat process stopped. Restarting in 2 seconds..." >> "$LOG_FILE"
  sleep 2
done
