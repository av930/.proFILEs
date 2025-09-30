#!/bin/bash
#서버 실행방법: nohup bash mcp_server.sh &
#서버 호출방법: @bash-mcp tool-jenkins 부분의 tool을 정의한다.
#서버 추가방법: ((++PORT)); MCP=mcp_handler_hello.sh 포함 3라인 추가

PORT=8000                               # 8001부터 할당
PATH_ROOT="$(dirname "$0")/.."          # core path기준
PATH_LOG="${PATH_ROOT}/log"             # log dir이하 저장
mkdir -p "$PATH_LOG"
log() { echo "[$(date '+%F %T')] $*"; }

trap 'rm -rf "$PATH_LOG"' EXIT

############################################ main ############################################
log "=== MCP bash Server Starting on port $PORT ==="
log "Starting socat listeners with multi-client support..."

# 포트 8001, 8002에 다중 클라이언트 동시 처리
((++PORT)); MCP=mcp_handler_hello.sh
socat TCP-LISTEN:${PORT},bind=0.0.0.0,reuseaddr,fork,max-children=100 EXEC:"$PATH_ROOT/$MCP" 2>&1 | tee -a "$PATH_LOG/${MCP/.sh/.log}" &
log "$MCP handler started on port ${PORT} with PID: $!"

((++PORT)); MCP=mcp_handler_retrigger.sh
socat TCP-LISTEN:${PORT},bind=0.0.0.0,reuseaddr,fork,max-children=100 EXEC:"$PATH_ROOT/$MCP" 2>&1 | tee -a "$PATH_LOG/${MCP/.sh/.log}" &
log "$MCP handler started on port ${PORT} with PID: $!"

#...
log "All services started. Waiting for processes..."
# 백그라운드 프로세스들이 종료될 때까지 대기, 부모 process임.
wait