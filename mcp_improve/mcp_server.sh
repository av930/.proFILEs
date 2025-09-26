#!/bin/bash
#실행방법: nohup bash mcp_server.sh &

TEMP_DIR="/tmp/bash-mcp"
F_LOG="$TEMP_DIR/mcp_server.log"
mkdir -p "$TEMP_DIR"
trap 'rm -rf "$TEMP_DIR"' EXIT

PORT=8002
HANDLER="$(dirname "$0")/mcp_handler_hello.sh"

log() { echo "[$(date '+%F %T')] $*" >> "$F_LOG"; }
log "=== MCP Improved Server Starting on port $PORT ==="

true > "$F_LOG"
while true; do
    log "Starting socat listener..."
    socat TCP-LISTEN:$PORT,reuseaddr,fork EXEC:"$HANDLER" 2>&1 | tee -a "$F_LOG"   #1
    #2...서비스가 다른 handler는 다른 port로 지정하여 구동
    #3...
    log "Server stopped, restarting in 2 seconds..."
    sleep 2
done